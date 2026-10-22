package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// ErrNotFound is returned when a lookup matches no row.
var ErrNotFound = errors.New("not found")

// ErrUsernameTaken is returned when registration collides with an existing
// account.
var ErrUsernameTaken = errors.New("username already taken")

// CreateUserWithDevice registers a new account together with its first device
// and that device's key material, in one transaction.
//
// The server stores the uploaded public keys verbatim. It does not, and
// cannot, verify that the client holds the matching private keys -- that is
// the documented trust model, and it is why clients must pin peer identity
// keys on first use and surface safety-number changes.
func (s *Store) CreateUserWithDevice(
	ctx context.Context,
	user *models.User,
	device *models.Device,
	spk *models.SignedPreKey,
	otps []models.OneTimePreKey,
) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(user).Error; err != nil {
			if isUniqueViolation(err) {
				return ErrUsernameTaken
			}
			return fmt.Errorf("create user: %w", err)
		}

		device.UserID = user.ID
		if err := tx.Create(device).Error; err != nil {
			return fmt.Errorf("create device: %w", err)
		}

		spk.DeviceID = device.ID
		spk.Active = true
		if err := tx.Create(spk).Error; err != nil {
			return fmt.Errorf("create signed prekey: %w", err)
		}

		if len(otps) > 0 {
			for i := range otps {
				otps[i].DeviceID = device.ID
			}
			if err := tx.Clauses(onConflictDoNothing("device_id", "key_id")).
				Create(&otps).Error; err != nil {
				return fmt.Errorf("create one-time prekeys: %w", err)
			}
		}
		return nil
	})
}

// UserByUsername looks up an account by its case-insensitive username.
func (s *Store) UserByUsername(ctx context.Context, username string) (*models.User, error) {
	var u models.User
	err := s.db.WithContext(ctx).Where("username = ?", username).First(&u).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("user by username: %w", err)
	}
	return &u, nil
}

// UserByID looks up an account by id.
func (s *Store) UserByID(ctx context.Context, id uuid.UUID) (*models.User, error) {
	var u models.User
	err := s.db.WithContext(ctx).First(&u, "id = ?", id).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("user by id: %w", err)
	}
	return &u, nil
}

// ActiveDevices lists a user's non-revoked devices. Message fan-out expands a
// recipient into this set.
func (s *Store) ActiveDevices(ctx context.Context, userID uuid.UUID) ([]models.Device, error) {
	var devices []models.Device
	err := s.db.WithContext(ctx).
		Where("user_id = ? AND revoked_at IS NULL", userID).
		Order("created_at").
		Find(&devices).Error
	if err != nil {
		return nil, fmt.Errorf("active devices: %w", err)
	}
	return devices, nil
}

// DeviceByID fetches a single device.
func (s *Store) DeviceByID(ctx context.Context, id uuid.UUID) (*models.Device, error) {
	var d models.Device
	err := s.db.WithContext(ctx).First(&d, "id = ?", id).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("device by id: %w", err)
	}
	return &d, nil
}

// AddDevice registers an additional device for an existing user.
func (s *Store) AddDevice(
	ctx context.Context,
	device *models.Device,
	spk *models.SignedPreKey,
	otps []models.OneTimePreKey,
) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(device).Error; err != nil {
			return fmt.Errorf("create device: %w", err)
		}
		spk.DeviceID = device.ID
		spk.Active = true
		if err := tx.Create(spk).Error; err != nil {
			return fmt.Errorf("create signed prekey: %w", err)
		}
		if len(otps) > 0 {
			for i := range otps {
				otps[i].DeviceID = device.ID
			}
			if err := tx.Clauses(onConflictDoNothing("device_id", "key_id")).
				Create(&otps).Error; err != nil {
				return fmt.Errorf("create one-time prekeys: %w", err)
			}
		}
		return nil
	})
}

// TouchDevice records that a device was seen online.
func (s *Store) TouchDevice(ctx context.Context, deviceID uuid.UUID) error {
	return s.db.WithContext(ctx).
		Model(&models.Device{}).
		Where("id = ?", deviceID).
		Update("last_seen_at", gorm.Expr("now()")).Error
}

// isUniqueViolation reports whether err is a PostgreSQL unique-constraint
// violation (SQLSTATE 23505).
func isUniqueViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	if errors.As(err, &pgErr) {
		return pgErr.SQLState() == "23505"
	}
	return errors.Is(err, gorm.ErrDuplicatedKey)
}
