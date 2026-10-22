// Package delivery routes ciphertext to recipient devices, spanning the local
// hub, other server instances, and the offline queue.
package delivery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/pubsub"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// flushPageSize is how many queued deliveries are read per query while
// draining a device's backlog. Pages are pushed with backpressure, so this
// bounds memory per query rather than the size of the backlog.
const flushPageSize = 100

// maxClientIDLength mirrors messages.client_id.
const maxClientIDLength = 64

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
//
// What a message may contain depends on the chat's mode, and the check is
// strict in both directions. A cloud chat takes only payloads the server can
// seal; a secret chat takes only ciphertext. Accepting a plaintext payload
// into a secret chat -- a client bug, or a downgrade attempt -- would quietly
// strip the protection the user chose.
func (r *Router) Send(ctx context.Context, env *ws.Envelope) (*models.Message, error) {
	if env.Sender == nil {
		return nil, fmt.Errorf("envelope has no sender")
	}
	if len(env.ID) > maxClientIDLength {
		return nil, fmt.Errorf("message id longer than %d bytes", maxClientIDLength)
	}

	chat, err := r.store.ChatByID(ctx, env.ChatID)
	if err != nil {
		return nil, fmt.Errorf("load chat: %w", err)
	}
	member, err := r.store.IsMember(ctx, env.ChatID, env.Sender.UserID)
	if err != nil {
		return nil, fmt.Errorf("check membership: %w", err)
	}
	if !member {
		return nil, fmt.Errorf("%w: sender is not a member of chat %s", ErrRejected, env.ChatID)
	}

	if chat.IsCloud() {
		return r.sendCloud(ctx, chat, env)
	}
	if err := validateSecret(chat, env); err != nil {
		return nil, err
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
	if env.ID != "" {
		id := env.ID
		msg.ClientID = &id
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

	persist := func() error { return r.store.PersistMessage(ctx, msg, deliveries) }
	if chat.IsGroup() {
		persist = func() error { return r.store.PersistGroupMessage(ctx, msg, deliveries, env.Epoch) }
	}
	if err := persist(); err != nil {
		if errors.Is(err, store.ErrDuplicateMessage) {
			// A resend after a lost acknowledgement. The recipients already
			// have it queued or delivered; the sender only needs the ack.
			r.log.Info("duplicate message acknowledged again",
				"message_id", msg.ID, "chat_id", msg.ChatID, "seq", msg.Seq)
			return msg, nil
		}
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

	for _, d := range deliveries {
		// Each device receives only its own ciphertext. Broadcasting one
		// payload to every device would be undecryptable for all but one.
		out := &ws.Envelope{
			Version:     1,
			Type:        ws.TypeMessage,
			ID:          msg.WireID(),
			ChatID:      msg.ChatID,
			Sender:      &ws.Address{UserID: msg.SenderID, DeviceID: msg.SenderDevID},
			Recipient:   &ws.Address{UserID: d.UserID, DeviceID: d.DeviceID},
			CipherType:  cipherTypeFor(perDevice, d.DeviceID, msg.CipherType),
			Ciphertext:  ciphertextFor(d, msg),
			ContentHint: msg.ContentHint,
			Timestamp:   msg.CreatedAt.UnixMilli(),
			Seq:         msg.Seq,
			Epoch:       groupEpoch(chat, env.Epoch),
		}
		// The row stays pending until the device acknowledges it. Handing a
		// frame to a socket proves nothing: the connection can die with the
		// frame still in its buffer, and a row retired at that point would be
		// lost for good. A redelivery is harmless, because it carries the same
		// id and the client drops ids it already holds.
		r.deliverToDevice(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.DeviceID}, out)
	}

	return msg, nil
}

// ErrRejected marks a message refused for what it is rather than because
// something failed: it will be refused again if resent unchanged.
var ErrRejected = errors.New("message rejected")

// validateSecret checks that a message for a secret chat is what that chat
// accepts: per-device ratchet ciphertext in a direct chat, one sender-key
// ciphertext in a group, and nothing the server could read in either. The
// cipher types are checked positively, so a cloud payload (type 0) fails
// both shapes.
func validateSecret(chat *models.Chat, env *ws.Envelope) error {
	if env.Kind != "" || env.TargetID != "" || env.Emoji != "" {
		// Events in a secret chat live inside the ciphertext. Metadata on
		// the envelope would tell the server who edited or reacted to what.
		return fmt.Errorf("%w: event fields on a secret-chat message", ErrRejected)
	}
	if chat.IsGroup() {
		if len(env.Payloads) > 0 || len(env.Ciphertext) == 0 ||
			env.CipherType != models.CipherTypeSenderKey {
			return fmt.Errorf("%w: a secret group takes one sender-key ciphertext", ErrRejected)
		}
		return nil
	}
	if len(env.Payloads) == 0 {
		return fmt.Errorf("%w: a secret direct chat takes per-device ciphertext", ErrRejected)
	}
	for _, p := range env.Payloads {
		if p.CipherType != models.CipherTypePreKey && p.CipherType != models.CipherTypeWhisper {
			return fmt.Errorf("%w: per-device payload of type %d", ErrRejected, p.CipherType)
		}
	}
	return nil
}

// groupEpoch is the epoch to stamp on an outgoing frame: the one the sender
// encrypted for, in a group; nothing elsewhere.
func groupEpoch(chat *models.Chat, epoch uint64) uint64 {
	if chat.IsGroup() {
		return epoch
	}
	return 0
}

// Acknowledge retires the deliveries a device reports having stored. Ids of
// sender-key distributions are told apart by their prefix.
func (r *Router) Acknowledge(ctx context.Context, key ws.ClientKey, wireIDs []string) (int64, error) {
	var messages []string
	var senderKeys []uint64
	for _, id := range wireIDs {
		if rest, ok := strings.CutPrefix(id, ws.SenderKeyAckPrefix); ok {
			if n, err := strconv.ParseUint(rest, 10, 64); err == nil {
				senderKeys = append(senderKeys, n)
			}
			continue
		}
		messages = append(messages, id)
	}
	if err := r.store.ConsumeSenderKeys(ctx, key.UserID, key.DeviceID, senderKeys); err != nil {
		return 0, err
	}
	return r.store.AcknowledgeDeliveries(ctx, key.UserID, key.DeviceID, messages)
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

	// Published to the owning node, which hands it to the live socket.
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
// The whole backlog is drained, page by page, with backpressure: each frame
// waits for room in the socket's send buffer rather than tripping the
// slow-consumer cutoff. Rows stay pending until the device acknowledges them,
// so a connection that dies mid-flush loses nothing.
func (r *Router) FlushOffline(ctx context.Context, key ws.ClientKey) (int, error) {
	var (
		after uint64
		sent  int
	)

	// Sender keys first: a queued group message is unreadable until the key
	// it was encrypted under has arrived.
	keys, err := r.store.PendingSenderKeys(ctx, key.UserID, key.DeviceID)
	if err != nil {
		return 0, fmt.Errorf("read pending sender keys: %w", err)
	}
	for _, k := range keys {
		if !r.hub.DeliverWait(ctx, ws.Delivery{Key: key, Envelope: senderKeyEnvelope(k)}) {
			return 0, nil
		}
	}

	for {
		pending, err := r.store.PendingDeliveriesAfter(ctx, key.UserID, key.DeviceID, after, flushPageSize)
		if err != nil {
			return sent, fmt.Errorf("read pending deliveries: %w", err)
		}
		if len(pending) == 0 {
			break
		}
		after = pending[len(pending)-1].ID

		ids := make([]uuid.UUID, 0, len(pending))
		for _, d := range pending {
			ids = append(ids, d.MessageID)
		}
		messages, err := r.store.MessagesByIDs(ctx, ids)
		if err != nil {
			return sent, fmt.Errorf("load queued messages: %w", err)
		}

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
				ID:          msg.WireID(),
				ChatID:      msg.ChatID,
				Sender:      &ws.Address{UserID: msg.SenderID, DeviceID: msg.SenderDevID},
				Recipient:   &ws.Address{UserID: key.UserID, DeviceID: key.DeviceID},
				CipherType:  msg.CipherType,
				Ciphertext:  ciphertext,
				ContentHint: msg.ContentHint,
				Timestamp:   msg.CreatedAt.UnixMilli(),
				Seq:         msg.Seq,
			}

			if !r.hub.DeliverWait(ctx, ws.Delivery{Key: key, Envelope: env}) {
				// Disconnected or out of time; the rest stays queued for the
				// next connect.
				r.log.Info("offline flush interrupted",
					"user_id", key.UserID, "device_id", key.DeviceID, "sent", sent)
				return sent, nil
			}
			sent++
		}

		if len(pending) < flushPageSize {
			break
		}
	}

	r.log.Info("offline queue flushed",
		"user_id", key.UserID, "device_id", key.DeviceID, "count", sent)

	// Tell the client the backlog is done, so it can distinguish history from
	// live traffic.
	r.hub.DeliverWait(ctx, ws.Delivery{
		Key: key,
		Envelope: &ws.Envelope{
			Version:   1,
			Type:      ws.TypeSyncDone,
			Timestamp: time.Now().UnixMilli(),
			Seq:       int64(sent),
		},
	})

	return sent, nil
}
