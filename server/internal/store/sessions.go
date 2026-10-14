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

// RevokeSession invalidates a single session and retires the device behind it.
//
// Revoking the session alone would only invalidate a token. The device would
// stay active in the key directory, so peers would keep fetching its bundle
// and encrypting to a device nobody can read from -- the exact situation after
// someone replaces a phone and signs the old one out. Both are updated in one
// transaction so a partial failure cannot leave a signed-out device still
// receiving ciphertext.
// Returns the id of the device that was retired, so callers can tell peers
// which device to stop encrypting to.
func (s *Store) RevokeSession(ctx context.Context, userID, sessionID uuid.UUID) (uuid.UUID, error) {
	var deviceID uuid.UUID

	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		now := time.Now()

		var sess models.ActiveSession
		err := tx.Where("id = ? AND user_id = ? AND revoked_at IS NULL", sessionID, userID).
			First(&sess).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load session: %w", err)
		}
		deviceID = sess.DeviceID

		if err := tx.Model(&models.ActiveSession{}).
			Where("id = ?", sessionID).
			Update("revoked_at", now).Error; err != nil {
			return fmt.Errorf("revoke session: %w", err)
		}

		// Scoped by user id as well, so a forged session row could not retire
		// another account's device.
		if err := tx.Model(&models.Device{}).
			Where("id = ? AND user_id = ? AND revoked_at IS NULL", sess.DeviceID, userID).
			Update("revoked_at", now).Error; err != nil {
			return fmt.Errorf("revoke device: %w", err)
		}

		return nil
	})

	return deviceID, err
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

// ErrRefreshReuse reports that a refresh token was presented after it had
// already been rotated away, outside the retry grace period. Only two parties
// can hold an old token -- the client and whoever copied it -- so the session
// is revoked.
var ErrRefreshReuse = errors.New("refresh token reuse")

// RotateRefreshToken exchanges a refresh token for a new one.
//
// presentedHash is the hash of the token the client sent. On success the
// session's token becomes newHash and the session is returned.
//
// The token being replaced stays acceptable for grace after the first
// rotation, so a client whose response was lost in transit can retry; that
// retry rotates again and invalidates the token the client never received.
// The grace window is measured from the first rotation and never extended, so
// a stolen old token cannot be kept alive by replaying it.
func (s *Store) RotateRefreshToken(
	ctx context.Context,
	presentedHash, newHash string,
	grace time.Duration,
) (*models.ActiveSession, error) {
	var (
		out    models.ActiveSession
		reused bool
	)

	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		now := time.Now()

		var sess models.ActiveSession
		err := tx.Clauses(forUpdate()).
			Where("refresh_hash = ?", presentedHash).
			Limit(1).Find(&sess).Error
		if err != nil {
			return fmt.Errorf("load session: %w", err)
		}

		if sess.ID == uuid.Nil {
			// Not the current token. Perhaps the one before it.
			err := tx.Clauses(forUpdate()).
				Where("prev_refresh_hash = ?", presentedHash).
				Limit(1).Find(&sess).Error
			if err != nil {
				return fmt.Errorf("load session by previous token: %w", err)
			}
			if sess.ID == uuid.Nil || !sess.IsValid(now) {
				return ErrNotFound
			}
			if sess.RotatedAt == nil || now.Sub(*sess.RotatedAt) > grace {
				if err := tx.Model(&models.ActiveSession{}).
					Where("id = ?", sess.ID).
					Update("revoked_at", now).Error; err != nil {
					return fmt.Errorf("revoke reused session: %w", err)
				}
				// Reported after the transaction: returning an error from
				// here would roll the revocation back.
				reused = true
				return nil
			}
			// A retry inside the grace window: rotate again, keeping the
			// original rotation time.
			if err := tx.Model(&models.ActiveSession{}).
				Where("id = ?", sess.ID).
				Updates(map[string]any{
					"refresh_hash": newHash,
					"last_used_at": now,
				}).Error; err != nil {
				return fmt.Errorf("rotate refresh token: %w", err)
			}
			sess.RefreshHash = newHash
			out = sess
			return nil
		}

		if !sess.IsValid(now) {
			return ErrNotFound
		}
		prev := presentedHash
		if err := tx.Model(&models.ActiveSession{}).
			Where("id = ?", sess.ID).
			Updates(map[string]any{
				"refresh_hash":      newHash,
				"prev_refresh_hash": prev,
				"rotated_at":        now,
				"last_used_at":      now,
			}).Error; err != nil {
			return fmt.Errorf("rotate refresh token: %w", err)
		}
		sess.RefreshHash = newHash
		sess.PrevRefreshHash = &prev
		sess.RotatedAt = &now
		out = sess
		return nil
	})
	if err != nil {
		return nil, err
	}
	if reused {
		return nil, ErrRefreshReuse
	}
	return &out, nil
}

// RevokeDeviceSessions ends every session of one device without retiring the
// device itself: the user signs out here but keeps their keys, and signing
// back in resumes the same device.
func (s *Store) RevokeDeviceSessions(ctx context.Context, userID, deviceID uuid.UUID) error {
	err := s.db.WithContext(ctx).
		Model(&models.ActiveSession{}).
		Where("user_id = ? AND device_id = ? AND revoked_at IS NULL", userID, deviceID).
		Update("revoked_at", time.Now()).Error
	if err != nil {
		return fmt.Errorf("revoke device sessions: %w", err)
	}
	return nil
}

// ChangePassword stores a new password hash, invalidates every access token
// the user holds, and ends all sessions. Returns the new token version.
//
// All sessions end, including the caller's: the caller receives fresh tokens
// from a new session, and anything still holding an old refresh token -- a
// possibly compromised device being the reason people change passwords -- has
// to sign in with the new password.
func (s *Store) ChangePassword(ctx context.Context, userID uuid.UUID, newHash string) (int, error) {
	var version int
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(forUpdate()).First(&user, "id = ?", userID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrNotFound
			}
			return fmt.Errorf("load user: %w", err)
		}
		version = user.TokenVersion + 1
		if err := tx.Model(&models.User{}).
			Where("id = ?", userID).
			Updates(map[string]any{
				"password_hash": newHash,
				"token_version": version,
				"updated_at":    time.Now(),
			}).Error; err != nil {
			return fmt.Errorf("update password: %w", err)
		}
		if err := tx.Model(&models.ActiveSession{}).
			Where("user_id = ? AND revoked_at IS NULL", userID).
			Update("revoked_at", time.Now()).Error; err != nil {
			return fmt.Errorf("revoke sessions: %w", err)
		}
		return nil
	})
	return version, err
}
