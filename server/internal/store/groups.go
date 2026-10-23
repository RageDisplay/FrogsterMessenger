package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// ErrStaleEpoch is returned when a message or sender key is tagged with an
// epoch the chat has already moved past.
var ErrStaleEpoch = errors.New("stale epoch")

// AddMember adds a user to a group and bumps the chat epoch.
//
// The epoch increment is what tells clients to rotate sender keys. It happens
// in the same transaction as the membership change so the two can never
// disagree.
func (s *Store) AddMember(ctx context.Context, chatID, userID uuid.UUID) (uint64, error) {
	var epoch uint64
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var chat models.Chat
		if err := tx.Clauses(forUpdate()).First(&chat, "id = ?", chatID).Error; err != nil {
			return fmt.Errorf("lock chat: %w", err)
		}
		if !chat.IsGroup() {
			return errors.New("cannot add members to a direct chat")
		}

		member := models.ChatMember{
			ChatID:   chatID,
			UserID:   userID,
			Role:     models.RoleMember,
			JoinedAt: time.Now(),
		}
		// Re-joining clears any previous departure.
		changes := map[string]any{"left_at": nil, "role": models.RoleMember}
		if chat.HideHistory && chat.IsCloud() {
			// The newcomer's history starts now: the same mark "clear
			// history" uses, so the list, sync and unread counts all agree.
			// Under the chat lock, so no message can slip in between.
			var last int64
			if err := tx.Raw(`SELECT COALESCE(MAX(seq), 0) FROM messages WHERE chat_id = ?`, chatID).
				Scan(&last).Error; err != nil {
				return fmt.Errorf("history start: %w", err)
			}
			// Not last_read_seq: that would turn the old messages "read"
			// for their senders, by someone who never saw them. Unread
			// counts start at cleared_seq anyway.
			changes["cleared_seq"] = last
		}
		if err := tx.Where("chat_id = ? AND user_id = ?", chatID, userID).
			Assign(changes).
			FirstOrCreate(&member).Error; err != nil {
			return fmt.Errorf("add member: %w", err)
		}

		epoch = chat.Epoch + 1
		if err := tx.Model(&models.Chat{}).
			Where("id = ?", chatID).
			Update("epoch", epoch).Error; err != nil {
			return fmt.Errorf("bump epoch: %w", err)
		}
		return nil
	})
	return epoch, err
}

// RemoveMember removes a user from a group, bumps the epoch, and invalidates
// every sender key from the epoch they had access to.
//
// This is the most security-critical operation in group messaging. A member
// who leaves keeps a copy of every sender key they ever received, so without
// rotation they could decrypt group traffic indefinitely. Bumping the epoch
// and deleting the old distributions forces every remaining member to publish
// a fresh key that the departing member never sees.
func (s *Store) RemoveMember(ctx context.Context, chatID, userID uuid.UUID) (uint64, error) {
	var epoch uint64
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var chat models.Chat
		if err := tx.Clauses(forUpdate()).First(&chat, "id = ?", chatID).Error; err != nil {
			return fmt.Errorf("lock chat: %w", err)
		}
		if !chat.IsGroup() {
			return errors.New("cannot remove members from a direct chat")
		}

		res := tx.Model(&models.ChatMember{}).
			Where("chat_id = ? AND user_id = ? AND left_at IS NULL", chatID, userID).
			Update("left_at", time.Now())
		if res.Error != nil {
			return fmt.Errorf("remove member: %w", res.Error)
		}
		if res.RowsAffected == 0 {
			return ErrNotFound
		}

		epoch = chat.Epoch + 1
		if err := tx.Model(&models.Chat{}).
			Where("id = ?", chatID).
			Update("epoch", epoch).Error; err != nil {
			return fmt.Errorf("bump epoch: %w", err)
		}

		// Undelivered sender keys from the old epoch are useless now and must
		// not reach anyone: they were generated while the removed member was
		// present.
		if err := tx.Where("chat_id = ? AND epoch < ?", chatID, epoch).
			Delete(&models.GroupSenderKeyDistribution{}).Error; err != nil {
			return fmt.Errorf("purge stale sender keys: %w", err)
		}
		return nil
	})
	return epoch, err
}

// StoreSenderKeyDistributions queues sealed sender keys for member devices.
//
// Distributions tagged with a stale epoch are rejected: accepting them would
// let a client re-publish a key the removed member already holds.
func (s *Store) StoreSenderKeyDistributions(
	ctx context.Context,
	chatID uuid.UUID,
	epoch uint64,
	rows []models.GroupSenderKeyDistribution,
) error {
	if len(rows) == 0 {
		return nil
	}
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var chat models.Chat
		if err := tx.First(&chat, "id = ?", chatID).Error; err != nil {
			return fmt.Errorf("load chat: %w", err)
		}
		if epoch != chat.Epoch {
			return fmt.Errorf("%w: distribution is for epoch %d, chat is at %d",
				ErrStaleEpoch, epoch, chat.Epoch)
		}

		for i := range rows {
			rows[i].ChatID = chatID
			rows[i].Epoch = epoch
		}
		// A sender that lost its key state publishes a new key for the same
		// epoch; the newer one has to replace the old, or its recipients
		// could never read it again. Rows come back with their ids.
		if err := tx.Clauses(clause.OnConflict{
			Columns: []clause.Column{
				{Name: "chat_id"}, {Name: "epoch"}, {Name: "sender_dev_id"}, {Name: "recip_dev_id"},
			},
			DoUpdates: clause.Assignments(map[string]any{
				"ciphertext":  gorm.Expr("EXCLUDED.ciphertext"),
				"consumed_at": nil,
				"created_at":  gorm.Expr("now()"),
			}),
		}).Create(&rows).Error; err != nil {
			return fmt.Errorf("store sender keys: %w", err)
		}
		return nil
	})
}

// PendingSenderKeys returns sealed sender keys awaiting a device, restricted
// to the chat's current epoch.
func (s *Store) PendingSenderKeys(
	ctx context.Context,
	userID, deviceID uuid.UUID,
) ([]models.GroupSenderKeyDistribution, error) {
	var out []models.GroupSenderKeyDistribution
	err := s.db.WithContext(ctx).
		Joins("JOIN chats ON chats.id = group_sender_key_distributions.chat_id "+
			"AND chats.epoch = group_sender_key_distributions.epoch").
		Where("recip_user_id = ? AND recip_dev_id = ? AND consumed_at IS NULL",
			userID, deviceID).
		Order("group_sender_key_distributions.id ASC").
		Find(&out).Error
	if err != nil {
		return nil, fmt.Errorf("pending sender keys: %w", err)
	}
	return out, nil
}

// ConsumeSenderKeys records that a device stored the listed sender keys.
// Scoped to the device, so one device cannot retire another's.
func (s *Store) ConsumeSenderKeys(ctx context.Context, userID, deviceID uuid.UUID, ids []uint64) error {
	if len(ids) == 0 {
		return nil
	}
	err := s.db.WithContext(ctx).
		Model(&models.GroupSenderKeyDistribution{}).
		Where("id IN ? AND recip_user_id = ? AND recip_dev_id = ? AND consumed_at IS NULL",
			ids, userID, deviceID).
		Update("consumed_at", time.Now()).Error
	if err != nil {
		return fmt.Errorf("consume sender keys: %w", err)
	}
	return nil
}

// MarkSenderKeysConsumed records that a device received its sender keys.
func (s *Store) MarkSenderKeysConsumed(ctx context.Context, ids []uint64) error {
	if len(ids) == 0 {
		return nil
	}
	err := s.db.WithContext(ctx).
		Model(&models.GroupSenderKeyDistribution{}).
		Where("id IN ?", ids).
		Update("consumed_at", time.Now()).Error
	if err != nil {
		return fmt.Errorf("mark sender keys consumed: %w", err)
	}
	return nil
}

// ChatEpoch returns a chat's current epoch.
func (s *Store) ChatEpoch(ctx context.Context, chatID uuid.UUID) (uint64, error) {
	var chat models.Chat
	if err := s.db.WithContext(ctx).
		Select("epoch").First(&chat, "id = ?", chatID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return 0, ErrNotFound
		}
		return 0, fmt.Errorf("chat epoch: %w", err)
	}
	return chat.Epoch, nil
}
