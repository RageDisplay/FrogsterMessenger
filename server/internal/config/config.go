// Package config loads runtime configuration from the environment.
//
// Every secret (DB DSN, JWT signing key) comes from the environment so that
// nothing sensitive is ever committed to the repository.
package config

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
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

	// AllowedOrigins lists browser origins permitted to open a WebSocket.
	// Native clients send no Origin header and are always allowed.
	AllowedOrigins []string

	// TrustedProxies lists the addresses or CIDR prefixes of reverse proxies
	// whose X-Forwarded-For header is believed. Empty means the header is
	// ignored, which is right when the server is exposed directly.
	TrustedProxies []string

	// QueueRetention bounds how long an undelivered message waits for a
	// device that never comes back.
	QueueRetention time.Duration

	// StorageKey seals cloud-chat content at rest (32 bytes). Losing it
	// makes stored cloud history unreadable, so it is generated once at
	// install time and never rotated by the installer.
	StorageKey []byte

	// VoiceUDPAddr is where voice channels take sound over UDP; "off" leaves
	// only the WebSocket path. VoicePublicPort is the port clients are told
	// to send to, when a NAT or container maps it to another.
	VoiceUDPAddr    string
	VoicePublicPort int

	LogLevel slog.Level
}

// Load reads configuration from the environment, applying dev-friendly
// defaults. It returns an error when a value required in production is
// missing or obviously unsafe, and when any value fails to parse: silently
// falling back to a default would turn a typo in a TTL into a different
// security posture.
func Load() (*Config, error) {
	var errs []error
	c := &Config{
		Env:             env("FROGSTER_ENV", "dev"),
		Addr:            env("FROGSTER_ADDR", ":8080"),
		DatabaseURL:     env("FROGSTER_DATABASE_URL", "postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable"),
		RedisURL:        env("FROGSTER_REDIS_URL", "redis://localhost:6379/0"),
		AccessTokenTTL:  envDuration("FROGSTER_ACCESS_TTL", 15*time.Minute, &errs),
		RefreshTokenTTL: envDuration("FROGSTER_REFRESH_TTL", 30*24*time.Hour, &errs),
		BcryptCost:      envInt("FROGSTER_BCRYPT_COST", 12, &errs),
		NodeID:          env("FROGSTER_NODE_ID", ""),
		AllowedOrigins:  splitList(os.Getenv("FROGSTER_ALLOWED_ORIGINS")),
		TrustedProxies:  splitList(os.Getenv("FROGSTER_TRUSTED_PROXIES")),
		QueueRetention:  envDuration("FROGSTER_QUEUE_RETENTION", 30*24*time.Hour, &errs),
		VoiceUDPAddr:    env("FROGSTER_VOICE_UDP", ":7882"),
		VoicePublicPort: envInt("FROGSTER_VOICE_PUBLIC_PORT", 0, &errs),
	}
	if c.VoiceUDPAddr != "off" && c.VoicePublicPort == 0 {
		_, port, err := net.SplitHostPort(c.VoiceUDPAddr)
		if n, convErr := strconv.Atoi(port); err != nil || convErr != nil || n <= 0 || n > 65535 {
			errs = append(errs, fmt.Errorf("FROGSTER_VOICE_UDP: %q is not host:port or \"off\"", c.VoiceUDPAddr))
		} else {
			c.VoicePublicPort = n
		}
	}
	if c.VoicePublicPort < 0 || c.VoicePublicPort > 65535 {
		errs = append(errs, fmt.Errorf("FROGSTER_VOICE_PUBLIC_PORT: %d is not a port", c.VoicePublicPort))
	}

	switch c.Env {
	case "dev", "prod":
	default:
		errs = append(errs, fmt.Errorf("FROGSTER_ENV must be dev or prod, got %q", c.Env))
	}

	if err := c.LogLevel.UnmarshalText([]byte(env("FROGSTER_LOG_LEVEL", "info"))); err != nil {
		errs = append(errs, fmt.Errorf("FROGSTER_LOG_LEVEL: %w", err))
	}

	secret := os.Getenv("FROGSTER_JWT_SECRET")
	if secret == "" {
		if c.Env != "dev" {
			errs = append(errs, errors.New("FROGSTER_JWT_SECRET is required outside dev"))
		}
		// Deterministic dev-only key. Never used when FROGSTER_ENV != dev.
		secret = "dev-only-insecure-jwt-secret-do-not-use-in-production"
	}
	if c.Env != "dev" && len(secret) < 32 {
		errs = append(errs, fmt.Errorf("FROGSTER_JWT_SECRET must be >= 32 bytes, got %d", len(secret)))
	}
	c.JWTSecret = []byte(secret)

	if raw := os.Getenv("FROGSTER_STORAGE_KEY"); raw != "" {
		key, err := storagecrypto.ParseKey(raw)
		if err != nil {
			errs = append(errs, fmt.Errorf("FROGSTER_STORAGE_KEY: %w", err))
		}
		c.StorageKey = key
	} else if c.Env != "dev" {
		errs = append(errs, errors.New("FROGSTER_STORAGE_KEY is required outside dev (64 hex characters)"))
	} else {
		// Deterministic dev-only key. Never used when FROGSTER_ENV != dev.
		sum := sha256.Sum256([]byte("dev-only-insecure-storage-key"))
		c.StorageKey = sum[:]
	}

	if c.BcryptCost < 10 || c.BcryptCost > 31 {
		errs = append(errs, fmt.Errorf("FROGSTER_BCRYPT_COST must be in [10,31], got %d", c.BcryptCost))
	}
	if c.AccessTokenTTL <= 0 || c.RefreshTokenTTL <= c.AccessTokenTTL {
		errs = append(errs, errors.New("token TTLs must be positive and the refresh TTL longer than the access TTL"))
	}

	if len(errs) > 0 {
		return nil, errors.Join(errs...)
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

func envInt(key string, def int, errs *[]error) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %q is not an integer", key, v))
		return def
	}
	return n
}

func envDuration(key string, def time.Duration, errs *[]error) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %q is not a duration (e.g. 15m, 720h)", key, v))
		return def
	}
	return d
}

// splitList parses a comma-separated list, dropping empty entries.
func splitList(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}
