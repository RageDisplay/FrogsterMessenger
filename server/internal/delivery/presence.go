package delivery

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// What others see of a user's presence.
const (
	StatusOnline = "online"
	// StatusOffline comes with the exact time the user was last seen.
	StatusOffline = "offline"
	// The rest are what a hidden "last seen" turns into: close enough to
	// know whether to expect an answer, not enough to track anyone.
	StatusRecently    = "recently"
	StatusWithinWeek  = "week"
	StatusWithinMonth = "month"
	StatusLongAgo     = "long_ago"
)

// offlineGrace is how long a user stays "online" after their last device
// went idle. Switching apps for a moment, or a phone reconnecting on a new
// network, should not announce a departure to everyone.
const offlineGrace = 8 * time.Second

// presenceStore is what presence needs of the database.
type presenceStore interface {
	ContactsOf(ctx context.Context, userID uuid.UUID) ([]uuid.UUID, error)
	PresenceInfo(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]store.PresenceInfo, error)
	SetLastSeen(ctx context.Context, userID uuid.UUID, at time.Time) error
}

// Presence tracks who is online and tells the people who share a chat with
// them.
//
// A user is online while one of their devices is active: connected and in
// the foreground. An app in the background keeps its connection for
// messages but says it is idle, so a phone in a pocket does not look like
// someone reading.
//
// The state lives in this process. The installer runs one server; several
// would each know only about the connections they hold.
type Presence struct {
	store presenceStore
	// devices and send reach contacts' connected devices: the router's in
	// the server, recorders in tests.
	devices func(ctx context.Context, users []uuid.UUID) ([]models.Device, error)
	send    func(ctx context.Context, key ws.ClientKey, env *ws.Envelope) bool
	log     *slog.Logger
	grace   time.Duration
	now     func() time.Time

	mu      sync.Mutex
	active  map[uuid.UUID]map[uuid.UUID]bool // user -> active devices
	leaving map[uuid.UUID]*time.Timer        // users within the grace period
}

// NewPresence builds the presence tracker.
func NewPresence(st *store.Store, router *Router, log *slog.Logger) *Presence {
	p := newPresence(st, log, offlineGrace)
	p.devices = st.UserDevicesFor
	// Presence is of the moment: a device that is not connected gets the
	// current state when it asks, not a backlog of old ones -- and the
	// router's delivery queues nothing for an offline device.
	p.send = router.deliverToDevice
	return p
}

func newPresence(st presenceStore, log *slog.Logger, grace time.Duration) *Presence {
	return &Presence{
		store:   st,
		log:     log,
		grace:   grace,
		now:     time.Now,
		active:  map[uuid.UUID]map[uuid.UUID]bool{},
		leaving: map[uuid.UUID]*time.Timer{},
	}
}

// DeviceActive records that a device is in use. The first one makes the
// user online.
func (p *Presence) DeviceActive(ctx context.Context, key ws.ClientKey) {
	p.mu.Lock()
	devices := p.active[key.UserID]
	wasOnline := len(devices) > 0
	_, wasLeaving := p.leaving[key.UserID]
	if devices == nil {
		devices = map[uuid.UUID]bool{}
		p.active[key.UserID] = devices
	}
	devices[key.DeviceID] = true
	if t := p.leaving[key.UserID]; t != nil {
		t.Stop()
		delete(p.leaving, key.UserID)
	}
	p.mu.Unlock()

	// Back within the grace period: nobody was told of the departure, so
	// there is no return to announce either.
	if !wasOnline && !wasLeaving {
		p.announce(ctx, key.UserID)
	}
}

// DeviceIdle records that a device went to the background or away. When it
// was the user's last active one, the user goes offline after the grace
// period.
func (p *Presence) DeviceIdle(ctx context.Context, key ws.ClientKey) {
	p.mu.Lock()
	defer p.mu.Unlock()
	devices := p.active[key.UserID]
	if !devices[key.DeviceID] {
		return
	}
	delete(devices, key.DeviceID)
	if len(devices) > 0 {
		return
	}
	delete(p.active, key.UserID)
	if _, already := p.leaving[key.UserID]; already {
		return
	}
	ctx = context.WithoutCancel(ctx)
	p.leaving[key.UserID] = time.AfterFunc(p.grace, func() { p.leave(ctx, key.UserID) })
}

func (p *Presence) leave(ctx context.Context, userID uuid.UUID) {
	p.mu.Lock()
	if _, still := p.leaving[userID]; !still || len(p.active[userID]) > 0 {
		p.mu.Unlock()
		return
	}
	delete(p.leaving, userID)
	p.mu.Unlock()

	if err := p.store.SetLastSeen(ctx, userID, p.now()); err != nil {
		p.log.Warn("record last seen", "err", err, "user_id", userID)
	}
	p.announce(ctx, userID)
}

// IsOnline reports whether a user is online, the grace period included.
func (p *Presence) IsOnline(userID uuid.UUID) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, leaving := p.leaving[userID]
	return len(p.active[userID]) > 0 || leaving
}

// VisibilityChanged re-announces a user whose "last seen" setting changed:
// their contacts now see more, or less.
func (p *Presence) VisibilityChanged(ctx context.Context, userID uuid.UUID) {
	p.announce(ctx, userID)
}

// Statuses reports the presence of the given users as viewer may see it.
// Only people who share a chat with the viewer are included: presence is
// for the people one talks to, not for watching strangers.
func (p *Presence) Statuses(ctx context.Context, viewer uuid.UUID, users []uuid.UUID) ([]store.PresenceStatus, error) {
	contacts, err := p.store.ContactsOf(ctx, viewer)
	if err != nil {
		return nil, err
	}
	known := make(map[uuid.UUID]bool, len(contacts))
	for _, c := range contacts {
		known[c] = true
	}
	ids := []uuid.UUID{viewer}
	for _, u := range users {
		if known[u] {
			ids = append(ids, u)
		}
	}
	info, err := p.store.PresenceInfo(ctx, ids)
	if err != nil {
		return nil, err
	}
	viewerVisible := info[viewer].Visible
	out := make([]store.PresenceStatus, 0, len(ids)-1)
	for _, u := range ids[1:] {
		out = append(out, p.statusFor(u, info[u], viewerVisible))
	}
	return out, nil
}

// statusFor is what a viewer sees of one user.
//
// As in other messengers it works both ways: hiding one's own "last seen"
// hides everyone else's from oneself. Otherwise hiding would cost nothing,
// and everyone would hide while watching the others.
func (p *Presence) statusFor(userID uuid.UUID, info store.PresenceInfo, viewerVisible bool) store.PresenceStatus {
	online := p.IsOnline(userID)
	if info.Visible && viewerVisible {
		if online {
			return store.PresenceStatus{UserID: userID, Status: StatusOnline}
		}
		if info.LastSeen != nil {
			return store.PresenceStatus{UserID: userID, Status: StatusOffline, LastSeen: info.LastSeen}
		}
		return store.PresenceStatus{UserID: userID, Status: StatusLongAgo}
	}
	if online || info.LastSeen == nil {
		// Never seen yet is a new account: "recently" rather than "long
		// ago", which would be wrong and tell something too.
		return store.PresenceStatus{UserID: userID, Status: StatusRecently}
	}
	switch age := p.now().Sub(*info.LastSeen); {
	case age <= 3*24*time.Hour:
		return store.PresenceStatus{UserID: userID, Status: StatusRecently}
	case age <= 7*24*time.Hour:
		return store.PresenceStatus{UserID: userID, Status: StatusWithinWeek}
	case age <= 30*24*time.Hour:
		return store.PresenceStatus{UserID: userID, Status: StatusWithinMonth}
	default:
		return store.PresenceStatus{UserID: userID, Status: StatusLongAgo}
	}
}

// announce sends a user's presence to every contact's connected devices,
// each as that contact may see it.
func (p *Presence) announce(ctx context.Context, userID uuid.UUID) {
	if p.send == nil {
		return
	}
	contacts, err := p.store.ContactsOf(ctx, userID)
	if err != nil {
		p.log.Warn("presence contacts", "err", err, "user_id", userID)
		return
	}
	if len(contacts) == 0 {
		return
	}
	info, err := p.store.PresenceInfo(ctx, append([]uuid.UUID{userID}, contacts...))
	if err != nil {
		p.log.Warn("presence info", "err", err, "user_id", userID)
		return
	}
	devices, err := p.devices(ctx, contacts)
	if err != nil {
		p.log.Warn("presence devices", "err", err, "user_id", userID)
		return
	}
	frames := map[uuid.UUID]*ws.Envelope{}
	for _, viewer := range contacts {
		status := p.statusFor(userID, info[userID], info[viewer].Visible)
		env := &ws.Envelope{
			Version: 1,
			Type:    ws.TypePresence,
			Sender:  &ws.Address{UserID: userID},
			Kind:    status.Status,
		}
		if status.LastSeen != nil {
			env.Timestamp = status.LastSeen.UnixMilli()
		}
		frames[viewer] = env
	}
	for _, d := range devices {
		p.send(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}, frames[d.UserID])
	}
}
