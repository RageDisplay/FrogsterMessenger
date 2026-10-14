package ratelimit_test

import (
	"net/http/httptest"
	"testing"

	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
)

// These tests share the package-level trusted-proxy list, so they do not run
// in parallel.

func withTrustedProxies(t *testing.T, specs ...string) {
	t.Helper()
	if err := ratelimit.SetTrustedProxies(specs); err != nil {
		t.Fatalf("set trusted proxies: %v", err)
	}
	t.Cleanup(func() { _ = ratelimit.SetTrustedProxies(nil) })
}

// TestClientIPIgnoresForwardedForFromUntrustedPeer: a client talking to the
// server directly could otherwise pick its own rate-limit bucket.
func TestClientIPIgnoresForwardedForFromUntrustedPeer(t *testing.T) {
	withTrustedProxies(t, "10.0.0.0/8")

	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "203.0.113.7:5000"
	r.Header.Set("X-Forwarded-For", "198.51.100.1")

	if got := ratelimit.ClientIP(r); got != "203.0.113.7" {
		t.Errorf("ClientIP = %q, want the TCP peer", got)
	}
}

// TestClientIPTakesRightmostUntrustedEntry: behind a trusted proxy, the
// leftmost X-Forwarded-For entry is whatever the client sent. The address the
// proxy itself appended is the last one.
func TestClientIPTakesRightmostUntrustedEntry(t *testing.T) {
	withTrustedProxies(t, "172.16.0.0/12")

	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "172.18.0.5:44321"
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")

	if got := ratelimit.ClientIP(r); got != "203.0.113.9" {
		t.Errorf("ClientIP = %q, want the entry the proxy appended", got)
	}
}

// TestClientIPWithoutTrustedProxies: the default ignores the header.
func TestClientIPWithoutTrustedProxies(t *testing.T) {
	withTrustedProxies(t)

	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "192.0.2.10:1234"
	r.Header.Set("X-Forwarded-For", "1.2.3.4")

	if got := ratelimit.ClientIP(r); got != "192.0.2.10" {
		t.Errorf("ClientIP = %q, want the TCP peer", got)
	}
}

func TestSetTrustedProxiesRejectsGarbage(t *testing.T) {
	if err := ratelimit.SetTrustedProxies([]string{"not-an-address"}); err == nil {
		t.Error("a malformed proxy spec was accepted")
	}
	_ = ratelimit.SetTrustedProxies(nil)
}
