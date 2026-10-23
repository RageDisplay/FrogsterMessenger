package voice

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

// MaxParticipants bounds one channel. The relay seals every datagram again
// for every listener, so its work grows with the square of this.
const MaxParticipants = 25

// idleTimeout drops a member nothing has been heard from. Clients ping every
// couple of seconds while silent, so this only fires for one that is gone:
// closed, crashed, or off the network.
const idleTimeout = 20 * time.Second

// Packets per second a member may send, and how far it may burst above
// that. Speech is 50 a second; the burst absorbs a network that delivers in
// clumps.
const (
	packetRate  = 100
	packetBurst = 150
)

// ErrFull is returned when a channel has MaxParticipants already.
var ErrFull = errors.New("voice channel is full")

// Participant is someone in a channel, as members of the chat see them.
type Participant struct {
	Member   uint32    `json:"member"`
	UserID   uuid.UUID `json:"user_id"`
	DeviceID uuid.UUID `json:"device_id"`
	Muted    bool      `json:"muted,omitempty"`
	Deafened bool      `json:"deafened,omitempty"`
}

// RoomState lists who is in one channel.
type RoomState struct {
	ChannelID    uuid.UUID     `json:"channel_id"`
	Participants []Participant `json:"participants"`
}

// Grant is what a device needs to talk in the channel it joined.
type Grant struct {
	Member uint32
	Tag    Tag
	Secret Secret
}

// Sender puts a datagram on the way back to a member, over whichever path
// the member last used.
type Sender func(pkt []byte)

type member struct {
	Participant
	chatID    uuid.UUID
	channelID uuid.UUID
	tag       Tag
	keys      keys
	joinedAt  time.Time
	down      atomic.Uint64 // last counter used towards this member

	mu        sync.Mutex
	window    replayWindow
	out       Sender
	lastHeard time.Time
	tokens    float64
	refilled  time.Time
}

// take spends one packet of the member's budget. Called with mu held.
func (m *member) take(now time.Time) bool {
	if m.refilled.IsZero() {
		m.tokens, m.refilled = packetBurst, now
	}
	m.tokens = min(packetBurst, m.tokens+now.Sub(m.refilled).Seconds()*packetRate)
	m.refilled = now
	if m.tokens < 1 {
		return false
	}
	m.tokens--
	return true
}

func (m *member) sender() Sender {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.out
}

// Manager holds every voice channel in use on this server.
//
// Channels live in memory only: who is talking right now is not worth
// keeping, and a restart simply has everyone reconnect.
type Manager struct {
	mu       sync.RWMutex
	rooms    map[uuid.UUID]map[uint32]*member // by channel
	byTag    map[Tag]*member
	byDevice map[uuid.UUID]*member
	nextID   uint32

	changed chan struct{}
	pending map[uuid.UUID]struct{} // chats whose members have to be told
	pmu     sync.Mutex

	notify func(ctx context.Context, chatID uuid.UUID, rooms []RoomState)
	now    func() time.Time
	log    *slog.Logger

	// mediaHello: see defaultMediaHello. A field, so tests can shorten it.
	mediaHello time.Duration
}

// NewManager builds a Manager. notify tells a chat's members who is in its
// channels now; it is called from one goroutine at a time, so the last call
// for a chat always carries its latest state.
func NewManager(notify func(ctx context.Context, chatID uuid.UUID, rooms []RoomState), log *slog.Logger) *Manager {
	return &Manager{
		rooms:      map[uuid.UUID]map[uint32]*member{},
		byTag:      map[Tag]*member{},
		byDevice:   map[uuid.UUID]*member{},
		changed:    make(chan struct{}, 1),
		pending:    map[uuid.UUID]struct{}{},
		notify:     notify,
		now:        time.Now,
		log:        log,
		mediaHello: defaultMediaHello,
	}
}

// Run announces changes and drops members gone quiet, until ctx ends.
func (m *Manager) Run(ctx context.Context) {
	sweep := time.NewTicker(5 * time.Second)
	defer sweep.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-sweep.C:
			m.Sweep()
		case <-m.changed:
		}
		m.announce(ctx)
	}
}

// announce tells every chat with a change who is in its channels now.
func (m *Manager) announce(ctx context.Context) {
	m.pmu.Lock()
	chats := m.pending
	m.pending = map[uuid.UUID]struct{}{}
	m.pmu.Unlock()
	for chatID := range chats {
		if m.notify != nil {
			m.notify(ctx, chatID, m.Rooms(chatID))
		}
	}
}

func (m *Manager) touched(chatIDs ...uuid.UUID) {
	m.pmu.Lock()
	for _, id := range chatIDs {
		m.pending[id] = struct{}{}
	}
	m.pmu.Unlock()
	select {
	case m.changed <- struct{}{}:
	default:
	}
}

// Join puts a device in a channel, taking it out of any other first. A user
// is in one channel at a time: joining from a second device moves them, as
// in Discord.
func (m *Manager) Join(chatID, channelID, userID, deviceID uuid.UUID) (Grant, error) {
	var g Grant
	if _, err := rand.Read(g.Secret[:]); err != nil {
		return g, err
	}
	k, err := deriveKeys(g.Secret)
	if err != nil {
		return g, err
	}

	m.mu.Lock()
	var left []uuid.UUID
	for _, other := range m.byDevice {
		if other.UserID == userID || other.DeviceID == deviceID {
			left = append(left, other.chatID)
			m.removeLocked(other)
		}
	}
	room := m.rooms[channelID]
	if len(room) >= MaxParticipants {
		m.mu.Unlock()
		m.touched(left...)
		return g, ErrFull
	}
	for {
		if _, err := rand.Read(g.Tag[:]); err != nil {
			m.mu.Unlock()
			return g, err
		}
		if _, taken := m.byTag[g.Tag]; !taken {
			break
		}
	}
	m.nextID++
	g.Member = m.nextID
	now := m.now()
	mem := &member{
		Participant: Participant{Member: g.Member, UserID: userID, DeviceID: deviceID},
		chatID:      chatID,
		channelID:   channelID,
		tag:         g.Tag,
		keys:        k,
		joinedAt:    now,
		lastHeard:   now,
	}
	if room == nil {
		room = map[uint32]*member{}
		m.rooms[channelID] = room
	}
	room[g.Member] = mem
	m.byTag[g.Tag] = mem
	m.byDevice[deviceID] = mem
	m.mu.Unlock()

	m.touched(append(left, chatID)...)
	return g, nil
}

func (m *Manager) removeLocked(mem *member) {
	delete(m.byTag, mem.tag)
	delete(m.byDevice, mem.DeviceID)
	if room := m.rooms[mem.channelID]; room != nil {
		delete(room, mem.Member)
		if len(room) == 0 {
			delete(m.rooms, mem.channelID)
		}
	}
}

// Leave takes a device out of its channel. It reports whether it was in one.
func (m *Manager) Leave(deviceID uuid.UUID) bool {
	m.mu.Lock()
	mem := m.byDevice[deviceID]
	if mem != nil {
		m.removeLocked(mem)
	}
	m.mu.Unlock()
	if mem == nil {
		return false
	}
	m.touched(mem.chatID)
	return true
}

// SetState records whether a device's microphone and sound are off. It
// reports whether the device is in a channel.
func (m *Manager) SetState(deviceID uuid.UUID, muted, deafened bool) bool {
	m.mu.Lock()
	mem := m.byDevice[deviceID]
	if mem != nil {
		// Someone who hears nothing does not talk either, as in Discord.
		mem.Muted, mem.Deafened = muted || deafened, deafened
	}
	m.mu.Unlock()
	if mem == nil {
		return false
	}
	m.touched(mem.chatID)
	return true
}

// Rooms lists the channels of a chat that have someone in them.
func (m *Manager) Rooms(chatID uuid.UUID) []RoomState {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []RoomState
	for channelID, room := range m.rooms {
		var state RoomState
		for _, mem := range room {
			if mem.chatID != chatID {
				break
			}
			state.Participants = append(state.Participants, mem.Participant)
		}
		if len(state.Participants) == 0 {
			continue
		}
		state.ChannelID = channelID
		sort.Slice(state.Participants, func(i, j int) bool {
			return state.Participants[i].Member < state.Participants[j].Member
		})
		out = append(out, state)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ChannelID.String() < out[j].ChannelID.String() })
	return out
}

// ActiveChats lists the chats that have someone in a channel.
func (m *Manager) ActiveChats() []uuid.UUID {
	m.mu.RLock()
	defer m.mu.RUnlock()
	seen := map[uuid.UUID]struct{}{}
	var out []uuid.UUID
	for _, mem := range m.byDevice {
		if _, dup := seen[mem.chatID]; !dup {
			seen[mem.chatID] = struct{}{}
			out = append(out, mem.chatID)
		}
	}
	return out
}

// CloseChannel takes everyone out of a channel that was deleted.
func (m *Manager) CloseChannel(chatID, channelID uuid.UUID) {
	m.mu.Lock()
	for _, mem := range m.rooms[channelID] {
		m.removeLocked(mem)
	}
	m.mu.Unlock()
	m.touched(chatID)
}

// RemoveUser takes someone out of a chat's channels: they left the group or
// were removed from it.
func (m *Manager) RemoveUser(chatID, userID uuid.UUID) {
	m.mu.Lock()
	for _, mem := range m.byDevice {
		if mem.chatID == chatID && mem.UserID == userID {
			m.removeLocked(mem)
		}
	}
	m.mu.Unlock()
	m.touched(chatID)
}

// RemoveDevice takes a signed-out device out of whatever channel it is in:
// its key must stop working with its session, not 20 seconds later.
func (m *Manager) RemoveDevice(deviceID uuid.UUID) { m.Leave(deviceID) }

// RemoveUserDevices takes every device of a user but keep out of voice: the
// account's sessions were ended, by a password change or its deletion.
func (m *Manager) RemoveUserDevices(userID, keep uuid.UUID) {
	m.mu.Lock()
	var chats []uuid.UUID
	for _, mem := range m.byDevice {
		if mem.UserID == userID && mem.DeviceID != keep {
			chats = append(chats, mem.chatID)
			m.removeLocked(mem)
		}
	}
	m.mu.Unlock()
	if len(chats) > 0 {
		m.touched(chats...)
	}
}

// Sweep drops members nothing has been heard from for idleTimeout.
func (m *Manager) Sweep() {
	now := m.now()
	m.mu.Lock()
	var chats []uuid.UUID
	for _, mem := range m.byDevice {
		mem.mu.Lock()
		quiet := now.Sub(mem.lastHeard)
		mem.mu.Unlock()
		if quiet > idleTimeout {
			chats = append(chats, mem.chatID)
			m.removeLocked(mem)
		}
	}
	m.mu.Unlock()
	if len(chats) > 0 {
		m.touched(chats...)
	}
}

// Receive handles one datagram from a client. reply is the path back to it,
// which becomes the member's path once the datagram proves to be theirs.
func (m *Manager) Receive(pkt []byte, reply Sender) { m.receive(pkt, reply) }

// receive is Receive, reporting whether the datagram was a member's.
func (m *Manager) receive(pkt []byte, reply Sender) bool {
	tag, counter, err := header(pkt)
	if err != nil {
		return false
	}
	m.mu.RLock()
	mem := m.byTag[tag]
	m.mu.RUnlock()
	if mem == nil {
		return false
	}
	plain, err := open(mem.keys.up, counter, pkt)
	if err != nil || len(plain) == 0 {
		return false
	}

	now := m.now()
	mem.mu.Lock()
	if !mem.window.accept(counter) {
		mem.mu.Unlock()
		return false
	}
	// Only now, with the datagram authenticated and fresh: an address
	// change is the member's network moving, not someone else's say-so.
	mem.out = reply
	mem.lastHeard = now
	allowed := mem.take(now)
	mem.mu.Unlock()
	if !allowed {
		return true
	}

	switch plain[0] {
	case kindPing:
		if body := plain[1:]; len(body) <= maxPingBody {
			reply(seal(mem.keys.down, mem.tag, mem.down.Add(1), append([]byte{kindPong}, body...)))
		}
	case kindAudio:
		if len(plain) >= 1+2+1 {
			m.relay(mem, plain[1:])
		}
	}
	return true
}

// relay sends one member's sound to everyone else in the channel.
func (m *Manager) relay(from *member, frame []byte) {
	m.mu.RLock()
	if from.Muted || m.byTag[from.tag] != from {
		m.mu.RUnlock()
		return
	}
	var targets []*member
	for _, mem := range m.rooms[from.channelID] {
		if mem != from && !mem.Deafened {
			targets = append(targets, mem)
		}
	}
	m.mu.RUnlock()

	body := make([]byte, 0, 1+4+len(frame))
	body = append(body, kindAudio)
	body = binary.BigEndian.AppendUint32(body, from.Member)
	body = append(body, frame...)
	for _, to := range targets {
		if out := to.sender(); out != nil {
			out(seal(to.keys.down, to.tag, to.down.Add(1), body))
		}
	}
}
