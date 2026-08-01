package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"gorm.io/gorm"

	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// ErrNoPreKeyAvailable is returned when a device's one-time prekey pool is
// empty. This is not fatal: X3DH proceeds without a one-time prekey, at the
// cost of weaker forward secrecy for the first message of the session.
var ErrNoPreKeyAvailable = errors.New("no one-time prekey available")

// PopOneTimePreKey atomically claims one unused prekey for the given device.
//
// Handing the same prekey to two peers would break the forward-secrecy
// guarantee it exists to provide, so claiming must be atomic under concurrent
// GET /keys requests. The UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP
// LOCKED) form lets concurrent callers skip rows another transaction is
// already claiming instead of blocking or colliding on one.
//
// Returns ErrNoPreKeyAvailable when the pool is drained.
func (s *Store) PopOneTimePreKey(ctx context.Context, deviceID uuid.UUID) (*models.OneTimePreKey, error) {
	const q = `
UPDATE one_time_pre_keys
SET consumed_at = now()
WHERE id = (
    SELECT id FROM one_time_pre_keys
    WHERE device_id = ? AND consumed_at IS NULL
    ORDER BY key_id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING id, device_id, key_id, public_key, consumed_at, created_at`

	var out models.OneTimePreKey
	err := s.db.WithContext(ctx).Raw(q, deviceID).Scan(&out).Error
	if err != nil {
		return nil, fmt.Errorf("pop one-time prekey: %w", err)
	}
	// Scan leaves the struct zeroed when no row matched.
	if out.ID == 0 {
		return nil, ErrNoPreKeyAvailable
	}
	return &out, nil
}

// CountAvailablePreKeys reports how many unused one-time prekeys remain, so
// the client can be told to replenish before the pool runs dry.
func (s *Store) CountAvailablePreKeys(ctx context.Context, deviceID uuid.UUID) (int64, error) {
	var n int64
	err := s.db.WithContext(ctx).
		Model(&models.OneTimePreKey{}).
		Where("device_id = ? AND consumed_at IS NULL", deviceID).
		Count(&n).Error
	if err != nil {
		return 0, fmt.Errorf("count prekeys: %w", err)
	}
	return n, nil
}

// AddOneTimePreKeys appends prekeys to a device's pool. Duplicate key ids for
// the same device are ignored so that a retried upload is harmless.
func (s *Store) AddOneTimePreKeys(ctx context.Context, deviceID uuid.UUID, keys []models.OneTimePreKey) error {
	if len(keys) == 0 {
		return nil
	}
	for i := range keys {
		keys[i].DeviceID = deviceID
		keys[i].ConsumedAt = nil
	}
	err := s.db.WithContext(ctx).
		Clauses(onConflictDoNothing("device_id", "key_id")).
		Create(&keys).Error
	if err != nil {
		return fmt.Errorf("add one-time prekeys: %w", err)
	}
	return nil
}

// ActiveSignedPreKey returns the signed prekey currently advertised for a
// device.
func (s *Store) ActiveSignedPreKey(ctx context.Context, deviceID uuid.UUID) (*models.SignedPreKey, error) {
	var spk models.SignedPreKey
	err := s.db.WithContext(ctx).
		Where("device_id = ? AND active = TRUE", deviceID).
		Order("created_at DESC").
		First(&spk).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, fmt.Errorf("device %s has no active signed prekey", deviceID)
	}
	if err != nil {
		return nil, fmt.Errorf("active signed prekey: %w", err)
	}
	return &spk, nil
}

// ReplaceSignedPreKey marks existing signed prekeys inactive and installs a
// new one, in a single transaction so a bundle fetch never observes zero
// active prekeys.
func (s *Store) ReplaceSignedPreKey(ctx context.Context, deviceID uuid.UUID, spk *models.SignedPreKey) error {
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.SignedPreKey{}).
			Where("device_id = ?", deviceID).
			Update("active", false).Error; err != nil {
			return fmt.Errorf("deactivate signed prekeys: %w", err)
		}
		spk.DeviceID = deviceID
		spk.Active = true
		if err := tx.Create(spk).Error; err != nil {
			return fmt.Errorf("create signed prekey: %w", err)
		}
		return nil
	})
}
