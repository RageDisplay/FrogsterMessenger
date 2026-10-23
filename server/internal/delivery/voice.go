package delivery

import (
	"context"
	"encoding/json"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/voice"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// NotifyVoice tells every device of a group's members who is in its voice
// channels now. Not queued for devices that are offline: they ask when they
// come back, and who was talking an hour ago is of no use to anyone.
func (r *Router) NotifyVoice(ctx context.Context, chatID uuid.UUID, rooms []voice.RoomState) {
	if rooms == nil {
		rooms = []voice.RoomState{}
	}
	raw, err := json.Marshal(rooms)
	if err != nil {
		r.log.Error("marshal voice state", "err", err)
		return
	}
	r.notifyVoice(ctx, chatID, &ws.Envelope{Version: 1, Type: ws.TypeVoice, ChatID: chatID, Voice: raw})
}

// NotifyVoiceChannels tells a group's members its channels changed.
func (r *Router) NotifyVoiceChannels(ctx context.Context, chatID uuid.UUID) {
	r.notifyVoice(ctx, chatID, &ws.Envelope{Version: 1, Type: ws.TypeVoice, ChatID: chatID, Kind: "channels"})
}

func (r *Router) notifyVoice(ctx context.Context, chatID uuid.UUID, env *ws.Envelope) {
	devices, err := r.store.RecipientDevices(ctx, chatID, uuid.Nil)
	if err != nil {
		r.log.Warn("notify voice", "err", err, "chat_id", chatID)
		return
	}
	env.Timestamp = time.Now().UnixMilli()
	for _, d := range devices {
		r.deliverToDevice(ctx, ws.ClientKey{UserID: d.UserID, DeviceID: d.ID}, env)
	}
}
