// Command filed serves encrypted attachments over gRPC.
//
// It stores and returns opaque byte streams. Files are encrypted by the client
// before upload with a key delivered to recipients inside the end-to-end
// encrypted chat message, so this process cannot read anything it holds.
package main

import (
	"context"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/filetransfer"
	frogsterv1 "github.com/vectrixsecurity/frogster/server/internal/gen/frogster/v1"
	"github.com/vectrixsecurity/frogster/server/internal/logging"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := logging.New(cfg.Env, slog.LevelInfo)

	addr := env("FROGSTER_FILED_ADDR", ":8081")
	blobDir := env("FROGSTER_BLOB_DIR", "./data/blobs")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, cfg.DatabaseURL, log)
	if err != nil {
		return err
	}
	defer st.Close()

	blobs, err := filetransfer.NewFileBlobStore(blobDir)
	if err != nil {
		return err
	}

	// Rate limiting is shared with the API server through Redis, so an
	// uploader cannot get a fresh quota by switching endpoints.
	var limiter ratelimit.Limiter = ratelimit.NewMemoryLimiter()
	if opt, err := redis.ParseURL(cfg.RedisURL); err == nil {
		rdb := redis.NewClient(opt)
		if err := rdb.Ping(ctx).Err(); err == nil {
			limiter = ratelimit.NewRedisLimiter(rdb)
			defer rdb.Close()
		} else {
			log.Warn("redis unavailable, upload quota is per-process", "err", err)
			_ = rdb.Close()
		}
	}

	tokens := auth.NewManager(cfg.JWTSecret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)

	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(filetransfer.UnaryAuthInterceptor(tokens, st)),
		grpc.StreamInterceptor(filetransfer.StreamAuthInterceptor(tokens, st)),
		// Chunks are 64 KiB; a much larger frame is a client bug or an attempt
		// to exhaust memory before the size check runs.
		grpc.MaxRecvMsgSize(1<<20),
	)
	frogsterv1.RegisterFileTransferServer(
		grpcServer,
		filetransfer.NewService(blobs, limiter, log),
	)

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("file server listening", "addr", addr, "blob_dir", blobDir)
		if err := grpcServer.Serve(listener); err != nil {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	grpcServer.GracefulStop()
	log.Info("shutdown complete")
	return nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
