package store_test

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// testDSN returns the database to test against, or "" when integration tests
// should be skipped (no database available in this environment).
func testDSN() string {
	if dsn := os.Getenv("FROGSTER_TEST_DATABASE_URL"); dsn != "" {
		return dsn
	}
	return "postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable"
}

func newTestStore(t *testing.T) *store.Store {
	t.Helper()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st, err := store.Open(context.Background(), testDSN(), log)
	if err != nil {
		t.Skipf("postgres unavailable, skipping integration test: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return st
}

// seedDevice creates a throwaway user + device and returns the device id.
func seedDevice(t *testing.T, st *store.Store, preKeyCount int) uuid.UUID {
	t.Helper()
	ctx := context.Background()

	user := &models.User{
		Username:     "test_" + uuid.NewString()[:12],
		PasswordHash: "$2a$12$abcdefghijklmnopqrstuv",
	}
	device := &models.Device{
		RegistrationID: 1,
		DeviceName:     "test-device",
		IdentityKeyPub: make([]byte, 33),
	}
	spk := &models.SignedPreKey{
		KeyID:     1,
		PublicKey: make([]byte, 33),
		Signature: make([]byte, 64),
	}

	otps := make([]models.OneTimePreKey, 0, preKeyCount)
	for i := range preKeyCount {
		otps = append(otps, models.OneTimePreKey{
			KeyID:     uint32(i + 1),
			PublicKey: make([]byte, 33),
		})
	}

	if err := st.CreateUserWithDevice(ctx, user, device, spk, otps); err != nil {
		t.Fatalf("seed user/device: %v", err)
	}
	return device.ID
}

// TestPopOneTimePreKeyIsAtomic is the central correctness test for X3DH key
// distribution: two peers must never receive the same one-time prekey, or the
// forward-secrecy guarantee that prekey provides is void.
//
// It runs many concurrent claims against a known pool size and asserts that
// every returned key id is distinct and that the pool drains exactly.
func TestPopOneTimePreKeyIsAtomic(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	const poolSize = 50
	deviceID := seedDevice(t, st, poolSize)

	const workers = 25
	const claimsPerWorker = 4 // 100 attempts against a pool of 50

	var (
		mu       sync.Mutex
		gotKeys  = make(map[uint32]int)
		drained  int
		otherErr error
	)

	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range claimsPerWorker {
				k, err := st.PopOneTimePreKey(context.Background(), deviceID)
				mu.Lock()
				switch {
				case err == nil:
					gotKeys[k.KeyID]++
				case err.Error() != "" && isNoPreKey(err):
					drained++
				default:
					otherErr = err
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if otherErr != nil {
		t.Fatalf("unexpected error during concurrent pop: %v", otherErr)
	}

	// No key may be handed out more than once.
	for keyID, n := range gotKeys {
		if n != 1 {
			t.Errorf("prekey %d was issued %d times, want exactly 1", keyID, n)
		}
	}

	if len(gotKeys) != poolSize {
		t.Errorf("claimed %d distinct prekeys, want %d", len(gotKeys), poolSize)
	}

	wantDrained := workers*claimsPerWorker - poolSize
	if drained != wantDrained {
		t.Errorf("got %d drained responses, want %d", drained, wantDrained)
	}

	remaining, err := st.CountAvailablePreKeys(context.Background(), deviceID)
	if err != nil {
		t.Fatalf("count remaining: %v", err)
	}
	if remaining != 0 {
		t.Errorf("pool has %d keys left, want 0", remaining)
	}
}

// TestPopOneTimePreKeyEmptyPool verifies that an exhausted pool reports a
// distinguishable error rather than returning a zero-valued key. X3DH may
// legitimately proceed without a one-time prekey, so callers must be able to
// tell "none left" apart from a real failure.
func TestPopOneTimePreKeyEmptyPool(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	deviceID := seedDevice(t, st, 0)

	_, err := st.PopOneTimePreKey(context.Background(), deviceID)
	if !isNoPreKey(err) {
		t.Fatalf("got %v, want ErrNoPreKeyAvailable", err)
	}
}

// TestAddOneTimePreKeysIsIdempotent verifies that a retried upload does not
// error or duplicate keys, so a flaky network cannot corrupt the pool.
func TestAddOneTimePreKeysIsIdempotent(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()
	deviceID := seedDevice(t, st, 0)

	batch := []models.OneTimePreKey{
		{KeyID: 100, PublicKey: make([]byte, 33)},
		{KeyID: 101, PublicKey: make([]byte, 33)},
	}
	if err := st.AddOneTimePreKeys(ctx, deviceID, batch); err != nil {
		t.Fatalf("first upload: %v", err)
	}

	retry := []models.OneTimePreKey{
		{KeyID: 100, PublicKey: make([]byte, 33)},
		{KeyID: 101, PublicKey: make([]byte, 33)},
	}
	if err := st.AddOneTimePreKeys(ctx, deviceID, retry); err != nil {
		t.Fatalf("retried upload should be a no-op, got: %v", err)
	}

	n, err := st.CountAvailablePreKeys(ctx, deviceID)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 2 {
		t.Errorf("pool has %d keys, want 2 (retry must not duplicate)", n)
	}
}

func isNoPreKey(err error) bool {
	return err != nil && err.Error() == store.ErrNoPreKeyAvailable.Error()
}
