package store_test

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// seedChatWith creates a direct chat between two fresh users and returns the
// chat plus both user/device pairs.
func seedChatWith(t *testing.T, st *store.Store) (
	chatID uuid.UUID,
	senderUser, senderDevice uuid.UUID,
	recipientUser, recipientDevice uuid.UUID,
) {
	t.Helper()
	ctx := context.Background()

	senderUser, senderDevice = seedUserDevice(t, st)
	recipientUser, recipientDevice = seedUserDevice(t, st)

	chat := &models.Chat{Type: models.ChatTypeDirect, CreatorID: senderUser}
	if err := st.CreateChat(ctx, chat, []uuid.UUID{senderUser, recipientUser}); err != nil {
		t.Fatalf("create chat: %v", err)
	}
	return chat.ID, senderUser, senderDevice, recipientUser, recipientDevice
}

// TestDeliveredMessageLeavesTheOfflineQueue is the guarantee that a reconnect
// does not replay messages the recipient already received.
//
// A Double Ratchet message can only be decrypted once: the message key is
// destroyed on first use. So a delivery row left pending after a live send is
// not a harmless duplicate -- on the next connect it is flushed again, fails
// its MAC check, and the conversation looks broken from that point on.
func TestDeliveredMessageLeavesTheOfflineQueue(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	chatID, senderUser, senderDevice, recipientUser, recipientDevice := seedChatWith(t, st)

	msg := &models.Message{
		ChatID:      chatID,
		SenderID:    senderUser,
		SenderDevID: senderDevice,
		Ciphertext:  []byte{},
		CipherType:  2,
	}
	deliveries := []models.MessageDelivery{{
		UserID:     recipientUser,
		DeviceID:   recipientDevice,
		Ciphertext: []byte("per-device ciphertext"),
		State:      models.DeliveryPending,
	}}

	if err := st.PersistMessage(ctx, msg, deliveries); err != nil {
		t.Fatalf("persist message: %v", err)
	}

	// PersistMessage has to hand back the generated row ids, or the router has
	// nothing to retire after a successful live send.
	if deliveries[0].ID == 0 {
		t.Fatal("delivery id was not populated; the router cannot mark it delivered")
	}

	pending, err := st.PendingDeliveries(ctx, recipientUser, recipientDevice, 50)
	if err != nil {
		t.Fatalf("pending before: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 queued delivery, got %d", len(pending))
	}

	// The frame reached a live socket.
	if err := st.MarkDelivered(ctx, []uint64{deliveries[0].ID}); err != nil {
		t.Fatalf("mark delivered: %v", err)
	}

	after, err := st.PendingDeliveries(ctx, recipientUser, recipientDevice, 50)
	if err != nil {
		t.Fatalf("pending after: %v", err)
	}
	if len(after) != 0 {
		t.Errorf("message still queued after a live delivery: it will be "+
			"replayed on reconnect and fail to decrypt (%d pending)", len(after))
	}
}

// TestUndeliveredMessageStaysQueued is the other half: a recipient who was
// genuinely offline must still get the message on reconnect.
func TestUndeliveredMessageStaysQueued(t *testing.T) {
	t.Parallel()

	st := newTestStore(t)
	ctx := context.Background()

	chatID, senderUser, senderDevice, recipientUser, recipientDevice := seedChatWith(t, st)

	msg := &models.Message{
		ChatID:      chatID,
		SenderID:    senderUser,
		SenderDevID: senderDevice,
		Ciphertext:  []byte{},
		CipherType:  2,
	}
	deliveries := []models.MessageDelivery{{
		UserID:     recipientUser,
		DeviceID:   recipientDevice,
		Ciphertext: []byte("per-device ciphertext"),
		State:      models.DeliveryPending,
	}}

	if err := st.PersistMessage(ctx, msg, deliveries); err != nil {
		t.Fatalf("persist message: %v", err)
	}

	// Nothing is marked: the socket was not there to take it.
	pending, err := st.PendingDeliveries(ctx, recipientUser, recipientDevice, 50)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(pending) != 1 {
		t.Errorf("an offline recipient lost the message (%d pending)", len(pending))
	}
}
