package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// seedUserDevice creates a throwaway user plus device and returns both ids.
func seedUserDevice(t *testing.T, st *store.Store) (userID, deviceID uuid.UUID) {
	t.Helper()
	ctx := context.Background()

	user := &models.User{
		Username:     "sess_" + uuid.NewString()[:12],
		PasswordHash: "$2a$12$abcdefghijklmnopqrstuv",
	}
	device := &models.Device{
		RegistrationID: 1,
		DeviceName:     "old-phone",
		IdentityKeyPub: make([]byte, 33),
	}
	spk := &models.SignedPreKey{
		KeyID:     1,
		PublicKey: make([]byte, 33),
		Signature: make([]byte, 64),
	}

	if err := st.CreateUserWithDevice(ctx, user, device, spk, nil); err != nil {
		t.Fatalf("seed user/device: %v", err)
	}
	return user.ID, device.ID
}

func seedSession(t *testing.T, st *store.Store, userID, deviceID uuid.UUID) uuid.UUID {
	t.Helper()

	sess := &models.ActiveSession{
		UserID:      userID,
		DeviceID:    deviceID,
		RefreshHash: uuid.NewString(),
		ExpiresAt:   time.Now().Add(24 * time.Hour),
		LastUsedAt:  time.Now(),
	}
	if err := st.CreateSession(context.Background(), sess); err != nil {
		t.Fatalf("create session: %v", err)
	}
	return sess.ID
}

// TestRevokeSessionRetiresDevice is the guarantee behind "sign out my old
// phone".
//
// Revoking only the session would invalidate a token while leaving the device
// active in the key directory, so contacts would keep fetching its bundle and
// encrypting messages to a handset that can never read them -- silently, with
// no error anywhere. The device must stop being handed out.
func TestRevokeSessionRetiresDevice(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	userID, deviceID := seedUserDevice(t, st)
	sessionID := seedSession(t, st, userID, deviceID)

	before, err := st.ActiveDevices(ctx, userID)
	if err != nil {
		t.Fatalf("active devices before: %v", err)
	}
	if len(before) != 1 {
		t.Fatalf("expected 1 active device before revoke, got %d", len(before))
	}

	revoked, err := st.RevokeSession(ctx, userID, sessionID)
	if err != nil {
		t.Fatalf("revoke session: %v", err)
	}
	if revoked != deviceID {
		t.Errorf("revoke returned device %s, want %s", revoked, deviceID)
	}

	after, err := st.ActiveDevices(ctx, userID)
	if err != nil {
		t.Fatalf("active devices after: %v", err)
	}
	if len(after) != 0 {
		t.Errorf("device still active after revoke: peers would keep "+
			"encrypting to a signed-out device (%d active)", len(after))
	}
}

// TestRevokeSessionRejectsOtherUsers keeps revocation scoped to its owner.
func TestRevokeSessionRejectsOtherUsers(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	ownerID, deviceID := seedUserDevice(t, st)
	sessionID := seedSession(t, st, ownerID, deviceID)
	attackerID, _ := seedUserDevice(t, st)

	if _, err := st.RevokeSession(ctx, attackerID, sessionID); err == nil {
		t.Fatal("another user was allowed to revoke this session")
	}

	active, err := st.ActiveDevices(ctx, ownerID)
	if err != nil {
		t.Fatalf("active devices: %v", err)
	}
	if len(active) != 1 {
		t.Errorf("owner's device was retired by another user's request")
	}
}
