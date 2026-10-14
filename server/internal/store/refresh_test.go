package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

func seedSessionWithHash(t *testing.T, st *store.Store, userID, deviceID uuid.UUID, hash string) {
	t.Helper()
	sess := &models.ActiveSession{
		UserID:      userID,
		DeviceID:    deviceID,
		RefreshHash: hash,
		ExpiresAt:   time.Now().Add(24 * time.Hour),
		LastUsedAt:  time.Now(),
	}
	if err := st.CreateSession(context.Background(), sess); err != nil {
		t.Fatalf("create session: %v", err)
	}
}

// uniqueHash returns a distinct 64-character stand-in for a token hash.
func uniqueHash() string {
	return (uuid.NewString() + uuid.NewString())[:64]
}

// TestRefreshTokenRotates: every refresh replaces the token, and the
// replaced token stops working once the retry grace has passed.
func TestRefreshTokenRotates(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	h1, h2, h3 := uniqueHash(), uniqueHash(), uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)

	sess, err := st.RotateRefreshToken(ctx, h1, h2, time.Minute)
	if err != nil {
		t.Fatalf("first rotation: %v", err)
	}
	if sess.UserID != userID || sess.DeviceID != deviceID {
		t.Fatalf("rotation returned the wrong session")
	}

	if _, err := st.RotateRefreshToken(ctx, h2, h3, time.Minute); err != nil {
		t.Fatalf("rotating the new token: %v", err)
	}
}

// TestRefreshRetryWithinGrace: a client whose refresh response was lost
// retries with the token it still has. That must work once, and the token it
// never received must die.
func TestRefreshRetryWithinGrace(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	h1, lost, retried := uniqueHash(), uniqueHash(), uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)

	if _, err := st.RotateRefreshToken(ctx, h1, lost, time.Minute); err != nil {
		t.Fatalf("rotation: %v", err)
	}
	if _, err := st.RotateRefreshToken(ctx, h1, retried, time.Minute); err != nil {
		t.Fatalf("retry inside the grace window was rejected: %v", err)
	}
	if _, err := st.RotateRefreshToken(ctx, lost, uniqueHash(), time.Minute); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("the token the client never received still works: %v", err)
	}
	if _, err := st.RotateRefreshToken(ctx, retried, uniqueHash(), time.Minute); err != nil {
		t.Errorf("the retried token does not work: %v", err)
	}
}

// TestRefreshReuseRevokesSession: an old token presented after the grace can
// only be a copy. Both the copy and the legitimate current token stop
// working, because the server cannot tell which holder is the owner.
func TestRefreshReuseRevokesSession(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	h1, h2 := uniqueHash(), uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)

	if _, err := st.RotateRefreshToken(ctx, h1, h2, 0); err != nil {
		t.Fatalf("rotation: %v", err)
	}
	if _, err := st.RotateRefreshToken(ctx, h1, uniqueHash(), 0); !errors.Is(err, store.ErrRefreshReuse) {
		t.Fatalf("reuse of a rotated token: got %v, want ErrRefreshReuse", err)
	}
	if _, err := st.RotateRefreshToken(ctx, h2, uniqueHash(), 0); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("session survived detected reuse: %v", err)
	}
}

// TestChangePasswordEndsEverySession: changing a password is what people do
// when they suspect a device; no existing refresh token may survive it.
func TestChangePasswordEndsEverySession(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	h1, h2 := uniqueHash(), uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)
	seedSessionWithHash(t, st, userID, deviceID, h2)

	before, err := st.UserByID(ctx, userID)
	if err != nil {
		t.Fatalf("load user: %v", err)
	}
	version, err := st.ChangePassword(ctx, userID, "$2a$12$newnewnewnewnewnewnewn")
	if err != nil {
		t.Fatalf("change password: %v", err)
	}
	if version != before.TokenVersion+1 {
		t.Errorf("token version = %d, want %d: old access tokens stay valid",
			version, before.TokenVersion+1)
	}
	for _, h := range []string{h1, h2} {
		if _, err := st.RotateRefreshToken(ctx, h, uniqueHash(), time.Minute); !errors.Is(err, store.ErrNotFound) {
			t.Errorf("a refresh token survived the password change: %v", err)
		}
	}
}

// TestLogoutKeepsTheDevice: signing out ends the sessions but leaves the
// device registered, so its keys stay valid and signing back in resumes it.
func TestLogoutKeepsTheDevice(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	h1 := uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)

	if err := st.RevokeDeviceSessions(ctx, userID, deviceID); err != nil {
		t.Fatalf("logout: %v", err)
	}
	if _, err := st.RotateRefreshToken(ctx, h1, uniqueHash(), time.Minute); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("refresh token survived logout: %v", err)
	}
	device, err := st.DeviceByID(ctx, deviceID)
	if err != nil || !device.IsActive() {
		t.Errorf("logout retired the device (err=%v)", err)
	}
}

// TestMigrateRecordsAndSkipsApplied: migrations run once and are recorded,
// so a restart does not re-run them.
func TestMigrateRecordsAndSkipsApplied(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()

	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	var names []string
	if err := st.DB().Raw("SELECT name FROM schema_migrations ORDER BY name").Scan(&names).Error; err != nil {
		t.Fatalf("read schema_migrations: %v", err)
	}
	want := map[string]bool{
		"0001_init.sql":                  true,
		"0002_ed25519_identity.sql":      true,
		"0003_delivery_and_sessions.sql": true,
	}
	for _, n := range names {
		delete(want, n)
	}
	if len(want) != 0 {
		t.Errorf("migrations not recorded: %v (have %v)", want, names)
	}
}

// TestPurgeExpiredDropsOnlyWhatIsDue: retention removes stale queue rows and
// spent sessions, and leaves fresh ones alone.
func TestPurgeExpiredDropsOnlyWhatIsDue(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	senderID, senderDevice := seedUserDevice(t, st)
	recipientID, recipientDevice := seedUserDevice(t, st)

	chat := &models.Chat{Type: models.ChatTypeDirect, CreatorID: senderID}
	if err := st.CreateChat(ctx, chat, []uuid.UUID{senderID, recipientID}); err != nil {
		t.Fatalf("create chat: %v", err)
	}
	queue := func() *models.Message {
		msg := &models.Message{
			ChatID: chat.ID, SenderID: senderID, SenderDevID: senderDevice,
			Ciphertext: []byte{}, CipherType: models.CipherTypeWhisper,
		}
		err := st.PersistMessage(ctx, msg, []models.MessageDelivery{{
			UserID: recipientID, DeviceID: recipientDevice, Ciphertext: []byte("x"),
		}})
		if err != nil {
			t.Fatalf("persist: %v", err)
		}
		return msg
	}
	stale := queue()
	queue() // fresh

	if err := st.DB().Exec(
		`UPDATE message_deliveries SET created_at = now() - interval '40 days' WHERE message_id = ?`,
		stale.ID).Error; err != nil {
		t.Fatalf("backdate: %v", err)
	}

	rep, err := st.PurgeExpired(ctx, store.RetentionPolicy{
		UndeliveredQueue: 30 * 24 * time.Hour,
		Delivered:        7 * 24 * time.Hour,
		Spent:            30 * 24 * time.Hour,
	})
	if err != nil {
		t.Fatalf("purge: %v", err)
	}
	if rep.UndeliveredDropped < 1 {
		t.Errorf("stale queue row was not purged: %+v", rep)
	}
	n, err := st.CountPending(ctx, recipientID, recipientDevice)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Errorf("pending after purge = %d, want only the fresh message", n)
	}
}

// TestRefreshGraceIsNotExtendedByRetries: the grace window runs from the
// first rotation. If each retry restarted it, whoever holds a copied old
// token could keep it alive indefinitely by replaying it.
func TestRefreshGraceIsNotExtendedByRetries(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	userID, deviceID := seedUserDevice(t, st)

	const grace = 300 * time.Millisecond
	h1 := uniqueHash()
	seedSessionWithHash(t, st, userID, deviceID, h1)

	if _, err := st.RotateRefreshToken(ctx, h1, uniqueHash(), grace); err != nil {
		t.Fatalf("rotation: %v", err)
	}
	time.Sleep(grace / 2)
	if _, err := st.RotateRefreshToken(ctx, h1, uniqueHash(), grace); err != nil {
		t.Fatalf("retry inside the window: %v", err)
	}
	time.Sleep(grace/2 + 100*time.Millisecond)

	// Past the window measured from the first rotation, though still inside
	// one measured from the retry.
	if _, err := st.RotateRefreshToken(ctx, h1, uniqueHash(), grace); !errors.Is(err, store.ErrRefreshReuse) {
		t.Errorf("old token accepted after the grace window: %v", err)
	}
}
