package filetransfer

import (
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newStore(t *testing.T) *FileBlobStore {
	t.Helper()

	store, err := NewFileBlobStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func writeBlob(t *testing.T, store *FileBlobStore, data []byte) string {
	t.Helper()

	id, w, err := store.Create("owner-1")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := w.Write(data); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	return id
}

func TestBlobRoundTrip(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	payload := []byte("encrypted attachment bytes")
	id := writeBlob(t, store, payload)

	reader, size, err := store.Open(id)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer reader.Close()

	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != string(payload) {
		t.Errorf("got %q, want %q", got, payload)
	}
	if size != int64(len(payload)) {
		t.Errorf("size %d, want %d", size, len(payload))
	}
}

// TestBlobIDsAreUnpredictable guards the only access control a blob has.
//
// There is no per-blob ACL: the server cannot tell who a file was shared with,
// because the decryption key travels inside an end-to-end encrypted message it
// never sees. An id that could be guessed or derived from content would let an
// observer fetch ciphertext, or confirm that two users uploaded the same file.
func TestBlobIDsAreUnpredictable(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	payload := []byte("identical content")

	seen := make(map[string]struct{}, 50)
	for range 50 {
		id := writeBlob(t, store, payload)
		if _, dup := seen[id]; dup {
			t.Fatalf("blob id %s was reused", id)
		}
		seen[id] = struct{}{}
	}
}

// TestBlobIDValidationBlocksTraversal covers the path-traversal guard.
//
// Blob ids reach filepath.Join, so an id like "../../secrets" would escape the
// blob directory entirely.
func TestBlobIDValidationBlocksTraversal(t *testing.T) {
	t.Parallel()

	store := newStore(t)

	for _, id := range []string{
		"../../etc/passwd",
		"..",
		"/etc/shadow",
		"a/../../b",
		"",
		"x",
		"not-a-uuid",
		// Parseable as UUIDs, but not the form the store hands out.
		"urn:uuid:6ba7b810-9dad-11d1-80b4-00c04fd430c8",
		"{6ba7b810-9dad-11d1-80b4-00c04fd430c8}",
		"6ba7b8109dad11d180b400c04fd430c8",
		"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
	} {
		if _, _, err := store.Open(id); !errors.Is(err, ErrBlobNotFound) {
			t.Errorf("Open(%q) = %v, want ErrBlobNotFound", id, err)
		}
		if err := store.Remove(id); !errors.Is(err, ErrBlobNotFound) {
			t.Errorf("Remove(%q) = %v, want ErrBlobNotFound", id, err)
		}
	}
}

func TestBlobNotFound(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	// Well-formed but never created.
	const id = "00000000-0000-4000-8000-000000000000"

	if _, _, err := store.Open(id); !errors.Is(err, ErrBlobNotFound) {
		t.Errorf("got %v, want ErrBlobNotFound", err)
	}
}

func TestBlobRemove(t *testing.T) {
	t.Parallel()

	store := newStore(t)
	id := writeBlob(t, store, []byte("temporary"))

	if err := store.Remove(id); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, _, err := store.Open(id); !errors.Is(err, ErrBlobNotFound) {
		t.Errorf("blob still readable after removal: %v", err)
	}
	if err := store.Remove(id); !errors.Is(err, ErrBlobNotFound) {
		t.Errorf("second removal: got %v, want ErrBlobNotFound", err)
	}
}

// TestBlobsAreShardedOnDisk confirms blobs do not all land in one directory,
// which becomes pathological once there are millions of them.
func TestBlobsAreShardedOnDisk(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	store, err := NewFileBlobStore(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	id := writeBlob(t, store, []byte("x"))

	expected := filepath.Join(dir, id[:2], id)
	if _, err := os.Stat(expected); err != nil {
		t.Errorf("blob not stored at the sharded path %s: %v", expected, err)
	}
}

// TestBlobFilesAreNotWorldReadable checks the on-disk permissions.
//
// A blob is ciphertext, but it is still material the operator should not be
// exposing to every account on the host.
func TestBlobFilesAreNotWorldReadable(t *testing.T) {
	if os.PathSeparator == '\\' {
		t.Skip("POSIX permission bits are not meaningful on Windows")
	}
	t.Parallel()

	dir := t.TempDir()
	store, err := NewFileBlobStore(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	id := writeBlob(t, store, []byte("secret ciphertext"))

	info, err := os.Stat(filepath.Join(dir, id[:2], id))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Errorf("blob mode %o allows group or other access", perm)
	}
}

func TestDigestWriterMatchesSHA256(t *testing.T) {
	t.Parallel()

	var sink strings.Builder
	w := newDigestWriter(&sink)

	payload := []byte("stream me in pieces")
	for _, chunk := range [][]byte{payload[:5], payload[5:12], payload[12:]} {
		if _, err := w.Write(chunk); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	want := sha256.Sum256(payload)
	if got := w.Digest(); string(got) != string(want[:]) {
		t.Error("digest does not match a single-pass SHA-256 of the same bytes")
	}
	if w.Written() != int64(len(payload)) {
		t.Errorf("written %d, want %d", w.Written(), len(payload))
	}
	if sink.String() != string(payload) {
		t.Error("bytes were altered on their way to the underlying writer")
	}
}

// TestSweepRemovesOnlyExpiredBlobs: expired blobs go, together with their
// owner sidecar; fresh ones stay.
func TestSweepRemovesOnlyExpiredBlobs(t *testing.T) {
	t.Parallel()
	store := newStore(t)

	old := writeBlob(t, store, []byte("old ciphertext"))
	fresh := writeBlob(t, store, []byte("fresh ciphertext"))

	past := time.Now().Add(-40 * 24 * time.Hour)
	if err := os.Chtimes(store.pathFor(old), past, past); err != nil {
		t.Fatalf("backdate: %v", err)
	}

	n, err := store.Sweep(30 * 24 * time.Hour)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if n != 1 {
		t.Errorf("swept %d blobs, want 1", n)
	}
	if _, _, err := store.Open(old); !errors.Is(err, ErrBlobNotFound) {
		t.Errorf("expired blob still readable: %v", err)
	}
	if _, err := os.Stat(store.pathFor(old) + ownerSuffix); !os.IsNotExist(err) {
		t.Errorf("owner sidecar of a swept blob left behind: %v", err)
	}
	if _, _, err := store.Open(fresh); err != nil {
		t.Errorf("fresh blob was swept: %v", err)
	}
}

func TestBlobRecordsOwner(t *testing.T) {
	t.Parallel()
	store := newStore(t)

	id := writeBlob(t, store, []byte("x"))
	owner, err := store.Owner(id)
	if err != nil {
		t.Fatalf("owner: %v", err)
	}
	if owner != "owner-1" {
		t.Errorf("owner = %q, want owner-1", owner)
	}
}
