package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// Device is one installation of the client belonging to a user. Every device
// runs its own Double Ratchet sessions, so messages are addressed to a
// (UserID, DeviceID) pair rather than to a user.
type Device struct {
	ID     uuid.UUID `gorm:"type:uuid;primaryKey" json:"device_id"`
	UserID uuid.UUID `gorm:"type:uuid;index;not null" json:"user_id"`

	// RegistrationID is the client-chosen Signal registration id, unique per
	// user. It lets peers distinguish a reinstalled device from the old one.
	RegistrationID uint32 `gorm:"not null" json:"registration_id"`

	DeviceName string `gorm:"type:varchar(64)" json:"device_name"`

	// IdentityKeyPub is the long-term Curve25519 public key (33 bytes, DJB
	// type-prefixed), used for Diffie-Hellman during X3DH.
	IdentityKeyPub []byte `gorm:"type:bytea;not null" json:"identity_key"`

	// IdentityKeyEd25519 is the long-term Ed25519 public key (32 bytes) used
	// to verify signed prekeys and sender keys.
	//
	// A device carries two identity keys because Curve25519 cannot sign and
	// Ed25519 cannot perform DH. See docs/adr/0002 for why this is preferred
	// over deriving signatures from the DH key via XEdDSA.
	IdentityKeyEd25519 []byte `gorm:"type:bytea" json:"identity_key_ed25519,omitempty"`

	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	RevokedAt  *time.Time `gorm:"index" json:"revoked_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`

	SignedPreKeys  []SignedPreKey  `gorm:"foreignKey:DeviceID;constraint:OnDelete:CASCADE" json:"-"`
	OneTimePreKeys []OneTimePreKey `gorm:"foreignKey:DeviceID;constraint:OnDelete:CASCADE" json:"-"`
}

// BeforeCreate assigns a UUID when one was not supplied.
func (d *Device) BeforeCreate(*gorm.DB) error {
	if d.ID == uuid.Nil {
		d.ID = uuid.New()
	}
	return nil
}

// IsActive reports whether the device may still authenticate and receive mail.
func (d *Device) IsActive() bool { return d.RevokedAt == nil }
