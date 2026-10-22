package delivery

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// sendCloud stores a cloud message or event and pushes it to every member
// device that is online, the sender's other devices included.
//
// Nothing is queued per device. A cloud chat's history lives on the server,
// so a device that was offline catches up by asking for what came after the
// last seq it saw -- and a new device the same way, from the beginning.
func (r *Router) sendCloud(ctx context.Context, chat *models.Chat, env *ws.Envelope) (*models.Message, error) {
	if len(env.Payloads) > 0 || env.CipherType != models.CipherTypeCloud {
		return nil, fmt.Errorf("%w: a cloud chat takes a plain payload", ErrRejected)
	}
	if len(env.Ciphertext) == 0 {
		return nil, fmt.Errorf("%w: empty payload", ErrRejected)
	}

	msg := &models.Message{
		ChatID:      chat.ID,
		SenderID:    env.Sender.UserID,
		SenderDevID: env.Sender.DeviceID,
		ContentHint: env.ContentHint,
		Kind:        env.Kind,
	}
	if env.ID != "" {
		id := env.ID
		msg.ClientID = &id
	}
	if env.TargetID != "" {
		if len(env.TargetID) > maxClientIDLength {
			return nil, fmt.Errorf("%w: target id too long", ErrRejected)
		}
		target := env.TargetID
		msg.TargetID = &target
	}

	err := r.store.PersistCloudMessage(ctx, msg, env.Ciphertext, env.Emoji)
	switch {
	case errors.Is(err, store.ErrDuplicateMessage):
		return msg, nil
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrForbidden):
		return nil, err
	case err != nil:
		return nil, fmt.Errorf("persist cloud message: %w", err)
	}

	r.log.Info("cloud message accepted",
		"message_id", msg.ID, "chat_id", msg.ChatID, "seq", msg.Seq,
		"kind", msg.Kind, "payload_bytes", len(env.Ciphertext))

	devices, err := r.store.RecipientDevices(ctx, chat.ID, env.Sender.DeviceID)
	if err != nil {
		// Stored; devices pick it up when they next sync.
		r.log.Warn("resolve cloud recipients", "err", err, "chat_id", chat.ID)
		return msg, nil
	}
	for _, d := range devices {
		key := ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}
		r.deliverToDevice(ctx, key, &ws.Envelope{
			Version:     1,
			Type:        ws.TypeMessage,
			ID:          msg.WireID(),
			ChatID:      msg.ChatID,
			Sender:      &ws.Address{UserID: msg.SenderID, DeviceID: msg.SenderDevID},
			Recipient:   &ws.Address{UserID: d.UserID, DeviceID: d.ID},
			CipherType:  models.CipherTypeCloud,
			Ciphertext:  env.Ciphertext,
			ContentHint: msg.ContentHint,
			Timestamp:   msg.CreatedAt.UnixMilli(),
			Seq:         msg.Seq,
			Kind:        msg.Kind,
			TargetID:    env.TargetID,
			Emoji:       env.Emoji,
		})
	}
	return msg, nil
}

// DistributeSenderKeys queues a member's sender key for the other member
// devices of a secret group and pushes it to those online.
//
// Each payload is sealed in the pairwise session with its recipient, so the
// server learns nothing about the key. Payloads for devices that are not in
// the group are dropped: a client must not be able to use a group as a relay
// to arbitrary devices.
func (r *Router) DistributeSenderKeys(ctx context.Context, env *ws.Envelope) (int, error) {
	if env.Sender == nil {
		return 0, fmt.Errorf("envelope has no sender")
	}
	chat, err := r.store.ChatByID(ctx, env.ChatID)
	if err != nil {
		return 0, fmt.Errorf("load chat: %w", err)
	}
	if chat.IsCloud() || !chat.IsGroup() {
		return 0, fmt.Errorf("%w: sender keys belong to secret groups", ErrRejected)
	}
	member, err := r.store.IsMember(ctx, chat.ID, env.Sender.UserID)
	if err != nil {
		return 0, fmt.Errorf("check membership: %w", err)
	}
	if !member {
		return 0, fmt.Errorf("%w: sender is not a member", ErrRejected)
	}

	devices, err := r.store.RecipientDevices(ctx, chat.ID, env.Sender.DeviceID)
	if err != nil {
		return 0, fmt.Errorf("resolve recipients: %w", err)
	}
	owner := make(map[uuid.UUID]uuid.UUID, len(devices))
	for _, d := range devices {
		owner[d.ID] = d.UserID
	}

	rows := make([]models.GroupSenderKeyDistribution, 0, len(env.Payloads))
	for _, p := range env.Payloads {
		user, ok := owner[p.DeviceID]
		if !ok || len(p.Ciphertext) == 0 {
			continue
		}
		rows = append(rows, models.GroupSenderKeyDistribution{
			SenderUserID: env.Sender.UserID,
			SenderDevID:  env.Sender.DeviceID,
			RecipUserID:  user,
			RecipDevID:   p.DeviceID,
			Ciphertext:   p.Ciphertext,
		})
	}
	if err := r.store.StoreSenderKeyDistributions(ctx, chat.ID, env.Epoch, rows); err != nil {
		return 0, err
	}

	for _, row := range rows {
		r.deliverToDevice(ctx,
			ws.ClientKey{UserID: row.RecipUserID, DeviceID: row.RecipDevID},
			senderKeyEnvelope(row))
	}
	r.log.Info("sender keys distributed",
		"chat_id", chat.ID, "epoch", env.Epoch, "sender_device_id", env.Sender.DeviceID,
		"recipients", len(rows))
	return len(rows), nil
}

// senderKeyEnvelope builds the frame that carries one queued distribution.
func senderKeyEnvelope(k models.GroupSenderKeyDistribution) *ws.Envelope {
	return &ws.Envelope{
		Version:    1,
		Type:       ws.TypeSKDM,
		ID:         ws.SenderKeyAckPrefix + strconv.FormatUint(k.ID, 10),
		ChatID:     k.ChatID,
		Sender:     &ws.Address{UserID: k.SenderUserID, DeviceID: k.SenderDevID},
		Recipient:  &ws.Address{UserID: k.RecipUserID, DeviceID: k.RecipDevID},
		Ciphertext: k.Ciphertext,
		Epoch:      k.Epoch,
		Timestamp:  k.CreatedAt.UnixMilli(),
	}
}

// MarkRead records how far a member has read and tells the chat.
//
// The reader's other devices clear their unread badge; the other members see
// their messages turn read. Only online devices are told: the position is
// stored, and the chat list reports it to everyone else when they next sync.
func (r *Router) MarkRead(ctx context.Context, reader ws.ClientKey, chatID uuid.UUID, seq int64) error {
	pos, err := r.store.MarkRead(ctx, chatID, reader.UserID, seq)
	if err != nil {
		return err
	}
	if pos == 0 {
		return nil
	}
	devices, err := r.store.RecipientDevices(ctx, chatID, reader.DeviceID)
	if err != nil {
		return fmt.Errorf("resolve read recipients: %w", err)
	}
	now := time.Now().UnixMilli()
	for _, d := range devices {
		r.deliverToDevice(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}, &ws.Envelope{
			Version:   1,
			Type:      ws.TypeRead,
			ChatID:    chatID,
			Sender:    &ws.Address{UserID: reader.UserID, DeviceID: reader.DeviceID},
			Seq:       pos,
			Timestamp: now,
		})
	}
	return nil
}

// NotifyChatUpdated tells every device of the given users that a chat
// changed, so they refetch it.
//
// users is passed in rather than read from the membership, because someone
// who was just removed must hear about it too.
func (r *Router) NotifyChatUpdated(ctx context.Context, chatID uuid.UUID, epoch uint64, users []uuid.UUID) {
	devices, err := r.store.UserDevicesFor(ctx, users)
	if err != nil {
		r.log.Warn("notify chat updated", "err", err, "chat_id", chatID)
		return
	}
	now := time.Now().UnixMilli()
	for _, d := range devices {
		r.deliverToDevice(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}, &ws.Envelope{
			Version:   1,
			Type:      ws.TypeChatUpdated,
			ChatID:    chatID,
			Epoch:     epoch,
			Timestamp: now,
		})
	}
}
