package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// ChatSummary is one row of a user's chat list.
type ChatSummary struct {
	models.Chat

	// Role, LastReadSeq and ClearedSeq are the requesting user's.
	Role        string
	LastReadSeq int64
	ClearedSeq  int64

	// LastSeq is the newest seq in the chat, events included.
	LastSeq int64

	// Unread counts messages from others after LastReadSeq.
	Unread int64

	// PeerReadSeq is the furthest any other member has read: what turns a
	// sent tick into a read one.
	PeerReadSeq int64

	Members []MemberInfo

	// Last is the newest visible message of a cloud chat, opened. Secret
	// chats have nothing readable here.
	Last *CloudMessage
}

// MemberInfo describes a current member of a chat.
type MemberInfo struct {
	UserID      uuid.UUID
	Username    string
	DisplayName string
	Role        string
	LastReadSeq int64
}

// summaryRow is what the chat-list query returns before members and the
// last message are attached.
type summaryRow struct {
	models.Chat
	Role        string
	LastReadSeq int64
	ClearedSeq  int64
	LastSeq     int64
	Unread      int64
	PeerReadSeq int64
}

const summarySelect = `
SELECT c.*, me.role, me.last_read_seq, me.cleared_seq,
       COALESCE((SELECT MAX(m.seq) FROM messages m WHERE m.chat_id = c.id), 0) AS last_seq,
       (SELECT COUNT(*) FROM messages m
         WHERE m.chat_id = c.id AND m.kind = '' AND m.deleted_at IS NULL
           AND m.seq > GREATEST(me.last_read_seq, me.cleared_seq)
           AND m.sender_id <> me.user_id) AS unread,
       COALESCE((SELECT MAX(o.last_read_seq) FROM chat_members o
         WHERE o.chat_id = c.id AND o.user_id <> me.user_id AND o.left_at IS NULL), 0) AS peer_read_seq
  FROM chats c
  JOIN chat_members me ON me.chat_id = c.id AND me.user_id = ? AND me.left_at IS NULL`

// ChatsForUser lists the chats a user currently belongs to, most recently
// active first.
func (s *Store) ChatsForUser(ctx context.Context, userID uuid.UUID) ([]ChatSummary, error) {
	var rows []summaryRow
	if err := s.db.WithContext(ctx).
		Raw(summarySelect+" ORDER BY last_seq DESC, c.created_at DESC", userID).
		Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("chats for user: %w", err)
	}
	return s.completeSummaries(ctx, userID, rows)
}

// ChatSummaryFor returns one chat as the given member sees it, or
// ErrNotFound when they are not a member.
func (s *Store) ChatSummaryFor(ctx context.Context, chatID, userID uuid.UUID) (*ChatSummary, error) {
	var rows []summaryRow
	if err := s.db.WithContext(ctx).
		Raw(summarySelect+" WHERE c.id = ?", userID, chatID).
		Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("chat summary: %w", err)
	}
	if len(rows) == 0 {
		return nil, ErrNotFound
	}
	out, err := s.completeSummaries(ctx, userID, rows)
	if err != nil {
		return nil, err
	}
	return &out[0], nil
}

func (s *Store) completeSummaries(ctx context.Context, viewer uuid.UUID, rows []summaryRow) ([]ChatSummary, error) {
	if len(rows) == 0 {
		return []ChatSummary{}, nil
	}
	ids := make([]uuid.UUID, 0, len(rows))
	var cloudIDs []uuid.UUID
	for _, r := range rows {
		ids = append(ids, r.ID)
		if r.Mode == models.ChatModeCloud {
			cloudIDs = append(cloudIDs, r.ID)
		}
	}

	members, err := s.membersOf(ctx, ids)
	if err != nil {
		return nil, err
	}

	last := map[uuid.UUID]*CloudMessage{}
	if len(cloudIDs) > 0 {
		var msgs []models.Message
		if err := s.db.WithContext(ctx).Raw(`
			SELECT DISTINCT ON (m.chat_id) m.* FROM messages m
			  JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?
			 WHERE m.chat_id IN ? AND m.kind = '' AND m.deleted_at IS NULL
			   AND m.seq > cm.cleared_seq
			 ORDER BY m.chat_id, m.seq DESC`, viewer, cloudIDs).Scan(&msgs).Error; err != nil {
			return nil, fmt.Errorf("last messages: %w", err)
		}
		opened, err := s.openCloud(msgs)
		if err != nil && !errors.Is(err, ErrNoStorageKey) {
			return nil, err
		}
		for i := range opened {
			last[opened[i].ChatID] = &opened[i]
		}
	}

	out := make([]ChatSummary, 0, len(rows))
	for _, r := range rows {
		out = append(out, ChatSummary{
			Chat:        r.Chat,
			Role:        r.Role,
			LastReadSeq: r.LastReadSeq,
			ClearedSeq:  r.ClearedSeq,
			LastSeq:     r.LastSeq,
			Unread:      r.Unread,
			PeerReadSeq: r.PeerReadSeq,
			Members:     members[r.ID],
			Last:        last[r.ID],
		})
	}
	return out, nil
}

func (s *Store) membersOf(ctx context.Context, chatIDs []uuid.UUID) (map[uuid.UUID][]MemberInfo, error) {
	type row struct {
		ChatID uuid.UUID
		MemberInfo
	}
	var rows []row
	err := s.db.WithContext(ctx).Raw(`
		SELECT cm.chat_id, cm.user_id, u.username, u.display_name, cm.role, cm.last_read_seq
		  FROM chat_members cm JOIN users u ON u.id = cm.user_id
		 WHERE cm.chat_id IN ? AND cm.left_at IS NULL
		 ORDER BY cm.joined_at ASC, u.username ASC`, chatIDs).Scan(&rows).Error
	if err != nil {
		return nil, fmt.Errorf("chat members: %w", err)
	}
	out := make(map[uuid.UUID][]MemberInfo, len(chatIDs))
	for _, r := range rows {
		out[r.ChatID] = append(out[r.ChatID], r.MemberInfo)
	}
	return out, nil
}

// MarkRead moves a member's read position forward to seq, never back and
// never past the end of the chat, and returns the resulting position.
func (s *Store) MarkRead(ctx context.Context, chatID, userID uuid.UUID, seq int64) (int64, error) {
	var pos int64
	err := s.db.WithContext(ctx).Raw(`
		UPDATE chat_members
		   SET last_read_seq = GREATEST(last_read_seq,
		       LEAST(?, COALESCE((SELECT MAX(seq) FROM messages WHERE chat_id = ?), 0)))
		 WHERE chat_id = ? AND user_id = ? AND left_at IS NULL
		RETURNING last_read_seq`, seq, chatID, chatID, userID).Scan(&pos).Error
	if err != nil {
		return 0, fmt.Errorf("mark read: %w", err)
	}
	return pos, nil
}

// ClearHistory hides everything currently in a chat from one member, and
// returns the seq it was cleared up to.
func (s *Store) ClearHistory(ctx context.Context, chatID, userID uuid.UUID) (int64, error) {
	var pos int64
	err := s.db.WithContext(ctx).Raw(`
		UPDATE chat_members
		   SET cleared_seq = COALESCE((SELECT MAX(seq) FROM messages WHERE chat_id = ?), 0)
		 WHERE chat_id = ? AND user_id = ? AND left_at IS NULL
		RETURNING cleared_seq`, chatID, chatID, userID).Scan(&pos).Error
	if err != nil {
		return 0, fmt.Errorf("clear history: %w", err)
	}
	return pos, nil
}

// ClearedSeq is where a member last cleared a chat, 0 if never.
func (s *Store) ClearedSeq(ctx context.Context, chatID, userID uuid.UUID) (int64, error) {
	var pos int64
	err := s.db.WithContext(ctx).Model(&models.ChatMember{}).
		Where("chat_id = ? AND user_id = ?", chatID, userID).
		Select("cleared_seq").Scan(&pos).Error
	if err != nil {
		return 0, fmt.Errorf("cleared seq: %w", err)
	}
	return pos, nil
}

// MemberRole returns a user's role in a chat, or ErrNotFound when they are
// not a current member.
func (s *Store) MemberRole(ctx context.Context, chatID, userID uuid.UUID) (string, error) {
	var m models.ChatMember
	err := s.db.WithContext(ctx).
		Where("chat_id = ? AND user_id = ? AND left_at IS NULL", chatID, userID).
		First(&m).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("member role: %w", err)
	}
	return m.Role, nil
}

// LeaveChat removes a user from a group of their own accord.
//
// A group must not be left without an administrator, or nobody could manage
// it again: when the last one leaves, the longest-standing member takes over.
func (s *Store) LeaveChat(ctx context.Context, chatID, userID uuid.UUID) (uint64, error) {
	epoch, err := s.RemoveMember(ctx, chatID, userID)
	if err != nil {
		return 0, err
	}
	err = s.db.WithContext(ctx).Exec(`
		UPDATE chat_members SET role = 'admin'
		 WHERE chat_id = ? AND left_at IS NULL
		   AND NOT EXISTS (SELECT 1 FROM chat_members a
		                    WHERE a.chat_id = ? AND a.left_at IS NULL AND a.role = 'admin')
		   AND user_id = (SELECT user_id FROM chat_members f
		                   WHERE f.chat_id = ? AND f.left_at IS NULL
		                   ORDER BY f.joined_at ASC LIMIT 1)`,
		chatID, chatID, chatID).Error
	if err != nil {
		return epoch, fmt.Errorf("hand over admin: %w", err)
	}
	return epoch, nil
}

// MemberUserIDs lists the current members of a chat.
func (s *Store) MemberUserIDs(ctx context.Context, chatID uuid.UUID) ([]uuid.UUID, error) {
	var ids []uuid.UUID
	err := s.db.WithContext(ctx).Model(&models.ChatMember{}).
		Where("chat_id = ? AND left_at IS NULL", chatID).
		Pluck("user_id", &ids).Error
	if err != nil {
		return nil, fmt.Errorf("member ids: %w", err)
	}
	return ids, nil
}

// UserDevicesFor lists the active devices of the given users.
func (s *Store) UserDevicesFor(ctx context.Context, userIDs []uuid.UUID) ([]models.Device, error) {
	if len(userIDs) == 0 {
		return nil, nil
	}
	var devices []models.Device
	err := s.db.WithContext(ctx).
		Where("user_id IN ? AND revoked_at IS NULL", userIDs).
		Find(&devices).Error
	if err != nil {
		return nil, fmt.Errorf("user devices: %w", err)
	}
	return devices, nil
}

// SearchUsers finds accounts whose username starts with prefix, excluding
// the searching user.
func (s *Store) SearchUsers(ctx context.Context, prefix string, exclude uuid.UUID, limit int) ([]models.User, error) {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	// LIKE wildcards in the query are literal characters to the user.
	escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(prefix)
	var users []models.User
	err := s.db.WithContext(ctx).
		Where("lower(username::text) LIKE ? AND id <> ?", escaped+"%", exclude).
		Order("length(username::text) ASC, username ASC").
		Limit(limit).
		Find(&users).Error
	if err != nil {
		return nil, fmt.Errorf("search users: %w", err)
	}
	return users, nil
}

// UpdateProfile changes a user's display name and bio.
func (s *Store) UpdateProfile(ctx context.Context, userID uuid.UUID, displayName, bio string) error {
	err := s.db.WithContext(ctx).Model(&models.User{}).Where("id = ?", userID).
		Updates(map[string]any{
			"display_name": displayName,
			"bio":          bio,
			"updated_at":   time.Now(),
		}).Error
	if err != nil {
		return fmt.Errorf("update profile: %w", err)
	}
	return nil
}
