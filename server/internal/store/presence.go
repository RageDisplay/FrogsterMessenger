package store

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// PresenceInfo is what presence needs to know about one user.
type PresenceInfo struct {
	LastSeen *time.Time
	Visible  bool
}

// PresenceStatus is one user's presence as one viewer may see it.
type PresenceStatus struct {
	UserID   uuid.UUID
	Status   string
	LastSeen *time.Time // only for an exact "offline"
}

// ContactsOf lists the other people who share a current chat with a user:
// the ones who see whether they are online.
func (s *Store) ContactsOf(ctx context.Context, userID uuid.UUID) ([]uuid.UUID, error) {
	var ids []uuid.UUID
	err := s.db.WithContext(ctx).Raw(`
		SELECT DISTINCT other.user_id
		  FROM chat_members me
		  JOIN chat_members other ON other.chat_id = me.chat_id
		 WHERE me.user_id = ? AND me.left_at IS NULL
		   AND other.user_id <> ? AND other.left_at IS NULL`, userID, userID).
		Scan(&ids).Error
	if err != nil {
		return nil, fmt.Errorf("contacts: %w", err)
	}
	return ids, nil
}

// PresenceInfo returns last-seen times and visibility for the given users.
func (s *Store) PresenceInfo(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]PresenceInfo, error) {
	out := make(map[uuid.UUID]PresenceInfo, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	var rows []struct {
		ID              uuid.UUID
		LastSeenAt      *time.Time
		LastSeenVisible bool
	}
	if err := s.db.WithContext(ctx).Model(&models.User{}).
		Select("id, last_seen_at, last_seen_visible").
		Where("id IN ?", ids).Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("presence info: %w", err)
	}
	for _, r := range rows {
		out[r.ID] = PresenceInfo{LastSeen: r.LastSeenAt, Visible: r.LastSeenVisible}
	}
	return out, nil
}

// SetLastSeen records when a user was last online.
func (s *Store) SetLastSeen(ctx context.Context, userID uuid.UUID, at time.Time) error {
	return s.db.WithContext(ctx).Model(&models.User{}).Where("id = ?", userID).
		UpdateColumn("last_seen_at", at).Error
}

// SetLastSeenVisible changes whether others see a user's last-seen time.
func (s *Store) SetLastSeenVisible(ctx context.Context, userID uuid.UUID, visible bool) error {
	return s.db.WithContext(ctx).Model(&models.User{}).Where("id = ?", userID).
		UpdateColumn("last_seen_visible", visible).Error
}
