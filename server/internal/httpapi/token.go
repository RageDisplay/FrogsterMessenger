package httpapi

import (
	"errors"
	"net/http"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

const maxTokenBody = 4 << 10

// refreshGrace is how long a rotated-away refresh token is still honoured,
// for a client whose refresh response never arrived. Long enough for a retry
// over a bad mobile link, short enough that a copied token is useless.
const refreshGrace = 2 * time.Minute

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// handleRefresh exchanges a refresh token for a new access token and a new
// refresh token.
//
// Refresh tokens rotate on every use. A token presented again after rotation
// (outside the retry grace) can only come from a copy, so the session is
// revoked and the device has to sign in again.
func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := decodeJSON(w, r, &req, maxTokenBody); err != nil || req.RefreshToken == "" {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}

	next, err := auth.NewOpaqueToken()
	if err != nil {
		s.log.Error("generate refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	sess, err := s.store.RotateRefreshToken(r.Context(),
		auth.HashToken(req.RefreshToken), auth.HashToken(next), refreshGrace)
	switch {
	case errors.Is(err, store.ErrRefreshReuse):
		s.log.Warn("refresh token reuse, session revoked")
		writeErr(w, http.StatusUnauthorized, "invalid refresh token", s.log)
		return
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusUnauthorized, "invalid refresh token", s.log)
		return
	case err != nil:
		s.log.Error("rotate refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	user, err := s.store.UserByID(r.Context(), sess.UserID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "invalid refresh token", s.log)
		return
	}
	device, err := s.store.DeviceByID(r.Context(), sess.DeviceID)
	if err != nil || !device.IsActive() {
		writeErr(w, http.StatusUnauthorized, "invalid refresh token", s.log)
		return
	}

	access, err := s.tokens.IssueAccess(user.ID, device.ID, user.TokenVersion)
	if err != nil {
		s.log.Error("issue access token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	writeJSON(w, http.StatusOK, tokenResponse{
		AccessToken:  access,
		RefreshToken: next,
		ExpiresAt:    time.Now().Add(s.tokens.AccessTTL()),
		UserID:       user.ID.String(),
		DeviceID:     device.ID.String(),
	}, s.log)
}

// handleLogout ends this device's sessions. The device stays registered, so
// its keys remain valid and signing back in resumes it; removing a device for
// good is DELETE /v1/sessions/{id}.
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	if err := s.store.RevokeDeviceSessions(r.Context(), claims.UserID, claims.DeviceID); err != nil {
		s.log.Error("logout", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "logged_out"}, s.log)
}

type changePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// handleChangePassword replaces the password, ends every session of the
// account and returns fresh tokens for the calling device.
func (s *Server) handleChangePassword(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	var req changePasswordRequest
	if err := decodeJSON(w, r, &req, maxTokenBody); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	if len(req.NewPassword) < minPasswordLen || len(req.NewPassword) > maxPasswordLen {
		writeErr(w, http.StatusBadRequest, "password must be 10-72 bytes", s.log)
		return
	}

	user, err := s.store.UserByID(r.Context(), claims.UserID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthorized", s.log)
		return
	}
	// The current password is required even with a valid token: a token
	// lifted from a device must not be enough to lock the owner out.
	if err := auth.VerifyPassword(user.PasswordHash, req.CurrentPassword); err != nil {
		writeErr(w, http.StatusForbidden, "current password is incorrect", s.log)
		return
	}

	hash, err := auth.HashPassword(req.NewPassword, s.cfg.BcryptCost)
	if err != nil {
		s.log.Error("hash password", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	version, err := s.store.ChangePassword(r.Context(), user.ID, hash)
	if err != nil {
		s.log.Error("change password", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	user.TokenVersion = version

	device, err := s.store.DeviceByID(r.Context(), claims.DeviceID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthorized", s.log)
		return
	}

	s.log.Info("password changed", "user_id", user.ID)
	s.issueTokens(w, r, user, device)
}
