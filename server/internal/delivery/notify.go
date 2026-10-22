package delivery

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// NotifyDeviceAdded tells a user's other devices that a new one joined, and
// tells their contacts that the user's device set changed.
//
// Both signals matter for the end-to-end guarantee. The user's own devices
// need to establish sessions with the newcomer; the contacts need to notice
// that a new key appeared, because a malicious server could otherwise
// register a device of its own and quietly receive copies of everything.
func (r *Router) NotifyDeviceAdded(
	ctx context.Context,
	userID, newDeviceID uuid.UUID,
) {
	now := time.Now().UnixMilli()

	// 1. The user's own devices.
	devices, err := r.store.ActiveDevices(ctx, userID)
	if err != nil {
		r.log.Warn("notify device added: list devices", "err", err, "user_id", userID)
		return
	}
	for _, d := range devices {
		if d.ID == newDeviceID {
			continue
		}
		r.deliverToDevice(ctx, ws.ClientKey{UserID: userID, DeviceID: d.ID}, &ws.Envelope{
			Version:   1,
			Type:      ws.TypeDeviceAdded,
			Sender:    &ws.Address{UserID: userID, DeviceID: newDeviceID},
			Timestamp: now,
		})
	}

	// 2. Everyone who shares a chat with this user.
	//
	// Notifying contacts is what lets a peer surface a safety-number change
	// promptly rather than only when they next send a message.
	contacts, err := r.store.ContactDevices(ctx, userID)
	if err != nil {
		r.log.Warn("notify device added: list contacts", "err", err, "user_id", userID)
		return
	}
	for _, c := range contacts {
		r.deliverToDevice(ctx, ws.ClientKey{UserID: c.UserID, DeviceID: c.ID}, &ws.Envelope{
			Version:   1,
			Type:      ws.TypeKeyChange,
			Sender:    &ws.Address{UserID: userID, DeviceID: newDeviceID},
			Timestamp: now,
		})
	}

	r.log.Info("device added notification sent",
		"user_id", userID,
		"new_device_id", newDeviceID,
		"own_devices", len(devices)-1,
		"contact_devices", len(contacts),
	)
}

// NotifyDeviceRevoked tells a user's remaining devices that one was signed
// out, so they can drop its sessions.
func (r *Router) NotifyDeviceRevoked(
	ctx context.Context,
	userID, revokedDeviceID uuid.UUID,
) {
	devices, err := r.store.ActiveDevices(ctx, userID)
	if err != nil {
		r.log.Warn("notify device revoked", "err", err, "user_id", userID)
		return
	}

	now := time.Now().UnixMilli()
	for _, d := range devices {
		r.deliverToDevice(ctx, ws.ClientKey{UserID: userID, DeviceID: d.ID}, &ws.Envelope{
			Version:   1,
			Type:      ws.TypeKeyChange,
			Sender:    &ws.Address{UserID: userID, DeviceID: revokedDeviceID},
			Timestamp: now,
		})
	}

	r.log.Info("device revoked notification sent",
		"user_id", userID, "revoked_device_id", revokedDeviceID)
}
