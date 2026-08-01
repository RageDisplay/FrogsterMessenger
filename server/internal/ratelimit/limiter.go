// Package ratelimit implements token-bucket rate limiting.
//
// The Redis-backed limiter is the production path: buckets are shared across
// server instances and survive restarts. The in-memory limiter exists so the
// server still runs in development without Redis.
package ratelimit

import (
	"context"
	"time"
)

// Rule describes a bucket: Burst tokens capacity, refilled at Rate tokens per
// Period.
type Rule struct {
	Burst  int
	Rate   int
	Period time.Duration
}

// Decision is the outcome of an Allow call.
type Decision struct {
	Allowed    bool
	Remaining  int
	RetryAfter time.Duration
}

// Limiter consumes tokens from a named bucket.
type Limiter interface {
	// Allow deducts cost tokens from the bucket identified by key.
	Allow(ctx context.Context, key string, rule Rule, cost int) (Decision, error)
}

// Common rules. Registration and login are deliberately strict: they are the
// endpoints an attacker probes for account enumeration and credential
// stuffing.
var (
	RuleRegister = Rule{Burst: 5, Rate: 5, Period: time.Hour}
	RuleLogin    = Rule{Burst: 10, Rate: 10, Period: 15 * time.Minute}
	// RuleKeys guards the prekey pool: fetching a bundle consumes a one-time
	// prekey, so an unbounded caller could drain a victim's pool and force
	// weaker sessions.
	RuleKeys     = Rule{Burst: 60, Rate: 60, Period: time.Minute}
	RuleMessages = Rule{Burst: 120, Rate: 120, Period: time.Minute}
	RuleWSFrames = Rule{Burst: 100, Rate: 30, Period: time.Second}
	// RuleUpload bounds attachment uploads. Blobs are large and the server
	// cannot inspect them, so an unbounded uploader could fill the disk with
	// material nobody can audit.
	RuleUpload = Rule{Burst: 20, Rate: 20, Period: time.Hour}
)
