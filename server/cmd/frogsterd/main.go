// Command frogsterd is the Frogster API and realtime server.
//
// It routes end-to-end encrypted ciphertext between devices. It holds no key
// material capable of decrypting message content, and it never logs payloads.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/delivery"
	"github.com/vectrixsecurity/frogster/server/internal/httpapi"
	"github.com/vectrixsecurity/frogster/server/internal/logging"
	"github.com/vectrixsecurity/frogster/server/internal/pubsub"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
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
	if cfg.NodeID == "" {
		cfg.NodeID = uuid.NewString()
	}
	log.Info("starting frogsterd", "env", cfg.Env, "addr", cfg.Addr, "node_id", cfg.NodeID)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, cfg.DatabaseURL, log)
	if err != nil {
		return err
	}
	defer st.Close()

	if err := st.Migrate(ctx); err != nil {
		return err
	}

	// Redis is optional in development: without it the server falls back to a
	// process-local rate limiter and a no-op broker, which is correct for a
	// single instance.
	rdb, err := openRedis(ctx, cfg.RedisURL, log)
	if err != nil && !cfg.IsDev() {
		return err
	}

	var (
		limiter ratelimit.Limiter
		broker  pubsub.Broker
	)
	if rdb != nil {
		limiter = ratelimit.NewRedisLimiter(rdb)
		broker = pubsub.NewRedisBroker(ctx, rdb, log)
	} else {
		log.Warn("running without redis: rate limits are per-process and cross-instance fan-out is disabled")
		limiter = ratelimit.NewMemoryLimiter()
		broker = pubsub.NewNopBroker()
	}
	defer broker.Close()

	tokens := auth.NewManager(cfg.JWTSecret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)

	hub := ws.NewHub(log)
	go hub.Run(ctx)

	presence := ws.NewPresence(rdb, cfg.NodeID)
	router := delivery.NewRouter(hub, st, broker, presence, log)
	go router.RunBrokerLoop(ctx)

	frames := delivery.NewFrameHandler(router, limiter, log)

	onConnect := func(ctx context.Context, key ws.ClientKey) {
		if err := broker.Subscribe(ctx, key.UserID); err != nil {
			log.Warn("subscribe to user channel", "err", err, "user_id", key.UserID)
		}
		if err := st.TouchDevice(ctx, key.DeviceID); err != nil {
			log.Warn("touch device", "err", err, "device_id", key.DeviceID)
		}
		if _, err := router.FlushOffline(ctx, key); err != nil {
			log.Warn("flush offline queue", "err", err, "device_id", key.DeviceID)
		}
	}
	onDisconnect := func(ctx context.Context, key ws.ClientKey) {
		if err := broker.Unsubscribe(ctx, key.UserID); err != nil {
			log.Warn("unsubscribe from user channel", "err", err, "user_id", key.UserID)
		}
	}

	wsHandler := ws.NewHandler(
		hub, tokens, st, frames, presence,
		onConnect, onDisconnect,
		allowedOrigins(cfg), log,
	)

	api := httpapi.NewServer(cfg, st, tokens, limiter, router, wsHandler, log)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           api.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		// No WriteTimeout: it would cap the lifetime of WebSocket connections,
		// which are long-lived by design. Per-write deadlines in writePump
		// bound individual writes instead.
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("http server listening", "addr", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	log.Info("shutdown complete")
	return nil
}

func openRedis(ctx context.Context, url string, log *slog.Logger) (*redis.Client, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opt)

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := rdb.Ping(pingCtx).Err(); err != nil {
		log.Warn("redis unavailable", "err", err)
		_ = rdb.Close()
		return nil, err
	}
	log.Info("connected to redis")
	return rdb, nil
}

// allowedOrigins lists origins permitted to open a WebSocket. Native clients
// send no Origin header and are always allowed.
func allowedOrigins(cfg *config.Config) []string {
	if cfg.IsDev() {
		return []string{"*"}
	}
	if v := os.Getenv("FROGSTER_ALLOWED_ORIGINS"); v != "" {
		return splitComma(v)
	}
	return nil
}

func splitComma(s string) []string {
	var out []string
	start := 0
	for i := range len(s) {
		if s[i] == ',' {
			if seg := trim(s[start:i]); seg != "" {
				out = append(out, seg)
			}
			start = i + 1
		}
	}
	if seg := trim(s[start:]); seg != "" {
		out = append(out, seg)
	}
	return out
}

func trim(s string) string {
	i, j := 0, len(s)
	for i < j && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t') {
		j--
	}
	return s[i:j]
}
