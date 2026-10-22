package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// ActiveSession backs a refresh token and the "active sessions" settings
// screen, letting a user see and revoke their logged-in devices.
//
// Only a SHA-256 hash of the refresh token is stored, so a database leak does
// not yield usable tokens. The client IP is likewise hashed rather than kept
// in the clear.
type ActiveSession struct {
	ID       uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	UserID   uuid.UUID `gorm:"type:uuid;index;not null" json:"user_id"`
	DeviceID uuid.UUID `gorm:"type:uuid;index;not null" json:"device_id"`

	// RefreshHash is the hex-encoded SHA-256 of the opaque refresh token.
	RefreshHash string `gorm:"type:varchar(64);uniqueIndex;not null" json:"-"`

	// PrevRefreshHash is the token this one replaced at RotatedAt. It is
	// honoured once more within a short grace period, for a client whose
	// refresh response was lost; after that, presenting it means the token
	// leaked and the session is revoked.
	PrevRefreshHash *string    `gorm:"type:varchar(64)" json:"-"`
	RotatedAt       *time.Time `json:"-"`

	UserAgent string `gorm:"type:varchar(256)" json:"user_agent,omitempty"`
	IPHash    string `gorm:"type:varchar(64)" json:"-"`

	ExpiresAt  time.Time  `gorm:"index" json:"expires_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt time.Time  `json:"last_used_at"`
}

// BeforeCreate assigns a UUID when one was not supplied.
func (s *ActiveSession) BeforeCreate(*gorm.DB) error {
	if s.ID == uuid.Nil {
		s.ID = uuid.New()
	}
	return nil
}

// IsValid reports whether the session may still be used to mint access tokens.
func (s *ActiveSession) IsValid(now time.Time) bool {
	return s.RevokedAt == nil && now.Before(s.ExpiresAt)
}
