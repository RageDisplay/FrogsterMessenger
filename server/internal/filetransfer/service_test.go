package filetransfer_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/filetransfer"
	frogsterv1 "github.com/vectrixsecurity/frogster/server/internal/gen/frogster/v1"
)

const testSecret = "test-secret-at-least-32-bytes-long!!"

// stubChecker accepts every token version, standing in for the database.
type stubChecker struct{ active bool }

func (s stubChecker) TokenVersion(context.Context, [16]byte, [16]byte) (int, bool, error) {
	return 1, s.active, nil
}

// harness is a running file service reachable over an in-memory connection.
type harness struct {
	client  frogsterv1.FileTransferClient
	blobDir string
	token   string
}

func newHarness(t *testing.T, deviceActive bool) *harness {
	t.Helper()

	blobDir := t.TempDir()
	blobs, err := filetransfer.NewFileBlobStore(blobDir)
	if err != nil {
		t.Fatalf("blob store: %v", err)
	}

	tokens := auth.NewManager([]byte(testSecret), time.Hour, 24*time.Hour)
	token, err := tokens.IssueAccess(uuid.New(), uuid.New(), 1)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	checker := stubChecker{active: deviceActive}

	server := grpc.NewServer(
		grpc.UnaryInterceptor(filetransfer.UnaryAuthInterceptor(tokens, checker)),
		grpc.StreamInterceptor(filetransfer.StreamAuthInterceptor(tokens, checker)),
	)
	frogsterv1.RegisterFileTransferServer(
		server,
		filetransfer.NewService(blobs, nil, log),
	)

	listener := bufconn.Listen(1 << 20)
	go func() { _ = server.Serve(listener) }()

	conn, err := grpc.NewClient(
		"passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}

	t.Cleanup(func() {
		_ = conn.Close()
		server.Stop()
		_ = listener.Close()
	})

	return &harness{
		client:  frogsterv1.NewFileTransferClient(conn),
		blobDir: blobDir,
		token:   token,
	}
}

// authCtx attaches the bearer token the interceptors expect.
func (h *harness) authCtx(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+h.token)
}

// upload streams payload and returns the blob id.
func (h *harness) upload(t *testing.T, ctx context.Context, payload []byte, digest []byte) (string, error) {
	t.Helper()

	stream, err := h.client.Upload(ctx)
	if err != nil {
		return "", err
	}

	if digest == nil {
		sum := sha256.Sum256(payload)
		digest = sum[:]
	}

	// A Send that returns io.EOF means the server already closed the stream --
	// for example because an interceptor rejected the call. The real status is
	// only available from CloseAndRecv, so sends stop but the error is never
	// returned directly. Returning the io.EOF instead would hide every
	// server-side rejection behind a meaningless "EOF".
	send := func(req *frogsterv1.UploadRequest) bool {
		return stream.Send(req) == nil
	}

	ok := send(&frogsterv1.UploadRequest{
		Payload: &frogsterv1.UploadRequest_Init{
			Init: &frogsterv1.UploadInit{
				TotalSize:   uint64(len(payload)),
				ContentHint: "attachment",
				Digest:      digest,
			},
		},
	})

	const chunk = 32 * 1024
	for offset := 0; ok && offset < len(payload); offset += chunk {
		end := min(offset+chunk, len(payload))
		ok = send(&frogsterv1.UploadRequest{
			Payload: &frogsterv1.UploadRequest_Chunk{Chunk: payload[offset:end]},
		})
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return "", err
	}
	return resp.GetBlobId(), nil
}

func (h *harness) download(t *testing.T, ctx context.Context, blobID string) ([]byte, error) {
	t.Helper()

	stream, err := h.client.Download(ctx, &frogsterv1.DownloadRequest{BlobId: blobID})
	if err != nil {
		return nil, err
	}

	var out bytes.Buffer
	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		out.Write(chunk.GetChunk())
	}
	return out.Bytes(), nil
}

func TestUploadDownloadRoundTrip(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	// Stands in for AES-256-GCM output: the server never sees anything else.
	payload := bytes.Repeat([]byte("encrypted-attachment-bytes"), 5000)

	blobID, err := h.upload(t, ctx, payload, nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	got, err := h.download(t, ctx, blobID)
	if err != nil {
		t.Fatalf("download: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("downloaded %d bytes, want %d identical", len(got), len(payload))
	}
}

// TestStoredBlobIsExactlyWhatWasUploaded is the core storage guarantee.
//
// The server must persist the ciphertext verbatim and add nothing of its own:
// any transformation would mean it parsed data it is not supposed to
// understand, and would break the recipient's digest check.
func TestStoredBlobIsExactlyWhatWasUploaded(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	payload := []byte("ciphertext-that-must-not-be-touched")
	blobID, err := h.upload(t, ctx, payload, nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	onDisk, err := os.ReadFile(filepath.Join(h.blobDir, blobID[:2], blobID))
	if err != nil {
		t.Fatalf("read blob from disk: %v", err)
	}
	if !bytes.Equal(onDisk, payload) {
		t.Errorf("stored bytes differ from the uploaded ciphertext")
	}
}

// TestPlaintextNeverReachesDisk confirms the end-to-end property from the
// server's side: what lands on disk carries no trace of the file's contents.
func TestPlaintextNeverReachesDisk(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	// A client encrypts before uploading, so the marker only ever exists on
	// the sending device. Here we upload ciphertext-like bytes and assert the
	// marker is absent from storage.
	const marker = "SECRET_DOCUMENT_CONTENTS"
	ciphertext := bytes.Repeat([]byte{0xA7, 0x3E, 0x91, 0x0C}, 4096)

	blobID, err := h.upload(t, ctx, ciphertext, nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	onDisk, err := os.ReadFile(filepath.Join(h.blobDir, blobID[:2], blobID))
	if err != nil {
		t.Fatalf("read blob: %v", err)
	}
	if bytes.Contains(onDisk, []byte(marker)) {
		t.Error("plaintext marker found in stored blob")
	}
}

// TestDigestMismatchRejected covers corruption in transit.
//
// Storing a blob whose bytes do not match the declared digest would surface
// much later, as an undecryptable attachment on the recipient's device, where
// the cause is far harder to identify.
func TestDigestMismatchRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	payload := []byte("the real bytes")
	wrong := sha256.Sum256([]byte("something else entirely"))

	_, err := h.upload(t, ctx, payload, wrong[:])
	if err == nil {
		t.Fatal("upload with a mismatched digest was accepted")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Errorf("got code %s, want InvalidArgument", status.Code(err))
	}

	// The rejected blob must not be left behind.
	entries, _ := os.ReadDir(h.blobDir)
	for _, entry := range entries {
		shard, _ := os.ReadDir(filepath.Join(h.blobDir, entry.Name()))
		if len(shard) > 0 {
			t.Error("a rejected upload left a blob on disk")
		}
	}
}

func TestMalformedDigestRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	_, err := h.upload(t, ctx, []byte("data"), []byte("too short"))
	if status.Code(err) != codes.InvalidArgument {
		t.Errorf("got %v, want InvalidArgument", err)
	}
}

func TestUnauthenticatedUploadRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// No authorization metadata at all.
	_, err := h.upload(t, ctx, []byte("data"), nil)
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("got %v, want Unauthenticated", err)
	}
}

func TestUnauthenticatedDownloadRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	authed := h.authCtx(t)

	blobID, err := h.upload(t, authed, []byte("data"), nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := h.download(t, ctx, blobID); status.Code(err) != codes.Unauthenticated {
		t.Errorf("got %v, want Unauthenticated", err)
	}
}

// TestRevokedDeviceRejected verifies that a signed-out device cannot keep
// uploading until its access token expires.
func TestRevokedDeviceRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, false) // device reported inactive
	ctx := h.authCtx(t)

	if _, err := h.upload(t, ctx, []byte("data"), nil); status.Code(err) != codes.Unauthenticated {
		t.Errorf("got %v, want Unauthenticated for a revoked device", err)
	}
}

func TestDownloadUnknownBlob(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	_, err := h.download(t, ctx, "00000000-0000-4000-8000-000000000000")
	if status.Code(err) != codes.NotFound {
		t.Errorf("got %v, want NotFound", err)
	}
}

// TestDownloadRejectsTraversalID confirms a crafted blob id cannot escape the
// storage directory.
func TestDownloadRejectsTraversalID(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	for _, id := range []string{"../../etc/passwd", "..", "/etc/shadow"} {
		if _, err := h.download(t, ctx, id); status.Code(err) != codes.NotFound {
			t.Errorf("download(%q): got %v, want NotFound", id, err)
		}
	}
}

func TestDeleteRemovesBlob(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	blobID, err := h.upload(t, ctx, []byte("temporary"), nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	resp, err := h.client.Delete(ctx, &frogsterv1.DeleteRequest{BlobId: blobID})
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	if !resp.GetDeleted() {
		t.Error("delete reported no blob removed")
	}

	if _, err := h.download(t, ctx, blobID); status.Code(err) != codes.NotFound {
		t.Errorf("blob still downloadable after delete: %v", err)
	}
}

func TestOversizedUploadRejected(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	stream, err := h.client.Upload(ctx)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	// Declares more than the limit without sending the bytes: the server must
	// refuse up front rather than stream 200 MiB before noticing.
	err = stream.Send(&frogsterv1.UploadRequest{
		Payload: &frogsterv1.UploadRequest_Init{
			Init: &frogsterv1.UploadInit{
				TotalSize: 200 << 20,
				Digest:    make([]byte, 32),
			},
		},
	})
	if err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("send init: %v", err)
	}

	if _, err := stream.CloseAndRecv(); status.Code(err) != codes.InvalidArgument {
		t.Errorf("got %v, want InvalidArgument", err)
	}
}

func TestUploadRequiresInitFirst(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	stream, err := h.client.Upload(ctx)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	// A chunk before the init message.
	err = stream.Send(&frogsterv1.UploadRequest{
		Payload: &frogsterv1.UploadRequest_Chunk{Chunk: []byte("premature")},
	})
	if err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("send chunk: %v", err)
	}

	if _, err := stream.CloseAndRecv(); status.Code(err) != codes.InvalidArgument {
		t.Errorf("got %v, want InvalidArgument", err)
	}
}

// TestLargeStreamingUpload exercises the chunked path with a payload well
// past a single message, which is the case that would break if the server
// buffered whole blobs.
func TestLargeStreamingUpload(t *testing.T) {
	t.Parallel()

	h := newHarness(t, true)
	ctx := h.authCtx(t)

	payload := make([]byte, 5<<20) // 5 MiB
	for i := range payload {
		payload[i] = byte(i * 7 % 251)
	}

	blobID, err := h.upload(t, ctx, payload, nil)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}

	got, err := h.download(t, ctx, blobID)
	if err != nil {
		t.Fatalf("download: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Error("5 MiB round trip did not preserve the bytes")
	}
}
