package httpapi

import (
	"bytes"
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
)

type voiceListJSON struct {
	Channels []struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Participants []struct {
			Member   uint32 `json:"member"`
			UserID   string `json:"user_id"`
			DeviceID string `json:"device_id"`
			Muted    bool   `json:"muted"`
			Deafened bool   `json:"deafened"`
		} `json:"participants"`
	} `json:"channels"`
}

func (f *apiFixture) voiceList(u apiUser, chatID string) (voiceListJSON, int) {
	var out voiceListJSON
	status := f.call(u, "GET", "/v1/chats/"+chatID+"/voice", nil, &out)
	return out, status
}

// inChannel lists the user ids in a channel, as a member sees them.
func (f *apiFixture) inChannel(u apiUser, chatID, channelID string) []string {
	f.t.Helper()
	list, status := f.voiceList(u, chatID)
	if status != http.StatusOK {
		f.t.Fatalf("list voice: %d", status)
	}
	var out []string
	for _, ch := range list.Channels {
		if ch.ID == channelID {
			for _, p := range ch.Participants {
				out = append(out, p.UserID)
			}
		}
	}
	return out
}

func (f *apiFixture) cloudGroup(admin apiUser, members ...apiUser) chatJSON {
	f.t.Helper()
	names := make([]string, 0, len(members))
	for _, m := range members {
		names = append(names, m.username)
	}
	chat, status := f.createChat(admin, map[string]any{"type": "group", "mode": "cloud", "title": "Пруд", "members": names})
	if status != http.StatusCreated {
		f.t.Fatalf("create group: %d", status)
	}
	return chat
}

func (f *apiFixture) newChannel(u apiUser, chatID, name string) (voiceChannelJSON, int) {
	var ch voiceChannelJSON
	status := f.call(u, "POST", "/v1/chats/"+chatID+"/voice", map[string]any{"name": name}, &ch)
	return ch, status
}

func TestVoiceChannelsAreManagedByAdmins(t *testing.T) {
	f := newAPI(t)
	admin, bob, stranger := f.user("admin"), f.user("bob"), f.user("stranger")
	group := f.cloudGroup(admin, bob)

	if _, status := f.newChannel(bob, group.ID, "Болталка"); status != http.StatusForbidden {
		t.Fatalf("a member made a channel: %d", status)
	}
	for _, name := range []string{"", "   ", strings.Repeat("я", maxChannelName+1)} {
		if _, status := f.newChannel(admin, group.ID, name); status != http.StatusBadRequest {
			t.Fatalf("name %q: %d", name, status)
		}
	}
	ch, status := f.newChannel(admin, group.ID, "  Болталка ")
	if status != http.StatusCreated || ch.Name != "Болталка" {
		t.Fatalf("create: %d %+v", status, ch)
	}
	if f.notifier.voiceTold(uuid.MustParse(group.ID)) == 0 {
		t.Error("the group was not told about the new channel")
	}

	// Sealed at rest, like the group's title.
	var row struct{ Name []byte }
	if err := f.st.DB().Raw(`SELECT name FROM voice_channels WHERE id = ?`, ch.ID).Scan(&row).Error; err != nil {
		t.Fatal(err)
	}
	if len(row.Name) == 0 || bytes.Contains(row.Name, []byte("Болталка")) {
		t.Fatal("the channel name is stored in the clear")
	}

	list, _ := f.voiceList(bob, group.ID)
	if len(list.Channels) != 1 || list.Channels[0].Name != "Болталка" {
		t.Fatalf("bob sees %+v", list)
	}
	if _, status := f.voiceList(stranger, group.ID); status != http.StatusNotFound {
		t.Fatalf("a stranger listed the channels: %d", status)
	}

	path := "/v1/chats/" + group.ID + "/voice/" + ch.ID
	if status := f.call(bob, "PATCH", path, map[string]any{"name": "Моё"}, nil); status != http.StatusForbidden {
		t.Fatalf("a member renamed: %d", status)
	}
	if status := f.call(admin, "PATCH", path, map[string]any{"name": "Кухня"}, nil); status != http.StatusNoContent {
		t.Fatalf("rename: %d", status)
	}
	if list, _ := f.voiceList(bob, group.ID); list.Channels[0].Name != "Кухня" {
		t.Fatalf("after rename: %+v", list)
	}

	for i := 1; i < 10; i++ {
		if _, status := f.newChannel(admin, group.ID, "к"+string(rune('0'+i))); status != http.StatusCreated {
			t.Fatalf("channel %d: %d", i, status)
		}
	}
	if _, status := f.newChannel(admin, group.ID, "лишний"); status != http.StatusConflict {
		t.Fatalf("an 11th channel: %d", status)
	}
}

func TestVoiceIsForCloudGroupsOnly(t *testing.T) {
	f := newAPI(t)
	alice, bob := f.user("alice"), f.user("bob")
	secret, _ := f.createChat(alice, map[string]any{"type": "group", "mode": "secret", "members": []string{bob.username}})
	direct, _ := f.createChat(alice, map[string]any{"type": "direct", "mode": "cloud", "peer": bob.username})
	for _, chat := range []chatJSON{secret, direct} {
		if _, status := f.voiceList(alice, chat.ID); status != http.StatusBadRequest {
			t.Errorf("%s %s chat: %d", chat.Mode, chat.Type, status)
		}
	}
}

func TestJoiningTalkingAndLeaving(t *testing.T) {
	f := newAPI(t)
	admin, bob, cat := f.user("admin"), f.user("bob"), f.user("cat")
	group := f.cloudGroup(admin, bob, cat)
	ch, _ := f.newChannel(admin, group.ID, "Общий")
	join := "/v1/chats/" + group.ID + "/voice/" + ch.ID + "/join"

	var grant voiceJoinJSON
	if status := f.call(bob, "POST", join, nil, &grant); status != http.StatusOK {
		t.Fatalf("join: %d", status)
	}
	if len(grant.Secret) != 32 || len(grant.Tag) != 8 || grant.Member == 0 {
		t.Fatalf("grant %+v", grant)
	}
	if grant.UDPPort != 7882 || grant.MediaPath != mediaPath {
		t.Fatalf("no way to send sound: %+v", grant)
	}
	var catGrant voiceJoinJSON
	f.call(cat, "POST", join, nil, &catGrant)
	if bytes.Equal(catGrant.Secret, grant.Secret) || bytes.Equal(catGrant.Tag, grant.Tag) {
		t.Fatal("two members share keys")
	}

	if got := f.inChannel(admin, group.ID, ch.ID); len(got) != 2 {
		t.Fatalf("in the channel: %v", got)
	}

	// Mute shows; deafen implies mute.
	if status := f.call(cat, "POST", "/v1/voice/state", map[string]any{"deafened": true}, nil); status != http.StatusNoContent {
		t.Fatalf("state: %d", status)
	}
	list, _ := f.voiceList(admin, group.ID)
	for _, p := range list.Channels[0].Participants {
		if p.UserID == cat.id.String() && !(p.Muted && p.Deafened) {
			t.Fatalf("cat %+v", p)
		}
	}

	// The chat list learns where people are talking; a stranger does not.
	var active struct {
		Chats []struct {
			ChatID string `json:"chat_id"`
		} `json:"chats"`
	}
	f.call(admin, "GET", "/v1/voice", nil, &active)
	if len(active.Chats) != 1 || active.Chats[0].ChatID != group.ID {
		t.Fatalf("active %+v", active)
	}
	stranger := f.user("stranger")
	active.Chats = nil
	f.call(stranger, "GET", "/v1/voice", nil, &active)
	if len(active.Chats) != 0 {
		t.Fatalf("a stranger sees %+v", active)
	}

	if status := f.call(bob, "POST", "/v1/voice/leave", nil, nil); status != http.StatusNoContent {
		t.Fatalf("leave: %d", status)
	}
	if got := f.inChannel(admin, group.ID, ch.ID); len(got) != 1 || got[0] != cat.id.String() {
		t.Fatalf("after leaving: %v", got)
	}
	if status := f.call(bob, "POST", "/v1/voice/state", map[string]any{"muted": true}, nil); status != http.StatusNotFound {
		t.Fatalf("state outside a channel: %d", status)
	}
}

func TestJoiningNeedsARealChannelOfThatGroup(t *testing.T) {
	f := newAPI(t)
	admin, bob, stranger := f.user("admin"), f.user("bob"), f.user("stranger")
	group := f.cloudGroup(admin, bob)
	other := f.cloudGroup(stranger, admin)
	foreign, _ := f.newChannel(stranger, other.ID, "Чужой")

	for name, path := range map[string]string{
		"made up":               "/v1/chats/" + group.ID + "/voice/" + uuid.NewString() + "/join",
		"another group's":       "/v1/chats/" + group.ID + "/voice/" + foreign.ID + "/join",
		"not a uuid":            "/v1/chats/" + group.ID + "/voice/x/join",
		"a group bob is not in": "/v1/chats/" + other.ID + "/voice/" + foreign.ID + "/join",
	} {
		if status := f.call(bob, "POST", path, nil, nil); status == http.StatusOK {
			t.Errorf("joined %s channel", name)
		}
	}
}

// secondDevice signs a user in on another device.
func (f *apiFixture) secondDevice(u apiUser) apiUser {
	f.t.Helper()
	d := &models.Device{UserID: u.id, RegistrationID: 2, DeviceName: "laptop", IdentityKeyPub: make([]byte, 33)}
	spk := &models.SignedPreKey{KeyID: 1, PublicKey: make([]byte, 33), Signature: make([]byte, 64)}
	if err := f.st.AddDevice(context.Background(), d, spk, nil); err != nil {
		f.t.Fatal(err)
	}
	var user models.User
	f.st.DB().First(&user, "id = ?", u.id)
	token, err := f.tokens.IssueAccess(u.id, d.ID, user.TokenVersion)
	if err != nil {
		f.t.Fatal(err)
	}
	return apiUser{id: u.id, username: u.username, token: token}
}

// A password change ends every other session of the account, and with them
// its voice elsewhere; the device that changed it stays in.
func TestPasswordChangeEndsVoiceElsewhere(t *testing.T) {
	f := newAPI(t)
	admin, bob, cat := f.user("admin"), f.user("bob"), f.user("cat")
	group := f.cloudGroup(admin, bob, cat)
	ch, _ := f.newChannel(admin, group.ID, "Общий")
	other, _ := f.newChannel(admin, group.ID, "Второй")
	join := func(u apiUser, channel string) {
		if status := f.call(u, "POST", "/v1/chats/"+group.ID+"/voice/"+channel+"/join", nil, nil); status != http.StatusOK {
			t.Fatalf("join: %d", status)
		}
	}

	hash, _ := auth.HashPassword("old-password-1", 10)
	f.st.DB().Model(&models.User{}).Where("id = ?", bob.id).Update("password_hash", hash)
	laptop := f.secondDevice(bob)
	join(laptop, ch.ID)
	join(cat, ch.ID)

	var tokens struct {
		AccessToken string `json:"access_token"`
	}
	if status := f.call(bob, "POST", "/v1/password",
		map[string]any{"current_password": "old-password-1", "new_password": "new-password-2"}, &tokens); status != http.StatusOK {
		t.Fatalf("password change: %d", status)
	}
	if got := f.inChannel(admin, group.ID, ch.ID); len(got) != 1 || got[0] != cat.id.String() {
		t.Fatalf("after the password change: %v", got)
	}

	// The device that changed it can still join, and stays when it does.
	phone := apiUser{id: bob.id, username: bob.username, token: tokens.AccessToken}
	join(phone, other.ID)
	f.call(admin, "POST", "/v1/password",
		map[string]any{"current_password": "wrong", "new_password": "whatever-123"}, nil)
	if got := f.inChannel(admin, group.ID, other.ID); len(got) != 1 {
		t.Fatalf("bob's own device was dropped: %v", got)
	}
}

// Whoever loses access to the group, or whose session ends, is out of its
// channels at once: their keys must stop working with their access.
func TestLosingAccessEndsVoice(t *testing.T) {
	f := newAPI(t)
	admin, bob, cat, dog := f.user("admin"), f.user("bob"), f.user("cat"), f.user("dog")
	group := f.cloudGroup(admin, bob, cat, dog)
	ch, _ := f.newChannel(admin, group.ID, "Общий")
	join := "/v1/chats/" + group.ID + "/voice/" + ch.ID + "/join"
	for _, u := range []apiUser{bob, cat, dog} {
		f.call(u, "POST", join, nil, nil)
	}

	f.call(admin, "DELETE", "/v1/chats/"+group.ID+"/members/"+bob.id.String(), nil, nil)
	f.call(cat, "POST", "/v1/chats/"+group.ID+"/leave", nil, nil)
	f.call(dog, "POST", "/v1/logout", nil, nil)
	if got := f.inChannel(admin, group.ID, ch.ID); len(got) != 0 {
		t.Fatalf("still in the channel: %v", got)
	}

	// Deleting the channel empties it.
	f.call(admin, "POST", join, nil, nil)
	if status := f.call(admin, "DELETE", "/v1/chats/"+group.ID+"/voice/"+ch.ID, nil, nil); status != http.StatusNoContent {
		t.Fatalf("delete: %d", status)
	}
	if rooms := f.voice.Rooms(uuid.MustParse(group.ID)); len(rooms) != 0 {
		t.Fatalf("rooms after deleting the channel: %+v", rooms)
	}
	if status := f.call(admin, "POST", join, nil, nil); status != http.StatusNotFound {
		t.Fatalf("joined a deleted channel: %d", status)
	}
}
