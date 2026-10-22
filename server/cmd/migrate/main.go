// Command migrate applies the Frogster database schema.
//
// Usage:
//
//	go run ./cmd/migrate up
package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/logging"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("load config", "err", err)
		os.Exit(1)
	}
	log := logging.New(cfg.Env, slog.LevelInfo)

	cmd := "up"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	if cmd != "up" {
		log.Error("unknown command", "cmd", cmd, "supported", "up")
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	st, err := store.Open(ctx, cfg.DatabaseURL, log)
	if err != nil {
		log.Error("open database", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	if err := st.Migrate(ctx); err != nil {
		log.Error("migrate", "err", err)
		os.Exit(1)
	}
	log.Info("migrations complete")
}
