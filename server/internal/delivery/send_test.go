package delivery_test

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/delivery"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

func testDSN() string {
	if dsn := os.Getenv("FROGSTER_TEST_DATABASE_URL"); dsn != "" {
		return dsn
	}
	return "postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable"
}

func newStore(t *testing.T) *store.Store {
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

func seedUser(t *testing.T, st *store.Store) (userID, deviceID uuid.UUID) {
	t.Helper()

	user := &models.User{
		Username:     "dlv_" + uuid.NewString()[:12],
		PasswordHash: "$2a$12$abcdefghijklmnopqrstuv",
	}
	device := &models.Device{
		RegistrationID: 1,
		DeviceName:     "device",
		IdentityKeyPub: make([]byte, 33),
	}
	spk := &models.SignedPreKey{
		KeyID:     1,
		PublicKey: make([]byte, 33),
		Signature: make([]byte, 64),
	}
	if err := st.CreateUserWithDevice(context.Background(), user, device, spk, nil); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return user.ID, device.ID
}

// TestLiveDeliveryIsNotReplayedOnReconnect covers the failure that silently
// broke conversations: a message handed to a connected socket stayed queued as
// pending, so the next reconnect flushed it a second time.
//
// A Double Ratchet message decrypts exactly once -- the message key is
// destroyed on use -- so the replay fails its MAC check. The recipient sees
// "decrypt failed" and every later message in that session is unreadable.
func TestLiveDeliveryIsNotReplayedOnReconnect(t *testing.T) {
	st := newStore(t)
	ctx := context.Background()

	senderUser, senderDevice := seedUser(t, st)
	recipientUser, recipientDevice := seedUser(t, st)

	chat := &models.Chat{Type: models.ChatTypeDirect, CreatorID: senderUser}
	if err := st.CreateChat(ctx, chat, []uuid.UUID{senderUser, recipientUser}); err != nil {
		t.Fatalf("create chat: %v", err)
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	hub := ws.NewHub(log)

	hubCtx, stopHub := context.WithCancel(ctx)
	defer stopHub()
	go hub.Run(hubCtx)

	// A recipient whose socket is live and draining frames.
	client := ws.NewDetachedClient(
		ws.ClientKey{UserID: recipientUser, DeviceID: recipientDevice}, log)
	hub.Register(client)

	// Registration is handled by the hub goroutine; wait for it to land.
	deadline := time.Now().Add(2 * time.Second)
	for !hub.IsLocal(ws.ClientKey{UserID: recipientUser, DeviceID: recipientDevice}) {
		if time.Now().After(deadline) {
			t.Fatal("client never registered with the hub")
		}
		time.Sleep(5 * time.Millisecond)
	}

	router := delivery.NewRouter(hub, st, nil, ws.NewPresence(nil, "test-node"), log)

	_, err := router.Send(ctx, &ws.Envelope{
		Version: 1,
		Type:    ws.TypeMessage,
		ChatID:  chat.ID,
		Sender:  &ws.Address{UserID: senderUser, DeviceID: senderDevice},
		Payloads: []ws.DevicePayload{{
			UserID:     recipientUser,
			DeviceID:   recipientDevice,
			CipherType: models.CipherTypeWhisper,
			Ciphertext: []byte("ciphertext for the live device"),
		}},
	})
	if err != nil {
		t.Fatalf("send: %v", err)
	}

	// The frame went to a live socket, so nothing may remain queued.
	pending, err := st.PendingDeliveries(ctx, recipientUser, recipientDevice, 50)
	if err != nil {
		t.Fatalf("pending deliveries: %v", err)
	}
	if len(pending) != 0 {
		t.Errorf("message delivered live is still queued (%d pending): it "+
			"will be replayed on reconnect and fail to decrypt", len(pending))
	}
}

// TestOfflineDeliveryStaysQueued is the other half of the invariant: a device
// that was not connected must still receive the message later.
func TestOfflineDeliveryStaysQueued(t *testing.T) {
	st := newStore(t)
	ctx := context.Background()

	senderUser, senderDevice := seedUser(t, st)
	recipientUser, recipientDevice := seedUser(t, st)

	chat := &models.Chat{Type: models.ChatTypeDirect, CreatorID: senderUser}
	if err := st.CreateChat(ctx, chat, []uuid.UUID{senderUser, recipientUser}); err != nil {
		t.Fatalf("create chat: %v", err)
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	hub := ws.NewHub(log)

	hubCtx, stopHub := context.WithCancel(ctx)
	defer stopHub()
	go hub.Run(hubCtx)

	// No client registered: the recipient is offline.
	router := delivery.NewRouter(hub, st, nil, ws.NewPresence(nil, "test-node"), log)

	_, err := router.Send(ctx, &ws.Envelope{
		Version: 1,
		Type:    ws.TypeMessage,
		ChatID:  chat.ID,
		Sender:  &ws.Address{UserID: senderUser, DeviceID: senderDevice},
		Payloads: []ws.DevicePayload{{
			UserID:     recipientUser,
			DeviceID:   recipientDevice,
			CipherType: models.CipherTypeWhisper,
			Ciphertext: []byte("ciphertext for an absent device"),
		}},
	})
	if err != nil {
		t.Fatalf("send: %v", err)
	}

	pending, err := st.PendingDeliveries(ctx, recipientUser, recipientDevice, 50)
	if err != nil {
		t.Fatalf("pending deliveries: %v", err)
	}
	if len(pending) != 1 {
		t.Errorf("an offline recipient lost the message (%d pending)", len(pending))
	}
}
