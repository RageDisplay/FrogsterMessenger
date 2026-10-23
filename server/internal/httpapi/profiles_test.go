package httpapi

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// png is the smallest thing that passes for a PNG: its signature, then
// anything.
var png = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{7}, 300)...)

// raw sends a body as it is and returns the status and response body.
func (f *apiFixture) raw(u apiUser, method, path string, body []byte) (int, []byte) {
	f.t.Helper()
	req, _ := http.NewRequest(method, f.srv.URL+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+u.token)
	req.Header.Set("Content-Type", "image/png")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func TestUserAvatar(t *testing.T) {
	f := newAPI(t)
	alice, bob := f.user("alice"), f.user("bob")
	chat, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})

	if status, _ := f.raw(alice, "PUT", "/v1/me/avatar", []byte("<svg onload=alert(1)>")); status != http.StatusUnsupportedMediaType {
		t.Fatalf("not an image: %d", status)
	}
	big := append(append([]byte{}, png...), make([]byte, 600<<10)...)
	if status, _ := f.raw(alice, "PUT", "/v1/me/avatar", big); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("too large: %d", status)
	}
	if status, _ := f.raw(bob, "GET", "/v1/users/"+alice.id.String()+"/avatar", nil); status != http.StatusNotFound {
		t.Fatalf("before any avatar: %d", status)
	}

	if status, _ := f.raw(alice, "PUT", "/v1/me/avatar", png); status != http.StatusOK {
		t.Fatalf("set: %d", status)
	}
	status, got := f.raw(bob, "GET", "/v1/users/"+alice.id.String()+"/avatar", nil)
	if status != http.StatusOK || !bytes.Equal(got, png) {
		t.Fatalf("get: %d, %d bytes", status, len(got))
	}
	if !f.notifier.told(uuid.MustParse(chat.ID), bob.id) {
		t.Fatal("bob was not told alice changed her picture")
	}

	// The chat carries the version, so bob's app knows to fetch it.
	var seen chatJSON
	f.call(bob, "GET", "/v1/chats/"+chat.ID, nil, &seen)
	version := 0
	for _, m := range seen.Members {
		if m.UserID == alice.id.String() {
			version = m.AvatarVersion
		}
	}
	if version != 1 {
		t.Fatalf("member avatar version %d", version)
	}

	// Sealed at rest.
	var stored struct{ Data []byte }
	if err := f.st.DB().Raw(`SELECT data FROM avatars WHERE owner_id = ?`, alice.id).Scan(&stored).Error; err != nil {
		t.Fatal(err)
	}
	if len(stored.Data) == 0 || bytes.Contains(stored.Data, png[:8]) {
		t.Fatal("the avatar is stored in the clear")
	}

	// Removed: gone, and the version differs from every earlier one.
	if status, _ := f.raw(alice, "DELETE", "/v1/me/avatar", nil); status != http.StatusNoContent {
		t.Fatalf("clear: %d", status)
	}
	if status, _ := f.raw(bob, "GET", "/v1/users/"+alice.id.String()+"/avatar", nil); status != http.StatusNotFound {
		t.Fatalf("after removal: %d", status)
	}
	var me userJSON
	f.call(alice, "GET", "/v1/me", nil, &me)
	if me.AvatarVersion > 0 {
		t.Fatalf("version after removal %d", me.AvatarVersion)
	}
	f.raw(alice, "PUT", "/v1/me/avatar", png)
	f.call(alice, "GET", "/v1/me", nil, &me)
	if me.AvatarVersion <= 1 {
		t.Fatalf("a new avatar after removal reused version %d", me.AvatarVersion)
	}
}

func TestGroupAvatar(t *testing.T) {
	f := newAPI(t)
	admin, ann, eve := f.user("adm"), f.user("ann"), f.user("eve")
	group, _ := f.createChat(admin, map[string]any{"type": "group", "mode": "cloud", "title": "Пруд", "members": []string{ann.username}})
	secret, _ := f.createChat(admin, map[string]any{"type": "group", "mode": "secret", "members": []string{ann.username}})
	path := "/v1/chats/" + group.ID + "/avatar"

	if status, _ := f.raw(ann, "PUT", path, png); status != http.StatusForbidden {
		t.Fatalf("a member set the group's avatar: %d", status)
	}
	if status, _ := f.raw(admin, "PUT", "/v1/chats/"+secret.ID+"/avatar", png); status != http.StatusBadRequest {
		t.Fatalf("a secret group got a server-side avatar: %d", status)
	}
	if status, _ := f.raw(admin, "PUT", path, png); status != http.StatusOK {
		t.Fatalf("set: %d", status)
	}
	if status, got := f.raw(ann, "GET", path, nil); status != http.StatusOK || !bytes.Equal(got, png) {
		t.Fatalf("member get: %d", status)
	}
	if status, _ := f.raw(eve, "GET", path, nil); status != http.StatusNotFound {
		t.Fatalf("outsider saw the group's avatar: %d", status)
	}
	var seen chatJSON
	f.call(ann, "GET", "/v1/chats/"+group.ID, nil, &seen)
	if seen.AvatarVersion != 1 {
		t.Fatalf("chat avatar version %d", seen.AvatarVersion)
	}
}

// A group that hides its past starts newcomers at the moment they join;
// the members from before keep everything.
func TestHideHistoryFromNewMembers(t *testing.T) {
	f := newAPI(t)
	admin, ann, ben, cat := f.user("adm"), f.user("ann"), f.user("ben"), f.user("cat")
	group, _ := f.createChat(admin, map[string]any{"type": "group", "mode": "cloud", "title": "Клуб", "members": []string{ann.username}})
	id := uuid.MustParse(group.ID)
	say := func(body string) {
		msg := &models.Message{ChatID: id, SenderID: admin.id, SenderDevID: uuid.New()}
		cid := uuid.NewString()
		msg.ClientID = &cid
		if err := f.st.PersistCloudMessage(context.Background(), msg, []byte(body), ""); err != nil {
			t.Fatal(err)
		}
	}
	say(`{"body":"before"}`)

	// Off by default: ben sees what was said before him.
	f.call(admin, "POST", "/v1/chats/"+group.ID+"/members", map[string]any{"members": []string{ben.username}}, nil)
	var page struct{ Messages []messageJSON }
	f.call(ben, "GET", "/v1/chats/"+group.ID+"/messages", nil, &page)
	if len(page.Messages) != 1 {
		t.Fatalf("history shown by default: %d messages", len(page.Messages))
	}

	if status := f.call(ann, "PATCH", "/v1/chats/"+group.ID, map[string]any{"hide_history": true}, nil); status != http.StatusForbidden {
		t.Fatalf("a member changed the setting: %d", status)
	}
	var updated chatJSON
	if status := f.call(admin, "PATCH", "/v1/chats/"+group.ID, map[string]any{"hide_history": true}, &updated); status != http.StatusOK || !updated.HideHistory || updated.Title != "Клуб" {
		t.Fatalf("turn on: %d %+v", status, updated)
	}

	f.call(admin, "POST", "/v1/chats/"+group.ID+"/members", map[string]any{"members": []string{cat.username}}, nil)
	say(`{"body":"after"}`)

	f.call(cat, "GET", "/v1/chats/"+group.ID+"/messages", nil, &page)
	if len(page.Messages) != 1 || string(page.Messages[0].Payload) != `{"body":"after"}` {
		t.Fatalf("newcomer history: %+v", page.Messages)
	}
	var list struct{ Chats []chatJSON }
	f.call(cat, "GET", "/v1/chats", nil, &list)
	if len(list.Chats) != 1 || list.Chats[0].Unread != 1 {
		t.Fatalf("newcomer unread: %+v", list.Chats)
	}
	// Turning it on took nothing from those already there.
	f.call(ben, "GET", "/v1/chats/"+group.ID+"/messages", nil, &page)
	if len(page.Messages) != 2 {
		t.Fatalf("an earlier member lost history: %d", len(page.Messages))
	}
}

// Each rule has its own bucket: spending the search budget leaves the rest
// of the API alone, and the general API cannot refill a stricter budget.
func TestRateLimitBucketsAreSeparate(t *testing.T) {
	claims := &auth.Claims{UserID: uuid.New()}
	r := httptest.NewRequest("GET", "/", nil).WithContext(auth.WithClaims(context.Background(), claims))
	api, search, password := userBucket("api")(r), userBucket("search")(r), userBucket("password")(r)
	if api == search || api == password || search == password {
		t.Fatalf("shared buckets: %q %q %q", api, search, password)
	}
	if userBucket("api")(httptest.NewRequest("GET", "/", nil)) != "" {
		t.Fatal("an anonymous request got a user bucket")
	}
}

// Search reaches what the device never loaded, but only where the user can
// look: not chats they are not in, not before they cleared, not deleted
// messages, not secret chats.
func TestSearchCloudHistory(t *testing.T) {
	f := newAPI(t)
	alice, bob, eve := f.user("alice"), f.user("bob"), f.user("eve")
	chat, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	other, _ := f.createChat(eve, map[string]any{"type": "direct", "mode": "cloud", "peer": alice.username})
	say := func(chatID string, from apiUser, payload string) string {
		msg := &models.Message{ChatID: uuid.MustParse(chatID), SenderID: from.id, SenderDevID: uuid.New()}
		cid := uuid.NewString()
		msg.ClientID = &cid
		if err := f.st.PersistCloudMessage(context.Background(), msg, []byte(payload), ""); err != nil {
			t.Fatal(err)
		}
		return cid
	}
	say(chat.ID, alice, `{"body":"Старый Пароль от вайфая"}`)
	f.call(bob, "POST", "/v1/chats/"+chat.ID+"/clear", nil, nil)
	say(chat.ID, alice, `{"body":"новый ПАРОЛЬ: лягушка"}`)
	gone := say(chat.ID, alice, `{"body":"пароль, который удалят"}`)
	say(chat.ID, bob, `{"attachment":{"name":"Пароли.pdf"}}`)
	say(other.ID, eve, `{"body":"пароль от евы"}`)
	del := &models.Message{ChatID: uuid.MustParse(chat.ID), SenderID: alice.id, SenderDevID: uuid.New(), Kind: models.KindDelete, TargetID: &gone}
	cid := uuid.NewString()
	del.ClientID = &cid
	if err := f.st.PersistCloudMessage(context.Background(), del, nil, ""); err != nil {
		t.Fatalf("delete event: %v", err)
	}

	var res struct {
		Results []searchHitJSON
	}
	if status := f.call(bob, "GET", "/v1/search?q="+url.QueryEscape("ПАРОЛ"), nil, &res); status != http.StatusOK {
		t.Fatalf("search: %d", status)
	}
	var bodies []string
	for _, r := range res.Results {
		if r.ChatID != chat.ID {
			t.Fatalf("a hit from a chat bob is not in: %+v", r)
		}
		bodies = append(bodies, string(r.Message.Payload))
	}
	want := []string{`{"attachment":{"name":"Пароли.pdf"}}`, `{"body":"новый ПАРОЛЬ: лягушка"}`}
	if strings.Join(bodies, "|") != strings.Join(want, "|") {
		t.Fatalf("hits: %v", bodies)
	}
	if status := f.call(bob, "GET", "/v1/search?q=a", nil, nil); status != http.StatusBadRequest {
		t.Fatalf("one-letter search: %d", status)
	}
}
