package httpapi

import (
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// handleLookupUser resolves a user id to a username.
//
// An inbound message names its sender by id, but a conversation is labelled
// with a username -- and sending a reply needs the username to fetch key
// bundles. A recipient who has never fetched that peer's keys has no way to
// connect the two without this.
//
// Authenticated, and returns nothing beyond the public username, so it does
// not expose more than the key endpoint already does.
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

	writeJSON(w, http.StatusOK, map[string]string{
		"user_id":  user.ID.String(),
		"username": user.Username,
	}, s.log)
}

type createChatRequest struct {
	Type string `json:"type"`
	// Peer names the other participant for a direct chat.
	Peer string `json:"peer,omitempty"`
	// Members lists usernames for a group chat.
	Members []string `json:"members,omitempty"`
	// Title is client-encrypted for groups; the server never sees a plaintext
	// group name.
	Title []byte `json:"title,omitempty"`
}

type chatResponse struct {
	ID      string   `json:"id"`
	Type    string   `json:"type"`
	Epoch   uint64   `json:"epoch"`
	Members []string `json:"members"`
}

// handleCreateChat creates a direct or group chat.
//
// Direct chats are deduplicated: requesting one that already exists returns
// the existing chat rather than a second parallel conversation.
func (s *Server) handleCreateChat(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	var req createChatRequest
	if err := decodeJSON(w, r, &req, 32<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}

	switch req.Type {
	case models.ChatTypeDirect:
		s.createDirectChat(w, r, claims.UserID, &req)
	case models.ChatTypeGroup:
		s.createGroupChat(w, r, claims.UserID, &req)
	default:
		writeErr(w, http.StatusBadRequest, `type must be "direct" or "group"`, s.log)
	}
}

func (s *Server) createDirectChat(w http.ResponseWriter, r *http.Request, self uuid.UUID, req *createChatRequest) {
	peer, err := s.store.UserByUsername(r.Context(), req.Peer)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "peer not found", s.log)
			return
		}
		s.log.Error("lookup peer", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if peer.ID == self {
		writeErr(w, http.StatusBadRequest, "cannot create a direct chat with yourself", s.log)
		return
	}

	// Return the existing conversation rather than forking a duplicate.
	if existing, err := s.store.FindDirectChat(r.Context(), self, peer.ID); err == nil {
		writeJSON(w, http.StatusOK, chatResponse{
			ID:      existing.ID.String(),
			Type:    existing.Type,
			Epoch:   existing.Epoch,
			Members: []string{self.String(), peer.ID.String()},
		}, s.log)
		return
	}

	chat := &models.Chat{Type: models.ChatTypeDirect, CreatorID: self}
	if err := s.store.CreateChat(r.Context(), chat, []uuid.UUID{self, peer.ID}); err != nil {
		s.log.Error("create direct chat", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	s.log.Info("direct chat created", "chat_id", chat.ID, "creator_id", self)
	writeJSON(w, http.StatusCreated, chatResponse{
		ID:      chat.ID.String(),
		Type:    chat.Type,
		Epoch:   chat.Epoch,
		Members: []string{self.String(), peer.ID.String()},
	}, s.log)
}

func (s *Server) createGroupChat(w http.ResponseWriter, r *http.Request, self uuid.UUID, req *createChatRequest) {
	if len(req.Members) == 0 || len(req.Members) > 500 {
		writeErr(w, http.StatusBadRequest, "expected 1-500 members", s.log)
		return
	}

	ids := []uuid.UUID{self}
	seen := map[uuid.UUID]struct{}{self: {}}
	for _, name := range req.Members {
		u, err := s.store.UserByUsername(r.Context(), name)
		if err != nil {
			writeErr(w, http.StatusNotFound, "member not found: "+name, s.log)
			return
		}
		if _, dup := seen[u.ID]; dup {
			continue
		}
		seen[u.ID] = struct{}{}
		ids = append(ids, u.ID)
	}

	chat := &models.Chat{
		Type:      models.ChatTypeGroup,
		Title:     req.Title, // already ciphertext
		CreatorID: self,
	}
	if err := s.store.CreateChat(r.Context(), chat, ids); err != nil {
		s.log.Error("create group chat", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	members := make([]string, 0, len(ids))
	for _, id := range ids {
		members = append(members, id.String())
	}

	s.log.Info("group chat created", "chat_id", chat.ID, "creator_id", self, "members", len(ids))
	writeJSON(w, http.StatusCreated, chatResponse{
		ID:      chat.ID.String(),
		Type:    chat.Type,
		Epoch:   chat.Epoch,
		Members: members,
	}, s.log)
}
