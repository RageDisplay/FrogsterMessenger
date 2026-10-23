package ws

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
)

// bearerSubprotocol prefixes the access token in the Sec-WebSocket-Protocol
// header.
//
// Browsers cannot set arbitrary headers on a WebSocket handshake, and putting
// the token in the query string would leak it into access logs and proxy
// history. The subprotocol header avoids both problems.
const bearerSubprotocol = "frogster.bearer."

// Authenticator validates an access token from the handshake.
type Authenticator interface {
	Parse(token string) (*auth.Claims, error)
}

// TokenChecker reports whether a token is still current for its user/device.
type TokenChecker interface {
	TokenVersion(ctx context.Context, userID, deviceID [16]byte) (int, bool, error)
}

// ConnectHook runs after a client registers, used to flush the offline queue
// and announce presence.
type ConnectHook func(ctx context.Context, key ClientKey)

// Handler upgrades HTTP requests to WebSocket connections.
type Handler struct {
	hub          *Hub
	tokens       Authenticator
	checker      TokenChecker
	frames       FrameHandler
	presence     *Presence
	onConnect    ConnectHook
	onDisconnect ConnectHook
	upgrader     websocket.Upgrader
	log          *slog.Logger
}

// NewHandler builds the upgrade handler.
func NewHandler(
	hub *Hub,
	tokens Authenticator,
	checker TokenChecker,
	frames FrameHandler,
	presence *Presence,
	onConnect, onDisconnect ConnectHook,
	allowedOrigins []string,
	log *slog.Logger,
) *Handler {
	return &Handler{
		hub:          hub,
		tokens:       tokens,
		checker:      checker,
		frames:       frames,
		presence:     presence,
		onConnect:    onConnect,
		onDisconnect: onDisconnect,
		log:          log,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			// Native clients send no Origin. Browsers do, and it is checked
			// against the allowlist to prevent cross-site socket hijacking.
			CheckOrigin: originChecker(allowedOrigins),
		},
	}
}

func originChecker(allowed []string) func(*http.Request) bool {
	return func(r *http.Request) bool { return OriginAllowed(r, allowed) }
}

// OriginAllowed reports whether a WebSocket handshake comes from a native
// client or from one of the allowed browser origins.
func OriginAllowed(r *http.Request, allowed []string) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true // non-browser client
	}
	for _, a := range allowed {
		if a == "*" || strings.EqualFold(a, origin) {
			return true
		}
	}
	return false
}

// ServeHTTP authenticates the handshake and starts the connection pumps.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	token, ok := tokenFromSubprotocols(r)
	if !ok {
		http.Error(w, "missing access token", http.StatusUnauthorized)
		return
	}

	claims, err := h.tokens.Parse(token)
	if err != nil {
		http.Error(w, "invalid access token", http.StatusUnauthorized)
		return
	}

	// A valid signature is not sufficient: the token must still be current for
	// this user and the device must not have been revoked.
	if h.checker != nil {
		version, active, err := h.checker.TokenVersion(r.Context(), claims.UserID, claims.DeviceID)
		if err != nil || !active || version != claims.TokenVer {
			http.Error(w, "invalid access token", http.StatusUnauthorized)
			return
		}
	}

	// RFC 6455 requires the server to select one of the client's offered
	// subprotocols verbatim. The token travels as a subprotocol, so echo back
	// exactly the value the client sent -- a rewritten or absent value makes
	// clients reject the handshake as a malformed header.
	respHeader := http.Header{}
	respHeader.Set("Sec-WebSocket-Protocol", bearerSubprotocol+token)

	conn, err := h.upgrader.Upgrade(w, r, respHeader)
	if err != nil {
		h.log.Info("websocket upgrade failed", "err", err)
		return
	}

	key := ClientKey{UserID: claims.UserID, DeviceID: claims.DeviceID}
	client := NewClient(h.hub, conn, key, h.frames, h.log)

	h.hub.Register(client)
	client.Start()

	// Presence and backlog flush run outside the request context, which is
	// cancelled as soon as the handshake completes. They live as long as the
	// connection instead: a large backlog drains at the pace of the socket.
	connCtx, cancelConn := context.WithCancel(context.Background())
	go func() {
		<-client.done()
		cancelConn()
	}()

	go func() {
		setCtx, cancel := context.WithTimeout(connCtx, 10*time.Second)
		if err := h.presence.Set(setCtx, key); err != nil {
			h.log.Warn("set presence", "err", err, "device_id", key.DeviceID)
		}
		cancel()

		if h.onConnect != nil {
			h.onConnect(connCtx, key)
		}
	}()

	// Presence keys expire so a crashed instance cleans up after itself; a
	// live connection has to keep extending its own, or after presenceTTL
	// other instances would treat the device as offline and stop routing
	// live traffic to it.
	go func() {
		ticker := time.NewTicker(presenceRefreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-connCtx.Done():
				return
			case <-ticker.C:
				refreshCtx, cancel := context.WithTimeout(connCtx, 5*time.Second)
				if err := h.presence.Refresh(refreshCtx, key); err != nil {
					h.log.Warn("refresh presence", "err", err, "device_id", key.DeviceID)
				}
				cancel()
			}
		}
	}()

	// Clean up presence once the read pump exits.
	go func() {
		<-client.done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := h.presence.Clear(ctx, key); err != nil {
			h.log.Warn("clear presence", "err", err, "device_id", key.DeviceID)
		}
		if h.onDisconnect != nil {
			h.onDisconnect(ctx, key)
		}
	}()
}

// tokenFromSubprotocols extracts the bearer token from the handshake.
func tokenFromSubprotocols(r *http.Request) (string, bool) {
	for _, proto := range websocket.Subprotocols(r) {
		if strings.HasPrefix(proto, bearerSubprotocol) {
			tok := strings.TrimPrefix(proto, bearerSubprotocol)
			if tok != "" {
				return tok, true
			}
		}
	}
	return "", false
}
