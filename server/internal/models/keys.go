package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// SignedPreKey is a medium-term Curve25519 prekey signed by the device's
// identity key using XEdDSA. Peers verify the signature before starting X3DH,
// which binds the prekey to the identity.
//
// The server stores the signature but does not treat verifying it as proof of
// private-key possession -- it cannot, by design.
type SignedPreKey struct {
	ID       uuid.UUID `gorm:"type:uuid;primaryKey" json:"-"`
	DeviceID uuid.UUID `gorm:"type:uuid;index;not null" json:"-"`

	KeyID     uint32 `gorm:"not null" json:"key_id"`
	PublicKey []byte `gorm:"type:bytea;not null" json:"public_key"`
	Signature []byte `gorm:"type:bytea;not null" json:"signature"`

	// Active marks the prekey currently advertised in key bundles. Older ones
	// are retained briefly so in-flight handshakes still resolve.
	Active bool `gorm:"index;not null;default:true" json:"-"`

	CreatedAt time.Time `json:"-"`
}

// BeforeCreate assigns a UUID when one was not supplied.
func (s *SignedPreKey) BeforeCreate(*gorm.DB) error {
	if s.ID == uuid.Nil {
		s.ID = uuid.New()
	}
	return nil
}

// OneTimePreKey is a single-use Curve25519 prekey. Consuming one during X3DH
// strengthens forward secrecy for the first message of a session.
//
// Handing the same prekey to two different peers would undermine that
// guarantee, so consumption must be atomic -- see store.PopOneTimePreKey.
type OneTimePreKey struct {
	ID       uint64    `gorm:"primaryKey;autoIncrement" json:"-"`
	DeviceID uuid.UUID `gorm:"type:uuid;not null;index:idx_otp_available,priority:1" json:"-"`

	KeyID     uint32 `gorm:"not null" json:"key_id"`
	PublicKey []byte `gorm:"type:bytea;not null" json:"public_key"`

	// ConsumedAt is nil while the key is still available. Rows are kept after
	// consumption so a replayed handshake can be recognised rather than
	// silently succeeding against a fresh key.
	ConsumedAt *time.Time `gorm:"index:idx_otp_available,priority:2" json:"-"`

	CreatedAt time.Time `json:"-"`
}

// PreKeyLowWaterMark is the pool depth below which a device should upload more
// one-time prekeys. Running dry is not fatal -- X3DH proceeds without a
// one-time prekey -- but it weakens forward secrecy for that first message.
const PreKeyLowWaterMark = 20
