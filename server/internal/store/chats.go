package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// CreateChat creates a chat with its initial membership.
func (s *Store) CreateChat(ctx context.Context, chat *models.Chat, memberIDs []uuid.UUID) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(chat).Error; err != nil {
			return fmt.Errorf("create chat: %w", err)
		}
		members := make([]models.ChatMember, 0, len(memberIDs))
		for _, id := range memberIDs {
			role := models.RoleMember
			if id == chat.CreatorID {
				role = models.RoleAdmin
			}
			members = append(members, models.ChatMember{
				ChatID: chat.ID,
				UserID: id,
				Role:   role,
			})
		}
		if len(members) > 0 {
			if err := tx.Create(&members).Error; err != nil {
				return fmt.Errorf("create members: %w", err)
			}
		}
		return nil
	})
}

// ChatByID loads a chat.
func (s *Store) ChatByID(ctx context.Context, id uuid.UUID) (*models.Chat, error) {
	var c models.Chat
	err := s.db.WithContext(ctx).First(&c, "id = ?", id).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("chat by id: %w", err)
	}
	return &c, nil
}

// FindDirectChat returns the existing 1:1 chat of the given mode between two
// users, if any. A pair can have one cloud and one secret chat side by side.
func (s *Store) FindDirectChat(ctx context.Context, a, b uuid.UUID, mode string) (*models.Chat, error) {
	var chat models.Chat
	err := s.db.WithContext(ctx).
		Joins("JOIN chat_members m1 ON m1.chat_id = chats.id AND m1.user_id = ?", a).
		Joins("JOIN chat_members m2 ON m2.chat_id = chats.id AND m2.user_id = ?", b).
		Where("chats.type = ? AND chats.mode = ?", models.ChatTypeDirect, mode).
		First(&chat).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find direct chat: %w", err)
	}
	return &chat, nil
}

// ActiveMembers lists the users currently in a chat.
func (s *Store) ActiveMembers(ctx context.Context, chatID uuid.UUID) ([]models.ChatMember, error) {
	var out []models.ChatMember
	err := s.db.WithContext(ctx).
		Where("chat_id = ? AND left_at IS NULL", chatID).
		Find(&out).Error
	if err != nil {
		return nil, fmt.Errorf("active members: %w", err)
	}
	return out, nil
}

// IsMember reports whether a user currently belongs to a chat. Every send path
// checks this before accepting a message.
func (s *Store) IsMember(ctx context.Context, chatID, userID uuid.UUID) (bool, error) {
	var n int64
	err := s.db.WithContext(ctx).
		Model(&models.ChatMember{}).
		Where("chat_id = ? AND user_id = ? AND left_at IS NULL", chatID, userID).
		Count(&n).Error
	if err != nil {
		return false, fmt.Errorf("is member: %w", err)
	}
	return n > 0, nil
}

// ContactDevices lists the active devices of every user who shares a chat
// with the given user, excluding the user's own devices.
//
// Used to broadcast key-change notifications: a contact needs to learn that a
// new device appeared for someone they talk to, because that is exactly what
// a server-side key substitution would look like.
func (s *Store) ContactDevices(ctx context.Context, userID uuid.UUID) ([]models.Device, error) {
	var devices []models.Device
	err := s.db.WithContext(ctx).
		Table("devices").
		Distinct("devices.*").
		Joins("JOIN chat_members peer ON peer.user_id = devices.user_id AND peer.left_at IS NULL").
		Joins("JOIN chat_members self ON self.chat_id = peer.chat_id "+
			"AND self.user_id = ? AND self.left_at IS NULL", userID).
		Where("devices.user_id <> ?", userID).
		Where("devices.revoked_at IS NULL").
		Find(&devices).Error
	if err != nil {
		return nil, fmt.Errorf("contact devices: %w", err)
	}
	return devices, nil
}

// RecipientDevices lists every active device of every current member of a
// chat, excluding the sending device. This is the fan-out target set.
func (s *Store) RecipientDevices(
	ctx context.Context,
	chatID uuid.UUID,
	excludeDeviceID uuid.UUID,
) ([]models.Device, error) {
	var devices []models.Device
	err := s.db.WithContext(ctx).
		Table("devices").
		Joins("JOIN chat_members ON chat_members.user_id = devices.user_id").
		Where("chat_members.chat_id = ? AND chat_members.left_at IS NULL", chatID).
		Where("devices.revoked_at IS NULL").
		Where("devices.id <> ?", excludeDeviceID).
		Find(&devices).Error
	if err != nil {
		return nil, fmt.Errorf("recipient devices: %w", err)
	}
	return devices, nil
}
