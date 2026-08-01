package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// User is an account. The server stores only a bcrypt password hash; it never
// holds any key material capable of decrypting message content.
type User struct {
	ID          uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	Username    string    `gorm:"type:citext;uniqueIndex;not null" json:"username"`
	DisplayName string    `gorm:"type:varchar(64)" json:"display_name"`

	// PasswordHash is a bcrypt digest (60 chars). Never serialized to clients.
	PasswordHash string `gorm:"type:varchar(72);not null" json:"-"`

	// TokenVersion is bumped on password change to invalidate every previously
	// issued access token for this user in one step.
	TokenVersion int `gorm:"not null;default:1" json:"-"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"-"`

	Devices []Device `gorm:"foreignKey:UserID;constraint:OnDelete:CASCADE" json:"devices,omitempty"`
}

// BeforeCreate assigns a UUID when one was not supplied.
func (u *User) BeforeCreate(*gorm.DB) error {
	if u.ID == uuid.Nil {
		u.ID = uuid.New()
	}
	return nil
}
