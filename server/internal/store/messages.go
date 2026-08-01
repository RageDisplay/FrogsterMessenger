package store

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// PersistMessage stores a message and its per-device delivery rows in one
// transaction, assigning the next per-chat sequence number.
//
// Sequence assignment happens under a row lock on the chat so that concurrent
// senders cannot receive the same seq, which would break the total ordering
// clients rely on to detect gaps.
func (s *Store) PersistMessage(
	ctx context.Context,
	msg *models.Message,
	recipients []models.MessageDelivery,
) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// Lock the chat row to serialise sequence assignment.
		var chat models.Chat
		if err := tx.Clauses(forUpdate()).First(&chat, "id = ?", msg.ChatID).Error; err != nil {
			return fmt.Errorf("lock chat: %w", err)
		}

		var maxSeq *int64
		if err := tx.Model(&models.Message{}).
			Where("chat_id = ?", msg.ChatID).
			Select("MAX(seq)").
			Scan(&maxSeq).Error; err != nil {
			return fmt.Errorf("read max seq: %w", err)
		}
		msg.Seq = 1
		if maxSeq != nil {
			msg.Seq = *maxSeq + 1
		}

		if err := tx.Create(msg).Error; err != nil {
			return fmt.Errorf("create message: %w", err)
		}

		if len(recipients) > 0 {
			for i := range recipients {
				recipients[i].MessageID = msg.ID
				if recipients[i].State == "" {
					recipients[i].State = models.DeliveryPending
				}
			}
			if err := tx.Clauses(onConflictDoNothing("message_id", "device_id")).
				Create(&recipients).Error; err != nil {
				return fmt.Errorf("create deliveries: %w", err)
			}
		}
		return nil
	})
}

// PendingDeliveries returns a device's queued mail in arrival order.
//
// Ordering by the delivery id (monotonic) rather than by timestamp avoids
// ties and clock skew, so a client draining its queue sees a stable sequence.
func (s *Store) PendingDeliveries(
	ctx context.Context,
	userID, deviceID uuid.UUID,
	limit int,
) ([]models.MessageDelivery, error) {
	var out []models.MessageDelivery
	err := s.db.WithContext(ctx).
		Where("user_id = ? AND device_id = ? AND state = ?",
			userID, deviceID, models.DeliveryPending).
		Order("id ASC").
		Limit(limit).
		Find(&out).Error
	if err != nil {
		return nil, fmt.Errorf("pending deliveries: %w", err)
	}
	return out, nil
}

// MessagesByIDs loads messages by id, for group deliveries whose ciphertext
// lives on the message row rather than per device.
func (s *Store) MessagesByIDs(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]models.Message, error) {
	if len(ids) == 0 {
		return map[uuid.UUID]models.Message{}, nil
	}
	var rows []models.Message
	if err := s.db.WithContext(ctx).Where("id IN ?", ids).Find(&rows).Error; err != nil {
		return nil, fmt.Errorf("messages by ids: %w", err)
	}
	out := make(map[uuid.UUID]models.Message, len(rows))
	for _, m := range rows {
		out[m.ID] = m
	}
	return out, nil
}

// MarkDelivered flips delivery rows to delivered once the client has them.
func (s *Store) MarkDelivered(ctx context.Context, ids []uint64) error {
	if len(ids) == 0 {
		return nil
	}
	err := s.db.WithContext(ctx).
		Model(&models.MessageDelivery{}).
		Where("id IN ? AND state = ?", ids, models.DeliveryPending).
		Updates(map[string]any{
			"state":        models.DeliveryDelivered,
			"delivered_at": time.Now(),
		}).Error
	if err != nil {
		return fmt.Errorf("mark delivered: %w", err)
	}
	return nil
}

// CountPending reports how much mail is queued for a device.
func (s *Store) CountPending(ctx context.Context, userID, deviceID uuid.UUID) (int64, error) {
	var n int64
	err := s.db.WithContext(ctx).
		Model(&models.MessageDelivery{}).
		Where("user_id = ? AND device_id = ? AND state = ?",
			userID, deviceID, models.DeliveryPending).
		Count(&n).Error
	if err != nil {
		return 0, fmt.Errorf("count pending: %w", err)
	}
	return n, nil
}
