package delivery

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// FrameHandler processes frames arriving from connected clients.
type FrameHandler struct {
	router   *Router
	limiter  ratelimit.Limiter
	presence *Presence
	log      *slog.Logger
}

// SetPresence lets clients say whether they are in the foreground.
func (h *FrameHandler) SetPresence(p *Presence) { h.presence = p }

// NewFrameHandler builds the inbound frame handler.
func NewFrameHandler(router *Router, limiter ratelimit.Limiter, log *slog.Logger) *FrameHandler {
	return &FrameHandler{router: router, limiter: limiter, log: log}
}

// HandleFrame dispatches one inbound frame.
//
// Frames are rate limited per connection: an authenticated client can
// otherwise flood the hub far more cheaply than over HTTP, since there is no
// per-request handshake.
func (h *FrameHandler) HandleFrame(c *ws.Client, env *ws.Envelope) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	key := c.Key()
	dec, err := h.limiter.Allow(ctx, "ws:"+key.UserID.String(), ratelimit.RuleWSFrames, 1)
	if err == nil && !dec.Allowed {
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, Error: "rate limit exceeded"})
		return
	}

	switch env.Type {
	case ws.TypeMessage:
		h.handleMessage(ctx, c, env)
	case ws.TypeTyping, ws.TypeReceipt:
		h.handleEphemeral(ctx, c, env)
	case ws.TypeDelivered:
		h.handleDelivered(ctx, c, env)
	case ws.TypeSKDM:
		h.handleSenderKeys(ctx, c, env)
	case ws.TypeRead:
		h.handleRead(ctx, c, env)
	case ws.TypePresence:
		h.handlePresence(ctx, c, env)
	default:
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, Error: "unsupported frame type"})
	}
}

// handleMessage persists and routes a chat message.
func (h *FrameHandler) handleMessage(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	// A message carries either one shared ciphertext (group sender-key) or a
	// per-device payload for each recipient (direct message). Requiring the
	// shared field would reject every direct message.
	if len(env.Ciphertext) == 0 && len(env.Payloads) == 0 {
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, ID: env.ID, Error: "empty ciphertext"})
		return
	}
	for _, p := range env.Payloads {
		if len(p.Ciphertext) == 0 {
			c.Send(&ws.Envelope{
				Version: 1, Type: ws.TypeError, ID: env.ID,
				Error: "empty per-device ciphertext",
			})
			return
		}
	}

	msg, err := h.router.Send(ctx, env)
	if err != nil {
		// The error may name a chat id but never message content.
		h.log.Warn("message rejected",
			"user_id", c.Key().UserID, "chat_id", env.ChatID, "err", err)
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, ID: env.ID, ChatID: env.ChatID, Error: clientError(err)})
		return
	}

	// Acknowledge with the server-assigned sequence so the sender can order
	// its local copy consistently with everyone else.
	c.Send(&ws.Envelope{
		Version:   1,
		Type:      ws.TypeAck,
		ID:        env.ID,
		ChatID:    msg.ChatID,
		Seq:       msg.Seq,
		Timestamp: msg.CreatedAt.UnixMilli(),
	})
}

// Reasons a client can act on. Anything else is reported as a plain failure,
// so internal errors do not leak through the socket.
const (
	ErrorStaleEpoch = "stale epoch"
	ErrorForbidden  = "forbidden"
	ErrorNotFound   = "not found"
	ErrorRejected   = "rejected"
	ErrorFailed     = "could not deliver message"
)

func clientError(err error) string {
	switch {
	case errors.Is(err, store.ErrStaleEpoch):
		// The group's membership changed under the sender: it has to make
		// a new sender key for the new epoch and send again.
		return ErrorStaleEpoch
	case errors.Is(err, store.ErrForbidden):
		return ErrorForbidden
	case errors.Is(err, store.ErrNotFound):
		return ErrorNotFound
	case errors.Is(err, ErrRejected):
		return ErrorRejected
	default:
		return ErrorFailed
	}
}

// handleSenderKeys relays a member's sender key to the group's devices.
func (h *FrameHandler) handleSenderKeys(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	if len(env.Payloads) == 0 {
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, ID: env.ID, Error: "no sender-key payloads"})
		return
	}
	key := c.Key()
	if _, err := h.router.DistributeSenderKeys(ctx, env); err != nil {
		h.log.Warn("sender keys rejected", "user_id", key.UserID, "chat_id", env.ChatID, "err", err)
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, ID: env.ID, ChatID: env.ChatID, Error: clientError(err)})
		return
	}
	c.Send(&ws.Envelope{Version: 1, Type: ws.TypeAck, ID: env.ID, ChatID: env.ChatID, Epoch: env.Epoch})
}

// handleRead records a read position.
func (h *FrameHandler) handleRead(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	if env.Seq <= 0 {
		return
	}
	if err := h.router.MarkRead(ctx, c.Key(), env.ChatID, env.Seq); err != nil {
		h.log.Warn("mark read", "err", err, "user_id", c.Key().UserID, "chat_id", env.ChatID)
	}
}

// maxAckIDs bounds one delivered frame. Clients batch acknowledgements, and a
// flush page is far smaller than this.
const maxAckIDs = 500

// handleDelivered retires the queued deliveries a device has stored.
func (h *FrameHandler) handleDelivered(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	if len(env.IDs) == 0 {
		return
	}
	if len(env.IDs) > maxAckIDs {
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, Error: "too many ids in one acknowledgement"})
		return
	}
	for _, id := range env.IDs {
		if id == "" || len(id) > maxClientIDLength {
			c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, Error: "malformed message id"})
			return
		}
	}
	if _, err := h.router.Acknowledge(ctx, c.Key(), env.IDs); err != nil {
		h.log.Warn("acknowledge deliveries", "err", err,
			"user_id", c.Key().UserID, "device_id", c.Key().DeviceID)
	}
}

// handleEphemeral forwards typing indicators and read receipts.
//
// These are not persisted: they are worthless once stale, and storing read
// receipts would add metadata the server has no need to retain.
func (h *FrameHandler) handleEphemeral(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	key := c.Key()

	member, err := h.router.store.IsMember(ctx, env.ChatID, key.UserID)
	if err != nil || !member {
		return
	}

	devices, err := h.router.store.RecipientDevices(ctx, env.ChatID, key.DeviceID)
	if err != nil {
		h.log.Warn("resolve ephemeral recipients", "err", err, "chat_id", env.ChatID)
		return
	}

	out := *env
	out.Version = 1
	out.Timestamp = time.Now().UnixMilli()

	for _, d := range devices {
		target := ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}
		if h.router.hub.IsLocal(target) {
			h.router.hub.Deliver(ws.Delivery{Key: target, Envelope: &out})
		}
		// Ephemeral frames are deliberately not queued for offline devices.
	}
}

// handlePresence records whether the sending device is in use.
func (h *FrameHandler) handlePresence(ctx context.Context, c *ws.Client, env *ws.Envelope) {
	if h.presence == nil {
		return
	}
	switch env.Kind {
	case "active":
		h.presence.DeviceActive(ctx, c.Key())
	case "idle":
		h.presence.DeviceIdle(ctx, c.Key())
	default:
		c.Send(&ws.Envelope{Version: 1, Type: ws.TypeError, Error: "unknown presence"})
	}
}
