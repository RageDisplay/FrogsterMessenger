package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// Chat types.
const (
	ChatTypeDirect = "direct"
	ChatTypeGroup  = "group"
)

// Chat modes.
//
// A secret chat is end-to-end encrypted: the server relays ciphertext it
// cannot read and keeps no readable history. A cloud chat is readable by the
// server, protected in transit by TLS and at rest by the storage key, and its
// history follows the user to every device.
const (
	ChatModeSecret = "secret"
	ChatModeCloud  = "cloud"
)

// Member roles.
const (
	RoleMember = "member"
	RoleAdmin  = "admin"
)

// Chat is a conversation.
type Chat struct {
	ID   uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	Type string    `gorm:"type:varchar(8);not null" json:"type"`
	Mode string    `gorm:"type:varchar(8);not null;default:'secret'" json:"mode"`

	// Title of a cloud group, sealed with the storage key. Secret groups keep
	// their title inside end-to-end encrypted messages, so it is nil there,
	// as it is for direct chats.
	Title []byte `gorm:"type:bytea" json:"-"`

	CreatorID uuid.UUID `gorm:"type:uuid" json:"creator_id"`

	// Epoch increases on every membership change. Sender keys are scoped to an
	// epoch so that a removed member's key cannot decrypt later traffic.
	Epoch uint64 `gorm:"not null;default:0" json:"epoch"`

	// AvatarVersion is 0 without an avatar; cloud groups only.
	AvatarVersion int `gorm:"not null;default:0" json:"avatar_version"`

	// HideHistory starts new members of a cloud group at the moment they
	// join, instead of showing them everything said before.
	HideHistory bool `gorm:"not null;default:false" json:"hide_history"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"-"`

	Members []ChatMember `gorm:"foreignKey:ChatID" json:"members,omitempty"`
}

// BeforeCreate assigns a UUID when one was not supplied.
func (c *Chat) BeforeCreate(*gorm.DB) error {
	if c.ID == uuid.Nil {
		c.ID = uuid.New()
	}
	return nil
}

// IsGroup reports whether the chat has more than two possible members.
func (c *Chat) IsGroup() bool { return c.Type == ChatTypeGroup }

// IsCloud reports whether the server can read and keep the chat's history.
func (c *Chat) IsCloud() bool { return c.Mode == ChatModeCloud }

// ChatMember links a user to a chat. Rows are retained after a member leaves
// so that history and epoch transitions stay auditable.
type ChatMember struct {
	ChatID uuid.UUID `gorm:"type:uuid;primaryKey" json:"chat_id"`
	UserID uuid.UUID `gorm:"type:uuid;primaryKey;index" json:"user_id"`

	Role     string     `gorm:"type:varchar(8);not null;default:'member'" json:"role"`
	JoinedAt time.Time  `json:"joined_at"`
	LeftAt   *time.Time `json:"left_at,omitempty"`

	// LastReadSeq is how far this member has read.
	LastReadSeq int64 `gorm:"not null;default:0" json:"last_read_seq"`

	// ClearedSeq is where this member's view of the history starts: moved
	// by "clear history", or set on joining a group that hides its past.
	ClearedSeq int64 `gorm:"not null;default:0" json:"-"`
}

// IsActive reports whether the member currently belongs to the chat.
func (m *ChatMember) IsActive() bool { return m.LeftAt == nil }
