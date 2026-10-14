package store

import (
	"context"
	"fmt"
	"time"
)

// RetentionPolicy says how long each kind of leftover data is kept.
type RetentionPolicy struct {
	// UndeliveredQueue bounds how long a message waits for a device that
	// never reconnects. Without a bound, an abandoned install accumulates
	// ciphertext forever.
	UndeliveredQueue time.Duration

	// Delivered is how long a delivered queue row is kept. Its per-device
	// ciphertext is useless once the device has it; the short delay keeps
	// recent rows around for diagnosing delivery problems.
	Delivered time.Duration

	// Spent covers revoked or expired sessions, consumed one-time prekeys and
	// consumed sender-key distributions.
	Spent time.Duration
}

// PurgeReport counts what one PurgeExpired run removed.
type PurgeReport struct {
	UndeliveredDropped int64
	DeliveredDropped   int64
	SessionsDropped    int64
	PreKeysDropped     int64
	SenderKeysDropped  int64
}

// PurgeExpired removes data past its retention period.
//
// Message rows themselves are kept: the per-chat sequence is derived from
// them, so deleting the newest would let a sequence number be handed out
// twice. Their bodies for 1:1 chats are already empty (the ciphertext lives on
// the delivery rows removed here).
func (s *Store) PurgeExpired(ctx context.Context, p RetentionPolicy) (PurgeReport, error) {
	var rep PurgeReport
	now := time.Now()
	db := s.db.WithContext(ctx)

	res := db.Exec(`DELETE FROM message_deliveries WHERE state = 'pending' AND created_at < ?`,
		now.Add(-p.UndeliveredQueue))
	if res.Error != nil {
		return rep, fmt.Errorf("purge undelivered: %w", res.Error)
	}
	rep.UndeliveredDropped = res.RowsAffected

	res = db.Exec(`DELETE FROM message_deliveries WHERE state <> 'pending' AND delivered_at < ?`,
		now.Add(-p.Delivered))
	if res.Error != nil {
		return rep, fmt.Errorf("purge delivered: %w", res.Error)
	}
	rep.DeliveredDropped = res.RowsAffected

	spentBefore := now.Add(-p.Spent)

	res = db.Exec(`DELETE FROM active_sessions
	               WHERE (revoked_at IS NOT NULL AND revoked_at < ?) OR expires_at < ?`,
		spentBefore, spentBefore)
	if res.Error != nil {
		return rep, fmt.Errorf("purge sessions: %w", res.Error)
	}
	rep.SessionsDropped = res.RowsAffected

	res = db.Exec(`DELETE FROM one_time_pre_keys WHERE consumed_at IS NOT NULL AND consumed_at < ?`,
		spentBefore)
	if res.Error != nil {
		return rep, fmt.Errorf("purge prekeys: %w", res.Error)
	}
	rep.PreKeysDropped = res.RowsAffected

	res = db.Exec(`DELETE FROM group_sender_key_distributions
	               WHERE consumed_at IS NOT NULL AND consumed_at < ?`, spentBefore)
	if res.Error != nil {
		return rep, fmt.Errorf("purge sender keys: %w", res.Error)
	}
	rep.SenderKeysDropped = res.RowsAffected

	return rep, nil
}
