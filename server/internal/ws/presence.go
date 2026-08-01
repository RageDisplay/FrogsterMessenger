package ws

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// presenceTTL outlives the client ping period, so a live connection keeps its
// key refreshed. Expiry is what makes presence self-healing: if an instance
// crashes without cleaning up, its keys simply lapse.
const presenceTTL = 90 * time.Second

// Presence records which instance holds which device's socket.
type Presence struct {
	rdb    *redis.Client
	nodeID string
}

// NewPresence builds a presence tracker for this instance.
func NewPresence(rdb *redis.Client, nodeID string) *Presence {
	return &Presence{rdb: rdb, nodeID: nodeID}
}

func presenceKey(userID, deviceID uuid.UUID) string {
	return "presence:" + userID.String() + ":" + deviceID.String()
}

// Set marks a device online on this instance.
func (p *Presence) Set(ctx context.Context, k ClientKey) error {
	if p.rdb == nil {
		return nil
	}
	err := p.rdb.Set(ctx, presenceKey(k.UserID, k.DeviceID), p.nodeID, presenceTTL).Err()
	if err != nil {
		return fmt.Errorf("set presence: %w", err)
	}
	return nil
}

// Refresh extends a device's presence, called from the ping ticker.
func (p *Presence) Refresh(ctx context.Context, k ClientKey) error {
	if p.rdb == nil {
		return nil
	}
	return p.rdb.Expire(ctx, presenceKey(k.UserID, k.DeviceID), presenceTTL).Err()
}

// Clear marks a device offline.
func (p *Presence) Clear(ctx context.Context, k ClientKey) error {
	if p.rdb == nil {
		return nil
	}
	return p.rdb.Del(ctx, presenceKey(k.UserID, k.DeviceID)).Err()
}

// IsOnline reports whether a device is connected to any instance.
func (p *Presence) IsOnline(ctx context.Context, k ClientKey) (bool, error) {
	if p.rdb == nil {
		return false, nil
	}
	n, err := p.rdb.Exists(ctx, presenceKey(k.UserID, k.DeviceID)).Result()
	if err != nil {
		return false, fmt.Errorf("check presence: %w", err)
	}
	return n > 0, nil
}
