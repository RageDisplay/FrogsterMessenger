package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// CreateSession records a refresh token for a device login.
func (s *Store) CreateSession(ctx context.Context, sess *models.ActiveSession) error {
	if err := s.db.WithContext(ctx).Create(sess).Error; err != nil {
		return fmt.Errorf("create session: %w", err)
	}
	return nil
}

// SessionByRefreshHash looks up a session by the hash of its refresh token.
func (s *Store) SessionByRefreshHash(ctx context.Context, hash string) (*models.ActiveSession, error) {
	var sess models.ActiveSession
	err := s.db.WithContext(ctx).Where("refresh_hash = ?", hash).First(&sess).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("session by refresh hash: %w", err)
	}
	return &sess, nil
}

// ListSessions returns a user's non-expired sessions for the settings screen.
func (s *Store) ListSessions(ctx context.Context, userID uuid.UUID) ([]models.ActiveSession, error) {
	var out []models.ActiveSession
	err := s.db.WithContext(ctx).
		Where("user_id = ? AND revoked_at IS NULL AND expires_at > now()", userID).
		Order("last_used_at DESC").
		Find(&out).Error
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	return out, nil
}

// RevokeSession invalidates a single session.
func (s *Store) RevokeSession(ctx context.Context, userID, sessionID uuid.UUID) error {
	res := s.db.WithContext(ctx).
		Model(&models.ActiveSession{}).
		Where("id = ? AND user_id = ? AND revoked_at IS NULL", sessionID, userID).
		Update("revoked_at", time.Now())
	if res.Error != nil {
		return fmt.Errorf("revoke session: %w", res.Error)
	}
	if res.RowsAffected == 0 {
		return ErrNotFound
	}
	return nil
}

// TouchSession records use of a refresh token.
func (s *Store) TouchSession(ctx context.Context, id uuid.UUID) error {
	return s.db.WithContext(ctx).
		Model(&models.ActiveSession{}).
		Where("id = ?", id).
		Update("last_used_at", time.Now()).Error
}

// TokenVersion reports a user's current token version and whether the device
// is still active. It implements auth.UserLookup so the middleware can reject
// tokens invalidated by a password change or device revocation before they
// expire.
func (s *Store) TokenVersion(ctx context.Context, userID, deviceID [16]byte) (int, bool, error) {
	var row struct {
		TokenVersion int
		RevokedAt    *time.Time
	}
	err := s.db.WithContext(ctx).
		Table("users").
		Select("users.token_version, devices.revoked_at").
		Joins("JOIN devices ON devices.user_id = users.id").
		Where("users.id = ? AND devices.id = ?", uuid.UUID(userID), uuid.UUID(deviceID)).
		Scan(&row).Error
	if err != nil {
		return 0, false, fmt.Errorf("token version: %w", err)
	}
	if row.TokenVersion == 0 {
		return 0, false, nil // no such user/device pair
	}
	return row.TokenVersion, row.RevokedAt == nil, nil
}
