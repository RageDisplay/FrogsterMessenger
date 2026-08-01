package ratelimit

import (
	"context"
	"sync"
	"time"
)

// MemoryLimiter is a process-local token bucket.
//
// It is the development fallback when Redis is not configured, and a
// last-resort safety net per process. It is not a substitute for the Redis
// limiter in a multi-instance deployment: each instance would enforce the
// limit independently, multiplying the effective quota by the replica count.
type MemoryLimiter struct {
	mu      sync.Mutex
	buckets map[string]*memBucket
	now     func() time.Time
}

type memBucket struct {
	tokens float64
	ts     time.Time
}

// NewMemoryLimiter builds an in-process limiter.
func NewMemoryLimiter() *MemoryLimiter {
	return &MemoryLimiter{
		buckets: make(map[string]*memBucket),
		now:     time.Now,
	}
}

// Allow implements Limiter.
func (l *MemoryLimiter) Allow(_ context.Context, key string, rule Rule, cost int) (Decision, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		b = &memBucket{tokens: float64(rule.Burst), ts: now}
		l.buckets[key] = b
	}

	elapsed := now.Sub(b.ts)
	if elapsed > 0 {
		refill := elapsed.Seconds() * float64(rule.Rate) / rule.Period.Seconds()
		b.tokens = min(float64(rule.Burst), b.tokens+refill)
	}
	b.ts = now

	if b.tokens >= float64(cost) {
		b.tokens -= float64(cost)
		return Decision{Allowed: true, Remaining: int(b.tokens)}, nil
	}

	deficit := float64(cost) - b.tokens
	retry := time.Duration(deficit * float64(rule.Period) / float64(rule.Rate))
	return Decision{Allowed: false, Remaining: int(b.tokens), RetryAfter: retry}, nil
}

// Reap drops buckets untouched for longer than maxIdle, bounding memory use.
func (l *MemoryLimiter) Reap(maxIdle time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := l.now().Add(-maxIdle)
	for k, b := range l.buckets {
		if b.ts.Before(cutoff) {
			delete(l.buckets, k)
		}
	}
}
