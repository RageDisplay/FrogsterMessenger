package store

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// searchScanPerChat bounds how far back one search looks in each chat.
// Messages are sealed at rest, so searching means opening them; this keeps
// a search on a long-lived chat to a fraction of a second.
const searchScanPerChat = 20000

// searchBatch is how many messages are opened at a time.
const searchBatch = 500

// SearchHit is a cloud message that matched a search.
type SearchHit struct {
	CloudMessage
}

// SearchCloud finds the user's cloud messages whose text or file name
// contains query, ignoring case, newest first.
//
// It looks only where the user can: chats they are in, after the point
// they cleared to or joined at. Secret chats are not here at all -- the
// server cannot read them, so they are searched on the device.
func (s *Store) SearchCloud(ctx context.Context, userID uuid.UUID, query string, limit int) ([]SearchHit, error) {
	needle := strings.ToLower(strings.TrimSpace(query))
	if needle == "" || limit <= 0 {
		return nil, nil
	}
	var chats []struct {
		ChatID     uuid.UUID
		ClearedSeq int64
	}
	if err := s.db.WithContext(ctx).Raw(`
		SELECT cm.chat_id, cm.cleared_seq FROM chat_members cm
		  JOIN chats c ON c.id = cm.chat_id
		 WHERE cm.user_id = ? AND cm.left_at IS NULL AND c.mode = ?`,
		userID, models.ChatModeCloud).Scan(&chats).Error; err != nil {
		return nil, fmt.Errorf("search chats: %w", err)
	}

	var hits []SearchHit
	for _, chat := range chats {
		found, err := s.searchChat(ctx, chat.ChatID, chat.ClearedSeq, needle, limit)
		if err != nil {
			return nil, err
		}
		hits = append(hits, found...)
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].CreatedAt.After(hits[j].CreatedAt) })
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits, nil
}

func (s *Store) searchChat(ctx context.Context, chatID uuid.UUID, floor int64, needle string, limit int) ([]SearchHit, error) {
	var hits []SearchHit
	before := int64(0)
	for scanned := 0; scanned < searchScanPerChat && len(hits) < limit; {
		q := s.db.WithContext(ctx).
			Where("chat_id = ? AND kind = '' AND deleted_at IS NULL AND seq > ?", chatID, floor).
			Order("seq DESC").Limit(searchBatch)
		if before > 0 {
			q = q.Where("seq < ?", before)
		}
		var rows []models.Message
		if err := q.Find(&rows).Error; err != nil {
			return nil, fmt.Errorf("search messages: %w", err)
		}
		if len(rows) == 0 {
			break
		}
		scanned += len(rows)
		before = rows[len(rows)-1].Seq
		opened, err := s.openCloud(rows)
		if err != nil {
			return nil, err
		}
		for _, m := range opened {
			if payloadMatches(m.Payload, needle) {
				hits = append(hits, SearchHit{CloudMessage: m})
				if len(hits) == limit {
					break
				}
			}
		}
	}
	return hits, nil
}

// payloadMatches looks into what a cloud message says: its text and the
// name of any file it carries.
func payloadMatches(payload []byte, needle string) bool {
	var p struct {
		Body       string `json:"body"`
		Attachment *struct {
			Name string `json:"name"`
		} `json:"attachment"`
	}
	if json.Unmarshal(payload, &p) != nil {
		return false
	}
	if strings.Contains(strings.ToLower(p.Body), needle) {
		return true
	}
	return p.Attachment != nil && strings.Contains(strings.ToLower(p.Attachment.Name), needle)
}
