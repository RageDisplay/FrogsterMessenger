package store

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// DeletedUsernamePrefix marks the account name left behind by a deletion.
const DeletedUsernamePrefix = "deleted-"

// AccountDeletion reports what deleting an account touched, so the callers
// can tell the people affected.
type AccountDeletion struct {
	// Groups maps each group the user left to its new epoch.
	Groups map[uuid.UUID]uint64
}

// DeleteAccount closes an account for good.
//
// Its messages stay where they are: other members' cloud history is theirs,
// and removing a chat's newest rows would let a seq be handed out twice --
// devices already past it would then miss the message that reuses it. What
// goes is everything that let the account act: devices with their keys,
// sessions and queued mail, its memberships, its password and its name,
// which becomes free for someone else.
func (s *Store) DeleteAccount(ctx context.Context, userID uuid.UUID) (AccountDeletion, error) {
	out := AccountDeletion{Groups: map[uuid.UUID]uint64{}}

	var groups []uuid.UUID
	if err := s.db.WithContext(ctx).
		Table("chat_members").
		Joins("JOIN chats ON chats.id = chat_members.chat_id").
		Where("chat_members.user_id = ? AND chat_members.left_at IS NULL AND chats.type = ?",
			userID, models.ChatTypeGroup).
		Pluck("chat_members.chat_id", &groups).Error; err != nil {
		return out, fmt.Errorf("list groups: %w", err)
	}
	// Leaving each group moves it to a new epoch, so the departing devices'
	// sender keys are useless from here on.
	for _, chatID := range groups {
		epoch, err := s.LeaveChat(ctx, chatID, userID)
		if err != nil {
			return out, fmt.Errorf("leave group %s: %w", chatID, err)
		}
		out.Groups[chatID] = epoch
	}

	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		now := time.Now()
		if err := tx.Model(&models.ChatMember{}).
			Where("user_id = ? AND left_at IS NULL", userID).
			Update("left_at", now).Error; err != nil {
			return fmt.Errorf("leave chats: %w", err)
		}
		// Devices cascade to their keys, sessions and queued deliveries.
		if err := tx.Where("user_id = ?", userID).Delete(&models.Device{}).Error; err != nil {
			return fmt.Errorf("delete devices: %w", err)
		}
		// "!" is no bcrypt hash, so no password can ever match it again.
		res := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]any{
			"username":      DeletedUsernamePrefix + userID.String(),
			"display_name":  "",
			"bio":           "",
			"password_hash": "!",
			"token_version": gorm.Expr("token_version + 1"),
			"updated_at":    now,
		})
		if res.Error != nil {
			return fmt.Errorf("close account: %w", res.Error)
		}
		if res.RowsAffected == 0 {
			return ErrNotFound
		}
		return nil
	})
	return out, err
}
