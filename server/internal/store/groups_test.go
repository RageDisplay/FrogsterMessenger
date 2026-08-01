package store_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// seedUser creates a throwaway account with one device.
func seedUser(t *testing.T, st *store.Store, name string) (uuid.UUID, uuid.UUID) {
	t.Helper()
	ctx := context.Background()

	user := &models.User{
		Username:     name + "_" + uuid.NewString()[:8],
		PasswordHash: "$2a$12$abcdefghijklmnopqrstuv",
	}
	device := &models.Device{
		RegistrationID: 1,
		IdentityKeyPub: make([]byte, 33),
	}
	spk := &models.SignedPreKey{
		KeyID:     1,
		PublicKey: make([]byte, 33),
		Signature: make([]byte, 64),
	}
	if err := st.CreateUserWithDevice(ctx, user, device, spk, nil); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return user.ID, device.ID
}

func seedGroup(t *testing.T, st *store.Store, creator uuid.UUID, members ...uuid.UUID) *models.Chat {
	t.Helper()

	chat := &models.Chat{Type: models.ChatTypeGroup, CreatorID: creator}
	all := append([]uuid.UUID{creator}, members...)
	if err := st.CreateChat(context.Background(), chat, all); err != nil {
		t.Fatalf("seed group: %v", err)
	}
	return chat
}

// TestRemoveMemberBumpsEpoch is the guard for the most dangerous logic error
// available in group messaging.
//
// A departing member keeps every sender key they ever received. If the epoch
// did not advance on removal, they could decrypt group traffic forever, and
// nothing about message delivery would look wrong.
func TestRemoveMemberBumpsEpoch(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, _ := seedUser(t, st, "alice")
	bob, _ := seedUser(t, st, "bob")
	mallory, _ := seedUser(t, st, "mallory")

	chat := seedGroup(t, st, alice, bob, mallory)
	if chat.Epoch != 0 {
		t.Fatalf("new chat epoch = %d, want 0", chat.Epoch)
	}

	newEpoch, err := st.RemoveMember(ctx, chat.ID, mallory)
	if err != nil {
		t.Fatalf("remove member: %v", err)
	}
	if newEpoch != 1 {
		t.Errorf("epoch after removal = %d, want 1", newEpoch)
	}

	stored, err := st.ChatEpoch(ctx, chat.ID)
	if err != nil {
		t.Fatalf("read epoch: %v", err)
	}
	if stored != 1 {
		t.Errorf("persisted epoch = %d, want 1", stored)
	}

	// The removed member must no longer be in the fan-out set.
	members, err := st.ActiveMembers(ctx, chat.ID)
	if err != nil {
		t.Fatalf("active members: %v", err)
	}
	for _, m := range members {
		if m.UserID == mallory {
			t.Error("removed member is still listed as active")
		}
	}
	if len(members) != 2 {
		t.Errorf("got %d active members, want 2", len(members))
	}
}

// TestRemoveMemberPurgesOldSenderKeys verifies that queued sender keys from
// the epoch a removed member had access to are destroyed, not delivered.
func TestRemoveMemberPurgesOldSenderKeys(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, aliceDev := seedUser(t, st, "alice")
	bob, bobDev := seedUser(t, st, "bob")
	mallory, _ := seedUser(t, st, "mallory")
	chat := seedGroup(t, st, alice, bob, mallory)

	// Alice publishes a sender key for epoch 0 addressed to Bob.
	err := st.StoreSenderKeyDistributions(ctx, chat.ID, 0,
		[]models.GroupSenderKeyDistribution{{
			SenderUserID: alice,
			SenderDevID:  aliceDev,
			RecipUserID:  bob,
			RecipDevID:   bobDev,
			Ciphertext:   []byte("sealed epoch-0 sender key"),
		}})
	if err != nil {
		t.Fatalf("store distribution: %v", err)
	}

	pending, err := st.PendingSenderKeys(ctx, bob, bobDev)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("got %d pending sender keys before removal, want 1", len(pending))
	}

	if _, err := st.RemoveMember(ctx, chat.ID, mallory); err != nil {
		t.Fatalf("remove member: %v", err)
	}

	// The epoch-0 key is now worthless: Mallory holds a copy.
	pending, err = st.PendingSenderKeys(ctx, bob, bobDev)
	if err != nil {
		t.Fatalf("pending after removal: %v", err)
	}
	if len(pending) != 0 {
		t.Errorf("got %d pending sender keys after removal, want 0; "+
			"keys from an epoch the removed member saw must not be delivered",
			len(pending))
	}

	// Also assert the rows are gone from the table, not merely filtered out of
	// the delivery query. Two independent mechanisms protect this invariant --
	// the epoch join and the purge -- and a test that only checks the query
	// would still pass if the purge were removed, leaving one layer of
	// defence where the design calls for two.
	var remaining int64
	if err := st.DB().WithContext(ctx).
		Model(&models.GroupSenderKeyDistribution{}).
		Where("chat_id = ? AND epoch < ?", chat.ID, 1).
		Count(&remaining).Error; err != nil {
		t.Fatalf("count stale rows: %v", err)
	}
	if remaining != 0 {
		t.Errorf("%d stale sender-key rows remain in the table; they must be "+
			"purged, not just filtered from delivery", remaining)
	}
}

// TestStaleEpochDistributionRejected stops a client re-publishing a sender key
// under an epoch the chat has already left behind.
func TestStaleEpochDistributionRejected(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, aliceDev := seedUser(t, st, "alice")
	bob, bobDev := seedUser(t, st, "bob")
	mallory, _ := seedUser(t, st, "mallory")
	chat := seedGroup(t, st, alice, bob, mallory)

	if _, err := st.RemoveMember(ctx, chat.ID, mallory); err != nil {
		t.Fatalf("remove member: %v", err)
	}

	err := st.StoreSenderKeyDistributions(ctx, chat.ID, 0,
		[]models.GroupSenderKeyDistribution{{
			SenderUserID: alice,
			SenderDevID:  aliceDev,
			RecipUserID:  bob,
			RecipDevID:   bobDev,
			Ciphertext:   []byte("stale"),
		}})

	if !errors.Is(err, store.ErrStaleEpoch) {
		t.Fatalf("got %v, want ErrStaleEpoch", err)
	}
}

// TestAddMemberBumpsEpoch confirms joins also rotate, so a new member cannot
// read history from before they joined.
func TestAddMemberBumpsEpoch(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, _ := seedUser(t, st, "alice")
	bob, _ := seedUser(t, st, "bob")
	carol, _ := seedUser(t, st, "carol")
	chat := seedGroup(t, st, alice, bob)

	epoch, err := st.AddMember(ctx, chat.ID, carol)
	if err != nil {
		t.Fatalf("add member: %v", err)
	}
	if epoch != 1 {
		t.Errorf("epoch after join = %d, want 1", epoch)
	}

	members, err := st.ActiveMembers(ctx, chat.ID)
	if err != nil {
		t.Fatalf("active members: %v", err)
	}
	if len(members) != 3 {
		t.Errorf("got %d members, want 3", len(members))
	}
}

// TestCurrentEpochDistributionDelivered confirms the purge does not discard
// keys for the epoch actually in force.
func TestCurrentEpochDistributionDelivered(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, aliceDev := seedUser(t, st, "alice")
	bob, bobDev := seedUser(t, st, "bob")
	mallory, _ := seedUser(t, st, "mallory")
	chat := seedGroup(t, st, alice, bob, mallory)

	epoch, err := st.RemoveMember(ctx, chat.ID, mallory)
	if err != nil {
		t.Fatalf("remove member: %v", err)
	}

	// Alice rotates and republishes under the new epoch.
	err = st.StoreSenderKeyDistributions(ctx, chat.ID, epoch,
		[]models.GroupSenderKeyDistribution{{
			SenderUserID: alice,
			SenderDevID:  aliceDev,
			RecipUserID:  bob,
			RecipDevID:   bobDev,
			Ciphertext:   []byte("fresh epoch-1 sender key"),
		}})
	if err != nil {
		t.Fatalf("store rotated distribution: %v", err)
	}

	pending, err := st.PendingSenderKeys(ctx, bob, bobDev)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("got %d pending sender keys, want 1", len(pending))
	}

	if err := st.MarkSenderKeysConsumed(ctx, []uint64{pending[0].ID}); err != nil {
		t.Fatalf("mark consumed: %v", err)
	}
	again, err := st.PendingSenderKeys(ctx, bob, bobDev)
	if err != nil {
		t.Fatalf("pending after consume: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("got %d pending after consumption, want 0", len(again))
	}
}

// TestContactDevicesFindsSharedChatPeers verifies the query behind key-change
// notifications.
//
// When a user registers a new device, their contacts must be told: a new key
// appearing for someone you talk to is exactly what a server-side key
// substitution looks like, and a client that never hears about it cannot warn
// the user.
func TestContactDevicesFindsSharedChatPeers(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, aliceDev := seedUser(t, st, "alice")
	bob, bobDev := seedUser(t, st, "bob")
	stranger, strangerDev := seedUser(t, st, "stranger")

	seedGroup(t, st, alice, bob)

	contacts, err := st.ContactDevices(ctx, alice)
	if err != nil {
		t.Fatalf("contact devices: %v", err)
	}

	found := map[uuid.UUID]bool{}
	for _, d := range contacts {
		found[d.ID] = true
	}

	if !found[bobDev] {
		t.Error("bob shares a chat with alice but was not notified")
	}
	if found[aliceDev] {
		t.Error("alice's own device must not appear in her contact list")
	}
	if found[strangerDev] {
		t.Errorf("stranger %s shares no chat with alice but would be "+
			"notified, leaking who alice's devices belong to", stranger)
	}
}

// TestContactDevicesExcludesDepartedMembers confirms that leaving a group ends
// the notification relationship.
func TestContactDevicesExcludesDepartedMembers(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	alice, _ := seedUser(t, st, "alice")
	bob, bobDev := seedUser(t, st, "bob")
	chat := seedGroup(t, st, alice, bob)

	if _, err := st.RemoveMember(ctx, chat.ID, bob); err != nil {
		t.Fatalf("remove member: %v", err)
	}

	contacts, err := st.ContactDevices(ctx, alice)
	if err != nil {
		t.Fatalf("contact devices: %v", err)
	}
	for _, d := range contacts {
		if d.ID == bobDev {
			t.Error("a departed member still receives alice's key-change notices")
		}
	}
}
