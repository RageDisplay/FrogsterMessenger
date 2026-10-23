package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/vectrixsecurity/frogster/server/internal/store"
)

type sessionJSON struct {
	ID         string `json:"id"`
	DeviceID   string `json:"device_id"`
	UserAgent  string `json:"user_agent"`
	DeviceName string `json:"device_name"`
	CreatedAt  string `json:"created_at"`
	LastUsedAt string `json:"last_used_at"`
	Current    bool   `json:"current"`
}

// handleListSessions powers the "active sessions" settings screen, letting a
// user see where their account is logged in.
func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	sessions, err := s.store.ListSessions(r.Context(), claims.UserID)
	if err != nil {
		s.log.Error("list sessions", "err", err, "user_id", claims.UserID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	out := make([]sessionJSON, 0, len(sessions))
	for _, sess := range sessions {
		out = append(out, sessionJSON{
			ID:         sess.ID.String(),
			DeviceID:   sess.DeviceID.String(),
			UserAgent:  sess.UserAgent,
			DeviceName: sess.DeviceName,
			CreatedAt:  sess.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
			LastUsedAt: sess.LastUsedAt.UTC().Format("2006-01-02T15:04:05Z"),
			Current:    sess.DeviceID == claims.DeviceID,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"sessions": out}, s.log)
}

// handleRevokeSession logs out one session.
func (s *Server) handleRevokeSession(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	id, err := parseUUID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id is not a valid UUID", s.log)
		return
	}

	// Scoped to the caller's own user id, so one account cannot revoke
	// another's sessions.
	deviceID, err := s.store.RevokeSession(r.Context(), claims.UserID, id)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "session not found", s.log)
			return
		}
		s.log.Error("revoke session", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	if s.voice != nil {
		s.voice.RemoveDevice(deviceID)
	}

	// The revoked device's peers keep sessions with it; telling them lets
	// clients drop that state instead of encrypting to a device that can no
	// longer read anything. This is the device id, not the session id: peers
	// address ratchet sessions by device.
	if s.notifier != nil {
		go s.notifier.NotifyDeviceRevoked(
			context.WithoutCancel(r.Context()), claims.UserID, deviceID,
		)
	}

	s.log.Info("session revoked", "user_id", claims.UserID, "session_id", id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "revoked"}, s.log)
}
