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
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
)

// MaxAvatarBytes bounds a stored avatar. The app sends a small square
// picture; anything near this size is not one.
const MaxAvatarBytes = 512 << 10

type avatarRow struct {
	OwnerID   uuid.UUID `gorm:"type:uuid;primaryKey"`
	Version   int
	Data      []byte
	UpdatedAt time.Time
}

func (avatarRow) TableName() string { return "avatars" }

// SetUserAvatar replaces a user's avatar and returns its new version.
func (s *Store) SetUserAvatar(ctx context.Context, userID uuid.UUID, image []byte) (int, error) {
	return s.setAvatar(ctx, &models.User{}, userID, image)
}

// SetChatAvatar replaces a group's avatar and returns its new version.
func (s *Store) SetChatAvatar(ctx context.Context, chatID uuid.UUID, image []byte) (int, error) {
	return s.setAvatar(ctx, &models.Chat{}, chatID, image)
}

// ClearUserAvatar removes a user's avatar.
func (s *Store) ClearUserAvatar(ctx context.Context, userID uuid.UUID) error {
	return s.clearAvatar(ctx, &models.User{}, userID)
}

// ClearChatAvatar removes a group's avatar.
func (s *Store) ClearChatAvatar(ctx context.Context, chatID uuid.UUID) error {
	return s.clearAvatar(ctx, &models.Chat{}, chatID)
}

// setAvatar stores the picture and bumps the owner's version in one
// transaction, so a client that sees the new version always finds the new
// picture.
func (s *Store) setAvatar(ctx context.Context, owner any, ownerID uuid.UUID, image []byte) (int, error) {
	if s.sealer == nil {
		return 0, ErrNoStorageKey
	}
	if len(image) == 0 || len(image) > MaxAvatarBytes {
		return 0, fmt.Errorf("avatar of %d bytes", len(image))
	}
	var version int
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var current struct{ AvatarVersion int }
		res := tx.Model(owner).Clauses(forUpdate()).Select("avatar_version").
			Where("id = ?", ownerID).Limit(1).Scan(&current)
		if res.Error != nil {
			return fmt.Errorf("lock avatar owner: %w", res.Error)
		}
		if res.RowsAffected == 0 {
			return ErrNotFound
		}
		// Negative after a removal; the count carries on from there.
		version = max(current.AvatarVersion, -current.AvatarVersion) + 1
		sealed, err := s.sealer.Seal(ownerID, storagecrypto.PurposeAvatar, int64(version), image)
		if err != nil {
			return fmt.Errorf("seal avatar: %w", err)
		}
		row := avatarRow{OwnerID: ownerID, Version: version, Data: sealed, UpdatedAt: time.Now()}
		if err := tx.Clauses(clause.OnConflict{UpdateAll: true}).Create(&row).Error; err != nil {
			return fmt.Errorf("store avatar: %w", err)
		}
		return tx.Model(owner).Where("id = ?", ownerID).Update("avatar_version", version).Error
	})
	return version, err
}

// clearAvatar deletes the picture. The version still moves on, so clients
// holding the old one notice it is gone.
func (s *Store) clearAvatar(ctx context.Context, owner any, ownerID uuid.UUID) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("owner_id = ?", ownerID).Delete(&avatarRow{}).Error; err != nil {
			return fmt.Errorf("delete avatar: %w", err)
		}
		// Kept negative while there is no picture: a client compares
		// versions, and "none" has to differ from every version it held.
		return tx.Model(owner).Where("id = ? AND avatar_version > 0", ownerID).
			Update("avatar_version", gorm.Expr("-(avatar_version + 1)")).Error
	})
}

// Avatar returns the picture of a user or group and its version, or
// ErrNotFound when there is none.
func (s *Store) Avatar(ctx context.Context, ownerID uuid.UUID) ([]byte, int, error) {
	if s.sealer == nil {
		return nil, 0, ErrNoStorageKey
	}
	var row avatarRow
	err := s.db.WithContext(ctx).Where("owner_id = ?", ownerID).Take(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, fmt.Errorf("load avatar: %w", err)
	}
	image, err := s.sealer.Open(ownerID, storagecrypto.PurposeAvatar, int64(row.Version), row.Data)
	if err != nil {
		return nil, 0, fmt.Errorf("open avatar: %w", err)
	}
	return image, row.Version, nil
}
