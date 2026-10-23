package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// Profile limits, in characters, mirroring the columns.
const (
	maxDisplayName = 64
	maxBio         = 140
)

type userJSON struct {
	UserID      string `json:"user_id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name,omitempty"`
	Bio         string `json:"bio,omitempty"`
	// AvatarVersion is 0 or negative without an avatar.
	AvatarVersion int `json:"avatar_version,omitempty"`
}

// meJSON is the caller's own profile, with their privacy settings.
type meJSON struct {
	userJSON
	LastSeenVisible bool `json:"last_seen_visible"`
}

func toMeJSON(u *models.User) meJSON {
	return meJSON{userJSON: toUserJSON(u), LastSeenVisible: u.LastSeenVisible}
}

func toUserJSON(u *models.User) userJSON {
	return userJSON{
		UserID:        u.ID.String(),
		Username:      u.Username,
		DisplayName:   u.DisplayName,
		Bio:           u.Bio,
		AvatarVersion: u.AvatarVersion,
	}
}

// handleLookupUser resolves a user id to their public profile.
//
// An inbound message names its sender by id, but a conversation is labelled
// with a name -- and sending a reply needs the username to fetch key bundles.
func (s *Server) handleLookupUser(w http.ResponseWriter, r *http.Request) {
	if _, ok := claimsOrUnauthorized(w, r, s); !ok {
		return
	}
	id, err := parseUUID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id is not a valid UUID", s.log)
		return
	}
	user, err := s.store.UserByID(r.Context(), id)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "user not found", s.log)
			return
		}
		s.log.Error("lookup user by id", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, http.StatusOK, toUserJSON(user), s.log)
}

// handleSearchUsers finds people by the start of their username.
//
// Prefix-only and capped, with a budget of its own: enough to start a chat
// with someone whose name you know, not enough to enumerate the user base.
func (s *Server) handleSearchUsers(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	q := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(r.URL.Query().Get("q")), "@"))
	if n := utf8.RuneCountInString(q); n < 2 || n > 32 {
		writeErr(w, http.StatusBadRequest, "query must be 2-32 characters", s.log)
		return
	}
	users, err := s.store.SearchUsers(r.Context(), q, claims.UserID, 20)
	if err != nil {
		s.log.Error("search users", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	out := make([]userJSON, 0, len(users))
	for i := range users {
		out = append(out, toUserJSON(&users[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": out}, s.log)
}

// handleGetMe returns the caller's own profile.
func (s *Server) handleGetMe(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	user, err := s.store.UserByID(r.Context(), claims.UserID)
	if err != nil {
		s.log.Error("load own profile", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, http.StatusOK, toMeJSON(user), s.log)
}

type updateProfileRequest struct {
	DisplayName     *string `json:"display_name"`
	Bio             *string `json:"bio"`
	LastSeenVisible *bool   `json:"last_seen_visible"`
}

// handleUpdateMe changes the caller's display name and bio. Absent fields
// keep their value.
func (s *Server) handleUpdateMe(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req updateProfileRequest
	if err := decodeJSON(w, r, &req, 4<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	user, err := s.store.UserByID(r.Context(), claims.UserID)
	if err != nil {
		s.log.Error("load own profile", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	name, bio := user.DisplayName, user.Bio
	if req.DisplayName != nil {
		name = strings.TrimSpace(*req.DisplayName)
	}
	if req.Bio != nil {
		bio = strings.TrimSpace(*req.Bio)
	}
	if utf8.RuneCountInString(name) > maxDisplayName || utf8.RuneCountInString(bio) > maxBio {
		writeErr(w, http.StatusBadRequest, "display name is at most 64 characters, bio at most 140", s.log)
		return
	}
	if err := s.store.UpdateProfile(r.Context(), claims.UserID, name, bio); err != nil {
		s.log.Error("update profile", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	user.DisplayName, user.Bio = name, bio
	if req.LastSeenVisible != nil && *req.LastSeenVisible != user.LastSeenVisible {
		if err := s.store.SetLastSeenVisible(r.Context(), claims.UserID, *req.LastSeenVisible); err != nil {
			s.log.Error("set last seen visibility", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			return
		}
		user.LastSeenVisible = *req.LastSeenVisible
		if s.presence != nil {
			s.presence.VisibilityChanged(context.WithoutCancel(r.Context()), claims.UserID)
		}
	}
	writeJSON(w, http.StatusOK, toMeJSON(user), s.log)
}

type deleteAccountRequest struct {
	Password string `json:"password"`
}

// handleDeleteMe closes the caller's account.
//
// The password is required even with a valid token, as for a password
// change: a token lifted from a device must not be enough to destroy the
// account. Every group the user was in moves to a new epoch and is told.
func (s *Server) handleDeleteMe(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req deleteAccountRequest
	if err := decodeJSON(w, r, &req, 4<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	user, err := s.store.UserByID(r.Context(), claims.UserID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthorized", s.log)
		return
	}
	if err := auth.VerifyPassword(user.PasswordHash, req.Password); err != nil {
		writeErr(w, http.StatusForbidden, "password is incorrect", s.log)
		return
	}

	deletion, err := s.store.DeleteAccount(r.Context(), user.ID)
	if err != nil {
		s.log.Error("delete account", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if s.voice != nil {
		s.voice.RemoveUserDevices(user.ID, uuid.Nil)
	}
	for chatID, epoch := range deletion.Groups {
		s.notifyMembers(r, chatID, epoch)
	}
	s.log.Info("account deleted", "user_id", user.ID, "groups_left", len(deletion.Groups))
	w.WriteHeader(http.StatusNoContent)
}
