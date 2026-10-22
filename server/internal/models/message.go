package models

import (
	"log/slog"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// Ciphertext types, mirroring the Signal message types the client produces.
const (
	CipherTypeCloud     uint8 = 0 // cloud chat payload, sealed by the server at rest
	CipherTypePreKey    uint8 = 1 // initial X3DH message, self-contained
	CipherTypeWhisper   uint8 = 2 // ordinary Double Ratchet message
	CipherTypeSenderKey uint8 = 3 // group message under a sender key
)

// What a cloud message does. Secret chats carry the same events inside the
// ciphertext, where the server cannot see them, so Kind stays empty there.
const (
	KindMessage = ""
	KindEdit    = "edit"
	KindDelete  = "delete"
	KindReact   = "react"
	KindUnreact = "unreact"
)

// Delivery states for the offline queue.
const (
	DeliveryPending   = "pending"
	DeliveryDelivered = "delivered"
	DeliveryRead      = "read"
)

// Message is an envelope of ciphertext. The server assigns ordering and
// routes the bytes; it has no code path that can decrypt Ciphertext.
type Message struct {
	ID uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`

	ChatID uuid.UUID `gorm:"type:uuid;not null;index:idx_chat_seq,priority:1" json:"chat_id"`

	// Seq is a per-chat monotonic sequence assigned by the server. It gives
	// clients a total order without trusting sender clocks.
	Seq int64 `gorm:"not null;index:idx_chat_seq,priority:2" json:"seq"`

	SenderID    uuid.UUID `gorm:"type:uuid;index;not null" json:"sender_id"`
	SenderDevID uuid.UUID `gorm:"type:uuid;not null" json:"sender_device_id"`

	// ClientID is the id the sending client chose. Recipients see this id on
	// every delivery path, and a resend with the same id is deduplicated.
	ClientID *string `gorm:"type:varchar(64)" json:"client_id,omitempty"`

	// Ciphertext is opaque. Nothing on the server parses, inspects, or logs it.
	Ciphertext []byte `gorm:"type:bytea;not null" json:"-"`

	CipherType uint8 `gorm:"not null" json:"cipher_type"`

	// ContentHint carries routing intent only ("default", "resendable"). It is
	// deliberately not derived from the message body.
	ContentHint string `gorm:"type:varchar(16)" json:"content_hint,omitempty"`

	// Kind and TargetID describe cloud events: an edit, deletion or reaction
	// that applies to the earlier message TargetID names.
	Kind     string  `gorm:"type:varchar(8);not null;default:''" json:"kind,omitempty"`
	TargetID *string `gorm:"type:varchar(64)" json:"target_id,omitempty"`

	EditedAt  *time.Time `json:"edited_at,omitempty"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`

	CreatedAt time.Time  `gorm:"index" json:"created_at"`
	ExpiresAt *time.Time `gorm:"index" json:"expires_at,omitempty"`
}

// WireID is the id clients know this message by.
func (m *Message) WireID() string {
	if m.ClientID != nil && *m.ClientID != "" {
		return *m.ClientID
	}
	return m.ID.String()
}

// BeforeCreate assigns a UUID when one was not supplied.
func (m *Message) BeforeCreate(*gorm.DB) error {
	if m.ID == uuid.Nil {
		m.ID = uuid.New()
	}
	return nil
}

// LogValue implements slog.LogValuer so that logging a Message can never emit
// its ciphertext. This makes the no-plaintext-on-server rule structural rather
// than a matter of call-site discipline.
func (m Message) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("message_id", m.ID.String()),
		slog.String("chat_id", m.ChatID.String()),
		slog.Int64("seq", m.Seq),
		slog.String("sender_id", m.SenderID.String()),
		slog.Int("ciphertext_bytes", len(m.Ciphertext)),
	)
}

// MessageDelivery is the per-device fan-out row and the offline queue. A
// message destined for a user with three devices produces three rows.
type MessageDelivery struct {
	ID        uint64    `gorm:"primaryKey;autoIncrement" json:"-"`
	MessageID uuid.UUID `gorm:"type:uuid;index;not null" json:"message_id"`

	UserID   uuid.UUID `gorm:"type:uuid;not null;index:idx_pending,priority:1" json:"user_id"`
	DeviceID uuid.UUID `gorm:"type:uuid;not null;index:idx_pending,priority:2" json:"device_id"`

	// Ciphertext holds the per-device payload for 1:1 chats, where each
	// recipient device has its own ratchet output. Group messages share one
	// sender-key ciphertext on the Message row, so this stays nil there.
	Ciphertext []byte `gorm:"type:bytea" json:"-"`

	State string `gorm:"type:varchar(10);not null;index:idx_pending,priority:3" json:"state"`

	DeliveredAt *time.Time `json:"delivered_at,omitempty"`
	ReadAt      *time.Time `json:"read_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

// LogValue implements slog.LogValuer, keeping per-device payloads out of logs.
func (d MessageDelivery) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("message_id", d.MessageID.String()),
		slog.String("user_id", d.UserID.String()),
		slog.String("device_id", d.DeviceID.String()),
		slog.String("state", d.State),
		slog.Int("ciphertext_bytes", len(d.Ciphertext)),
	)
}
