package ratelimit

import (
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
)

// maxDrainBytes caps how much of a rejected request's body is read before
// responding. Draining keeps the connection usable; the cap stops a large
// upload from making rejection expensive.
const maxDrainBytes = 1 << 20

// KeyFunc derives the bucket key for a request. Returning "" skips limiting.
type KeyFunc func(r *http.Request) string

// Middleware enforces a rule against the bucket named by keyFn.
//
// A limiter failure (Redis down) allows the request rather than rejecting it:
// losing rate limiting degrades a defence, whereas failing closed would take
// the whole service down with the cache.
func Middleware(l Limiter, rule Rule, keyFn KeyFunc, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := keyFn(r)
			if key == "" {
				next.ServeHTTP(w, r)
				return
			}

			dec, err := l.Allow(r.Context(), key, rule, 1)
			if err != nil {
				log.Warn("rate limiter unavailable, allowing request", "err", err)
				next.ServeHTTP(w, r)
				return
			}

			w.Header().Set("X-RateLimit-Limit", strconv.Itoa(rule.Burst))
			w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(dec.Remaining))

			if !dec.Allowed {
				// Drain and close the request body before responding.
				//
				// Rejecting a request without consuming its body leaves unread
				// bytes in the connection: Go then closes with a TCP RST, and
				// clients that write the body before reading the response see
				// a connection reset instead of this 429. The body is capped
				// so a large payload cannot be used to make draining costly.
				_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, maxDrainBytes))
				_ = r.Body.Close()

				retry := int(dec.RetryAfter.Seconds())
				if retry < 1 {
					retry = 1
				}
				w.Header().Set("Retry-After", strconv.Itoa(retry))
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(`{"error":"rate limit exceeded"}`))
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// ByIP keys buckets by client address, for endpoints reachable without
// authentication.
func ByIP(prefix string) KeyFunc {
	return func(r *http.Request) string {
		return prefix + ":" + ClientIP(r)
	}
}

// ClientIP extracts the client address, honouring X-Forwarded-For only for its
// first entry.
//
// Trusting this header requires a proxy that overwrites it; when the server is
// exposed directly, a client can forge it and evade IP limits. Deploy behind a
// proxy that strips inbound values.
func ClientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		for i := range len(xff) {
			if xff[i] == ',' {
				return trimSpace(xff[:i])
			}
		}
		return trimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func trimSpace(s string) string {
	start, end := 0, len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t') {
		start++
	}
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t') {
		end--
	}
	return s[start:end]
}
