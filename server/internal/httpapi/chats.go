package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// maxGroupMembers bounds a group's size. Every secret-group membership change
// makes each member distribute a new sender key to every other member device,
// so cost grows with the square of this.
const maxGroupMembers = 500

// maxTitleLength bounds a group title, in characters.
const maxTitleLength = 64

type createChatRequest struct {
	Type string `json:"type"`
	// Mode is "cloud" or "secret". Absent from clients that predate cloud
	// chats, which only ever made secret ones.
	Mode string `json:"mode,omitempty"`
	// Peer names the other participant for a direct chat.
	Peer string `json:"peer,omitempty"`
	// Members lists usernames for a group chat.
	Members []string `json:"members,omitempty"`
	// Title names a cloud group. Secret groups keep their title inside
	// end-to-end encrypted messages, so one sent here is ignored.
	Title string `json:"title,omitempty"`
	// HideHistory starts members added later at the moment they join.
	// Cloud groups only: a secret group has no history on the server.
	HideHistory bool `json:"hide_history,omitempty"`
}

type memberJSON struct {
	UserID      string `json:"user_id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name,omitempty"`
	Role        string `json:"role"`
	// AvatarVersion is 0 or negative without an avatar.
	AvatarVersion int `json:"avatar_version,omitempty"`
}

type chatJSON struct {
	ID            string       `json:"id"`
	Type          string       `json:"type"`
	Mode          string       `json:"mode"`
	Epoch         uint64       `json:"epoch"`
	Title         string       `json:"title,omitempty"`
	Role          string       `json:"role"`
	LastSeq       int64        `json:"last_seq"`
	LastReadSeq   int64        `json:"last_read_seq"`
	PeerReadSeq   int64        `json:"peer_read_seq"`
	ClearedSeq    int64        `json:"cleared_seq,omitempty"`
	Unread        int64        `json:"unread"`
	Members       []memberJSON `json:"members"`
	AvatarVersion int          `json:"avatar_version,omitempty"`
	HideHistory   bool         `json:"hide_history,omitempty"`
	Last          *messageJSON `json:"last,omitempty"`
	CreatedAt     time.Time    `json:"created_at"`
}

type messageJSON struct {
	ID             string              `json:"id"`
	Seq            int64               `json:"seq"`
	SenderID       string              `json:"sender_id"`
	SenderDeviceID string              `json:"sender_device_id"`
	Timestamp      int64               `json:"ts"`
	Kind           string              `json:"kind,omitempty"`
	TargetID       string              `json:"target_id,omitempty"`
	Payload        []byte              `json:"payload,omitempty"`
	EditedAt       *int64              `json:"edited_at,omitempty"`
	Deleted        bool                `json:"deleted,omitempty"`
	Reactions      map[string][]string `json:"reactions,omitempty"`
}

func (s *Server) chatJSON(c *store.ChatSummary) chatJSON {
	out := chatJSON{
		ID:            c.ID.String(),
		Type:          c.Type,
		Mode:          c.Mode,
		Epoch:         c.Epoch,
		Title:         s.store.OpenTitle(&c.Chat),
		Role:          c.Role,
		LastSeq:       c.LastSeq,
		LastReadSeq:   c.LastReadSeq,
		PeerReadSeq:   c.PeerReadSeq,
		ClearedSeq:    c.ClearedSeq,
		Unread:        c.Unread,
		Members:       make([]memberJSON, 0, len(c.Members)),
		CreatedAt:     c.CreatedAt,
		AvatarVersion: c.AvatarVersion,
		HideHistory:   c.HideHistory,
	}
	for _, m := range c.Members {
		out.Members = append(out.Members, memberJSON{
			UserID:        m.UserID.String(),
			Username:      m.Username,
			DisplayName:   m.DisplayName,
			Role:          m.Role,
			AvatarVersion: m.AvatarVersion,
		})
	}
	if c.Last != nil {
		last := messageToJSON(c.Last)
		out.Last = &last
	}
	return out
}

func messageToJSON(m *store.CloudMessage) messageJSON {
	out := messageJSON{
		ID:             m.WireID(),
		Seq:            m.Seq,
		SenderID:       m.SenderID.String(),
		SenderDeviceID: m.SenderDevID.String(),
		Timestamp:      m.CreatedAt.UnixMilli(),
		Kind:           m.Kind,
		Payload:        m.Payload,
		Deleted:        m.DeletedAt != nil,
	}
	if m.TargetID != nil {
		out.TargetID = *m.TargetID
	}
	if m.EditedAt != nil {
		at := m.EditedAt.UnixMilli()
		out.EditedAt = &at
	}
	if len(m.Reactions) > 0 {
		out.Reactions = make(map[string][]string, len(m.Reactions))
		for emoji, users := range m.Reactions {
			for _, u := range users {
				out.Reactions[emoji] = append(out.Reactions[emoji], u.String())
			}
		}
	}
	return out
}

// handleCreateChat creates a direct or group chat, cloud or secret.
//
// Direct chats are deduplicated per mode: requesting one that already exists
// returns it rather than forking a parallel conversation, while a cloud and
// a secret chat with the same person live side by side, as in Telegram.
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
	if req.Mode == "" {
		req.Mode = models.ChatModeSecret
	}
	if req.Mode != models.ChatModeCloud && req.Mode != models.ChatModeSecret {
		writeErr(w, http.StatusBadRequest, `mode must be "cloud" or "secret"`, s.log)
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

	if existing, err := s.store.FindDirectChat(r.Context(), self, peer.ID, req.Mode); err == nil {
		s.writeChat(w, r, existing.ID, self, http.StatusOK)
		return
	}

	chat := &models.Chat{Type: models.ChatTypeDirect, Mode: req.Mode, CreatorID: self}
	if err := s.store.CreateChat(r.Context(), chat, []uuid.UUID{self, peer.ID}); err != nil {
		s.log.Error("create direct chat", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	s.log.Info("direct chat created", "chat_id", chat.ID, "mode", chat.Mode, "creator_id", self)
	s.chatChanged(r, chat.ID, chat.Epoch, self, peer.ID)
	s.writeChat(w, r, chat.ID, self, http.StatusCreated)
}

func (s *Server) createGroupChat(w http.ResponseWriter, r *http.Request, self uuid.UUID, req *createChatRequest) {
	if len(req.Members) == 0 || len(req.Members) >= maxGroupMembers {
		writeErr(w, http.StatusBadRequest, "expected 1-499 members besides the creator", s.log)
		return
	}
	title := strings.TrimSpace(req.Title)
	if req.Mode == models.ChatModeCloud && !validTitle(title) {
		writeErr(w, http.StatusBadRequest, "a cloud group needs a title of 1-64 characters", s.log)
		return
	}

	ids, ok := s.resolveUsernames(w, r, req.Members, self)
	if !ok {
		return
	}
	ids = append([]uuid.UUID{self}, ids...)

	chat := &models.Chat{
		ID:        uuid.New(),
		Type:      models.ChatTypeGroup,
		Mode:      req.Mode,
		CreatorID: self,
	}
	chat.HideHistory = req.HideHistory && chat.IsCloud()
	if chat.IsCloud() {
		sealed, err := s.store.SealTitle(chat.ID, title)
		if err != nil {
			s.log.Error("seal group title", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			return
		}
		chat.Title = sealed
	}
	if err := s.store.CreateChat(r.Context(), chat, ids); err != nil {
		s.log.Error("create group chat", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	s.log.Info("group chat created", "chat_id", chat.ID, "mode", chat.Mode, "creator_id", self, "members", len(ids))
	s.chatChanged(r, chat.ID, chat.Epoch, ids...)
	s.writeChat(w, r, chat.ID, self, http.StatusCreated)
}

// resolveUsernames turns usernames into user ids, dropping duplicates and the
// requesting user. It writes the error response itself.
func (s *Server) resolveUsernames(w http.ResponseWriter, r *http.Request, names []string, self uuid.UUID) ([]uuid.UUID, bool) {
	seen := map[uuid.UUID]struct{}{self: {}}
	var ids []uuid.UUID
	for _, name := range names {
		u, err := s.store.UserByUsername(r.Context(), name)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				writeErr(w, http.StatusNotFound, "member not found: "+name, s.log)
			} else {
				s.log.Error("lookup member", "err", err)
				writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			}
			return nil, false
		}
		if _, dup := seen[u.ID]; dup {
			continue
		}
		seen[u.ID] = struct{}{}
		ids = append(ids, u.ID)
	}
	return ids, true
}

func validTitle(title string) bool {
	n := utf8.RuneCountInString(title)
	return n >= 1 && n <= maxTitleLength
}

// writeChat responds with a chat as the given member sees it.
func (s *Server) writeChat(w http.ResponseWriter, r *http.Request, chatID, self uuid.UUID, status int) {
	summary, err := s.store.ChatSummaryFor(r.Context(), chatID, self)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "chat not found", s.log)
			return
		}
		s.log.Error("load chat", "err", err, "chat_id", chatID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, status, s.chatJSON(summary), s.log)
}

// chatChanged tells the given users' devices to refetch a chat. Detached from
// the request so the fan-out outlives the response.
func (s *Server) chatChanged(r *http.Request, chatID uuid.UUID, epoch uint64, users ...uuid.UUID) {
	if s.notifier == nil {
		return
	}
	go s.notifier.NotifyChatUpdated(context.WithoutCancel(r.Context()), chatID, epoch, users)
}

// handleListChats lists the caller's chats, most recently active first.
//
// This is how a device learns what happened while it was away: new chats,
// unread counts, how far the other side has read, and for cloud chats where
// their history ends, so it can fetch what it missed.
func (s *Server) handleListChats(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chats, err := s.store.ChatsForUser(r.Context(), claims.UserID)
	if err != nil {
		s.log.Error("list chats", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	out := make([]chatJSON, 0, len(chats))
	for i := range chats {
		out = append(out, s.chatJSON(&chats[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": out}, s.log)
}

// handleGetChat returns one chat to a member.
func (s *Server) handleGetChat(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chatID, err := parseUUID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id is not a valid UUID", s.log)
		return
	}
	s.writeChat(w, r, chatID, claims.UserID, http.StatusOK)
}

// handleChatMessages serves a cloud chat's history.
//
// With ?after=N it returns everything after seq N in order, events included:
// what a device replays to catch up. Otherwise it pages backwards from
// ?before=N (or the end) through messages in their current state.
func (s *Server) handleChatMessages(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.memberChat(w, r, claims.UserID)
	if !ok {
		return
	}
	if !chat.IsCloud() {
		// A secret chat's history exists only on its members' devices.
		writeErr(w, http.StatusBadRequest, "secret chats keep no history on the server", s.log)
		return
	}

	q := r.URL.Query()
	limit := 50
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 200 {
			writeErr(w, http.StatusBadRequest, "limit must be 1-200", s.log)
			return
		}
		limit = n
	}
	seqParam := func(name string) (int64, bool) {
		v := q.Get(name)
		if v == "" {
			return 0, true
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			writeErr(w, http.StatusBadRequest, name+" must be a non-negative seq", s.log)
			return 0, false
		}
		return n, true
	}
	before, ok := seqParam("before")
	if !ok {
		return
	}
	after, ok := seqParam("after")
	if !ok {
		return
	}

	floor, err := s.store.ClearedSeq(r.Context(), chat.ID, claims.UserID)
	if err != nil {
		s.log.Error("cleared seq", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	var msgs []store.CloudMessage
	if q.Has("after") {
		msgs, err = s.store.CloudSince(r.Context(), chat.ID, floor, after, limit)
	} else {
		msgs, err = s.store.CloudHistory(r.Context(), chat.ID, floor, before, limit)
	}
	if err != nil {
		s.log.Error("chat messages", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	out := make([]messageJSON, 0, len(msgs))
	for i := range msgs {
		out = append(out, messageToJSON(&msgs[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": out}, s.log)
}

// memberChat loads the chat named in the path, provided the caller belongs to
// it. Non-members get the same 404 as a chat that does not exist, so chat ids
// cannot be probed.
func (s *Server) memberChat(w http.ResponseWriter, r *http.Request, self uuid.UUID) (*models.Chat, bool) {
	chatID, err := parseUUID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "id is not a valid UUID", s.log)
		return nil, false
	}
	member, err := s.store.IsMember(r.Context(), chatID, self)
	if err != nil {
		s.log.Error("check membership", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return nil, false
	}
	if !member {
		writeErr(w, http.StatusNotFound, "chat not found", s.log)
		return nil, false
	}
	chat, err := s.store.ChatByID(r.Context(), chatID)
	if err != nil {
		s.log.Error("load chat", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return nil, false
	}
	return chat, true
}

// adminGroup loads a group the caller administers.
func (s *Server) adminGroup(w http.ResponseWriter, r *http.Request, self uuid.UUID) (*models.Chat, bool) {
	chat, ok := s.memberChat(w, r, self)
	if !ok {
		return nil, false
	}
	if !chat.IsGroup() {
		writeErr(w, http.StatusBadRequest, "not a group", s.log)
		return nil, false
	}
	role, err := s.store.MemberRole(r.Context(), chat.ID, self)
	if err != nil {
		s.log.Error("member role", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return nil, false
	}
	if role != models.RoleAdmin {
		writeErr(w, http.StatusForbidden, "only group admins can do this", s.log)
		return nil, false
	}
	return chat, true
}

type updateChatRequest struct {
	Title       *string `json:"title"`
	HideHistory *bool   `json:"hide_history"`
}

// handleUpdateChat renames a cloud group or changes what newcomers see of
// its past. A secret group is renamed by a message to its members, which
// the server cannot read; it has no history on the server to hide.
func (s *Server) handleUpdateChat(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req updateChatRequest
	if err := decodeJSON(w, r, &req, 4<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	chat, ok := s.adminGroup(w, r, claims.UserID)
	if !ok {
		return
	}
	if !chat.IsCloud() {
		writeErr(w, http.StatusBadRequest, "a secret group's title is set end to end", s.log)
		return
	}
	if req.Title == nil && req.HideHistory == nil {
		writeErr(w, http.StatusBadRequest, "nothing to change", s.log)
		return
	}
	if req.Title != nil {
		title := strings.TrimSpace(*req.Title)
		if !validTitle(title) {
			writeErr(w, http.StatusBadRequest, "title must be 1-64 characters", s.log)
			return
		}
		if err := s.store.SetChatTitle(r.Context(), chat.ID, title); err != nil {
			s.log.Error("set chat title", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			return
		}
	}
	if req.HideHistory != nil {
		if err := s.store.SetHideHistory(r.Context(), chat.ID, *req.HideHistory); err != nil {
			s.log.Error("set hide history", "err", err)
			writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			return
		}
	}
	s.notifyMembers(r, chat.ID, chat.Epoch)
	s.writeChat(w, r, chat.ID, claims.UserID, http.StatusOK)
}

type addMembersRequest struct {
	Members []string `json:"members"`
}

// handleAddMembers adds users to a group. Each addition moves a secret
// group to a new epoch, so the newcomers never receive a sender key from
// before they joined.
func (s *Server) handleAddMembers(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req addMembersRequest
	if err := decodeJSON(w, r, &req, 32<<10); err != nil || len(req.Members) == 0 {
		writeErr(w, http.StatusBadRequest, "expected a list of usernames", s.log)
		return
	}
	chat, ok := s.adminGroup(w, r, claims.UserID)
	if !ok {
		return
	}
	ids, ok := s.resolveUsernames(w, r, req.Members, claims.UserID)
	if !ok {
		return
	}
	current, err := s.store.MemberUserIDs(r.Context(), chat.ID)
	if err != nil {
		s.log.Error("member ids", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if len(current)+len(ids) > maxGroupMembers {
		writeErr(w, http.StatusBadRequest, "a group holds at most 500 members", s.log)
		return
	}

	epoch := chat.Epoch
	for _, id := range ids {
		if epoch, err = s.store.AddMember(r.Context(), chat.ID, id); err != nil {
			s.log.Error("add member", "err", err, "chat_id", chat.ID)
			writeErr(w, http.StatusInternalServerError, "internal error", s.log)
			return
		}
	}
	s.log.Info("group members added", "chat_id", chat.ID, "added", len(ids), "epoch", epoch)
	s.notifyMembers(r, chat.ID, epoch)
	s.writeChat(w, r, chat.ID, claims.UserID, http.StatusOK)
}

// handleRemoveMember removes someone from a group. Admins remove members;
// only the group's creator removes another admin.
func (s *Server) handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.adminGroup(w, r, claims.UserID)
	if !ok {
		return
	}
	target, err := parseUUID(r.PathValue("user"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "user is not a valid UUID", s.log)
		return
	}
	if target == claims.UserID {
		writeErr(w, http.StatusBadRequest, "leave the group instead", s.log)
		return
	}
	role, err := s.store.MemberRole(r.Context(), chat.ID, target)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not a member", s.log)
		return
	}
	if err != nil {
		s.log.Error("member role", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if role == models.RoleAdmin && chat.CreatorID != claims.UserID {
		writeErr(w, http.StatusForbidden, "only the group's creator removes admins", s.log)
		return
	}

	epoch, err := s.store.RemoveMember(r.Context(), chat.ID, target)
	if err != nil {
		s.log.Error("remove member", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if s.voice != nil {
		s.voice.RemoveUser(chat.ID, target)
	}
	s.log.Info("group member removed", "chat_id", chat.ID, "epoch", epoch)
	s.notifyMembers(r, chat.ID, epoch, target)
	s.writeChat(w, r, chat.ID, claims.UserID, http.StatusOK)
}

// handleLeaveChat takes the caller out of a group.
func (s *Server) handleLeaveChat(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.memberChat(w, r, claims.UserID)
	if !ok {
		return
	}
	if !chat.IsGroup() {
		writeErr(w, http.StatusBadRequest, "only groups can be left", s.log)
		return
	}
	epoch, err := s.store.LeaveChat(r.Context(), chat.ID, claims.UserID)
	if err != nil {
		s.log.Error("leave chat", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	if s.voice != nil {
		s.voice.RemoveUser(chat.ID, claims.UserID)
	}
	s.notifyMembers(r, chat.ID, epoch, claims.UserID)
	w.WriteHeader(http.StatusNoContent)
}

// handleClearChat clears a cloud chat's history for the caller alone.
// Everyone else keeps theirs; a secret chat's history was never here.
func (s *Server) handleClearChat(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.memberChat(w, r, claims.UserID)
	if !ok {
		return
	}
	pos, err := s.store.ClearHistory(r.Context(), chat.ID, claims.UserID)
	if err != nil {
		s.log.Error("clear chat", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"cleared_seq": pos}, s.log)
}

// notifyMembers tells a chat's current members, and anyone named in extra,
// that it changed.
func (s *Server) notifyMembers(r *http.Request, chatID uuid.UUID, epoch uint64, extra ...uuid.UUID) {
	ids, err := s.store.MemberUserIDs(r.Context(), chatID)
	if err != nil {
		s.log.Warn("notify members", "err", err, "chat_id", chatID)
		return
	}
	s.chatChanged(r, chatID, epoch, append(ids, extra...)...)
}
