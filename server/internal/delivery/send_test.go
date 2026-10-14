package delivery_test

import (
	"context"
	"encoding/json"
	"fmt"
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

// fixture is a direct chat between two seeded users with a running hub.
type fixture struct {
	st        *store.Store
	hub       *ws.Hub
	router    *delivery.Router
	chat      *models.Chat
	sender    ws.ClientKey
	recipient ws.ClientKey
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
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
	t.Cleanup(stopHub)
	go hub.Run(hubCtx)

	return &fixture{
		st:        st,
		hub:       hub,
		router:    delivery.NewRouter(hub, st, nil, ws.NewPresence(nil, "test-node"), log),
		chat:      chat,
		sender:    ws.ClientKey{UserID: senderUser, DeviceID: senderDevice},
		recipient: ws.ClientKey{UserID: recipientUser, DeviceID: recipientDevice},
	}
}

// connect registers a live recipient socket and waits for the hub to see it.
func (f *fixture) connect(t *testing.T) *ws.Client {
	t.Helper()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	client := ws.NewDetachedClient(f.recipient, log)
	f.hub.Register(client)
	deadline := time.Now().Add(2 * time.Second)
	for !f.hub.IsLocal(f.recipient) {
		if time.Now().After(deadline) {
			t.Fatal("client never registered with the hub")
		}
		time.Sleep(5 * time.Millisecond)
	}
	return client
}

func (f *fixture) send(t *testing.T, id string) *models.Message {
	t.Helper()
	msg, err := f.router.Send(context.Background(), &ws.Envelope{
		Version: 1,
		Type:    ws.TypeMessage,
		ID:      id,
		ChatID:  f.chat.ID,
		Sender:  &ws.Address{UserID: f.sender.UserID, DeviceID: f.sender.DeviceID},
		Payloads: []ws.DevicePayload{{
			UserID:     f.recipient.UserID,
			DeviceID:   f.recipient.DeviceID,
			CipherType: models.CipherTypeWhisper,
			Ciphertext: []byte("ciphertext " + id),
		}},
	})
	if err != nil {
		t.Fatalf("send %s: %v", id, err)
	}
	return msg
}

func (f *fixture) pending(t *testing.T) int {
	t.Helper()
	n, err := f.st.CountPending(context.Background(), f.recipient.UserID, f.recipient.DeviceID)
	if err != nil {
		t.Fatalf("count pending: %v", err)
	}
	return int(n)
}

// nextFrame reads one queued frame from a detached client.
func nextFrame(t *testing.T, c *ws.Client) ws.Envelope {
	t.Helper()
	select {
	case raw := <-c.Outbox():
		var env ws.Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("decode frame: %v", err)
		}
		return env
	case <-time.After(2 * time.Second):
		t.Fatal("no frame arrived")
		return ws.Envelope{}
	}
}

// TestLiveDeliveryStaysQueuedUntilAcknowledged: handing a frame to a socket
// proves nothing -- the connection can die with the frame still buffered -- so
// the queue row is retired only when the device says it stored the message.
func TestLiveDeliveryStaysQueuedUntilAcknowledged(t *testing.T) {
	f := newFixture(t)
	client := f.connect(t)

	f.send(t, "live-1")
	if got := nextFrame(t, client); got.ID != "live-1" {
		t.Fatalf("live frame id = %q, want the sender's id", got.ID)
	}
	if n := f.pending(t); n != 1 {
		t.Fatalf("pending = %d before acknowledgement, want 1", n)
	}

	retired, err := f.router.Acknowledge(context.Background(), f.recipient, []string{"live-1"})
	if err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	if retired != 1 || f.pending(t) != 0 {
		t.Errorf("acknowledgement retired %d rows, %d still pending; want 1 and 0",
			retired, f.pending(t))
	}
}

// TestAcknowledgeIsScopedToTheDevice: one device cannot clear another's queue.
func TestAcknowledgeIsScopedToTheDevice(t *testing.T) {
	f := newFixture(t)
	f.send(t, "scoped-1")

	if _, err := f.router.Acknowledge(context.Background(), f.sender, []string{"scoped-1"}); err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	if n := f.pending(t); n != 1 {
		t.Errorf("another device's acknowledgement retired the row (pending = %d)", n)
	}
}

// TestRedeliveryCarriesTheClientID: a message that reaches a device from the
// offline queue must carry the same id as the live copy. Otherwise the client
// cannot recognise a redelivery, tries to decrypt it a second time, and a
// ratchet message decrypts only once.
func TestRedeliveryCarriesTheClientID(t *testing.T) {
	f := newFixture(t)
	f.send(t, "queued-1") // recipient offline

	client := f.connect(t)
	sent, err := f.router.FlushOffline(context.Background(), f.recipient)
	if err != nil {
		t.Fatalf("flush: %v", err)
	}
	if sent != 1 {
		t.Fatalf("flushed %d messages, want 1", sent)
	}
	if got := nextFrame(t, client); got.Type != ws.TypeMessage || got.ID != "queued-1" {
		t.Errorf("flushed frame = %s %q, want msg with the sender's id", got.Type, got.ID)
	}
	if got := nextFrame(t, client); got.Type != ws.TypeSyncDone {
		t.Errorf("after the backlog got %s, want %s", got.Type, ws.TypeSyncDone)
	}
}

// TestResendIsDeduplicated: a sender that lost the acknowledgement resends
// with the same id. The duplicate must resolve to the stored message, not be
// queued a second time.
func TestResendIsDeduplicated(t *testing.T) {
	f := newFixture(t)

	first := f.send(t, "resend-1")
	second := f.send(t, "resend-1")

	if first.ID != second.ID || first.Seq != second.Seq {
		t.Errorf("resend produced a new message (%s/%d vs %s/%d)",
			first.ID, first.Seq, second.ID, second.Seq)
	}
	if n := f.pending(t); n != 1 {
		t.Errorf("pending = %d after a resend, want 1", n)
	}
}

// TestFlushDrainsABacklogLargerThanTheSocketBuffer: a device returning after
// a long absence must receive its whole backlog. Pushing it without
// backpressure overflows the connection's send buffer, which closes the
// connection -- and the device reconnects into the same overflow forever.
func TestFlushDrainsABacklogLargerThanTheSocketBuffer(t *testing.T) {
	f := newFixture(t)
	const backlog = 600 // more than the send buffer and several flush pages

	for i := 0; i < backlog; i++ {
		f.send(t, fmt.Sprintf("backlog-%d", i))
	}

	client := f.connect(t)

	received := make(chan []string, 1)
	go func() {
		var ids []string
		for raw := range client.Outbox() {
			var env ws.Envelope
			_ = json.Unmarshal(raw, &env)
			if env.Type == ws.TypeSyncDone {
				break
			}
			ids = append(ids, env.ID)
			time.Sleep(50 * time.Microsecond) // a socket slower than the server
		}
		received <- ids
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	sent, err := f.router.FlushOffline(ctx, f.recipient)
	if err != nil {
		t.Fatalf("flush: %v", err)
	}
	if sent != backlog {
		t.Fatalf("flushed %d messages, want %d", sent, backlog)
	}

	select {
	case ids := <-received:
		if len(ids) != backlog {
			t.Fatalf("client received %d messages, want %d", len(ids), backlog)
		}
		for i, id := range ids {
			if want := fmt.Sprintf("backlog-%d", i); id != want {
				t.Fatalf("message %d is %q, want %q: the backlog must arrive in order", i, id, want)
			}
		}
	case <-time.After(30 * time.Second):
		t.Fatal("backlog never finished arriving")
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
