package filetransfer

import (
	"context"
	"crypto/subtle"
	"errors"
	"io"
	"log/slog"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	frogsterv1 "github.com/vectrixsecurity/frogster/server/internal/gen/frogster/v1"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
)

const (
	// maxBlobSize caps a single upload. Anything larger is a client bug or an
	// attempt to fill the disk.
	maxBlobSize = 100 << 20 // 100 MiB

	// downloadChunkSize bounds per-message memory on both sides. Streaming in
	// chunks is what keeps a 100 MiB transfer from costing 100 MiB of RAM.
	downloadChunkSize = 64 << 10
)

// Service implements the FileTransfer gRPC service.
type Service struct {
	frogsterv1.UnimplementedFileTransferServer

	blobs   BlobStore
	limiter ratelimit.Limiter
	log     *slog.Logger
}

// NewService builds the file transfer service.
func NewService(blobs BlobStore, limiter ratelimit.Limiter, log *slog.Logger) *Service {
	return &Service{blobs: blobs, limiter: limiter, log: log}
}

// Upload receives an encrypted blob.
//
// The stream must open with an init message and then carry only ciphertext.
// The server verifies the declared digest against what it actually received,
// so a truncated or corrupted upload is rejected rather than stored as a blob
// that will fail to decrypt later, when the cause is much harder to diagnose.
func (s *Service) Upload(stream frogsterv1.FileTransfer_UploadServer) error {
	ctx := stream.Context()

	claims, ok := ClaimsFrom(ctx)
	if !ok {
		return status.Error(codes.Unauthenticated, "missing credentials")
	}

	if s.limiter != nil {
		decision, err := s.limiter.Allow(ctx, "upload:"+claims.UserID.String(),
			ratelimit.RuleUpload, 1)
		if err == nil && !decision.Allowed {
			return status.Error(codes.ResourceExhausted, "upload quota exceeded")
		}
	}

	first, err := stream.Recv()
	if err != nil {
		return status.Error(codes.InvalidArgument, "expected an init message")
	}
	init := first.GetInit()
	if init == nil {
		return status.Error(codes.InvalidArgument, "first message must be init")
	}
	if init.GetTotalSize() > maxBlobSize {
		return status.Errorf(codes.InvalidArgument,
			"blob of %d bytes exceeds the %d byte limit",
			init.GetTotalSize(), maxBlobSize)
	}
	if len(init.GetDigest()) != 32 {
		return status.Error(codes.InvalidArgument, "digest must be 32 bytes")
	}

	blobID, writer, err := s.blobs.Create()
	if err != nil {
		s.log.Error("create blob", "err", err, "user_id", claims.UserID)
		return status.Error(codes.Internal, "could not store blob")
	}

	digested := newDigestWriter(writer)
	// Any failure past this point must not leave a partial blob behind.
	cleanup := func() {
		_ = writer.Close()
		_ = s.blobs.Remove(blobID)
	}

	for {
		msg, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			cleanup()
			return status.Error(codes.Aborted, "upload interrupted")
		}

		chunk := msg.GetChunk()
		if chunk == nil {
			cleanup()
			return status.Error(codes.InvalidArgument, "expected a chunk")
		}
		if digested.Written()+int64(len(chunk)) > maxBlobSize {
			cleanup()
			return status.Error(codes.InvalidArgument, "blob exceeds the size limit")
		}
		if _, err := digested.Write(chunk); err != nil {
			cleanup()
			s.log.Error("write blob", "err", err, "blob_id", blobID)
			return status.Error(codes.Internal, "could not store blob")
		}
	}

	if err := writer.Close(); err != nil {
		_ = s.blobs.Remove(blobID)
		s.log.Error("close blob", "err", err, "blob_id", blobID)
		return status.Error(codes.Internal, "could not store blob")
	}

	// Constant-time comparison: a timing side channel here would let an
	// attacker search for a digest that the server accepts.
	if subtle.ConstantTimeCompare(digested.Digest(), init.GetDigest()) != 1 {
		_ = s.blobs.Remove(blobID)
		return status.Error(codes.InvalidArgument,
			"digest does not match the uploaded bytes")
	}

	// Only sizes and identifiers are logged. The blob is ciphertext, and its
	// content hint is deliberately not the real MIME type.
	s.log.Info("blob stored",
		"blob_id", blobID,
		"user_id", claims.UserID,
		"device_id", claims.DeviceID,
		"bytes", digested.Written(),
	)

	return stream.SendAndClose(&frogsterv1.UploadResponse{
		BlobId:     blobID,
		StoredSize: uint64(digested.Written()),
		ExpiresAt:  time.Now().Add(blobTTL).Unix(),
	})
}

// Download streams a blob back to an authenticated caller.
//
// Access is by blob id alone, which is an unguessable random UUID. That is
// deliberate: the server cannot tell who a blob was shared with, because the
// decryption key travels inside an end-to-end encrypted message it never sees.
// Knowing the id conveys no ability to read the contents.
func (s *Service) Download(
	req *frogsterv1.DownloadRequest,
	stream frogsterv1.FileTransfer_DownloadServer,
) error {
	ctx := stream.Context()

	claims, ok := ClaimsFrom(ctx)
	if !ok {
		return status.Error(codes.Unauthenticated, "missing credentials")
	}

	reader, size, err := s.blobs.Open(req.GetBlobId())
	if err != nil {
		if errors.Is(err, ErrBlobNotFound) {
			return status.Error(codes.NotFound, "blob not found")
		}
		s.log.Error("open blob", "err", err, "blob_id", req.GetBlobId())
		return status.Error(codes.Internal, "could not read blob")
	}
	defer reader.Close()

	buf := make([]byte, downloadChunkSize)
	var offset uint64

	for {
		n, err := reader.Read(buf)
		if n > 0 {
			chunk := &frogsterv1.DownloadChunk{
				Chunk:     buf[:n],
				Offset:    offset,
				TotalSize: uint64(size),
			}
			if err := stream.Send(chunk); err != nil {
				return status.Error(codes.Aborted, "download interrupted")
			}
			offset += uint64(n)
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			s.log.Error("read blob", "err", err, "blob_id", req.GetBlobId())
			return status.Error(codes.Internal, "could not read blob")
		}
	}

	s.log.Info("blob served",
		"blob_id", req.GetBlobId(),
		"user_id", claims.UserID,
		"bytes", offset,
	)
	return nil
}

// Delete removes a blob.
func (s *Service) Delete(
	ctx context.Context,
	req *frogsterv1.DeleteRequest,
) (*frogsterv1.DeleteResponse, error) {
	claims, ok := ClaimsFrom(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing credentials")
	}

	if err := s.blobs.Remove(req.GetBlobId()); err != nil {
		if errors.Is(err, ErrBlobNotFound) {
			return &frogsterv1.DeleteResponse{Deleted: false}, nil
		}
		s.log.Error("remove blob", "err", err, "blob_id", req.GetBlobId())
		return nil, status.Error(codes.Internal, "could not delete blob")
	}

	s.log.Info("blob deleted", "blob_id", req.GetBlobId(), "user_id", claims.UserID)
	return &frogsterv1.DeleteResponse{Deleted: true}, nil
}
