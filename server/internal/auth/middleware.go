// Package auth implements password hashing, token issuance, and the
// authentication middleware.
package auth

import (
	"context"
	"net/http"
	"strings"
)

type ctxKey int

const claimsCtxKey ctxKey = iota

// UserLookup reports the current token version for a user and whether the
// device is still active. It lets the middleware reject tokens that are
// syntactically valid but semantically stale -- after a password change or a
// device revocation -- without waiting for them to expire.
type UserLookup interface {
	TokenVersion(ctx context.Context, userID, deviceID [16]byte) (version int, deviceActive bool, err error)
}

// RequireAuth authenticates requests carrying a bearer access token.
//
// Order matters in the chain: this sits after IP-based rate limiting (so
// unauthenticated floods are rejected cheaply) and before user-based rate
// limiting (which needs an identity).
func RequireAuth(m *Manager, lookup UserLookup) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := bearerToken(r)
			if !ok {
				unauthorized(w)
				return
			}

			claims, err := m.Parse(token)
			if err != nil {
				unauthorized(w)
				return
			}

			// A valid signature is not enough: the token must also still be
			// current for this user and device.
			if lookup != nil {
				version, active, err := lookup.TokenVersion(r.Context(), claims.UserID, claims.DeviceID)
				if err != nil || !active || version != claims.TokenVer {
					unauthorized(w)
					return
				}
			}

			ctx := context.WithValue(r.Context(), claimsCtxKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// ClaimsFrom retrieves the authenticated claims from a request context.
func ClaimsFrom(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(claimsCtxKey).(*Claims)
	return c, ok
}

// WithClaims returns a context carrying the given claims. Used by the
// WebSocket upgrade path, which authenticates before handing off to the hub.
func WithClaims(ctx context.Context, c *Claims) context.Context {
	return context.WithValue(ctx, claimsCtxKey, c)
}

// bearerToken extracts a token from the Authorization header.
func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	if h == "" {
		return "", false
	}
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(prefix):])
	return tok, tok != ""
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="frogster"`)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
}
