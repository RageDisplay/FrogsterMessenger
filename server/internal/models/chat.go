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

// Member roles.
const (
	RoleMember = "member"
	RoleAdmin  = "admin"
)

// Chat is a conversation. Group titles are stored as ciphertext because the
// server must not learn them; direct chats carry no title at all.
type Chat struct {
	ID   uuid.UUID `gorm:"type:uuid;primaryKey" json:"id"`
	Type string    `gorm:"type:varchar(8);not null" json:"type"`

	// Title is client-encrypted for groups and nil for direct chats.
	Title []byte `gorm:"type:bytea" json:"title,omitempty"`

	CreatorID uuid.UUID `gorm:"type:uuid" json:"creator_id"`

	// Epoch increases on every membership change. Sender keys are scoped to an
	// epoch so that a removed member's key cannot decrypt later traffic.
	Epoch uint64 `gorm:"not null;default:0" json:"epoch"`

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

// IsGroup reports whether the chat uses group (sender-key) semantics.
func (c *Chat) IsGroup() bool { return c.Type == ChatTypeGroup }

// ChatMember links a user to a chat. Rows are retained after a member leaves
// so that history and epoch transitions stay auditable.
type ChatMember struct {
	ChatID uuid.UUID `gorm:"type:uuid;primaryKey" json:"chat_id"`
	UserID uuid.UUID `gorm:"type:uuid;primaryKey;index" json:"user_id"`

	Role     string     `gorm:"type:varchar(8);not null;default:'member'" json:"role"`
	JoinedAt time.Time  `json:"joined_at"`
	LeftAt   *time.Time `json:"left_at,omitempty"`
}

// IsActive reports whether the member currently belongs to the chat.
func (m *ChatMember) IsActive() bool { return m.LeftAt == nil }
