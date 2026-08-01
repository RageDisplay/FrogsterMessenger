// Package delivery routes ciphertext to recipient devices, spanning the local
// hub, other server instances, and the offline queue.
package delivery

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/pubsub"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// maxFlushBatch bounds how much backlog is pushed on reconnect, so a device
// returning after a long absence cannot be swamped in one burst.
const maxFlushBatch = 500

// Router delivers messages to devices.
type Router struct {
	hub      *ws.Hub
	store    *store.Store
	broker   pubsub.Broker
	presence *ws.Presence
	log      *slog.Logger
}

// NewRouter builds a delivery router.
func NewRouter(
	hub *ws.Hub,
	st *store.Store,
	broker pubsub.Broker,
	presence *ws.Presence,
	log *slog.Logger,
) *Router {
	return &Router{hub: hub, store: st, broker: broker, presence: presence, log: log}
}

// Send persists a message and delivers it to every recipient device.
//
// Persistence happens first, unconditionally. Every recipient therefore has a
// durable queue row before any delivery is attempted, so a crash mid-fan-out
// loses nothing: undelivered rows are simply still pending on reconnect.
func (r *Router) Send(ctx context.Context, env *ws.Envelope) (*models.Message, error) {
	if env.Sender == nil {
		return nil, fmt.Errorf("envelope has no sender")
	}

	member, err := r.store.IsMember(ctx, env.ChatID, env.Sender.UserID)
	if err != nil {
		return nil, fmt.Errorf("check membership: %w", err)
	}
	if !member {
		return nil, fmt.Errorf("sender is not a member of chat %s", env.ChatID)
	}

	devices, err := r.store.RecipientDevices(ctx, env.ChatID, env.Sender.DeviceID)
	if err != nil {
		return nil, fmt.Errorf("resolve recipients: %w", err)
	}

	// Index the per-device ciphertexts, when the sender supplied them.
	perDevice := make(map[uuid.UUID]ws.DevicePayload, len(env.Payloads))
	for _, p := range env.Payloads {
		perDevice[p.DeviceID] = p
	}

	msg := &models.Message{
		ChatID:      env.ChatID,
		SenderID:    env.Sender.UserID,
		SenderDevID: env.Sender.DeviceID,
		Ciphertext:  env.Ciphertext,
		CipherType:  messageCipherType(env),
		ContentHint: env.ContentHint,
	}

	// A direct message carries per-device payloads and no shared ciphertext.
	// The messages table requires one, so store an empty marker there and keep
	// the real bytes on the delivery rows.
	if len(perDevice) > 0 && len(msg.Ciphertext) == 0 {
		msg.Ciphertext = []byte{}
	}

	deliveries := make([]models.MessageDelivery, 0, len(devices))
	addressed := 0
	for _, d := range devices {
		delivery := models.MessageDelivery{
			UserID:   d.UserID,
			DeviceID: d.ID,
			State:    models.DeliveryPending,
		}
		if payload, ok := perDevice[d.ID]; ok {
			delivery.Ciphertext = payload.Ciphertext
			addressed++
		} else if len(perDevice) > 0 {
			// The sender did not encrypt for this device -- usually one that
			// registered after they fetched key bundles. Skipping it is right:
			// queueing a row with no ciphertext would deliver an empty frame
			// the device cannot decrypt. It receives the message once a new
			// session is established.
			r.log.Info("device not addressed by sender, skipping",
				"message_chat_id", env.ChatID, "device_id", d.ID)
			continue
		}
		deliveries = append(deliveries, delivery)
	}

	if err := r.store.PersistMessage(ctx, msg, deliveries); err != nil {
		return nil, fmt.Errorf("persist message: %w", err)
	}

	// Only identifiers and sizes are logged, never the payload.
	r.log.Info("message accepted",
		"message_id", msg.ID,
		"chat_id", msg.ChatID,
		"sender_user_id", msg.SenderID,
		"seq", msg.Seq,
		"recipients", len(deliveries),
		"per_device_payloads", addressed,
		"ciphertext_bytes", len(msg.Ciphertext),
	)

	livelyDelivered := make([]uint64, 0, len(deliveries))
	for _, d := range deliveries {
		// Each device receives only its own ciphertext. Broadcasting one
		// payload to every device would be undecryptable for all but one.
		out := &ws.Envelope{
			Version:     1,
			Type:        ws.TypeMessage,
			ID:          envelopeID(env, msg),
			ChatID:      msg.ChatID,
			Sender:      &ws.Address{UserID: msg.SenderID, DeviceID: msg.SenderDevID},
			Recipient:   &ws.Address{UserID: d.UserID, DeviceID: d.DeviceID},
			CipherType:  cipherTypeFor(perDevice, d.DeviceID, msg.CipherType),
			Ciphertext:  ciphertextFor(d, msg),
			ContentHint: msg.ContentHint,
			Timestamp:   msg.CreatedAt.UnixMilli(),
			Seq:         msg.Seq,
		}
		if r.deliverToDevice(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.DeviceID}, out) {
			livelyDelivered = append(livelyDelivered, d.ID)
		}
	}

	// Retire the rows that reached a live socket. Leaving them pending would
	// replay every message on the next reconnect, and a ratchet message cannot
	// be decrypted a second time -- its message key is destroyed on first use,
	// so the replay fails authentication and the conversation appears broken.
	if len(livelyDelivered) > 0 {
		if err := r.store.MarkDelivered(ctx, livelyDelivered); err != nil {
			// Not fatal: the message was delivered. Worst case it is replayed
			// and the client rejects the duplicate.
			r.log.Warn("mark live delivery", "err", err, "count", len(livelyDelivered))
		}
	}

	return msg, nil
}

// messageCipherType picks the type recorded on the message row.
//
// A direct message carries its real type per device -- the first message of a
// session is a prekey message for one device and an ordinary ratchet message
// for another -- so the row-level value is only a summary. It still has to be
// one of the valid types, because the schema constrains it; leaving it zero
// makes every direct message fail to persist.
func messageCipherType(env *ws.Envelope) uint8 {
	if env.CipherType != 0 {
		return env.CipherType
	}
	for _, p := range env.Payloads {
		if p.CipherType != 0 {
			return p.CipherType
		}
	}
	return models.CipherTypeWhisper
}

// envelopeID keeps the sender's own message id when they supplied one, so the
// acknowledgement correlates with the copy already rendered on their screen.
func envelopeID(env *ws.Envelope, msg *models.Message) string {
	if env.ID != "" {
		return env.ID
	}
	return msg.ID.String()
}

// ciphertextFor picks the per-device payload when there is one, and otherwise
// the shared group ciphertext.
func ciphertextFor(d models.MessageDelivery, msg *models.Message) []byte {
	if len(d.Ciphertext) > 0 {
		return d.Ciphertext
	}
	return msg.Ciphertext
}

func cipherTypeFor(
	perDevice map[uuid.UUID]ws.DevicePayload,
	deviceID uuid.UUID,
	fallback uint8,
) uint8 {
	if payload, ok := perDevice[deviceID]; ok && payload.CipherType != 0 {
		return payload.CipherType
	}
	return fallback
}

// deliverToDevice attempts live delivery, in order of decreasing locality, and
// reports whether the frame was handed to a live socket.
//
// Failing at every step is not an error: the message is already queued in the
// database, so the device receives it on its next connect.
//
// The return value drives whether the queued delivery row can be retired. A
// message delivered live but left pending is redelivered on the next connect,
// and a Double Ratchet message cannot be decrypted twice: the message key is
// destroyed on first use, so the replay fails its MAC check. From the outside
// that looks like the conversation breaking after a reconnect.
func (r *Router) deliverToDevice(ctx context.Context, key ws.ClientKey, env *ws.Envelope) bool {
	if r.hub.IsLocal(key) {
		if r.hub.Deliver(ws.Delivery{Key: key, Envelope: env}) {
			return true
		}
	}

	online, err := r.presence.IsOnline(ctx, key)
	if err != nil {
		r.log.Warn("presence lookup failed", "err", err, "device_id", key.DeviceID)
		return false
	}
	if !online {
		return false // stays pending in the offline queue
	}

	payload, err := json.Marshal(routedFrame{Target: key, Envelope: env})
	if err != nil {
		r.log.Error("marshal routed frame", "err", err)
		return false
	}
	if err := r.broker.Publish(ctx, key.UserID, payload); err != nil {
		r.log.Warn("cross-instance publish failed", "err", err, "device_id", key.DeviceID)
		return false
	}

	// Published to the owning node. Treated as delivered: that node hands it to
	// a live socket, and keeping the row pending would replay the message on
	// the next reconnect.
	return true
}

// routedFrame wraps an envelope with its target device for cross-instance
// transport, since the receiving instance needs to know which socket to use.
type routedFrame struct {
	Target   ws.ClientKey `json:"target"`
	Envelope *ws.Envelope `json:"envelope"`
}

// HandleBrokerMessage delivers a frame that arrived from another instance.
func (r *Router) HandleBrokerMessage(payload []byte) {
	var frame routedFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		r.log.Error("unmarshal routed frame", "err", err)
		return
	}
	if !r.hub.IsLocal(frame.Target) {
		return // the device moved or disconnected in the meantime
	}
	r.hub.Deliver(ws.Delivery{Key: frame.Target, Envelope: frame.Envelope})
}

// RunBrokerLoop consumes cross-instance traffic until ctx is cancelled.
func (r *Router) RunBrokerLoop(ctx context.Context) {
	messages := r.broker.Messages()
	for {
		select {
		case <-ctx.Done():
			return
		case payload, ok := <-messages:
			if !ok {
				return
			}
			r.HandleBrokerMessage(payload)
		}
	}
}

// FlushOffline pushes a device's queued mail on connect.
//
// The queue is drained before live traffic is routed to the socket, so a
// reconnecting client sees its backlog in order rather than interleaved with
// new messages arriving mid-drain.
func (r *Router) FlushOffline(ctx context.Context, key ws.ClientKey) (int, error) {
	pending, err := r.store.PendingDeliveries(ctx, key.UserID, key.DeviceID, maxFlushBatch)
	if err != nil {
		return 0, fmt.Errorf("read pending deliveries: %w", err)
	}
	if len(pending) == 0 {
		return 0, nil
	}

	ids := make([]uuid.UUID, 0, len(pending))
	for _, d := range pending {
		ids = append(ids, d.MessageID)
	}
	messages, err := r.store.MessagesByIDs(ctx, ids)
	if err != nil {
		return 0, fmt.Errorf("load queued messages: %w", err)
	}

	delivered := make([]uint64, 0, len(pending))
	for _, d := range pending {
		msg, ok := messages[d.MessageID]
		if !ok {
			continue // message expired or was purged
		}

		// Per-device ciphertext wins for 1:1; group messages share the
		// sender-key ciphertext stored on the message row.
		ciphertext := d.Ciphertext
		if len(ciphertext) == 0 {
			ciphertext = msg.Ciphertext
		}

		env := &ws.Envelope{
			Version:     1,
			Type:        ws.TypeMessage,
			ID:          msg.ID.String(),
			ChatID:      msg.ChatID,
			Sender:      &ws.Address{UserID: msg.SenderID, DeviceID: msg.SenderDevID},
			Recipient:   &ws.Address{UserID: key.UserID, DeviceID: key.DeviceID},
			CipherType:  msg.CipherType,
			Ciphertext:  ciphertext,
			ContentHint: msg.ContentHint,
			Timestamp:   msg.CreatedAt.UnixMilli(),
			Seq:         msg.Seq,
		}

		if !r.hub.Deliver(ws.Delivery{Key: key, Envelope: env}) {
			break // socket is saturated; the rest stays pending
		}
		delivered = append(delivered, d.ID)
	}

	if err := r.store.MarkDelivered(ctx, delivered); err != nil {
		return len(delivered), fmt.Errorf("mark delivered: %w", err)
	}

	r.log.Info("offline queue flushed",
		"user_id", key.UserID, "device_id", key.DeviceID, "count", len(delivered))

	// Tell the client the backlog is done, so it can distinguish history from
	// live traffic.
	r.hub.Deliver(ws.Delivery{
		Key: key,
		Envelope: &ws.Envelope{
			Version:   1,
			Type:      ws.TypeSyncDone,
			Timestamp: time.Now().UnixMilli(),
			Seq:       int64(len(delivered)),
		},
	})

	return len(delivered), nil
}
