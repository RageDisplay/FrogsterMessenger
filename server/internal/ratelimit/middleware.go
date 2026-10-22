package ratelimit

import (
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
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

// ClientIP extracts the address of the client that made the request.
//
// X-Forwarded-For is honoured only when the request arrived from a trusted
// proxy (see SetTrustedProxies), and then it is read from the right: each
// proxy appends the address it received the request from, so the rightmost
// entry that is not itself a trusted proxy is the real client. The leftmost
// entry is whatever the client chose to send, and trusting it would let anyone
// pick their own rate-limit bucket.
func ClientIP(r *http.Request) string {
	remote := remoteHost(r)
	if !isTrustedProxy(remote) {
		return remote
	}

	xff := r.Header.Values("X-Forwarded-For")
	for i := len(xff) - 1; i >= 0; i-- {
		parts := strings.Split(xff[i], ",")
		for j := len(parts) - 1; j >= 0; j-- {
			candidate := strings.TrimSpace(parts[j])
			if candidate == "" {
				continue
			}
			if !isTrustedProxy(candidate) {
				return candidate
			}
		}
	}
	return remote
}

func remoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

var (
	trustedMu      sync.RWMutex
	trustedProxies []netip.Prefix
)

// SetTrustedProxies configures which peers may set X-Forwarded-For, as CIDR
// prefixes or single addresses. With none configured the header is ignored
// and the TCP peer address is used, which is the safe default for a server
// exposed directly.
func SetTrustedProxies(specs []string) error {
	prefixes := make([]netip.Prefix, 0, len(specs))
	for _, spec := range specs {
		spec = strings.TrimSpace(spec)
		if spec == "" {
			continue
		}
		if p, err := netip.ParsePrefix(spec); err == nil {
			prefixes = append(prefixes, p.Masked())
			continue
		}
		addr, err := netip.ParseAddr(spec)
		if err != nil {
			return fmt.Errorf("trusted proxy %q is neither an address nor a CIDR prefix", spec)
		}
		prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
	}
	trustedMu.Lock()
	trustedProxies = prefixes
	trustedMu.Unlock()
	return nil
}

func isTrustedProxy(host string) bool {
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	trustedMu.RLock()
	defer trustedMu.RUnlock()
	for _, p := range trustedProxies {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}
