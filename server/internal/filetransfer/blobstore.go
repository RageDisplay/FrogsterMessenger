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

// ErrNotOwner is returned when someone other than the uploader tries to
// delete a blob.
var ErrNotOwner = errors.New("not the owner of this blob")

// BlobStore persists opaque byte streams.
type BlobStore interface {
	// Create opens a writer for a new blob owned by owner and returns its
	// id.
	Create(owner string) (id string, w io.WriteCloser, err error)

	// Owner reports who uploaded a blob. Blobs stored before ownership was
	// recorded have no owner, reported as "".
	Owner(id string) (string, error)

	// Sweep removes blobs older than maxAge and reports how many went.
	Sweep(maxAge time.Duration) (int, error)

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
//
// The owner is recorded in a sidecar file next to the blob. It is the only
// metadata kept: who uploaded, never what or for whom.
func (s *FileBlobStore) Create(owner string) (string, io.WriteCloser, error) {
	id := uuid.NewString()
	path := s.pathFor(id)

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", nil, fmt.Errorf("create blob shard: %w", err)
	}
	if err := os.WriteFile(path+ownerSuffix, []byte(owner), 0o600); err != nil {
		return "", nil, fmt.Errorf("record blob owner: %w", err)
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
	_ = os.Remove(s.pathFor(id) + ownerSuffix)
	return nil
}

// Owner implements BlobStore.
func (s *FileBlobStore) Owner(id string) (string, error) {
	if !validBlobID(id) {
		return "", ErrBlobNotFound
	}
	if _, err := os.Stat(s.pathFor(id)); err != nil {
		if os.IsNotExist(err) {
			return "", ErrBlobNotFound
		}
		return "", fmt.Errorf("stat blob: %w", err)
	}
	owner, err := os.ReadFile(s.pathFor(id) + ownerSuffix)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read blob owner: %w", err)
	}
	return string(owner), nil
}

// Sweep implements BlobStore. Age is taken from the file's modification
// time, which is when the upload finished writing it.
func (s *FileBlobStore) Sweep(maxAge time.Duration) (int, error) {
	cutoff := time.Now().Add(-maxAge)
	removed := 0
	err := filepath.WalkDir(s.root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !validBlobID(d.Name()) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil // removed concurrently
		}
		if info.ModTime().Before(cutoff) {
			if err := s.Remove(d.Name()); err == nil {
				removed++
			}
		}
		return nil
	})
	if err != nil {
		return removed, fmt.Errorf("sweep blobs: %w", err)
	}
	return removed, nil
}

// ownerSuffix names the sidecar file holding a blob's uploader. A blob id is
// a bare UUID, so the sidecar can never be mistaken for a blob.
const ownerSuffix = ".owner"

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
//
// Only the canonical form the store hands out is accepted: uuid.Parse also
// takes "urn:uuid:...", braces and undashed hex, none of which should ever
// reach a file name.
func validBlobID(id string) bool {
	parsed, err := uuid.Parse(id)
	return err == nil && parsed.String() == id
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

// BlobTTL bounds how long an attachment survives.
//
// Retention is capped because the server holds ciphertext it can never read:
// keeping it forever grows a store of material that is only ever a liability.
const BlobTTL = 30 * 24 * time.Hour
