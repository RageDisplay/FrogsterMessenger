// Command frogsterd is the Frogster API and realtime server.
//
// It routes end-to-end encrypted ciphertext between devices. It holds no key
// material capable of decrypting message content, and it never logs payloads.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
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
	"github.com/vectrixsecurity/frogster/server/internal/janitor"
	"github.com/vectrixsecurity/frogster/server/internal/logging"
	"github.com/vectrixsecurity/frogster/server/internal/pubsub"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/voice"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	// The container image has no shell or curl, so the binary probes itself.
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
	if cfg.NodeID == "" {
		cfg.NodeID = uuid.NewString()
	}
	log.Info("starting frogsterd", "version", version, "env", cfg.Env, "addr", cfg.Addr, "node_id", cfg.NodeID)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := ratelimit.SetTrustedProxies(cfg.TrustedProxies); err != nil {
		return err
	}

	st, err := store.Open(ctx, cfg.DatabaseURL, log)
	if err != nil {
		return err
	}
	defer st.Close()

	if err := st.Migrate(ctx); err != nil {
		return err
	}

	sealer, err := storagecrypto.New(cfg.StorageKey)
	if err != nil {
		return err
	}
	st.SetSealer(sealer)

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

	if mem, ok := limiter.(*ratelimit.MemoryLimiter); ok {
		go reapLimiter(ctx, mem)
	}

	go janitor.Run(ctx, time.Hour, log,
		janitor.PurgeTask(st, store.RetentionPolicy{
			UndeliveredQueue: cfg.QueueRetention,
			Delivered:        7 * 24 * time.Hour,
			Spent:            30 * 24 * time.Hour,
		}, log),
	)

	tokens := auth.NewManager(cfg.JWTSecret, cfg.AccessTokenTTL, cfg.RefreshTokenTTL)

	hub := ws.NewHub(log)
	go hub.Run(ctx)

	presence := ws.NewPresence(rdb, cfg.NodeID)
	router := delivery.NewRouter(hub, st, broker, presence, log)
	go router.RunBrokerLoop(ctx)

	// Who is online, as people who share a chat with them see it.
	online := delivery.NewPresence(st, router, log)

	frames := delivery.NewFrameHandler(router, limiter, log)
	frames.SetPresence(online)

	onConnect := func(ctx context.Context, key ws.ClientKey) {
		if err := broker.Subscribe(ctx, key.UserID); err != nil {
			log.Warn("subscribe to user channel", "err", err, "user_id", key.UserID)
		}
		if err := st.TouchDevice(ctx, key.DeviceID); err != nil {
			log.Warn("touch device", "err", err, "device_id", key.DeviceID)
		}
		// Active until the app says it went to the background.
		online.DeviceActive(ctx, key)
		if _, err := router.FlushOffline(ctx, key); err != nil {
			log.Warn("flush offline queue", "err", err, "device_id", key.DeviceID)
		}
	}
	onDisconnect := func(ctx context.Context, key ws.ClientKey) {
		if err := broker.Unsubscribe(ctx, key.UserID); err != nil {
			log.Warn("unsubscribe from user channel", "err", err, "user_id", key.UserID)
		}
		// A reconnect replaces the old socket, which then closes: the device
		// is still here on the new one.
		if !hub.IsLocal(key) {
			online.DeviceIdle(ctx, key)
		}
	}

	wsHandler := ws.NewHandler(
		hub, tokens, st, frames, presence,
		onConnect, onDisconnect,
		allowedOrigins(cfg), log,
	)

	// Voice channels: rooms in memory, sound over UDP or a WebSocket.
	voices := voice.NewManager(router.NotifyVoice, log)
	go voices.Run(ctx)
	udpPort := 0
	if cfg.VoiceUDPAddr != "off" {
		addr, err := net.ResolveUDPAddr("udp", cfg.VoiceUDPAddr)
		if err != nil {
			return fmt.Errorf("FROGSTER_VOICE_UDP: %w", err)
		}
		conn, err := net.ListenUDP("udp", addr)
		if err != nil {
			return fmt.Errorf("listen for voice: %w", err)
		}
		udpPort = cfg.VoicePublicPort
		log.Info("voice listening", "udp", cfg.VoiceUDPAddr, "public_port", udpPort)
		go func() {
			if err := voices.ServeUDP(ctx, conn); err != nil {
				log.Error("voice udp stopped", "err", err)
			}
		}()
	}
	origins := allowedOrigins(cfg)
	media := voices.MediaHandler(func(r *http.Request) bool { return ws.OriginAllowed(r, origins) })

	api := httpapi.NewServer(cfg, st, tokens, limiter, router, wsHandler, log)
	api.SetPresence(online)
	api.SetVoice(voices, router, udpPort, media)
	api.SetReadinessCheck(func(ctx context.Context) error {
		if err := st.Ping(ctx); err != nil {
			return fmt.Errorf("postgres: %w", err)
		}
		if rdb != nil {
			if err := rdb.Ping(ctx).Err(); err != nil {
				return fmt.Errorf("redis: %w", err)
			}
		}
		return nil
	})

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
	return cfg.AllowedOrigins
}

// reapLimiter bounds the in-memory limiter, which otherwise keeps a bucket
// for every address and user it has ever seen.
func reapLimiter(ctx context.Context, l *ratelimit.MemoryLimiter) {
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			l.Reap(time.Hour)
		}
	}
}

// healthcheck probes the local liveness endpoint, for the container
// healthcheck. Returns the process exit code.
func healthcheck() int {
	addr := os.Getenv("FROGSTER_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return 1
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
