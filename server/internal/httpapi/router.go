package httpapi

import (
	"bufio"
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// DeviceNotifier announces device-set changes to a user's own devices and to
// their contacts. Declared as an interface so httpapi does not depend on the
// delivery package.
type DeviceNotifier interface {
	NotifyDeviceAdded(ctx context.Context, userID, newDeviceID uuid.UUID)
	NotifyDeviceRevoked(ctx context.Context, userID, revokedDeviceID uuid.UUID)

	// NotifyChatUpdated tells the given users' devices that a chat was
	// created or changed, so they refetch it.
	NotifyChatUpdated(ctx context.Context, chatID uuid.UUID, epoch uint64, users []uuid.UUID)
}

// Server holds the dependencies shared by the HTTP handlers.
type Server struct {
	cfg      *config.Config
	store    *store.Store
	tokens   *auth.Manager
	limiter  ratelimit.Limiter
	notifier DeviceNotifier
	log      *slog.Logger

	// wsHandler serves the WebSocket upgrade. Injected so that httpapi does
	// not depend on the ws package, keeping the dependency one-directional.
	wsHandler http.Handler

	// ready reports whether dependencies (database, Redis) are reachable.
	ready func(ctx context.Context) error
}

// SetReadinessCheck installs the dependency check behind /readyz.
func (s *Server) SetReadinessCheck(check func(ctx context.Context) error) {
	s.ready = check
}

// NewServer builds the API server.
func NewServer(
	cfg *config.Config,
	st *store.Store,
	tokens *auth.Manager,
	limiter ratelimit.Limiter,
	notifier DeviceNotifier,
	wsHandler http.Handler,
	log *slog.Logger,
) *Server {
	return &Server{
		cfg:       cfg,
		store:     st,
		tokens:    tokens,
		limiter:   limiter,
		notifier:  notifier,
		wsHandler: wsHandler,
		log:       log,
	}
}

// Routes builds the HTTP handler.
//
// Middleware order is deliberate: recovery and request logging wrap
// everything, IP-based rate limiting runs before authentication so that
// unauthenticated floods are cheap to reject, and user-based limiting runs
// after authentication because it needs an identity.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	requireAuth := auth.RequireAuth(s.tokens, s.store)

	// authed applies authentication and the per-user budget. Endpoints with a
	// stricter rule of their own add it on top.
	authed := func(h http.HandlerFunc) http.Handler {
		return requireAuth(ratelimit.Middleware(s.limiter, ratelimit.RuleAPI, byUser, s.log)(h))
	}

	// Public endpoints.
	mux.Handle("POST /v1/register",
		ratelimit.Middleware(s.limiter, ratelimit.RuleRegister, ratelimit.ByIP("register"), s.log)(
			http.HandlerFunc(s.handleRegister)))

	mux.Handle("POST /v1/login",
		ratelimit.Middleware(s.limiter, ratelimit.RuleLogin, loginKey, s.log)(
			http.HandlerFunc(s.handleLogin)))

	mux.Handle("POST /v1/token/refresh",
		ratelimit.Middleware(s.limiter, ratelimit.RuleRefresh, ratelimit.ByIP("refresh"), s.log)(
			http.HandlerFunc(s.handleRefresh)))

	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /readyz", s.handleReady)

	// Authenticated endpoints.
	mux.Handle("GET /v1/keys/{username}",
		requireAuth(ratelimit.Middleware(s.limiter, ratelimit.RuleKeys, byUser, s.log)(
			http.HandlerFunc(s.handleGetKeys))))

	// /v1/keys/count shadows a user literally named "count"; the /v1/me form
	// is the one clients use. The old path stays for older builds.
	mux.Handle("GET /v1/keys/count", authed(s.handlePreKeyCount))
	mux.Handle("GET /v1/me/keys/count", authed(s.handlePreKeyCount))

	mux.Handle("POST /v1/keys", authed(s.handleUploadPreKeys))
	mux.Handle("PUT /v1/keys/signed", authed(s.handleRotateSignedPreKey))

	// Registered before /v1/users/{id}: the more specific pattern wins, so a
	// user can never shadow the search endpoint.
	mux.Handle("GET /v1/users/search",
		requireAuth(ratelimit.Middleware(s.limiter, ratelimit.RuleSearch, byUser, s.log)(
			http.HandlerFunc(s.handleSearchUsers))))
	mux.Handle("GET /v1/users/{id}", authed(s.handleLookupUser))

	mux.Handle("GET /v1/me", authed(s.handleGetMe))
	mux.Handle("PATCH /v1/me", authed(s.handleUpdateMe))
	mux.Handle("DELETE /v1/me",
		requireAuth(ratelimit.Middleware(s.limiter, ratelimit.RulePassword, byUser, s.log)(
			http.HandlerFunc(s.handleDeleteMe))))

	mux.Handle("GET /v1/chats", authed(s.handleListChats))
	mux.Handle("POST /v1/chats", authed(s.handleCreateChat))
	mux.Handle("GET /v1/chats/{id}", authed(s.handleGetChat))
	mux.Handle("PATCH /v1/chats/{id}", authed(s.handleUpdateChat))
	mux.Handle("GET /v1/chats/{id}/messages", authed(s.handleChatMessages))
	mux.Handle("POST /v1/chats/{id}/members", authed(s.handleAddMembers))
	mux.Handle("DELETE /v1/chats/{id}/members/{user}", authed(s.handleRemoveMember))
	mux.Handle("POST /v1/chats/{id}/leave", authed(s.handleLeaveChat))
	mux.Handle("POST /v1/chats/{id}/clear", authed(s.handleClearChat))

	mux.Handle("GET /v1/sessions", authed(s.handleListSessions))
	mux.Handle("DELETE /v1/sessions/{id}", authed(s.handleRevokeSession))

	mux.Handle("POST /v1/logout", authed(s.handleLogout))
	mux.Handle("POST /v1/password",
		requireAuth(ratelimit.Middleware(s.limiter, ratelimit.RulePassword, byUser, s.log)(
			http.HandlerFunc(s.handleChangePassword))))

	// The WebSocket endpoint authenticates inside the handler, because the
	// upgrade carries its token in a subprotocol header rather than a normal
	// Authorization header.
	if s.wsHandler != nil {
		mux.Handle("GET /v1/ws", s.wsHandler)
	}

	return recoverer(s.log)(requestLogger(s.log)(securityHeaders(mux)))
}

// loginKey buckets login attempts by client address.
func loginKey(r *http.Request) string {
	return "login:" + ratelimit.ClientIP(r)
}

// byUser buckets by authenticated user.
func byUser(r *http.Request) string {
	claims, ok := auth.ClaimsFrom(r.Context())
	if !ok {
		return ""
	}
	return "user:" + claims.UserID.String()
}

// handleHealth is the liveness probe: the process is up and serving. It
// deliberately checks nothing else, so a database outage does not get a
// healthy server restarted in a loop.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"}, s.log)
}

// handleReady is the readiness probe: dependencies answer.
func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if s.ready != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := s.ready(ctx); err != nil {
			s.log.Warn("readiness check failed", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"}, s.log)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"}, s.log)
}

// claimsOrUnauthorized fetches claims or writes a 401.
func claimsOrUnauthorized(w http.ResponseWriter, r *http.Request, s *Server) (*auth.Claims, bool) {
	claims, ok := auth.ClaimsFrom(r.Context())
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized", s.log)
		return nil, false
	}
	return claims, true
}

func parseUUID(s string) (uuid.UUID, error) { return uuid.Parse(s) }

// securityHeaders sets conservative defaults on every response.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// requestLogger records request metadata.
//
// It deliberately logs only method, path, status, and duration. Bodies are
// never logged, because on this service a request body may carry ciphertext.
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)

			log.Info("http request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", time.Since(start).Milliseconds(),
			)
		})
	}
}

// recoverer turns a handler panic into a 500 instead of killing the process.
func recoverer(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					log.Error("panic in handler", "path", r.URL.Path, "panic", rec)
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = w.Write([]byte(`{"error":"internal error"}`))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if r.wroteHeader {
		return
	}
	r.status = code
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(code)
}

// Hijack forwards to the underlying ResponseWriter.
//
// Wrapping a ResponseWriter hides the optional interfaces it implements. The
// WebSocket upgrade needs http.Hijacker to take over the TCP connection, so
// without this the /v1/ws handshake fails with "response does not implement
// http.Hijacker".
func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("underlying ResponseWriter is not an http.Hijacker")
	}
	return h.Hijack()
}

// Flush forwards to the underlying ResponseWriter, preserving streaming for
// the same reason.
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
