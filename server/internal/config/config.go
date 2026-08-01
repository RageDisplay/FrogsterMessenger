// Package config loads runtime configuration from the environment.
//
// Every secret (DB DSN, JWT signing key) comes from the environment so that
// nothing sensitive is ever committed to the repository.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config holds all runtime settings for frogsterd.
type Config struct {
	Env  string // "dev" | "prod"
	Addr string // HTTP listen address

	DatabaseURL string
	RedisURL    string

	// JWTSecret signs access tokens. Must be at least 32 bytes in prod.
	JWTSecret       []byte
	AccessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration

	// BcryptCost is the work factor for password hashing.
	BcryptCost int

	// NodeID identifies this instance in Redis presence keys. Generated per
	// process when unset.
	NodeID string
}

// Load reads configuration from the environment, applying dev-friendly
// defaults. It returns an error when a value required in production is
// missing or obviously unsafe.
func Load() (*Config, error) {
	c := &Config{
		Env:             env("FROGSTER_ENV", "dev"),
		Addr:            env("FROGSTER_ADDR", ":8080"),
		DatabaseURL:     env("FROGSTER_DATABASE_URL", "postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable"),
		RedisURL:        env("FROGSTER_REDIS_URL", "redis://localhost:6379/0"),
		AccessTokenTTL:  envDuration("FROGSTER_ACCESS_TTL", 15*time.Minute),
		RefreshTokenTTL: envDuration("FROGSTER_REFRESH_TTL", 30*24*time.Hour),
		BcryptCost:      envInt("FROGSTER_BCRYPT_COST", 12),
		NodeID:          env("FROGSTER_NODE_ID", ""),
	}

	secret := os.Getenv("FROGSTER_JWT_SECRET")
	if secret == "" {
		if c.Env != "dev" {
			return nil, errors.New("FROGSTER_JWT_SECRET is required outside dev")
		}
		// Deterministic dev-only key. Never used when FROGSTER_ENV != dev.
		secret = "dev-only-insecure-jwt-secret-do-not-use-in-production"
	}
	if c.Env != "dev" && len(secret) < 32 {
		return nil, fmt.Errorf("FROGSTER_JWT_SECRET must be >= 32 bytes, got %d", len(secret))
	}
	c.JWTSecret = []byte(secret)

	if c.BcryptCost < 10 || c.BcryptCost > 31 {
		return nil, fmt.Errorf("FROGSTER_BCRYPT_COST must be in [10,31], got %d", c.BcryptCost)
	}

	return c, nil
}

// IsDev reports whether the server runs with development conveniences enabled.
func (c *Config) IsDev() bool { return c.Env == "dev" }

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func envDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}
