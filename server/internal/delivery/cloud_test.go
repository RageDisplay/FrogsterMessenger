package delivery_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/delivery"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// group is a chat with live sockets for chosen devices.
type group struct {
	t      *testing.T
	st     *store.Store
	hub    *ws.Hub
	router *delivery.Router
	chat   *models.Chat
	// members[0] is the creator and an admin.
	members []ws.ClientKey
}

func quietLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func newGroup(t *testing.T, chatType, mode string, members int) *group {
	t.Helper()
	st := newStore(t)
	sealer, err := storagecrypto.New(bytes.Repeat([]byte{3}, storagecrypto.KeySize))
	if err != nil {
		t.Fatal(err)
	}
	st.SetSealer(sealer)

	g := &group{t: t, st: st}
	ids := make([]uuid.UUID, 0, members)
	for range members {
		u, d := seedUser(t, st)
		ids = append(ids, u)
		g.members = append(g.members, ws.ClientKey{UserID: u, DeviceID: d})
	}
	g.chat = &models.Chat{Type: chatType, Mode: mode, CreatorID: ids[0]}
	if err := st.CreateChat(context.Background(), g.chat, ids); err != nil {
		t.Fatalf("create chat: %v", err)
	}

	g.hub = ws.NewHub(quietLog())
	ctx, stop := context.WithCancel(context.Background())
	t.Cleanup(stop)
	go g.hub.Run(ctx)
	g.router = delivery.NewRouter(g.hub, st, nil, ws.NewPresence(nil, "test-node"), quietLog())
	return g
}

// addDevice gives a member a second device.
func (g *group) addDevice(member int) ws.ClientKey {
	g.t.Helper()
	d := &models.Device{
		UserID:         g.members[member].UserID,
		RegistrationID: 2,
		DeviceName:     "second",
		IdentityKeyPub: make([]byte, 33),
	}
	spk := &models.SignedPreKey{KeyID: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)}
	if err := g.st.AddDevice(context.Background(), d, spk, nil); err != nil {
		g.t.Fatalf("add device: %v", err)
	}
	return ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}
}

func (g *group) connect(key ws.ClientKey) *ws.Client {
	g.t.Helper()
	c := ws.NewDetachedClient(key, quietLog())
	g.hub.Register(c)
	deadline := time.Now().Add(2 * time.Second)
	for !g.hub.IsLocal(key) {
		if time.Now().After(deadline) {
			g.t.Fatal("client never registered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	return c
}

// cloud sends a cloud message or event from a member's first device.
func (g *group) cloud(from int, env ws.Envelope) (*models.Message, error) {
	key := g.members[from]
	env.Version = 1
	env.Type = ws.TypeMessage
	env.ChatID = g.chat.ID
	env.Sender = &ws.Address{UserID: key.UserID, DeviceID: key.DeviceID}
	return g.router.Send(context.Background(), &env)
}

func (g *group) mustCloud(from int, env ws.Envelope) *models.Message {
	g.t.Helper()
	msg, err := g.cloud(from, env)
	if err != nil {
		g.t.Fatalf("send: %v", err)
	}
	return msg
}

func (g *group) history() map[string]store.CloudMessage {
	g.t.Helper()
	msgs, err := g.st.CloudHistory(context.Background(), g.chat.ID, 0, 100)
	if err != nil {
		g.t.Fatalf("history: %v", err)
	}
	out := map[string]store.CloudMessage{}
	for _, m := range msgs {
		out[m.WireID()] = m
	}
	return out
}

func noFrame(t *testing.T, c *ws.Client) {
	t.Helper()
	select {
	case raw := <-c.Outbox():
		t.Fatalf("unexpected frame: %s", raw)
	case <-time.After(100 * time.Millisecond):
	}
}

// A cloud message reaches every other device of the chat at once, the
// sender's own other devices included, and is kept for history -- sealed,
// never as the plaintext the client sent.
func TestCloudMessageIsSealedAndReachesEveryDevice(t *testing.T) {
	g := newGroup(t, models.ChatTypeDirect, models.ChatModeCloud, 2)
	second := g.addDevice(0)
	peer := g.connect(g.members[1])
	mine := g.connect(second)
	sender := g.connect(g.members[0])

	body := []byte(`{"body":"привет, облако"}`)
	msg := g.mustCloud(0, ws.Envelope{ID: "c-1", Ciphertext: body})

	for name, c := range map[string]*ws.Client{"peer": peer, "own other device": mine} {
		got := nextFrame(t, c)
		if got.ID != "c-1" || got.Seq != msg.Seq || !bytes.Equal(got.Ciphertext, body) {
			t.Fatalf("%s got %+v", name, got)
		}
	}
	noFrame(t, sender)

	var raw models.Message
	if err := g.st.DB().First(&raw, "id = ?", msg.ID).Error; err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw.Ciphertext, []byte("облако")) || len(raw.Ciphertext) == 0 {
		t.Fatal("cloud message stored unsealed")
	}
	if got := g.history()["c-1"]; !bytes.Equal(got.Payload, body) {
		t.Fatalf("history payload %q", got.Payload)
	}

	var queued int64
	g.st.DB().Model(&models.MessageDelivery{}).Where("message_id = ?", msg.ID).Count(&queued)
	if queued != 0 {
		t.Fatalf("cloud message queued %d delivery rows; history is the queue", queued)
	}
}

// Each mode takes only what it is meant to. A plaintext payload accepted into
// a secret chat would silently strip the end-to-end encryption the user
// chose; ratchet ciphertext in a cloud chat would be history nobody can read.
func TestModesRefuseEachOthersPayloads(t *testing.T) {
	secret := newGroup(t, models.ChatTypeDirect, models.ChatModeSecret, 2)
	if _, err := secret.cloud(0, ws.Envelope{ID: "p", Ciphertext: []byte(`{"body":"x"}`)}); !errors.Is(err, delivery.ErrRejected) {
		t.Fatalf("plaintext into a secret chat: %v", err)
	}
	peer := secret.members[1]
	if _, err := secret.cloud(0, ws.Envelope{
		ID: "e", Kind: models.KindEdit, TargetID: "x",
		Payloads: []ws.DevicePayload{{UserID: peer.UserID, DeviceID: peer.DeviceID, Ciphertext: []byte{1}, CipherType: 2}},
	}); !errors.Is(err, delivery.ErrRejected) {
		t.Fatalf("event metadata on a secret message: %v", err)
	}

	cloud := newGroup(t, models.ChatTypeDirect, models.ChatModeCloud, 2)
	p := cloud.members[1]
	if _, err := cloud.cloud(0, ws.Envelope{
		ID: "r", Ciphertext: []byte(`{"body":"x"}`), CipherType: models.CipherTypeWhisper,
		Payloads: []ws.DevicePayload{{UserID: p.UserID, DeviceID: p.DeviceID, Ciphertext: []byte{1}, CipherType: 2}},
	}); !errors.Is(err, delivery.ErrRejected) {
		t.Fatalf("ratchet payload into a cloud chat: %v", err)
	}

	group := newGroup(t, models.ChatTypeGroup, models.ChatModeSecret, 3)
	for _, ct := range []uint8{models.CipherTypeCloud, models.CipherTypeWhisper} {
		if _, err := group.cloud(0, ws.Envelope{ID: "g", Ciphertext: []byte("x"), CipherType: ct}); !errors.Is(err, delivery.ErrRejected) {
			t.Fatalf("type %d into a secret group: %v", ct, err)
		}
	}
	// A secret direct chat takes only ratchet types, never a cloud payload
	// smuggled in as one device's ciphertext.
	if _, err := secret.cloud(0, ws.Envelope{
		ID:       "s",
		Payloads: []ws.DevicePayload{{UserID: peer.UserID, DeviceID: peer.DeviceID, Ciphertext: []byte("x"), CipherType: models.CipherTypeCloud}},
	}); !errors.Is(err, delivery.ErrRejected) {
		t.Fatalf("cloud-typed payload into a secret chat: %v", err)
	}
}

func TestOnlyTheAuthorEdits(t *testing.T) {
	g := newGroup(t, models.ChatTypeGroup, models.ChatModeCloud, 3)
	g.mustCloud(1, ws.Envelope{ID: "m", Ciphertext: []byte(`{"body":"v1"}`)})

	// Not even an admin may change someone else's words.
	if _, err := g.cloud(0, ws.Envelope{ID: "e1", Kind: models.KindEdit, TargetID: "m", Ciphertext: []byte(`{"body":"forged"}`)}); !errors.Is(err, store.ErrForbidden) {
		t.Fatalf("admin edited another's message: %v", err)
	}
	g.mustCloud(1, ws.Envelope{ID: "e2", Kind: models.KindEdit, TargetID: "m", Ciphertext: []byte(`{"body":"v2"}`)})

	got := g.history()["m"]
	if string(got.Payload) != `{"body":"v2"}` || got.EditedAt == nil {
		t.Fatalf("after edit: %q edited=%v", got.Payload, got.EditedAt)
	}
	if _, ok := g.history()["e2"]; ok {
		t.Fatal("history lists the edit event as a message")
	}
}

func TestDeletionErasesContent(t *testing.T) {
	g := newGroup(t, models.ChatTypeGroup, models.ChatModeCloud, 3)
	g.mustCloud(1, ws.Envelope{ID: "a", Ciphertext: []byte(`{"body":"one"}`)})
	g.mustCloud(1, ws.Envelope{ID: "b", Ciphertext: []byte(`{"body":"two"}`)})
	g.mustCloud(2, ws.Envelope{ID: "r", Kind: models.KindReact, TargetID: "a", Emoji: "🐸", Ciphertext: []byte(`{}`)})

	// A plain member cannot delete someone else's message...
	if _, err := g.cloud(2, ws.Envelope{ID: "d1", Kind: models.KindDelete, TargetID: "a", Ciphertext: []byte(`{}`)}); !errors.Is(err, store.ErrForbidden) {
		t.Fatalf("member deleted another's message: %v", err)
	}
	// ...the author can, and so can a group admin.
	g.mustCloud(1, ws.Envelope{ID: "d2", Kind: models.KindDelete, TargetID: "a", Ciphertext: []byte(`{}`)})
	g.mustCloud(0, ws.Envelope{ID: "d3", Kind: models.KindDelete, TargetID: "b", Ciphertext: []byte(`{}`)})

	h := g.history()
	for _, id := range []string{"a", "b"} {
		if !h[id].Deleted() || len(h[id].Payload) != 0 || len(h[id].Reactions) != 0 {
			t.Fatalf("%s after delete: %+v", id, h[id])
		}
	}
	var raw models.Message
	g.st.DB().Where("client_id = ?", "a").First(&raw)
	if len(raw.Ciphertext) != 0 {
		t.Fatal("deleted message kept its sealed body in the database")
	}
	// A deleted message cannot be edited back to life.
	if _, err := g.cloud(1, ws.Envelope{ID: "e", Kind: models.KindEdit, TargetID: "a", Ciphertext: []byte(`{"body":"back"}`)}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("edited a deleted message: %v", err)
	}
}

func TestReactionsAndSync(t *testing.T) {
	g := newGroup(t, models.ChatTypeDirect, models.ChatModeCloud, 2)
	g.mustCloud(0, ws.Envelope{ID: "m", Ciphertext: []byte(`{"body":"hi"}`)})
	g.mustCloud(1, ws.Envelope{ID: "r1", Kind: models.KindReact, TargetID: "m", Emoji: "👍", Ciphertext: []byte(`{}`)})
	g.mustCloud(0, ws.Envelope{ID: "r2", Kind: models.KindReact, TargetID: "m", Emoji: "👍", Ciphertext: []byte(`{}`)})
	g.mustCloud(0, ws.Envelope{ID: "r3", Kind: models.KindUnreact, TargetID: "m", Emoji: "👍", Ciphertext: []byte(`{}`)})

	got := g.history()["m"].Reactions["👍"]
	if len(got) != 1 || got[0] != g.members[1].UserID {
		t.Fatalf("reactions %v", got)
	}

	// A device that saw seq 1 replays the events after it, in order.
	since, err := g.st.CloudSince(context.Background(), g.chat.ID, 1, 100)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, m := range since {
		kinds = append(kinds, m.Kind)
	}
	if len(kinds) != 3 || kinds[0] != "react" || kinds[2] != "unreact" {
		t.Fatalf("sync after seq 1: %v", kinds)
	}
	if _, err := g.cloud(0, ws.Envelope{ID: "bad", Kind: models.KindReact, TargetID: "m", Ciphertext: []byte(`{}`)}); err == nil {
		t.Fatal("reaction without an emoji accepted")
	}
}

func TestReadPositionsAndUnreadCounts(t *testing.T) {
	g := newGroup(t, models.ChatTypeDirect, models.ChatModeCloud, 2)
	for _, id := range []string{"1", "2", "3"} {
		g.mustCloud(0, ws.Envelope{ID: id, Ciphertext: []byte(`{"body":"x"}`)})
	}
	ctx := context.Background()
	reader := g.members[1]
	own := g.connect(g.members[0])

	summary := func(user uuid.UUID) store.ChatSummary {
		t.Helper()
		s, err := g.st.ChatSummaryFor(ctx, g.chat.ID, user)
		if err != nil {
			t.Fatal(err)
		}
		return *s
	}
	if s := summary(reader.UserID); s.Unread != 3 || s.LastSeq != 3 {
		t.Fatalf("before reading: %+v", s)
	}
	if s := summary(g.members[0].UserID); s.Unread != 0 {
		t.Fatalf("own messages counted as unread: %d", s.Unread)
	}

	if err := g.router.MarkRead(ctx, reader, g.chat.ID, 2); err != nil {
		t.Fatal(err)
	}
	if got := nextFrame(t, own); got.Type != ws.TypeRead || got.Seq != 2 {
		t.Fatalf("sender saw %+v", got)
	}
	if s := summary(g.members[0].UserID); s.PeerReadSeq != 2 {
		t.Fatalf("peer read seq %d", s.PeerReadSeq)
	}

	// Never backwards, never past the end.
	if pos, _ := g.st.MarkRead(ctx, g.chat.ID, reader.UserID, 1); pos != 2 {
		t.Fatalf("read position moved back to %d", pos)
	}
	if pos, _ := g.st.MarkRead(ctx, g.chat.ID, reader.UserID, 99); pos != 3 {
		t.Fatalf("read position ran past the end: %d", pos)
	}
	if s := summary(reader.UserID); s.Unread != 0 {
		t.Fatalf("after reading everything: %d unread", s.Unread)
	}
}

func TestCloudGroupTitleIsSealed(t *testing.T) {
	g := newGroup(t, models.ChatTypeGroup, models.ChatModeCloud, 2)
	if err := g.st.SetChatTitle(context.Background(), g.chat.ID, "Лягушатник"); err != nil {
		t.Fatal(err)
	}
	chat, err := g.st.ChatByID(context.Background(), g.chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(chat.Title, []byte("Лягушатник")) {
		t.Fatal("title stored unsealed")
	}
	if got := g.st.OpenTitle(chat); got != "Лягушатник" {
		t.Fatalf("title %q", got)
	}
}

// secretGroupMessage sends a sender-key message for an epoch.
func (g *group) secretGroupMessage(from int, id string, epoch uint64) error {
	key := g.members[from]
	_, err := g.router.Send(context.Background(), &ws.Envelope{
		Version: 1, Type: ws.TypeMessage, ID: id, ChatID: g.chat.ID,
		Sender:     &ws.Address{UserID: key.UserID, DeviceID: key.DeviceID},
		CipherType: models.CipherTypeSenderKey, Ciphertext: []byte("sealed"), Epoch: epoch,
	})
	return err
}

// Removing a member moves the group to a new epoch, and a message encrypted
// under the old one is refused: its sender key is one the removed member
// holds.
func TestSecretGroupRefusesTheEpochARemovedMemberKnows(t *testing.T) {
	g := newGroup(t, models.ChatTypeGroup, models.ChatModeSecret, 3)
	if err := g.secretGroupMessage(0, "before", 0); err != nil {
		t.Fatalf("current epoch refused: %v", err)
	}
	epoch, err := g.st.RemoveMember(context.Background(), g.chat.ID, g.members[2].UserID)
	if err != nil {
		t.Fatal(err)
	}
	if err := g.secretGroupMessage(0, "stale", epoch-1); !errors.Is(err, store.ErrStaleEpoch) {
		t.Fatalf("old epoch accepted: %v", err)
	}
	if err := g.secretGroupMessage(0, "after", epoch); err != nil {
		t.Fatalf("new epoch refused: %v", err)
	}
	var queued int64
	g.st.DB().Model(&models.MessageDelivery{}).
		Joins("JOIN messages ON messages.id = message_deliveries.message_id").
		Where("messages.client_id = ? AND message_deliveries.user_id = ?", "after", g.members[2].UserID).
		Count(&queued)
	if queued != 0 {
		t.Fatal("removed member still receives the group's messages")
	}
}

// Sender keys go only to devices in the group, arrive before the messages
// that need them, and are retired by the device that stored them.
func TestSenderKeysReachOnlyMembersAndComeFirst(t *testing.T) {
	g := newGroup(t, models.ChatTypeGroup, models.ChatModeSecret, 3)
	outsiderUser, outsiderDevice := seedUser(t, g.st)
	ctx := context.Background()
	sender := g.members[0]

	payload := func(k ws.ClientKey) ws.DevicePayload {
		return ws.DevicePayload{UserID: k.UserID, DeviceID: k.DeviceID, Ciphertext: []byte("skdm"), CipherType: 1}
	}
	n, err := g.router.DistributeSenderKeys(ctx, &ws.Envelope{
		Type: ws.TypeSKDM, ChatID: g.chat.ID, Epoch: 0,
		Sender: &ws.Address{UserID: sender.UserID, DeviceID: sender.DeviceID},
		Payloads: []ws.DevicePayload{
			payload(g.members[1]), payload(g.members[2]),
			payload(ws.ClientKey{UserID: outsiderUser, DeviceID: outsiderDevice}),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("distributed to %d devices; the outsider must be dropped", n)
	}
	if err := g.secretGroupMessage(0, "g-1", 0); err != nil {
		t.Fatal(err)
	}

	member := g.members[1]
	client := g.connect(member)
	go func() { _, _ = g.router.FlushOffline(ctx, member) }()

	first := nextFrame(t, client)
	if first.Type != ws.TypeSKDM || first.Sender.DeviceID != sender.DeviceID {
		t.Fatalf("first frame %+v; the sender key must come before the message", first)
	}
	if second := nextFrame(t, client); second.Type != ws.TypeMessage || second.ID != "g-1" {
		t.Fatalf("second frame %+v", second)
	}
	nextFrame(t, client) // sync_done

	// Another device cannot retire this device's key.
	if _, err := g.router.Acknowledge(ctx, g.members[2], []string{first.ID}); err != nil {
		t.Fatal(err)
	}
	if keys, _ := g.st.PendingSenderKeys(ctx, member.UserID, member.DeviceID); len(keys) != 1 {
		t.Fatalf("someone else's ack retired the key: %d left", len(keys))
	}
	if _, err := g.router.Acknowledge(ctx, member, []string{first.ID}); err != nil {
		t.Fatal(err)
	}
	if keys, _ := g.st.PendingSenderKeys(ctx, member.UserID, member.DeviceID); len(keys) != 0 {
		t.Fatalf("acknowledged key still pending: %d", len(keys))
	}

	// A key for an epoch the group already left is refused.
	if _, err := g.st.RemoveMember(ctx, g.chat.ID, g.members[2].UserID); err != nil {
		t.Fatal(err)
	}
	_, err = g.router.DistributeSenderKeys(ctx, &ws.Envelope{
		Type: ws.TypeSKDM, ChatID: g.chat.ID, Epoch: 0,
		Sender:   &ws.Address{UserID: sender.UserID, DeviceID: sender.DeviceID},
		Payloads: []ws.DevicePayload{payload(g.members[1])},
	})
	if !errors.Is(err, store.ErrStaleEpoch) {
		t.Fatalf("stale-epoch sender key accepted: %v", err)
	}
}

// The janitor keeps cloud history and drops the leftover body of a secret
// group message once nobody can still be waiting for it.
func TestRetentionKeepsCloudHistory(t *testing.T) {
	cloud := newGroup(t, models.ChatTypeDirect, models.ChatModeCloud, 2)
	kept := cloud.mustCloud(0, ws.Envelope{ID: "keep", Ciphertext: []byte(`{"body":"x"}`)})
	secret := newGroup(t, models.ChatTypeGroup, models.ChatModeSecret, 2)
	if err := secret.secretGroupMessage(0, "old", 0); err != nil {
		t.Fatal(err)
	}
	db := cloud.st.DB()
	db.Exec("UPDATE messages SET created_at = now() - interval '90 days' WHERE chat_id IN (?, ?)", cloud.chat.ID, secret.chat.ID)

	if _, err := cloud.st.PurgeExpired(context.Background(), store.RetentionPolicy{
		UndeliveredQueue: 24 * time.Hour, Delivered: time.Hour, Spent: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}
	var m models.Message
	db.First(&m, "id = ?", kept.ID)
	if len(m.Ciphertext) == 0 {
		t.Fatal("retention emptied a cloud message")
	}
	var old models.Message
	db.Where("chat_id = ? AND client_id = ?", secret.chat.ID, "old").First(&old)
	if old.ID == uuid.Nil || len(old.Ciphertext) != 0 {
		t.Fatal("old secret-group body kept forever")
	}
}
