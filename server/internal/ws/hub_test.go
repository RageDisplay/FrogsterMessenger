package ws

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

// newTestClient builds a Client with no live socket. The hub only ever touches
// the send channel and the key, so the nil conn is never dereferenced as long
// as the pumps are not started.
func newTestClient(hub *Hub, key ClientKey) *Client {
	return &Client{
		hub:    hub,
		key:    key,
		send:   make(chan []byte, sendBuffer),
		closed: make(chan struct{}),
		log:    testLogger(),
	}
}

func startHub(t *testing.T) *Hub {
	t.Helper()

	hub := NewHub(testLogger())
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	go hub.Run(ctx)
	return hub
}

// waitFor polls until cond holds or the deadline passes. Registration is
// asynchronous (the hub owns its maps in one goroutine), so tests must not
// assume it completed the instant Register returned.
func waitFor(t *testing.T, cond func() bool) bool {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return false
}

func TestHubRegisterAndUnregister(t *testing.T) {
	hub := startHub(t)

	key := ClientKey{UserID: uuid.New(), DeviceID: uuid.New()}
	c := newTestClient(hub, key)

	hub.Register(c)
	if !waitFor(t, func() bool { return hub.IsLocal(key) }) {
		t.Fatal("client did not register")
	}
	if got := hub.Count(); got != 1 {
		t.Errorf("hub has %d clients, want 1", got)
	}

	hub.Unregister(c)
	if !waitFor(t, func() bool { return !hub.IsLocal(key) }) {
		t.Fatal("client did not unregister")
	}
	if got := hub.Count(); got != 0 {
		t.Errorf("hub has %d clients, want 0", got)
	}
}

// TestHubRoutesPerDevice is the core multi-device guarantee: a frame addressed
// to one device must not reach the user's other devices, because each device
// holds a distinct ratchet session and could not decrypt the other's payload.
func TestHubRoutesPerDevice(t *testing.T) {
	hub := startHub(t)

	userID := uuid.New()
	keyA := ClientKey{UserID: userID, DeviceID: uuid.New()}
	keyB := ClientKey{UserID: userID, DeviceID: uuid.New()}

	a := newTestClient(hub, keyA)
	b := newTestClient(hub, keyB)
	hub.Register(a)
	hub.Register(b)

	if !waitFor(t, func() bool { return hub.IsLocal(keyA) && hub.IsLocal(keyB) }) {
		t.Fatal("clients did not register")
	}

	hub.Deliver(Delivery{
		Key:      keyA,
		Envelope: &Envelope{Version: 1, Type: TypeMessage, Ciphertext: []byte("for-device-a")},
	})

	select {
	case payload := <-a.send:
		if len(payload) == 0 {
			t.Error("device A received an empty frame")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("device A never received the frame")
	}

	select {
	case <-b.send:
		t.Fatal("device B received a frame addressed to device A")
	case <-time.After(100 * time.Millisecond):
		// Correct: nothing for B.
	}
}

// TestHubReplacesDuplicateConnection covers reconnect before the old socket's
// read deadline expires. The stale entry must be displaced, or messages would
// be routed into a dead connection and silently lost.
func TestHubReplacesDuplicateConnection(t *testing.T) {
	hub := startHub(t)

	key := ClientKey{UserID: uuid.New(), DeviceID: uuid.New()}
	first := newTestClient(hub, key)
	second := newTestClient(hub, key)

	hub.Register(first)
	if !waitFor(t, func() bool { return hub.IsLocal(key) }) {
		t.Fatal("first client did not register")
	}

	hub.Register(second)
	if !waitFor(t, func() bool { return hub.Count() == 1 }) {
		t.Fatalf("hub has %d clients after replacement, want 1", hub.Count())
	}

	// The displaced connection's send channel must be closed so its writePump
	// exits rather than leaking.
	select {
	case _, open := <-first.send:
		if open {
			t.Error("displaced client's channel delivered a frame instead of closing")
		}
	case <-time.After(2 * time.Second):
		t.Error("displaced client's send channel was not closed")
	}

	// Delivery must now reach the new connection.
	hub.Deliver(Delivery{Key: key, Envelope: &Envelope{Version: 1, Type: TypeMessage}})
	select {
	case <-second.send:
	case <-time.After(2 * time.Second):
		t.Error("replacement client did not receive the frame")
	}
}

// TestHubUnregisterStaleClientIsNoop ensures a displaced connection's deferred
// Unregister does not evict the live connection that replaced it.
func TestHubUnregisterStaleClientIsNoop(t *testing.T) {
	hub := startHub(t)

	key := ClientKey{UserID: uuid.New(), DeviceID: uuid.New()}
	first := newTestClient(hub, key)
	second := newTestClient(hub, key)

	hub.Register(first)
	waitFor(t, func() bool { return hub.IsLocal(key) })
	hub.Register(second)
	waitFor(t, func() bool { return hub.Count() == 1 })

	// The old connection's readPump exits and unregisters itself.
	hub.Unregister(first)

	// The replacement must survive.
	time.Sleep(50 * time.Millisecond)
	if !hub.IsLocal(key) {
		t.Fatal("stale unregister evicted the live replacement connection")
	}
}

// TestClientEnqueueClosesOnBackpressure verifies the bounded-buffer policy: a
// client that cannot keep up is disconnected rather than allowed to grow the
// queue without bound, which would be a memory-exhaustion vector.
func TestClientEnqueueClosesOnBackpressure(t *testing.T) {
	hub := startHub(t)
	c := newTestClient(hub, ClientKey{UserID: uuid.New(), DeviceID: uuid.New()})

	// Fill the buffer exactly.
	for range sendBuffer {
		c.enqueue([]byte("x"))
	}

	// One more must trip the overflow path and close the channel.
	c.enqueue([]byte("overflow"))

	drained := 0
	for range c.send {
		drained++
	}
	if drained != sendBuffer {
		t.Errorf("drained %d frames before close, want %d", drained, sendBuffer)
	}
}

func TestHubLocalDevices(t *testing.T) {
	hub := startHub(t)

	userID := uuid.New()
	keys := []ClientKey{
		{UserID: userID, DeviceID: uuid.New()},
		{UserID: userID, DeviceID: uuid.New()},
	}
	for _, k := range keys {
		hub.Register(newTestClient(hub, k))
	}
	if !waitFor(t, func() bool { return len(hub.LocalDevices(userID)) == 2 }) {
		t.Fatalf("got %d local devices, want 2", len(hub.LocalDevices(userID)))
	}

	if got := hub.LocalDevices(uuid.New()); got != nil {
		t.Errorf("unknown user has %d devices, want none", len(got))
	}
}
