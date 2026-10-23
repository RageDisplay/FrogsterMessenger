package voice

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// client is a device in a channel, as the app would be.
type client struct {
	t       *testing.T
	g       Grant
	keys    keys
	counter uint64

	mu       sync.Mutex
	got      [][]byte // opened plaintexts
	received int      // datagrams that arrived at all
	sender   Sender
}

func newClient(t *testing.T, g Grant) *client {
	t.Helper()
	k, err := deriveKeys(g.Secret)
	if err != nil {
		t.Fatal(err)
	}
	c := &client{t: t, g: g, keys: k}
	c.sender = c.deliver
	return c
}

func (c *client) deliver(pkt []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.received++
	tag, counter, err := header(pkt)
	if err != nil || tag != c.g.Tag {
		return
	}
	plain, err := open(c.keys.down, counter, pkt)
	if err != nil {
		return
	}
	c.got = append(c.got, plain)
}

func (c *client) datagram(plain []byte) []byte {
	c.counter++
	return seal(c.keys.up, c.g.Tag, c.counter, plain)
}

func audio(seq uint16, opus string) []byte {
	b := []byte{kindAudio}
	b = binary.BigEndian.AppendUint16(b, seq)
	return append(b, opus...)
}

func (c *client) say(m *Manager, seq uint16, opus string) {
	m.Receive(c.datagram(audio(seq, opus)), c.sender)
}

// heard lists the sound that reached this client as "member:opus".
func (c *client) heard() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for _, p := range c.got {
		if p[0] != kindAudio {
			continue
		}
		member := binary.BigEndian.Uint32(p[1:])
		out = append(out, string(rune('0'+member))+":"+string(p[7:]))
	}
	return out
}

type fixture struct {
	m       *Manager
	chat    uuid.UUID
	channel uuid.UUID
	clock   time.Time
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{m: NewManager(nil, nil), chat: uuid.New(), channel: uuid.New(), clock: time.Unix(1_000_000, 0)}
	f.m.now = func() time.Time { return f.clock }
	return f
}

// join puts a new user's device in the channel and has it say hello, so the
// relay knows the way back to it.
func (f *fixture) join(t *testing.T) *client {
	t.Helper()
	return f.joinAs(t, uuid.New(), uuid.New(), f.channel)
}

func (f *fixture) joinAs(t *testing.T, user, device, channel uuid.UUID) *client {
	t.Helper()
	g, err := f.m.Join(f.chat, channel, user, device)
	if err != nil {
		t.Fatal(err)
	}
	c := newClient(t, g)
	f.m.Receive(c.datagram([]byte{kindPing}), c.sender)
	return c
}

func TestSoundReachesEveryoneElse(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.join(t), f.join(t), f.join(t)

	a.say(f.m, 7, "hello")
	if len(a.heard()) != 0 {
		t.Error("the speaker heard themselves")
	}
	for _, listener := range []*client{b, c} {
		if got := listener.heard(); len(got) != 1 || got[0] != "1:hello" {
			t.Errorf("heard %v, want [1:hello]", got)
		}
	}
	// The sequence number survives, for the receiver's jitter buffer.
	b.mu.Lock()
	var last []byte
	for _, p := range b.got {
		if p[0] == kindAudio {
			last = p
		}
	}
	b.mu.Unlock()
	if seq := binary.BigEndian.Uint16(last[5:]); seq != 7 {
		t.Errorf("seq %d, want 7", seq)
	}
}

func TestForgedTamperedAndReplayedDatagramsAreDropped(t *testing.T) {
	f := newFixture(t)
	a, b := f.join(t), f.join(t)

	good := a.datagram(audio(1, "once"))
	f.m.Receive(good, a.sender)
	f.m.Receive(good, a.sender) // replayed
	if got := b.heard(); len(got) != 1 {
		t.Fatalf("replay relayed: %v", got)
	}

	tampered := a.datagram(audio(2, "flip"))
	tampered[len(tampered)-1] ^= 1
	f.m.Receive(tampered, a.sender)

	// Under a's tag but sealed with b's key: someone who knows the tag is
	// still no one.
	forged := seal(b.keys.up, a.g.Tag, 99, audio(3, "forged"))
	f.m.Receive(forged, a.sender)

	// A truncated header, and an unknown version.
	f.m.Receive(good[:10], a.sender)
	other := a.datagram(audio(4, "v2"))
	other[0] = 2
	f.m.Receive(other, a.sender)

	if got := b.heard(); len(got) != 1 {
		t.Fatalf("relayed %v, want only the first", got)
	}
}

// A forger must not be able to redirect a member's sound by sending from a
// new address: only a datagram that opens moves the path back.
func TestThePathBackMovesOnlyForTheMember(t *testing.T) {
	f := newFixture(t)
	a, b := f.join(t), f.join(t)

	var stolen int
	thief := func([]byte) { stolen++ }
	forged := seal(a.keys.up, b.g.Tag, 1000, []byte{kindPing})
	forged[len(forged)-1] ^= 1
	f.m.Receive(forged, thief)
	a.say(f.m, 1, "x")
	if stolen != 0 || len(b.heard()) != 1 {
		t.Fatalf("b's sound went to the forger (%d) instead of b", stolen)
	}

	// b's network changes: its next datagram comes from somewhere new.
	moved := newClient(t, b.g)
	moved.counter = b.counter
	f.m.Receive(moved.datagram([]byte{kindPing}), moved.sender)
	a.say(f.m, 2, "y")
	if got := moved.heard(); len(got) != 1 || got[0] != "1:y" {
		t.Fatalf("after moving, b heard %v", got)
	}
}

func TestMutedAndDeafened(t *testing.T) {
	f := newFixture(t)
	a, b, c := f.join(t), f.join(t), f.join(t)

	f.m.SetState(a.g.Tag2Device(f), true, false)
	a.say(f.m, 1, "muted")
	if len(b.heard())+len(c.heard()) != 0 {
		t.Fatal("a muted member was heard")
	}

	f.m.SetState(c.g.Tag2Device(f), false, true)
	b.say(f.m, 1, "hi")
	if len(c.heard()) != 0 {
		t.Error("a deafened member was sent sound")
	}
	c.say(f.m, 1, "deaf")
	if got := b.heard(); len(got) != 0 {
		t.Errorf("a deafened member was heard: %v", got)
	}
	for _, p := range f.m.Rooms(f.chat)[0].Participants {
		if p.Member == c.g.Member && !(p.Muted && p.Deafened) {
			t.Error("deafened without muted")
		}
	}
}

// Tag2Device finds the device a grant was made for, for tests.
func (g Grant) Tag2Device(f *fixture) uuid.UUID {
	f.m.mu.RLock()
	defer f.m.mu.RUnlock()
	return f.m.byTag[g.Tag].DeviceID
}

func TestOneChannelPerUser(t *testing.T) {
	f := newFixture(t)
	user := uuid.New()
	other := uuid.New()
	phone := f.joinAs(t, user, uuid.New(), f.channel)
	listener := f.join(t)

	// The same user from a laptop: the phone is out.
	laptop := f.joinAs(t, user, uuid.New(), f.channel)
	f.m.Receive(phone.datagram(audio(1, "old")), phone.sender)
	laptop.say(f.m, 1, "new")
	if got := listener.heard(); len(got) != 1 || !strings.HasSuffix(got[0], ":new") {
		t.Fatalf("heard %v, want only the laptop", got)
	}

	// Into another channel: out of this one.
	f.m.Join(f.chat, other, user, uuid.New())
	for _, room := range f.m.Rooms(f.chat) {
		if room.ChannelID == f.channel && len(room.Participants) != 1 {
			t.Fatalf("still in the first channel: %+v", room.Participants)
		}
	}
}

func TestPingIsAnsweredWithoutAmplification(t *testing.T) {
	f := newFixture(t)
	a := f.join(t)
	before := len(a.got)
	f.m.Receive(a.datagram(append([]byte{kindPing}, "t=42"...)), a.sender)
	if len(a.got) != before+1 || string(a.got[len(a.got)-1]) != "\x03t=42" {
		t.Fatalf("no pong echoing the ping")
	}
	f.m.Receive(a.datagram(append([]byte{kindPing}, bytes.Repeat([]byte{1}, maxPingBody+1)...)), a.sender)
	if len(a.got) != before+1 {
		t.Error("a long ping was echoed")
	}
}

func TestQuietMembersAreDropped(t *testing.T) {
	f := newFixture(t)
	talker, gone := f.join(t), f.join(t)

	for i := 0; i < 5; i++ {
		f.clock = f.clock.Add(5 * time.Second)
		f.m.Receive(talker.datagram([]byte{kindPing}), talker.sender)
		f.m.Sweep()
	}
	rooms := f.m.Rooms(f.chat)
	if len(rooms) != 1 || len(rooms[0].Participants) != 1 || rooms[0].Participants[0].Member != talker.g.Member {
		t.Fatalf("rooms %+v, want only the one still pinging", rooms)
	}
	_ = gone
}

func TestChannelFull(t *testing.T) {
	f := newFixture(t)
	for i := 0; i < MaxParticipants; i++ {
		f.join(t)
	}
	if _, err := f.m.Join(f.chat, f.channel, uuid.New(), uuid.New()); err != ErrFull {
		t.Fatalf("err %v, want ErrFull", err)
	}
}

func TestFloodIsCapped(t *testing.T) {
	f := newFixture(t)
	a, b := f.join(t), f.join(t)
	for i := 0; i < 1000; i++ {
		a.say(f.m, uint16(i), "x")
	}
	if n := len(b.heard()); n > packetBurst {
		t.Fatalf("relayed %d datagrams at once, budget is %d", n, packetBurst)
	}
	f.clock = f.clock.Add(time.Second)
	before := len(b.heard())
	a.say(f.m, 1, "later")
	if len(b.heard()) != before+1 {
		t.Error("the budget did not refill")
	}
}

func TestRemovalsEmptyTheRoom(t *testing.T) {
	f := newFixture(t)
	user := uuid.New()
	a := f.joinAs(t, user, uuid.New(), f.channel)
	b, c := f.join(t), f.join(t)

	f.m.RemoveUser(f.chat, user)
	b.say(f.m, 1, "anyone?")
	a.say(f.m, 1, "still here")
	if len(a.heard()) != 0 || len(b.heard()) != 0 {
		t.Fatal("a removed member still hears or is heard")
	}
	if got := c.heard(); len(got) != 1 {
		t.Fatalf("the others lost each other too: %v", got)
	}

	f.m.CloseChannel(f.chat, f.channel)
	if rooms := f.m.Rooms(f.chat); len(rooms) != 0 {
		t.Fatalf("rooms after closing: %+v", rooms)
	}
}

func TestChangesAreAnnouncedWithTheLatestState(t *testing.T) {
	var mu sync.Mutex
	var told [][]RoomState
	m := NewManager(func(_ context.Context, _ uuid.UUID, rooms []RoomState) {
		mu.Lock()
		told = append(told, rooms)
		mu.Unlock()
	}, nil)
	chat, channel := uuid.New(), uuid.New()
	g, _ := m.Join(chat, channel, uuid.New(), uuid.New())
	m.Join(chat, channel, uuid.New(), uuid.New())
	m.SetState(m.byTag[g.Tag].DeviceID, true, false)

	m.announce(context.Background())
	mu.Lock()
	defer mu.Unlock()
	if len(told) != 1 {
		t.Fatalf("told %d times, want the changes folded into one", len(told))
	}
	room := told[0][0]
	if len(room.Participants) != 2 || !room.Participants[0].Muted {
		t.Fatalf("told %+v", room)
	}
}

func TestReplayWindow(t *testing.T) {
	var w replayWindow
	for _, c := range []uint64{1, 3, 2, 10, 5} {
		if !w.accept(c) {
			t.Fatalf("%d rejected", c)
		}
	}
	for _, c := range []uint64{0, 1, 3, 10} {
		if w.accept(c) {
			t.Fatalf("%d accepted twice", c)
		}
	}
	if !w.accept(200) || w.accept(200-64) || !w.accept(200-63) {
		t.Fatal("window edge wrong")
	}
}

// TestWireVector pins the format: the app makes the same bytes from the same
// secret (client/packages/frogster_audio/test), so a change on either side
// that the other does not share shows up here, not as silence.
func TestWireVector(t *testing.T) {
	var secret Secret
	for i := range secret {
		secret[i] = byte(i + 1)
	}
	tag := Tag{0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8}
	k, err := deriveKeys(secret)
	if err != nil {
		t.Fatal(err)
	}
	up := seal(k.up, tag, 1, []byte{kindPing, 'h', 'i'})
	down := seal(k.down, tag, 1, []byte{kindPong, 'h', 'i'})
	const wantUp = "01a1a2a3a4a5a6a7a800000000000000013e11414f59a96c1dcbcc3ef986b046daf3f431"
	const wantDown = "01a1a2a3a4a5a6a7a800000000000000010660bd9cd407715a76d02914b1da52144c3ae1"
	if got := hex.EncodeToString(up); got != wantUp {
		t.Errorf("up   %s\nwant %s", got, wantUp)
	}
	if got := hex.EncodeToString(down); got != wantDown {
		t.Errorf("down %s\nwant %s", got, wantDown)
	}
}

// A datagram reflected back at its sender does not open: the two directions
// are under different keys.
func TestDirectionsUseDifferentKeys(t *testing.T) {
	var secret Secret
	secret[0] = 9
	k, _ := deriveKeys(secret)
	pkt := seal(k.up, Tag{1}, 5, []byte{kindAudio, 0, 1, 'x'})
	if _, err := open(k.down, 5, pkt); err == nil {
		t.Fatal("a client's own datagram opens as one from the relay")
	}
}

// A member removed between reading its datagram and relaying it is not
// relayed: removal takes effect at once, not one datagram later.
func TestRemovedMidwayIsNotRelayed(t *testing.T) {
	f := newFixture(t)
	a, b := f.join(t), f.join(t)
	f.m.mu.RLock()
	from := f.m.byTag[a.g.Tag]
	f.m.mu.RUnlock()
	f.m.Leave(from.DeviceID)
	f.m.relay(from, audio(1, "late")[1:])
	if got := b.heard(); len(got) != 0 {
		t.Fatalf("relayed %v from a member who left", got)
	}
}

// A socket that never proves to be a member's is closed, however much it
// sends: junk does not keep it open.
func TestMediaSocketWithoutAMemberIsClosed(t *testing.T) {
	old := mediaHello
	mediaHello = 300 * time.Millisecond
	defer func() { mediaHello = old }()
	f := newFixture(t)
	srv := httptest.NewServer(f.m.MediaHandler(func(*http.Request) bool { return true }))
	defer srv.Close()
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	closed := make(chan struct{})
	go func() {
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				close(closed)
				return
			}
		}
	}()
	junk := make([]byte, headerSize+20)
	junk[0] = wireVersion
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-closed:
			return
		case <-deadline:
			t.Fatal("a socket sending only junk stayed open")
		case <-time.After(50 * time.Millisecond):
			_ = conn.WriteMessage(websocket.BinaryMessage, junk)
		}
	}
}

func TestMediaOverWebSocket(t *testing.T) {
	f := newFixture(t)
	srv := httptest.NewServer(f.m.MediaHandler(func(*http.Request) bool { return true }))
	defer srv.Close()

	g, _ := f.m.Join(f.chat, f.channel, uuid.New(), uuid.New())
	c := newClient(t, g)
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Junk first: no answer, and the socket is still there for the real one.
	_ = conn.WriteMessage(websocket.BinaryMessage, []byte("not a datagram at all"))
	_ = conn.WriteMessage(websocket.BinaryMessage, c.datagram(append([]byte{kindPing}, "ws"...)))
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, pkt, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	c.deliver(pkt)
	if len(c.got) != 1 || string(c.got[0]) != "\x03ws" {
		t.Fatalf("got %q", c.got)
	}

	// And sound from a UDP member reaches the WebSocket one.
	other := f.join(t)
	other.say(f.m, 1, "over tcp")
	_, pkt, err = conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	c.deliver(pkt)
	if got := c.heard(); len(got) != 1 || !strings.HasSuffix(got[0], ":over tcp") {
		t.Fatalf("heard %v", got)
	}
}
