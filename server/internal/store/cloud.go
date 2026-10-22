package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
)

// ErrForbidden is returned when a member tries to change something that is
// not theirs to change: another member's message, or a group they do not
// administer.
var ErrForbidden = errors.New("forbidden")

// ErrNoStorageKey is returned by cloud operations on a store that was not
// given a storage key. Cloud content is never written unsealed.
var ErrNoStorageKey = errors.New("storage key not configured")

// maxEmojiLength mirrors message_reactions.emoji.
const maxEmojiLength = 16

// SetSealer installs the storage-key sealer used for cloud content.
func (s *Store) SetSealer(sealer *storagecrypto.Sealer) { s.sealer = sealer }

// CloudMessage is a stored cloud message, opened.
type CloudMessage struct {
	models.Message

	// Payload is the message as its sender wrote it, unsealed. Empty for a
	// deleted message.
	Payload []byte

	// Reactions maps each emoji to the users who reacted with it. Filled
	// in for history pages only; sync pages carry reactions as events.
	Reactions map[string][]uuid.UUID
}

// PersistCloudMessage stores a cloud message or event, sealing its payload
// for the seq it is assigned, and applies the event to its target.
//
// emoji is required for react and unreact events and ignored otherwise. The
// event row is kept alongside its effect: devices that were offline replay
// events in seq order, while history pages show messages in their current
// state.
func (s *Store) PersistCloudMessage(
	ctx context.Context,
	msg *models.Message,
	payload []byte,
	emoji string,
) error {
	if s.sealer == nil {
		return ErrNoStorageKey
	}
	switch msg.Kind {
	case models.KindMessage:
		if msg.TargetID != nil {
			return fmt.Errorf("an ordinary message has no target")
		}
	case models.KindEdit, models.KindDelete, models.KindReact, models.KindUnreact:
		if msg.TargetID == nil || *msg.TargetID == "" {
			return fmt.Errorf("%s event without a target", msg.Kind)
		}
	default:
		return fmt.Errorf("unknown message kind %q", msg.Kind)
	}
	if msg.Kind == models.KindReact || msg.Kind == models.KindUnreact {
		if emoji == "" || len(emoji) > maxEmojiLength {
			return fmt.Errorf("reaction emoji must be 1-%d bytes", maxEmojiLength)
		}
	}

	msg.CipherType = models.CipherTypeCloud
	return s.persist(ctx, msg, nil, persistHooks{
		check: func(chat *models.Chat) error {
			if !chat.IsCloud() {
				return fmt.Errorf("chat %s is not a cloud chat", chat.ID)
			}
			return nil
		},
		prepare: func(msg *models.Message) error {
			sealed, err := s.sealer.Seal(msg.ChatID, storagecrypto.PurposeMessage, msg.Seq, payload)
			if err != nil {
				return err
			}
			msg.Ciphertext = sealed
			return nil
		},
		apply: func(tx *gorm.DB, chat *models.Chat, event *models.Message) error {
			if event.Kind == models.KindMessage {
				return nil
			}
			return s.applyCloudEvent(tx, chat, event, payload, emoji)
		},
	})
}

// applyCloudEvent makes an event take effect on the message it targets.
func (s *Store) applyCloudEvent(
	tx *gorm.DB,
	chat *models.Chat,
	event *models.Message,
	payload []byte,
	emoji string,
) error {
	var target models.Message
	err := tx.Clauses(forUpdate()).
		Where("chat_id = ? AND kind = '' AND (client_id = ? OR id::text = ?)",
			chat.ID, *event.TargetID, *event.TargetID).
		Limit(1).Find(&target).Error
	if err != nil {
		return fmt.Errorf("load target: %w", err)
	}
	if target.ID == uuid.Nil || target.DeletedAt != nil {
		return ErrNotFound
	}

	now := time.Now()
	switch event.Kind {
	case models.KindEdit:
		// Only the author edits. Nobody, an admin included, may put words
		// in someone else's mouth.
		if target.SenderID != event.SenderID {
			return ErrForbidden
		}
		// Sealed for the target's own seq, so it opens where it lives.
		sealed, err := s.sealer.Seal(chat.ID, storagecrypto.PurposeMessage, target.Seq, payload)
		if err != nil {
			return err
		}
		return tx.Model(&models.Message{}).Where("id = ?", target.ID).
			Updates(map[string]any{"ciphertext": sealed, "edited_at": now}).Error

	case models.KindDelete:
		if target.SenderID != event.SenderID {
			admin, err := isAdmin(tx, chat.ID, event.SenderID)
			if err != nil {
				return err
			}
			if !chat.IsGroup() || !admin {
				return ErrForbidden
			}
		}
		// The content goes, not just a flag: a deleted message must not
		// survive in the database where the next dump would carry it.
		if err := tx.Where("message_id = ?", target.ID).
			Delete(&reactionRow{}).Error; err != nil {
			return fmt.Errorf("drop reactions: %w", err)
		}
		return tx.Model(&models.Message{}).Where("id = ?", target.ID).
			Updates(map[string]any{"ciphertext": []byte{}, "deleted_at": now}).Error

	case models.KindReact:
		return tx.Clauses(onConflictDoNothing("message_id", "user_id", "emoji")).
			Create(&reactionRow{MessageID: target.ID, UserID: event.SenderID, Emoji: emoji}).Error

	case models.KindUnreact:
		return tx.Where("message_id = ? AND user_id = ? AND emoji = ?",
			target.ID, event.SenderID, emoji).Delete(&reactionRow{}).Error
	}
	return nil
}

// reactionRow is one user's reaction to one cloud message.
type reactionRow struct {
	MessageID uuid.UUID `gorm:"type:uuid;primaryKey"`
	UserID    uuid.UUID `gorm:"type:uuid;primaryKey"`
	Emoji     string    `gorm:"primaryKey"`
	CreatedAt time.Time
}

func (reactionRow) TableName() string { return "message_reactions" }

func isAdmin(tx *gorm.DB, chatID, userID uuid.UUID) (bool, error) {
	var n int64
	err := tx.Model(&models.ChatMember{}).
		Where("chat_id = ? AND user_id = ? AND role = ? AND left_at IS NULL",
			chatID, userID, models.RoleAdmin).
		Count(&n).Error
	if err != nil {
		return false, fmt.Errorf("check admin: %w", err)
	}
	return n > 0, nil
}

// CloudHistory returns up to limit messages of a cloud chat before seq
// beforeSeq (0 for the newest), newest first, in their current state:
// edited text, deletions and reactions applied. Events are left out; their
// effect is already visible.
func (s *Store) CloudHistory(ctx context.Context, chatID uuid.UUID, beforeSeq int64, limit int) ([]CloudMessage, error) {
	q := s.db.WithContext(ctx).
		Where("chat_id = ? AND kind = ''", chatID).
		Order("seq DESC").Limit(limit)
	if beforeSeq > 0 {
		q = q.Where("seq < ?", beforeSeq)
	}
	var rows []models.Message
	if err := q.Find(&rows).Error; err != nil {
		return nil, fmt.Errorf("cloud history: %w", err)
	}
	out, err := s.openCloud(rows)
	if err != nil {
		return nil, err
	}
	return out, s.attachReactions(ctx, out)
}

// CloudSince returns up to limit rows of a cloud chat after seq afterSeq,
// oldest first, events included: what a device that last saw afterSeq has
// to replay to catch up.
func (s *Store) CloudSince(ctx context.Context, chatID uuid.UUID, afterSeq int64, limit int) ([]CloudMessage, error) {
	var rows []models.Message
	err := s.db.WithContext(ctx).
		Where("chat_id = ? AND seq > ?", chatID, afterSeq).
		Order("seq ASC").Limit(limit).
		Find(&rows).Error
	if err != nil {
		return nil, fmt.Errorf("cloud sync: %w", err)
	}
	return s.openCloud(rows)
}

func (s *Store) openCloud(rows []models.Message) ([]CloudMessage, error) {
	if s.sealer == nil {
		return nil, ErrNoStorageKey
	}
	out := make([]CloudMessage, 0, len(rows))
	for _, m := range rows {
		cm := CloudMessage{Message: m}
		if len(m.Ciphertext) > 0 {
			payload, err := s.sealer.Open(m.ChatID, storagecrypto.PurposeMessage, m.Seq, m.Ciphertext)
			if err != nil {
				// One bad row must not hide a whole chat. It is logged by
				// id and shown as empty; the key mismatch it usually means
				// is an operator error worth hearing about.
				s.log.Error("cloud message does not open", "message_id", m.ID, "chat_id", m.ChatID, "seq", m.Seq, "err", err)
			} else {
				cm.Payload = payload
			}
		}
		cm.Ciphertext = nil
		out = append(out, cm)
	}
	return out, nil
}

func (s *Store) attachReactions(ctx context.Context, msgs []CloudMessage) error {
	if len(msgs) == 0 {
		return nil
	}
	ids := make([]uuid.UUID, 0, len(msgs))
	index := make(map[uuid.UUID]int, len(msgs))
	for i, m := range msgs {
		ids = append(ids, m.ID)
		index[m.ID] = i
	}
	var rows []reactionRow
	if err := s.db.WithContext(ctx).Where("message_id IN ?", ids).
		Order("created_at ASC").Find(&rows).Error; err != nil {
		return fmt.Errorf("load reactions: %w", err)
	}
	for _, r := range rows {
		m := &msgs[index[r.MessageID]]
		if m.Reactions == nil {
			m.Reactions = map[string][]uuid.UUID{}
		}
		m.Reactions[r.Emoji] = append(m.Reactions[r.Emoji], r.UserID)
	}
	return nil
}

// SealTitle seals a cloud group's title for storage.
func (s *Store) SealTitle(chatID uuid.UUID, title string) ([]byte, error) {
	if s.sealer == nil {
		return nil, ErrNoStorageKey
	}
	return s.sealer.Seal(chatID, storagecrypto.PurposeTitle, 0, []byte(title))
}

// OpenTitle opens a title sealed with SealTitle; empty when there is none.
func (s *Store) OpenTitle(chat *models.Chat) string {
	if len(chat.Title) == 0 || s.sealer == nil || !chat.IsCloud() {
		return ""
	}
	title, err := s.sealer.Open(chat.ID, storagecrypto.PurposeTitle, 0, chat.Title)
	if err != nil {
		s.log.Error("chat title does not open", "chat_id", chat.ID, "err", err)
		return ""
	}
	return string(title)
}

// SetChatTitle replaces a cloud group's title.
func (s *Store) SetChatTitle(ctx context.Context, chatID uuid.UUID, title string) error {
	sealed, err := s.SealTitle(chatID, title)
	if err != nil {
		return err
	}
	return s.db.WithContext(ctx).Model(&models.Chat{}).Where("id = ?", chatID).
		Updates(map[string]any{"title": sealed, "updated_at": time.Now()}).Error
}

// Deleted reports whether the message was deleted for everyone.
func (m CloudMessage) Deleted() bool { return m.DeletedAt != nil }
