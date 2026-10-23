package httpapi

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// avatarType names the image format from its first bytes, or "" for
// anything that is not a JPEG, PNG or WebP picture. The declared content
// type is not trusted: the bytes are served back to other people's apps.
func avatarType(image []byte) string {
	switch {
	case bytes.HasPrefix(image, []byte{0xFF, 0xD8, 0xFF}):
		return "image/jpeg"
	case bytes.HasPrefix(image, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case len(image) >= 12 && bytes.Equal(image[:4], []byte("RIFF")) && bytes.Equal(image[8:12], []byte("WEBP")):
		return "image/webp"
	}
	return ""
}

// readAvatar reads an uploaded picture, refusing anything too big or not
// an image.
func (s *Server) readAvatar(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	image, err := io.ReadAll(http.MaxBytesReader(w, r.Body, store.MaxAvatarBytes+1))
	if err != nil || len(image) > store.MaxAvatarBytes {
		writeErr(w, http.StatusRequestEntityTooLarge, "avatar must be at most 512 KB", s.log)
		return nil, false
	}
	if avatarType(image) == "" {
		writeErr(w, http.StatusUnsupportedMediaType, "avatar must be a JPEG, PNG or WebP image", s.log)
		return nil, false
	}
	return image, true
}

// handleSetMyAvatar replaces the caller's avatar.
func (s *Server) handleSetMyAvatar(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	image, ok := s.readAvatar(w, r)
	if !ok {
		return
	}
	version, err := s.store.SetUserAvatar(r.Context(), claims.UserID, image)
	if err != nil {
		s.log.Error("set avatar", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	s.profileChanged(r, claims.UserID)
	writeJSON(w, http.StatusOK, map[string]int{"avatar_version": version}, s.log)
}

// handleClearMyAvatar removes the caller's avatar.
func (s *Server) handleClearMyAvatar(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	if err := s.store.ClearUserAvatar(r.Context(), claims.UserID); err != nil {
		s.log.Error("clear avatar", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	s.profileChanged(r, claims.UserID)
	w.WriteHeader(http.StatusNoContent)
}

// handleUserAvatar serves someone's avatar. Like the rest of a profile it
// is visible to any signed-in user: it is what people see before they
// start talking.
func (s *Server) handleUserAvatar(w http.ResponseWriter, r *http.Request) {
	if _, ok := claimsOrUnauthorized(w, r, s); !ok {
		return
	}
	id, err := parseUUID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id is not a valid UUID", s.log)
		return
	}
	s.serveAvatar(w, r, id)
}

// handleSetChatAvatar replaces a cloud group's avatar. A secret group's
// look stays between its members, like its title.
func (s *Server) handleSetChatAvatar(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.adminGroup(w, r, claims.UserID)
	if !ok {
		return
	}
	if !chat.IsCloud() {
		writeErr(w, http.StatusBadRequest, "secret groups have no avatar on the server", s.log)
		return
	}
	image, ok := s.readAvatar(w, r)
	if !ok {
		return
	}
	version, err := s.store.SetChatAvatar(r.Context(), chat.ID, image)
	if err != nil {
		s.log.Error("set chat avatar", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	s.notifyMembers(r, chat.ID, chat.Epoch)
	writeJSON(w, http.StatusOK, map[string]int{"avatar_version": version}, s.log)
}

// handleClearChatAvatar removes a cloud group's avatar.
func (s *Server) handleClearChatAvatar(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.adminGroup(w, r, claims.UserID)
	if !ok {
		return
	}
	if err := s.store.ClearChatAvatar(r.Context(), chat.ID); err != nil {
		s.log.Error("clear chat avatar", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	s.notifyMembers(r, chat.ID, chat.Epoch)
	w.WriteHeader(http.StatusNoContent)
}

// handleChatAvatar serves a group's avatar to its members.
func (s *Server) handleChatAvatar(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.memberChat(w, r, claims.UserID)
	if !ok {
		return
	}
	s.serveAvatar(w, r, chat.ID)
}

func (s *Server) serveAvatar(w http.ResponseWriter, r *http.Request, owner uuid.UUID) {
	image, version, err := s.store.Avatar(r.Context(), owner)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no avatar", s.log)
		return
	}
	if err != nil {
		s.log.Error("load avatar", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	w.Header().Set("Content-Type", avatarType(image))
	w.Header().Set("X-Avatar-Version", strconv.Itoa(version))
	// Each version is immutable; the client asks for a new one by version.
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.Header().Set("Content-Length", strconv.Itoa(len(image)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(image)
}

// profileChanged tells everyone who shares a chat with the user to refetch
// those chats, which carry the member's avatar version.
func (s *Server) profileChanged(r *http.Request, userID uuid.UUID) {
	if s.notifier == nil {
		return
	}
	chats, err := s.store.ChatsForUser(r.Context(), userID)
	if err != nil {
		s.log.Warn("profile changed", "err", err)
		return
	}
	ctx := context.WithoutCancel(r.Context())
	for _, c := range chats {
		users := make([]uuid.UUID, 0, len(c.Members))
		for _, m := range c.Members {
			users = append(users, m.UserID)
		}
		go s.notifier.NotifyChatUpdated(ctx, c.ID, c.Epoch, users)
	}
}
