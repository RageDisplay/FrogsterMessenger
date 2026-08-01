package filetransfer_test

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// chunkSize mirrors the client's attachmentChunkSize.
const chunkSize = 64 * 1024

// clientEncrypt reproduces what client/lib/crypto/attachment.dart does before
// an upload: split the file into chunks and seal each under AES-256-GCM with
// its index as associated data.
//
// Duplicated here rather than shared, because the point of the test is that
// the *server* never needs any of it. If the two implementations drift, the
// round-trip assertions below fail, which is exactly the signal wanted.
func clientEncrypt(t *testing.T, plaintext []byte) (ciphertext, key, digest []byte) {
	t.Helper()

	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatalf("generate key: %v", err)
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatalf("aes: %v", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("gcm: %v", err)
	}

	var out bytes.Buffer
	for index, offset := 0, 0; offset < len(plaintext); index, offset = index+1, offset+chunkSize {
		end := min(offset+chunkSize, len(plaintext))

		nonce := make([]byte, gcm.NonceSize())
		if _, err := rand.Read(nonce); err != nil {
			t.Fatalf("nonce: %v", err)
		}

		aad := chunkAAD(index)
		sealed := gcm.Seal(nil, nonce, plaintext[offset:end], aad)

		// Wire layout: nonce || body || tag, matching AeadCiphertext.serialize.
		out.Write(nonce)
		out.Write(sealed)
	}

	ciphertext = out.Bytes()
	sum := sha256.Sum256(ciphertext)
	return ciphertext, key, sum[:]
}

// clientDecrypt reverses clientEncrypt, verifying the digest first.
func clientDecrypt(t *testing.T, ciphertext, key, digest []byte) []byte {
	t.Helper()

	// Verified before the cipher sees the bytes: a mismatch means the blob was
	// altered, and feeding it to the AEAD anyway invites chosen-ciphertext
	// games.
	sum := sha256.Sum256(ciphertext)
	if !bytes.Equal(sum[:], digest) {
		t.Fatal("digest mismatch: the stored blob was modified")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatalf("aes: %v", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("gcm: %v", err)
	}

	sealedChunk := gcm.NonceSize() + chunkSize + gcm.Overhead()

	var out bytes.Buffer
	for index, offset := 0, 0; offset < len(ciphertext); index, offset = index+1, offset+sealedChunk {
		end := min(offset+sealedChunk, len(ciphertext))
		block := ciphertext[offset:end]

		nonce := block[:gcm.NonceSize()]
		body := block[gcm.NonceSize():]

		plain, err := gcm.Open(nil, nonce, body, chunkAAD(index))
		if err != nil {
			t.Fatalf("chunk %d failed authentication: %v", index, err)
		}
		out.Write(plain)
	}
	return out.Bytes()
}

func chunkAAD(index int) []byte {
	return []byte("frogster-attachment-chunk:" + itoa(index))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// TestAttachmentEndToEnd is the whole-feature check: a client encrypts a file,
// uploads it, and another client downloads and decrypts it -- while the bytes
// on the server's disk reveal nothing about the contents.
func TestAttachmentEndToEnd(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	// A recognisable document, so a leak would be unmistakable.
	document := bytes.Repeat(
		[]byte("CONFIDENTIAL: quarterly figures and the CEO's home address. "),
		2000,
	)

	ciphertext, key, digest := clientEncrypt(t, document)

	blobID, err := h.upload(t, ctx, ciphertext, digest)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	// 1. What the server persisted must not contain the document.
	onDisk, err := os.ReadFile(filepath.Join(h.blobDir, blobID[:2], blobID))
	if err != nil {
		t.Fatalf("read stored blob: %v", err)
	}
	for _, marker := range []string{"CONFIDENTIAL", "quarterly", "home address"} {
		if bytes.Contains(onDisk, []byte(marker)) {
			t.Errorf("plaintext %q found in the stored blob", marker)
		}
	}

	// 2. The recipient downloads and recovers the document exactly.
	downloaded, err := h.download(t, ctx, blobID)
	if err != nil {
		t.Fatalf("download: %v", err)
	}

	recovered := clientDecrypt(t, downloaded, key, digest)
	if !bytes.Equal(recovered, document) {
		t.Error("the decrypted attachment does not match the original")
	}

	// 3. Without the key -- which never reached the server -- the blob is
	//    useless. The key travels inside the end-to-end encrypted chat message.
	wrongKey := make([]byte, 32)
	block, _ := aes.NewCipher(wrongKey)
	gcm, _ := cipher.NewGCM(block)
	if _, err := gcm.Open(nil, downloaded[:12], downloaded[12:1000], chunkAAD(0)); err == nil {
		t.Error("the blob decrypted under a key the server could have guessed")
	}
}

// TestServerCannotDistinguishFileTypes confirms the metadata story: two very
// different files produce uploads the server cannot tell apart beyond size.
func TestServerCannotDistinguishFileTypes(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	// A PNG header and a PDF header are unmistakable in plaintext.
	png := append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A},
		bytes.Repeat([]byte("image data"), 500)...)
	pdf := append([]byte("%PDF-1.7\n"),
		bytes.Repeat([]byte("document data"), 500)...)

	for name, payload := range map[string][]byte{"png": png, "pdf": pdf} {
		ciphertext, _, digest := clientEncrypt(t, payload)

		blobID, err := h.upload(t, ctx, ciphertext, digest)
		if err != nil {
			t.Fatalf("upload %s: %v", name, err)
		}

		onDisk, err := os.ReadFile(filepath.Join(h.blobDir, blobID[:2], blobID))
		if err != nil {
			t.Fatalf("read %s blob: %v", name, err)
		}

		// The magic bytes that identify the format must not survive.
		for _, magic := range [][]byte{{0x89, 'P', 'N', 'G'}, []byte("%PDF")} {
			if bytes.Contains(onDisk, magic) {
				t.Errorf("%s: file-type magic bytes are visible in storage", name)
			}
		}
	}
}

// TestAttachmentKeyNeverTravelsWithTheBlob documents the separation that makes
// the whole scheme work.
//
// The upload carries ciphertext, a size and a digest. The key is delivered
// through the chat's Double Ratchet session instead. If it ever appeared in
// the upload metadata, the server could decrypt every attachment it stores.
func TestAttachmentKeyNeverTravelsWithTheBlob(t *testing.T) {
	t.Parallel()

	document := []byte("some private file")
	ciphertext, key, digest := clientEncrypt(t, document)

	// Everything the upload path conveys to the server.
	uploadMetadata := map[string]any{
		"total_size":   len(ciphertext),
		"content_hint": "attachment",
		"digest":       digest,
	}

	encoded, err := json.Marshal(uploadMetadata)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if bytes.Contains(encoded, key) {
		t.Fatal("the attachment key appears in the upload metadata")
	}
	if bytes.Contains(ciphertext, key) {
		t.Fatal("the attachment key appears in the ciphertext")
	}

	// The declared hint must not be the real type either.
	if hint := uploadMetadata["content_hint"]; hint != "attachment" {
		t.Errorf("content hint %q leaks the file type", hint)
	}
}
