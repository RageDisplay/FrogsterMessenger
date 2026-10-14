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
	"time"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/filetransfer"
	frogsterv1 "github.com/vectrixsecurity/frogster/server/internal/gen/frogster/v1"
	"github.com/vectrixsecurity/frogster/server/internal/janitor"
	"github.com/vectrixsecurity/frogster/server/internal/logging"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	// The container image has no shell or grpc tooling, so the binary probes
	// itself.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
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
	log := logging.New(cfg.Env, cfg.LogLevel)

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

	go janitor.Run(ctx, time.Hour, log, janitor.Task{
		Name: "sweep_blobs",
		Run: func(context.Context) error {
			n, err := blobs.Sweep(filetransfer.BlobTTL)
			if n > 0 {
				log.Info("expired blobs removed", "count", n)
			}
			return err
		},
	})

	tokens := auth.NewManager(cfg.JWTSecret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)

	grpcServer := grpc.NewServer(
		grpc.ChainUnaryInterceptor(skipHealthAuth(filetransfer.UnaryAuthInterceptor(tokens, st))),
		grpc.StreamInterceptor(filetransfer.StreamAuthInterceptor(tokens, st)),
		// Chunks are 64 KiB; a much larger frame is a client bug or an attempt
		// to exhaust memory before the size check runs.
		grpc.MaxRecvMsgSize(1<<20),
	)
	frogsterv1.RegisterFileTransferServer(
		grpcServer,
		filetransfer.NewService(blobs, limiter, log),
	)
	healthpb.RegisterHealthServer(grpcServer, health.NewServer())

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("file server listening", "version", version, "addr", addr, "blob_dir", blobDir)
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

// skipHealthAuth lets the standard health check through without a token, so
// orchestrators can probe the server. It reveals nothing beyond "serving".
func skipHealthAuth(next grpc.UnaryServerInterceptor) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req any,
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (any, error) {
		if info.FullMethod == healthpb.Health_Check_FullMethodName {
			return handler(ctx, req)
		}
		return next(ctx, req, info, handler)
	}
}

// healthcheck asks the local server's health service whether it is serving.
// Returns the process exit code.
func healthcheck() int {
	addr := env("FROGSTER_FILED_ADDR", ":8081")
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	conn, err := grpc.NewClient("127.0.0.1:"+port,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return 1
	}
	defer conn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
	if err != nil || resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		return 1
	}
	return 0
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
