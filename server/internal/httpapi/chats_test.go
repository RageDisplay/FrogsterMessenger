package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/config"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/storagecrypto"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// recordingNotifier remembers which chats were announced to whom.
type recordingNotifier struct {
	mu      sync.Mutex
	updated map[uuid.UUID][]uuid.UUID
}

func (n *recordingNotifier) NotifyDeviceAdded(context.Context, uuid.UUID, uuid.UUID)   {}
func (n *recordingNotifier) NotifyDeviceRevoked(context.Context, uuid.UUID, uuid.UUID) {}
func (n *recordingNotifier) NotifyChatUpdated(_ context.Context, chatID uuid.UUID, _ uint64, users []uuid.UUID) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.updated[chatID] = append(n.updated[chatID], users...)
}

func (n *recordingNotifier) told(chatID, user uuid.UUID) bool {
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		n.mu.Lock()
		for _, u := range n.updated[chatID] {
			if u == user {
				n.mu.Unlock()
				return true
			}
		}
		n.mu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

type apiFixture struct {
	t        *testing.T
	st       *store.Store
	srv      *httptest.Server
	tokens   *auth.Manager
	notifier *recordingNotifier
}

type apiUser struct {
	id       uuid.UUID
	username string
	token    string
}

func newAPI(t *testing.T) *apiFixture {
	t.Helper()
	dsn := os.Getenv("FROGSTER_TEST_DATABASE_URL")
	if dsn == "" {
		dsn = "postgres://frogster:frogster@localhost:5432/frogster?sslmode=disable"
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, err := store.Open(context.Background(), dsn, log)
	if err != nil {
		t.Skipf("postgres unavailable: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatal(err)
	}
	sealer, _ := storagecrypto.New(bytes.Repeat([]byte{5}, storagecrypto.KeySize))
	st.SetSealer(sealer)

	tokens := auth.NewManager([]byte("test-secret-test-secret-test-secret!"), time.Hour, 24*time.Hour)
	notifier := &recordingNotifier{updated: map[uuid.UUID][]uuid.UUID{}}
	api := NewServer(&config.Config{}, st, tokens, ratelimit.NewMemoryLimiter(), notifier, nil, log)
	srv := httptest.NewServer(api.Routes())
	t.Cleanup(srv.Close)
	return &apiFixture{t: t, st: st, srv: srv, tokens: tokens, notifier: notifier}
}

func (f *apiFixture) user(prefix string) apiUser {
	f.t.Helper()
	u := &models.User{Username: prefix + "_" + uuid.NewString()[:8], PasswordHash: "$2a$12$abcdefghijklmnopqrstuv"}
	d := &models.Device{RegistrationID: 1, DeviceName: "d", IdentityKeyPub: make([]byte, 33)}
	spk := &models.SignedPreKey{KeyID: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)}
	if err := f.st.CreateUserWithDevice(context.Background(), u, d, spk, nil); err != nil {
		f.t.Fatal(err)
	}
	token, err := f.tokens.IssueAccess(u.ID, d.ID, u.TokenVersion)
	if err != nil {
		f.t.Fatal(err)
	}
	return apiUser{id: u.ID, username: u.Username, token: token}
}

// call sends a request and decodes a JSON response into out, returning the
// status.
func (f *apiFixture) call(u apiUser, method, path string, body, out any) int {
	f.t.Helper()
	var r io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		r = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, f.srv.URL+path, r)
	req.Header.Set("Authorization", "Bearer "+u.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil && resp.StatusCode < 300 && resp.StatusCode != http.StatusNoContent {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			f.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return resp.StatusCode
}

func (f *apiFixture) createChat(u apiUser, body map[string]any) (chatJSON, int) {
	var c chatJSON
	status := f.call(u, "POST", "/v1/chats", body, &c)
	return c, status
}

// A cloud and a secret chat with the same person live side by side, and
// asking for either again returns the one that exists.
func TestDirectChatsAreOnePerMode(t *testing.T) {
	f := newAPI(t)
	alice, bob := f.user("alice"), f.user("bob")

	cloud, status := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	if status != http.StatusCreated || cloud.Mode != "cloud" {
		t.Fatalf("cloud chat: %d %+v", status, cloud)
	}
	secret, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "secret", "peer": bob.username})
	if secret.ID == cloud.ID || secret.Mode != "secret" {
		t.Fatal("the secret chat reused the cloud one")
	}
	again, status := f.createChat(bob, map[string]any{"type": "direct", "mode": "cloud", "peer": alice.username})
	if status != http.StatusOK || again.ID != cloud.ID {
		t.Fatalf("the peer asking again got %d %s, want the existing %s", status, again.ID, cloud.ID)
	}
	// Clients from before cloud chats send no mode, and only made secret ones.
	legacy, _ := f.createChat(bob, map[string]any{"type": "direct", "peer": alice.username})
	if legacy.ID != secret.ID {
		t.Fatal("a request without a mode did not resolve to the secret chat")
	}
	if !f.notifier.told(uuid.MustParse(cloud.ID), bob.id) {
		t.Fatal("the peer was not told about the new chat")
	}

	var list struct{ Chats []chatJSON }
	f.call(bob, "GET", "/v1/chats", nil, &list)
	if len(list.Chats) != 2 {
		t.Fatalf("bob lists %d chats", len(list.Chats))
	}
}

func TestHistoryIsForMembersOfCloudChats(t *testing.T) {
	f := newAPI(t)
	alice, bob, eve := f.user("alice"), f.user("bob"), f.user("eve")
	cloud, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	secret, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "secret", "peer": bob.username})

	id := uuid.MustParse(cloud.ID)
	for i, body := range []string{`{"body":"one"}`, `{"body":"two"}`, `{"body":"three"}`} {
		msg := &models.Message{ChatID: id, SenderID: alice.id, SenderDevID: uuid.New()}
		cid := uuid.NewString()
		msg.ClientID = &cid
		if err := f.st.PersistCloudMessage(context.Background(), msg, []byte(body), ""); err != nil {
			t.Fatalf("message %d: %v", i, err)
		}
	}

	var page struct{ Messages []messageJSON }
	if status := f.call(bob, "GET", "/v1/chats/"+cloud.ID+"/messages?limit=2", nil, &page); status != http.StatusOK {
		t.Fatalf("history: %d", status)
	}
	if len(page.Messages) != 2 || string(page.Messages[0].Payload) != `{"body":"three"}` {
		t.Fatalf("newest page: %+v", page.Messages)
	}
	f.call(bob, "GET", "/v1/chats/"+cloud.ID+"/messages?before=2", nil, &page)
	if len(page.Messages) != 1 || page.Messages[0].Seq != 1 {
		t.Fatalf("older page: %+v", page.Messages)
	}
	f.call(bob, "GET", "/v1/chats/"+cloud.ID+"/messages?after=1", nil, &page)
	if len(page.Messages) != 2 || page.Messages[0].Seq != 2 {
		t.Fatalf("sync page: %+v", page.Messages)
	}

	// Someone outside the chat cannot tell it exists.
	if status := f.call(eve, "GET", "/v1/chats/"+cloud.ID+"/messages", nil, nil); status != http.StatusNotFound {
		t.Fatalf("outsider read history: %d", status)
	}
	if status := f.call(eve, "GET", "/v1/chats/"+cloud.ID, nil, nil); status != http.StatusNotFound {
		t.Fatalf("outsider read the chat: %d", status)
	}
	if status := f.call(bob, "GET", "/v1/chats/"+secret.ID+"/messages", nil, nil); status != http.StatusBadRequest {
		t.Fatalf("secret chat served history: %d", status)
	}

	var list struct{ Chats []chatJSON }
	f.call(bob, "GET", "/v1/chats", nil, &list)
	for _, c := range list.Chats {
		if c.ID == cloud.ID && (c.Unread != 3 || c.Last == nil || string(c.Last.Payload) != `{"body":"three"}`) {
			t.Fatalf("cloud chat in the list: %+v", c)
		}
	}
}

func TestGroupAdministration(t *testing.T) {
	f := newAPI(t)
	admin, ann, ben, cat := f.user("adm"), f.user("ann"), f.user("ben"), f.user("cat")

	if _, status := f.createChat(admin, map[string]any{"type": "group", "mode": "cloud", "members": []string{ann.username}}); status != http.StatusBadRequest {
		t.Fatalf("cloud group without a title: %d", status)
	}
	group, status := f.createChat(admin, map[string]any{
		"type": "group", "mode": "cloud", "title": "Пруд", "members": []string{ann.username, ben.username},
	})
	if status != http.StatusCreated || group.Title != "Пруд" || len(group.Members) != 3 || group.Role != "admin" {
		t.Fatalf("create group: %d %+v", status, group)
	}
	path := "/v1/chats/" + group.ID

	// Members cannot manage the group.
	if status := f.call(ann, "POST", path+"/members", map[string]any{"members": []string{cat.username}}, nil); status != http.StatusForbidden {
		t.Fatalf("member added someone: %d", status)
	}
	if status := f.call(ann, "PATCH", path, map[string]any{"title": "мой"}, nil); status != http.StatusForbidden {
		t.Fatalf("member renamed the group: %d", status)
	}

	var updated chatJSON
	if status := f.call(admin, "POST", path+"/members", map[string]any{"members": []string{cat.username}}, &updated); status != http.StatusOK || len(updated.Members) != 4 {
		t.Fatalf("add member: %d %+v", status, updated)
	}
	if updated.Epoch <= group.Epoch {
		t.Fatal("adding a member did not move the epoch")
	}
	if !f.notifier.told(uuid.MustParse(group.ID), cat.id) {
		t.Fatal("the new member was not told")
	}
	f.call(admin, "PATCH", path, map[string]any{"title": "Болото"}, &updated)
	if updated.Title != "Болото" {
		t.Fatalf("rename: %q", updated.Title)
	}

	if status := f.call(admin, "DELETE", path+"/members/"+ben.id.String(), nil, &updated); status != http.StatusOK || len(updated.Members) != 3 {
		t.Fatalf("remove member: %d", status)
	}
	if status := f.call(ben, "GET", path, nil, nil); status != http.StatusNotFound {
		t.Fatalf("removed member still sees the group: %d", status)
	}

	// The last admin leaving hands the group to the longest-standing member.
	if status := f.call(admin, "POST", path+"/leave", nil, nil); status != http.StatusNoContent {
		t.Fatalf("leave: %d", status)
	}
	var seen chatJSON
	f.call(ann, "GET", path, nil, &seen)
	if seen.Role != "admin" {
		t.Fatalf("after the admin left, ann is %q", seen.Role)
	}
}

func TestSecretGroupTitleNeverReachesTheServer(t *testing.T) {
	f := newAPI(t)
	admin, ann := f.user("adm"), f.user("ann")
	group, status := f.createChat(admin, map[string]any{
		"type": "group", "mode": "secret", "title": "секрет", "members": []string{ann.username},
	})
	if status != http.StatusCreated || group.Title != "" {
		t.Fatalf("secret group: %d %+v", status, group)
	}
	chat, _ := f.st.ChatByID(context.Background(), uuid.MustParse(group.ID))
	if len(chat.Title) != 0 {
		t.Fatal("the server stored a secret group's title")
	}
	if status := f.call(admin, "PATCH", "/v1/chats/"+group.ID, map[string]any{"title": "x"}, nil); status != http.StatusBadRequest {
		t.Fatalf("server-side rename of a secret group: %d", status)
	}
}

func TestSearchAndProfile(t *testing.T) {
	f := newAPI(t)
	me := f.user("srch")
	other := f.user("srch")

	var found struct{ Users []userJSON }
	if status := f.call(me, "GET", "/v1/users/search?q=@srch_", nil, &found); status != http.StatusOK {
		t.Fatalf("search: %d", status)
	}
	sawOther := false
	for _, u := range found.Users {
		if u.UserID == me.id.String() {
			t.Fatal("search returned the searcher")
		}
		sawOther = sawOther || u.UserID == other.id.String()
	}
	if !sawOther {
		t.Fatal("search missed a matching user")
	}
	// A LIKE wildcard is a literal character, not "match anything".
	f.call(me, "GET", "/v1/users/search?q=%25%25", nil, &found)
	if len(found.Users) != 0 {
		t.Fatalf("wildcard query matched %d users", len(found.Users))
	}
	if status := f.call(me, "GET", "/v1/users/search?q=s", nil, nil); status != http.StatusBadRequest {
		t.Fatalf("one-letter search: %d", status)
	}

	var profile userJSON
	f.call(me, "PATCH", "/v1/me", map[string]any{"display_name": "  Квакша  ", "bio": "живу в пруду"}, &profile)
	if profile.DisplayName != "Квакша" {
		t.Fatalf("display name %q", profile.DisplayName)
	}
	var cleared userJSON
	f.call(me, "PATCH", "/v1/me", map[string]any{"bio": ""}, &cleared)
	if cleared.DisplayName != "Квакша" || cleared.Bio != "" {
		t.Fatalf("partial update: %+v", cleared)
	}
	long := bytes.Repeat([]byte("я"), 65)
	if status := f.call(me, "PATCH", "/v1/me", map[string]any{"display_name": string(long)}, nil); status != http.StatusBadRequest {
		t.Fatalf("overlong name: %d", status)
	}
	var seen userJSON
	f.call(other, "GET", "/v1/users/"+me.id.String(), nil, &seen)
	if seen.DisplayName != "Квакша" || seen.Username != me.username {
		t.Fatalf("lookup: %+v", seen)
	}
}

// Clearing a cloud chat hides its history from the one who cleared it, on
// every device and every later sync, and from nobody else.
func TestClearHistoryIsPersonal(t *testing.T) {
	f := newAPI(t)
	alice, bob := f.user("alice"), f.user("bob")
	chat, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	id := uuid.MustParse(chat.ID)
	send := func(body string) {
		msg := &models.Message{ChatID: id, SenderID: alice.id, SenderDevID: uuid.New()}
		cid := uuid.NewString()
		msg.ClientID = &cid
		if err := f.st.PersistCloudMessage(context.Background(), msg, []byte(body), ""); err != nil {
			t.Fatal(err)
		}
	}
	send(`{"body":"old"}`)

	if status := f.call(bob, "POST", "/v1/chats/"+chat.ID+"/clear", nil, nil); status != http.StatusOK {
		t.Fatalf("clear: %d", status)
	}
	send(`{"body":"new"}`)

	var page struct{ Messages []messageJSON }
	f.call(bob, "GET", "/v1/chats/"+chat.ID+"/messages", nil, &page)
	if len(page.Messages) != 1 || string(page.Messages[0].Payload) != `{"body":"new"}` {
		t.Fatalf("bob's history after clearing: %+v", page.Messages)
	}
	f.call(bob, "GET", "/v1/chats/"+chat.ID+"/messages?after=0", nil, &page)
	if len(page.Messages) != 1 {
		t.Fatalf("bob's sync replays cleared rows: %d", len(page.Messages))
	}
	var seen chatJSON
	f.call(bob, "GET", "/v1/chats/"+chat.ID, nil, &seen)
	if seen.Unread != 1 || seen.ClearedSeq != 1 {
		t.Fatalf("bob's chat: unread %d cleared %d", seen.Unread, seen.ClearedSeq)
	}
	f.call(alice, "GET", "/v1/chats/"+chat.ID+"/messages", nil, &page)
	if len(page.Messages) != 2 {
		t.Fatalf("clearing touched alice's history: %d", len(page.Messages))
	}
}

// Deleting an account needs the password, ends every session, leaves every
// group with a new epoch, frees the name -- and keeps the messages the
// others already have.
func TestDeleteAccount(t *testing.T) {
	f := newAPI(t)
	alice, bob := f.user("alice"), f.user("bob")
	hash, err := auth.HashPassword("correct horse battery", 10)
	if err != nil {
		t.Fatal(err)
	}
	f.st.DB().Model(&models.User{}).Where("id = ?", alice.id).Update("password_hash", hash)

	direct, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	group, _ := f.createChat(bob, map[string]any{
		"type": "group", "mode": "secret", "members": []string{alice.username},
	})
	msg := &models.Message{ChatID: uuid.MustParse(direct.ID), SenderID: alice.id, SenderDevID: uuid.New()}
	cid := "from-alice"
	msg.ClientID = &cid
	if err := f.st.PersistCloudMessage(context.Background(), msg, []byte(`{"body":"на память"}`), ""); err != nil {
		t.Fatal(err)
	}

	if status := f.call(alice, "DELETE", "/v1/me", map[string]any{"password": "wrong password!"}, nil); status != http.StatusForbidden {
		t.Fatalf("wrong password: %d", status)
	}
	if status := f.call(alice, "DELETE", "/v1/me", map[string]any{"password": "correct horse battery"}, nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}

	if status := f.call(alice, "GET", "/v1/me", nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("the deleted account's token still works: %d", status)
	}
	if _, err := f.st.UserByUsername(context.Background(), alice.username); err == nil {
		t.Fatal("the name was not freed")
	}
	// Nobody can fetch keys for the account any more: no device is left
	// to encrypt for.
	if devices, _ := f.st.ActiveDevices(context.Background(), alice.id); len(devices) != 0 {
		t.Fatalf("%d devices survived the deletion", len(devices))
	}

	var seen chatJSON
	f.call(bob, "GET", "/v1/chats/"+group.ID, nil, &seen)
	if len(seen.Members) != 1 || seen.Epoch <= group.Epoch {
		t.Fatalf("group after deletion: %d members, epoch %d", len(seen.Members), seen.Epoch)
	}
	if !f.notifier.told(uuid.MustParse(group.ID), bob.id) {
		t.Fatal("the group was not told")
	}
	var page struct{ Messages []messageJSON }
	f.call(bob, "GET", "/v1/chats/"+direct.ID+"/messages", nil, &page)
	if len(page.Messages) != 1 {
		t.Fatalf("bob lost the deleted account's messages: %d", len(page.Messages))
	}
}
