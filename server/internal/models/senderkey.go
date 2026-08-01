package models

import (
	"log/slog"
	"time"

	"github.com/google/uuid"
)

// GroupSenderKeyDistribution carries a Sender Key Distribution Message from
// one member device to another.
//
// The SKDM is itself encrypted inside the pairwise Double Ratchet session
// between the two devices, so the server relays opaque bytes here as well.
//
// Rows are scoped to an epoch. When a member is removed the chat epoch is
// bumped and every remaining member must publish a fresh sender key for the
// new epoch; otherwise the removed member could keep decrypting group traffic.
type GroupSenderKeyDistribution struct {
	ID     uint64    `gorm:"primaryKey;autoIncrement" json:"-"`
	ChatID uuid.UUID `gorm:"type:uuid;not null;index" json:"chat_id"`
	Epoch  uint64    `gorm:"not null" json:"epoch"`

	SenderUserID uuid.UUID `gorm:"type:uuid;not null" json:"sender_user_id"`
	SenderDevID  uuid.UUID `gorm:"type:uuid;not null" json:"sender_device_id"`

	RecipUserID uuid.UUID `gorm:"type:uuid;not null;index" json:"recipient_user_id"`
	RecipDevID  uuid.UUID `gorm:"type:uuid;not null" json:"recipient_device_id"`

	// Ciphertext is the SKDM sealed in the pairwise session. Opaque here.
	Ciphertext []byte `gorm:"type:bytea;not null" json:"-"`

	ConsumedAt *time.Time `json:"consumed_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

// LogValue implements slog.LogValuer, keeping the sealed SKDM out of logs.
func (g GroupSenderKeyDistribution) LogValue() slog.Value {
	return slog.GroupValue(
		slog.String("chat_id", g.ChatID.String()),
		slog.Uint64("epoch", g.Epoch),
		slog.String("sender_device_id", g.SenderDevID.String()),
		slog.String("recipient_device_id", g.RecipDevID.String()),
		slog.Int("ciphertext_bytes", len(g.Ciphertext)),
	)
}
