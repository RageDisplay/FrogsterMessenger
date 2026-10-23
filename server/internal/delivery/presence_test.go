package delivery

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// fakePresenceStore holds who shares a chat with whom, and last-seen data.
type fakePresenceStore struct {
	mu       sync.Mutex
	contacts map[uuid.UUID][]uuid.UUID
	info     map[uuid.UUID]store.PresenceInfo
}

func (s *fakePresenceStore) ContactsOf(_ context.Context, id uuid.UUID) ([]uuid.UUID, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.contacts[id], nil
}

func (s *fakePresenceStore) PresenceInfo(_ context.Context, ids []uuid.UUID) (map[uuid.UUID]store.PresenceInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[uuid.UUID]store.PresenceInfo{}
	for _, id := range ids {
		out[id] = s.info[id]
	}
	return out, nil
}

func (s *fakePresenceStore) SetLastSeen(_ context.Context, id uuid.UUID, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	i := s.info[id]
	i.LastSeen = &at
	s.info[id] = i
	return nil
}

type sentFrame struct {
	to  uuid.UUID
	env *ws.Envelope
}

type presenceRig struct {
	p      *Presence
	st     *fakePresenceStore
	mu     sync.Mutex
	frames []sentFrame
	alice  uuid.UUID
	bob    uuid.UUID
	eve    uuid.UUID
}

// newRig: alice and bob share a chat; eve shares nothing with anyone.
func newRig(grace time.Duration) *presenceRig {
	r := &presenceRig{alice: uuid.New(), bob: uuid.New(), eve: uuid.New()}
	r.st = &fakePresenceStore{
		contacts: map[uuid.UUID][]uuid.UUID{r.alice: {r.bob}, r.bob: {r.alice}},
		info: map[uuid.UUID]store.PresenceInfo{
			r.alice: {Visible: true}, r.bob: {Visible: true}, r.eve: {Visible: true},
		},
	}
	r.p = newPresence(r.st, slog.New(slog.NewTextHandler(io.Discard, nil)), grace)
	r.p.devices = func(_ context.Context, users []uuid.UUID) ([]models.Device, error) {
		var out []models.Device
		for _, u := range users {
			out = append(out, models.Device{ID: uuid.New(), UserID: u})
		}
		return out, nil
	}
	r.p.send = func(_ context.Context, key ws.ClientKey, env *ws.Envelope) bool {
		r.mu.Lock()
		defer r.mu.Unlock()
		r.frames = append(r.frames, sentFrame{to: key.UserID, env: env})
		return true
	}
	return r
}

func (r *presenceRig) sent() []sentFrame {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]sentFrame(nil), r.frames...)
}

func (r *presenceRig) key(user uuid.UUID) ws.ClientKey {
	return ws.ClientKey{UserID: user, DeviceID: user}
}

func TestPresenceAnnouncesComingAndGoing(t *testing.T) {
	r := newRig(30 * time.Millisecond)
	ctx := context.Background()

	r.p.DeviceActive(ctx, r.key(r.alice))
	frames := r.sent()
	if len(frames) != 1 || frames[0].to != r.bob || frames[0].env.Kind != StatusOnline || frames[0].env.Sender.UserID != r.alice {
		t.Fatalf("coming online: %+v", frames)
	}

	// A second device changes nothing anyone sees.
	r.p.DeviceActive(ctx, ws.ClientKey{UserID: r.alice, DeviceID: uuid.New()})
	if len(r.sent()) != 1 {
		t.Fatal("a second device announced again")
	}
	r.p.DeviceIdle(ctx, ws.ClientKey{UserID: r.alice, DeviceID: uuid.New()}) // never active: ignored
	r.p.DeviceIdle(ctx, r.key(r.alice))
	time.Sleep(80 * time.Millisecond)
	if len(r.sent()) != 1 || !r.p.IsOnline(r.alice) {
		t.Fatal("went offline while a device was still active")
	}
}

// Switching apps for a moment is not leaving.
func TestPresenceGracePeriod(t *testing.T) {
	r := newRig(60 * time.Millisecond)
	ctx := context.Background()
	r.p.DeviceActive(ctx, r.key(r.alice))
	r.p.DeviceIdle(ctx, r.key(r.alice))
	time.Sleep(20 * time.Millisecond)
	r.p.DeviceActive(ctx, r.key(r.alice))
	time.Sleep(100 * time.Millisecond)
	if frames := r.sent(); len(frames) != 1 {
		t.Fatalf("a brief absence was announced: %d frames", len(frames))
	}

	r.p.DeviceIdle(ctx, r.key(r.alice))
	time.Sleep(120 * time.Millisecond)
	frames := r.sent()
	last := frames[len(frames)-1].env
	if len(frames) != 2 || last.Kind != StatusOffline || last.Timestamp == 0 {
		t.Fatalf("leaving: %+v", last)
	}
	if r.p.IsOnline(r.alice) {
		t.Fatal("still online after leaving")
	}
	r.st.mu.Lock()
	recorded := r.st.info[r.alice].LastSeen
	r.st.mu.Unlock()
	if recorded == nil {
		t.Fatal("last seen was not recorded")
	}
}

// Hiding one's last seen hides it from others -- and others' from oneself.
func TestPresencePrivacyWorksBothWays(t *testing.T) {
	r := newRig(10 * time.Millisecond)
	ctx := context.Background()
	seen := time.Now().Add(-2 * time.Hour)
	r.st.info[r.alice] = store.PresenceInfo{Visible: true, LastSeen: &seen}

	status := func(viewer, user uuid.UUID) store.PresenceStatus {
		got, err := r.p.Statuses(ctx, viewer, []uuid.UUID{user})
		if err != nil || len(got) != 1 {
			t.Fatalf("statuses: %v %+v", err, got)
		}
		return got[0]
	}
	if s := status(r.bob, r.alice); s.Status != StatusOffline || s.LastSeen == nil {
		t.Fatalf("visible: %+v", s)
	}

	r.st.info[r.alice] = store.PresenceInfo{Visible: false, LastSeen: &seen}
	if s := status(r.bob, r.alice); s.Status != StatusRecently || s.LastSeen != nil {
		t.Fatalf("alice hidden: %+v", s)
	}

	r.st.info[r.alice] = store.PresenceInfo{Visible: true, LastSeen: &seen}
	r.st.info[r.bob] = store.PresenceInfo{Visible: false}
	if s := status(r.bob, r.alice); s.Status != StatusRecently {
		t.Fatalf("bob, who hides his own, saw alice's: %+v", s)
	}

	// Online is hidden the same way.
	r.p.DeviceActive(ctx, r.key(r.alice))
	if s := status(r.bob, r.alice); s.Status != StatusRecently {
		t.Fatalf("bob saw alice online: %+v", s)
	}
	frames := r.sent()
	if frames[len(frames)-1].env.Kind != StatusRecently {
		t.Fatalf("the announcement to bob gave alice away: %+v", frames[len(frames)-1].env)
	}

	old := time.Now().Add(-10 * 24 * time.Hour)
	r.st.info[r.eve] = store.PresenceInfo{Visible: false, LastSeen: &old}
	r.st.contacts[r.bob] = append(r.st.contacts[r.bob], r.eve)
	if s := status(r.bob, r.eve); s.Status != StatusWithinMonth {
		t.Fatalf("a vague age: %+v", s)
	}
}

// Presence is for people who share a chat, not for watching strangers.
func TestPresenceOnlyForContacts(t *testing.T) {
	r := newRig(10 * time.Millisecond)
	ctx := context.Background()
	r.p.DeviceActive(ctx, r.key(r.eve))
	if len(r.sent()) != 0 {
		t.Fatal("eve, with no contacts, was announced to someone")
	}
	got, err := r.p.Statuses(ctx, r.alice, []uuid.UUID{r.eve, r.bob})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].UserID != r.bob {
		t.Fatalf("alice learned about a stranger: %+v", got)
	}
}
