package ws

import (
	"log/slog"

	"github.com/google/uuid"
)

// Envelope types exchanged over the socket.
const (
	TypeMessage     = "msg"
	TypeAck         = "ack"
	TypeReceipt     = "receipt"
	TypeTyping      = "typing"
	TypeSKDM        = "skdm"
	TypeDeviceAdded = "device_added"
	TypeKeyChange   = "key_change"
	TypeError       = "error"
	TypeSyncDone    = "sync_done"

	// TypeDelivered is sent by a client once it has stored the messages
	// listed in IDs. Until then they stay queued and are redelivered on the
	// next connect, so a frame lost with a dying socket is not lost for good.
	TypeDelivered = "delivered"

	// TypeRead moves the sender's read position in a chat to Seq. The
	// server keeps it and relays it, so other members see read ticks and
	// the reader's other devices clear their unread badges.
	TypeRead = "read"

	// TypeChatUpdated tells members that a chat's metadata changed: it was
	// created, renamed, or its membership (and with it the epoch) changed.
	TypeChatUpdated = "chat_updated"
)

// SenderKeyAckPrefix marks a sender-key distribution in a delivered frame.
// Distributions are queued separately from messages, so their ids are kept
// apart from message ids.
const SenderKeyAckPrefix = "skdm-"

// Address identifies a specific device of a specific user. Messages are
// addressed per device because each device holds its own ratchet state.
type Address struct {
	UserID   uuid.UUID `json:"user_id"`
	DeviceID uuid.UUID `json:"device_id"`
}

// DevicePayload is ciphertext addressed to one specific device.
//
// A 1:1 conversation between two users with several devices each needs one
// ciphertext per device: every device runs its own Double Ratchet session, so
// a payload encrypted for one device is undecryptable by any other. Sending a
// single shared ciphertext would silently deliver garbage to every device but
// one.
type DevicePayload struct {
	UserID   uuid.UUID `json:"user_id"`
	DeviceID uuid.UUID `json:"device_id"`

	// Ciphertext for this device. Opaque to the server.
	Ciphertext []byte `json:"ciphertext"`

	CipherType uint8 `json:"ct_type,omitempty"`
}

// LogValue implements slog.LogValuer, keeping per-device payloads out of logs.
func (p DevicePayload) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("user_id", p.UserID.String()),
		slog.String("device_id", p.DeviceID.String()),
		slog.Int("ciphertext_bytes", len(p.Ciphertext)),
	)
}

// Envelope is the wire format for every WebSocket frame.
//
// Ciphertext is opaque to the server: it is stored, routed, and echoed without
// ever being parsed. Message bodies, attachments, and reactions all live
// inside it, so the server cannot learn what was said or who reacted to what.
type Envelope struct {
	Version int    `json:"v"`
	Type    string `json:"type"`

	// ID is a client-generated ULID/UUID used for idempotent delivery and to
	// correlate acknowledgements.
	ID string `json:"id,omitempty"`

	ChatID    uuid.UUID `json:"chat_id,omitempty"`
	Sender    *Address  `json:"sender,omitempty"`
	Recipient *Address  `json:"recipient,omitempty"`

	CipherType uint8 `json:"ct_type,omitempty"`

	// Ciphertext carries a single encrypted payload. Used by group messages,
	// where one sender-key ciphertext serves every member, and by frames the
	// server echoes back to one device.
	Ciphertext []byte `json:"ciphertext,omitempty"`

	// Payloads carries one ciphertext per recipient device, used by direct
	// messages where each device has its own ratchet session. When present it
	// takes precedence over Ciphertext.
	Payloads []DevicePayload `json:"payloads,omitempty"`

	ContentHint string `json:"content_hint,omitempty"`
	Timestamp   int64  `json:"ts,omitempty"`
	Seq         int64  `json:"seq,omitempty"`

	// Epoch is the group epoch a secret-group message or sender key was
	// made for. The server refuses one for an epoch the chat has left.
	Epoch uint64 `json:"epoch,omitempty"`

	// Kind, TargetID and Emoji describe a cloud event: an edit, deletion or
	// reaction to an earlier message. Secret chats never set them; their
	// events are inside the ciphertext.
	Kind     string `json:"kind,omitempty"`
	TargetID string `json:"target_id,omitempty"`
	Emoji    string `json:"emoji,omitempty"`

	// IDs lists message ids, for frames that refer to several messages at
	// once (TypeDelivered).
	IDs []string `json:"ids,omitempty"`

	// Error carries a human-readable reason for TypeError frames.
	Error string `json:"error,omitempty"`
}

// LogValue implements slog.LogValuer.
//
// This is what makes the no-plaintext-on-server rule structural rather than a
// matter of remembering not to log the wrong field: even a careless
// slog.Info("frame", "env", env) cannot emit ciphertext, because slog calls
// this method instead of reflecting over the struct.
func (e Envelope) LogValue() slog.Value {
	attrs := []slog.Attr{
		slog.String("type", e.Type),
		slog.Int("ciphertext_bytes", len(e.Ciphertext)),
		slog.Int("payload_count", len(e.Payloads)),
	}
	if e.ID != "" {
		attrs = append(attrs, slog.String("envelope_id", e.ID))
	}
	if e.ChatID != uuid.Nil {
		attrs = append(attrs, slog.String("chat_id", e.ChatID.String()))
	}
	if e.Sender != nil {
		attrs = append(attrs,
			slog.String("sender_user_id", e.Sender.UserID.String()),
			slog.String("sender_device_id", e.Sender.DeviceID.String()))
	}
	if e.Seq != 0 {
		attrs = append(attrs, slog.Int64("seq", e.Seq))
	}
	return slog.GroupValue(attrs...)
}
