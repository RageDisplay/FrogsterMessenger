package ratelimit_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
)

func TestMemoryLimiterAllowsBurstThenBlocks(t *testing.T) {
	t.Parallel()

	l := ratelimit.NewMemoryLimiter()
	rule := ratelimit.Rule{Burst: 3, Rate: 3, Period: time.Minute}
	ctx := context.Background()

	for i := range 3 {
		dec, err := l.Allow(ctx, "k", rule, 1)
		if err != nil {
			t.Fatalf("allow %d: %v", i, err)
		}
		if !dec.Allowed {
			t.Fatalf("request %d denied inside the burst allowance", i+1)
		}
	}

	dec, err := l.Allow(ctx, "k", rule, 1)
	if err != nil {
		t.Fatalf("allow: %v", err)
	}
	if dec.Allowed {
		t.Error("request past the burst allowance was permitted")
	}
	if dec.RetryAfter <= 0 {
		t.Error("denied request did not report a retry delay")
	}
}

// TestMemoryLimiterKeysAreIndependent guards against one caller's traffic
// consuming another's quota, which would let a single client lock everyone out.
func TestMemoryLimiterKeysAreIndependent(t *testing.T) {
	t.Parallel()

	l := ratelimit.NewMemoryLimiter()
	rule := ratelimit.Rule{Burst: 1, Rate: 1, Period: time.Minute}
	ctx := context.Background()

	if dec, _ := l.Allow(ctx, "alice", rule, 1); !dec.Allowed {
		t.Fatal("alice's first request was denied")
	}
	if dec, _ := l.Allow(ctx, "alice", rule, 1); dec.Allowed {
		t.Fatal("alice exceeded her quota")
	}
	if dec, _ := l.Allow(ctx, "bob", rule, 1); !dec.Allowed {
		t.Error("bob was blocked by alice's usage")
	}
}

func TestMemoryLimiterRefillsOverTime(t *testing.T) {
	t.Parallel()

	l := ratelimit.NewMemoryLimiter()
	// 10 tokens per 100ms, so one token returns roughly every 10ms.
	rule := ratelimit.Rule{Burst: 2, Rate: 10, Period: 100 * time.Millisecond}
	ctx := context.Background()

	l.Allow(ctx, "k", rule, 1)
	l.Allow(ctx, "k", rule, 1)

	if dec, _ := l.Allow(ctx, "k", rule, 1); dec.Allowed {
		t.Fatal("bucket was not exhausted as expected")
	}

	time.Sleep(60 * time.Millisecond)

	if dec, _ := l.Allow(ctx, "k", rule, 1); !dec.Allowed {
		t.Error("bucket did not refill after waiting")
	}
}

// TestMemoryLimiterReapDropsIdleBuckets confirms bucket storage is bounded, so
// traffic from many distinct IPs cannot grow memory without limit.
func TestMemoryLimiterReapDropsIdleBuckets(t *testing.T) {
	t.Parallel()

	l := ratelimit.NewMemoryLimiter()
	rule := ratelimit.Rule{Burst: 1, Rate: 1, Period: time.Minute}
	ctx := context.Background()

	l.Allow(ctx, "stale", rule, 1)
	time.Sleep(20 * time.Millisecond)
	l.Reap(10 * time.Millisecond)

	// After reaping, the key behaves as new: a full burst is available again.
	if dec, _ := l.Allow(ctx, "stale", rule, 1); !dec.Allowed {
		t.Error("bucket was not reclaimed by Reap")
	}
}

// TestMiddlewareDrainsBodyOnReject guards against a subtle connection bug.
//
// Responding 429 without consuming the request body leaves unread bytes in
// the connection. Go then closes it with a TCP RST, so a client that writes
// its body before reading the response sees "connection reset" instead of the
// 429 the server sent. curl hides this (it writes first); most HTTP libraries
// do not.
func TestMiddlewareDrainsBodyOnReject(t *testing.T) {
	t.Parallel()

	l := ratelimit.NewMemoryLimiter()
	rule := ratelimit.Rule{Burst: 1, Rate: 1, Period: time.Hour}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	handler := ratelimit.Middleware(l, rule, func(*http.Request) string { return "k" }, log)(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		}))

	srv := httptest.NewServer(handler)
	defer srv.Close()

	body := strings.Repeat("x", 4096)

	// First request consumes the single token.
	resp, err := http.Post(srv.URL, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("first request: %v", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	// Second must return a clean 429, not a connection reset.
	resp2, err := http.Post(srv.URL, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("rejected request failed at the transport level "+
			"(body was probably not drained): %v", err)
	}
	defer resp2.Body.Close()

	if resp2.StatusCode != http.StatusTooManyRequests {
		t.Errorf("status %d, want 429", resp2.StatusCode)
	}
	if resp2.Header.Get("Retry-After") == "" {
		t.Error("429 response is missing Retry-After")
	}
}
