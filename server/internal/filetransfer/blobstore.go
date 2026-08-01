// Package filetransfer serves encrypted attachments over gRPC.
//
// The service handles ciphertext exclusively: clients encrypt a file with a
// fresh AES-256-GCM key before uploading and share that key inside the chat
// message's encrypted payload. Nothing here can decrypt a blob, and nothing
// here learns a file's name, type, or contents.
package filetransfer

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"
)

// ErrBlobNotFound is returned for an unknown or expired blob id.
var ErrBlobNotFound = errors.New("blob not found")

// BlobStore persists opaque byte streams.
type BlobStore interface {
	// Create opens a writer for a new blob and returns its id.
	Create() (id string, w io.WriteCloser, err error)

	// Open returns a reader over a stored blob and its size.
	Open(id string) (r io.ReadCloser, size int64, err error)

	// Remove deletes a blob.
	Remove(id string) error

	// Size reports a blob's stored length.
	Size(id string) (int64, error)
}

// FileBlobStore stores blobs on the local filesystem.
//
// Blob ids are random UUIDs rather than derived from content or uploader:
// a predictable id would let anyone who guesses one fetch the ciphertext,
// and a content-derived id would let an observer confirm that two users
// uploaded the same file.
type FileBlobStore struct {
	root string
}

// NewFileBlobStore prepares a store rooted at dir.
func NewFileBlobStore(dir string) (*FileBlobStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create blob directory: %w", err)
	}
	return &FileBlobStore{root: dir}, nil
}

// Create implements BlobStore.
func (s *FileBlobStore) Create() (string, io.WriteCloser, error) {
	id := uuid.NewString()
	path := s.pathFor(id)

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", nil, fmt.Errorf("create blob shard: %w", err)
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", nil, fmt.Errorf("create blob file: %w", err)
	}
	return id, f, nil
}

// Open implements BlobStore.
func (s *FileBlobStore) Open(id string) (io.ReadCloser, int64, error) {
	if !validBlobID(id) {
		return nil, 0, ErrBlobNotFound
	}

	f, err := os.Open(s.pathFor(id))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, 0, ErrBlobNotFound
		}
		return nil, 0, fmt.Errorf("open blob: %w", err)
	}

	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, 0, fmt.Errorf("stat blob: %w", err)
	}
	return f, info.Size(), nil
}

// Remove implements BlobStore.
func (s *FileBlobStore) Remove(id string) error {
	if !validBlobID(id) {
		return ErrBlobNotFound
	}
	if err := os.Remove(s.pathFor(id)); err != nil {
		if os.IsNotExist(err) {
			return ErrBlobNotFound
		}
		return fmt.Errorf("remove blob: %w", err)
	}
	return nil
}

// Size implements BlobStore.
func (s *FileBlobStore) Size(id string) (int64, error) {
	if !validBlobID(id) {
		return 0, ErrBlobNotFound
	}
	info, err := os.Stat(s.pathFor(id))
	if err != nil {
		if os.IsNotExist(err) {
			return 0, ErrBlobNotFound
		}
		return 0, fmt.Errorf("stat blob: %w", err)
	}
	return info.Size(), nil
}

// pathFor shards blobs by the first two characters of their id, so a single
// directory does not accumulate millions of entries.
func (s *FileBlobStore) pathFor(id string) string {
	return filepath.Join(s.root, id[:2], id)
}

// validBlobID rejects anything that is not a UUID.
//
// This is a path-traversal guard as much as a format check: an id like
// "../../etc/passwd" reaching filepath.Join would escape the blob root.
func validBlobID(id string) bool {
	if len(id) < 3 {
		return false
	}
	_, err := uuid.Parse(id)
	return err == nil
}

// digestWriter tees writes into a SHA-256 hash while counting bytes, so the
// upload can be verified and measured without a second pass over the data.
type digestWriter struct {
	dst    io.Writer
	hash   hashWriter
	writen int64
}

type hashWriter interface {
	io.Writer
	Sum(b []byte) []byte
}

func newDigestWriter(dst io.Writer) *digestWriter {
	return &digestWriter{dst: dst, hash: sha256.New()}
}

func (w *digestWriter) Write(p []byte) (int, error) {
	n, err := w.dst.Write(p)
	if n > 0 {
		w.hash.Write(p[:n])
		w.writen += int64(n)
	}
	return n, err
}

func (w *digestWriter) Digest() []byte { return w.hash.Sum(nil) }
func (w *digestWriter) Written() int64 { return w.writen }

// blobTTL bounds how long an attachment survives.
//
// Retention is capped because the server holds ciphertext it can never read:
// keeping it forever grows a store of material that is only ever a liability.
const blobTTL = 30 * 24 * time.Hour
