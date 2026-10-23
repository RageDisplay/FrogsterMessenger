package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
	"github.com/vectrixsecurity/frogster/server/internal/voice"
)

// VoiceChannelNotifier tells a group's members its voice channels changed.
type VoiceChannelNotifier interface {
	NotifyVoiceChannels(ctx context.Context, chatID uuid.UUID)
}

// SetVoice installs the voice channels. udpPort is where clients send
// sound, 0 when only the WebSocket path is offered.
func (s *Server) SetVoice(m *voice.Manager, notifier VoiceChannelNotifier, udpPort int, media http.Handler) {
	s.voice, s.voiceNotifier, s.voicePort, s.voiceMedia = m, notifier, udpPort, media
}

// maxChannelName bounds a voice channel's name, in characters.
const maxChannelName = 32

type voiceChannelJSON struct {
	ID           string              `json:"id"`
	Name         string              `json:"name"`
	Position     int                 `json:"position"`
	Participants []voice.Participant `json:"participants"`
}

type voiceChannelRequest struct {
	Name string `json:"name"`
}

type voiceJoinJSON struct {
	ChannelID string `json:"channel_id"`
	Member    uint32 `json:"member"`
	Tag       []byte `json:"tag"`
	Secret    []byte `json:"secret"`
	// UDPPort is where sound goes, on the same host as this API; 0 when
	// the server offers only MediaPath.
	UDPPort   int    `json:"udp_port,omitempty"`
	MediaPath string `json:"media_path"`
}

const mediaPath = "/v1/voice/media"

// voiceGroup loads the cloud group in the path, for a member.
func (s *Server) voiceGroup(w http.ResponseWriter, r *http.Request, self uuid.UUID, admin bool) (*models.Chat, bool) {
	if s.voice == nil {
		writeErr(w, http.StatusNotFound, "voice channels are not enabled on this server", s.log)
		return nil, false
	}
	var chat *models.Chat
	var ok bool
	if admin {
		chat, ok = s.adminGroup(w, r, self)
	} else {
		chat, ok = s.memberChat(w, r, self)
	}
	if !ok {
		return nil, false
	}
	if !chat.IsGroup() || !chat.IsCloud() {
		// A secret group's server knows nothing it could relay without
		// hearing it; voice there would need end-to-end media.
		writeErr(w, http.StatusBadRequest, "voice channels are for cloud groups", s.log)
		return nil, false
	}
	return chat, true
}

func validChannelName(name string) bool {
	n := utf8.RuneCountInString(name)
	return n >= 1 && n <= maxChannelName
}

// handleListVoiceChannels lists a group's channels and who is in each.
func (s *Server) handleListVoiceChannels(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.voiceGroup(w, r, claims.UserID, false)
	if !ok {
		return
	}
	channels, err := s.store.VoiceChannels(r.Context(), chat.ID)
	if err != nil {
		s.log.Error("voice channels", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	inRoom := map[uuid.UUID][]voice.Participant{}
	for _, room := range s.voice.Rooms(chat.ID) {
		inRoom[room.ChannelID] = room.Participants
	}
	out := make([]voiceChannelJSON, 0, len(channels))
	for _, ch := range channels {
		people := inRoom[ch.ID]
		if people == nil {
			people = []voice.Participant{}
		}
		out = append(out, voiceChannelJSON{ID: ch.ID.String(), Name: ch.Name, Position: ch.Position, Participants: people})
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": out}, s.log)
}

// handleCreateVoiceChannel adds a channel to a group. Admins only.
func (s *Server) handleCreateVoiceChannel(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req voiceChannelRequest
	if err := decodeJSON(w, r, &req, 4<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	name := strings.TrimSpace(req.Name)
	if !validChannelName(name) {
		writeErr(w, http.StatusBadRequest, "a channel name is 1-32 characters", s.log)
		return
	}
	chat, ok := s.voiceGroup(w, r, claims.UserID, true)
	if !ok {
		return
	}
	ch, err := s.store.CreateVoiceChannel(r.Context(), chat.ID, name)
	if errors.Is(err, store.ErrTooManyChannels) {
		writeErr(w, http.StatusConflict, "a group has at most 10 voice channels", s.log)
		return
	}
	if err != nil {
		s.log.Error("create voice channel", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	s.voiceChannelsChanged(r, chat.ID)
	writeJSON(w, http.StatusCreated, voiceChannelJSON{
		ID: ch.ID.String(), Name: ch.Name, Position: ch.Position, Participants: []voice.Participant{},
	}, s.log)
}

// channelInPath reads the channel id from the path.
func (s *Server) channelInPath(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := parseUUID(r.PathValue("channel"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "channel is not a valid UUID", s.log)
		return uuid.Nil, false
	}
	return id, true
}

// handleRenameVoiceChannel renames a channel. Admins only.
func (s *Server) handleRenameVoiceChannel(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req voiceChannelRequest
	if err := decodeJSON(w, r, &req, 4<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	name := strings.TrimSpace(req.Name)
	if !validChannelName(name) {
		writeErr(w, http.StatusBadRequest, "a channel name is 1-32 characters", s.log)
		return
	}
	chat, ok := s.voiceGroup(w, r, claims.UserID, true)
	if !ok {
		return
	}
	channelID, ok := s.channelInPath(w, r)
	if !ok {
		return
	}
	if err := s.store.RenameVoiceChannel(r.Context(), chat.ID, channelID, name); err != nil {
		s.channelError(w, err, chat.ID)
		return
	}
	s.voiceChannelsChanged(r, chat.ID)
	w.WriteHeader(http.StatusNoContent)
}

// handleDeleteVoiceChannel removes a channel, and everyone in it. Admins
// only.
func (s *Server) handleDeleteVoiceChannel(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.voiceGroup(w, r, claims.UserID, true)
	if !ok {
		return
	}
	channelID, ok := s.channelInPath(w, r)
	if !ok {
		return
	}
	if err := s.store.DeleteVoiceChannel(r.Context(), chat.ID, channelID); err != nil {
		s.channelError(w, err, chat.ID)
		return
	}
	s.voice.CloseChannel(chat.ID, channelID)
	s.voiceChannelsChanged(r, chat.ID)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) channelError(w http.ResponseWriter, err error, chatID uuid.UUID) {
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "voice channel not found", s.log)
		return
	}
	s.log.Error("voice channel", "err", err, "chat_id", chatID)
	writeErr(w, http.StatusInternalServerError, "internal error", s.log)
}

func (s *Server) voiceChannelsChanged(r *http.Request, chatID uuid.UUID) {
	if s.voiceNotifier != nil {
		go s.voiceNotifier.NotifyVoiceChannels(context.WithoutCancel(r.Context()), chatID)
	}
}

// handleJoinVoice puts the caller's device in a channel and hands it the
// keys to talk there.
func (s *Server) handleJoinVoice(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	chat, ok := s.voiceGroup(w, r, claims.UserID, false)
	if !ok {
		return
	}
	channelID, ok := s.channelInPath(w, r)
	if !ok {
		return
	}
	if _, err := s.store.VoiceChannel(r.Context(), chat.ID, channelID); err != nil {
		s.channelError(w, err, chat.ID)
		return
	}
	grant, err := s.voice.Join(chat.ID, channelID, claims.UserID, claims.DeviceID)
	if errors.Is(err, voice.ErrFull) {
		writeErr(w, http.StatusConflict, "the channel is full", s.log)
		return
	}
	if err != nil {
		s.log.Error("join voice", "err", err, "chat_id", chat.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	writeJSON(w, http.StatusOK, voiceJoinJSON{
		ChannelID: channelID.String(),
		Member:    grant.Member,
		Tag:       grant.Tag[:],
		Secret:    grant.Secret[:],
		UDPPort:   s.voicePort,
		MediaPath: mediaPath,
	}, s.log)
}

// handleLeaveVoice takes the caller's device out of its channel.
func (s *Server) handleLeaveVoice(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	if s.voice != nil {
		s.voice.Leave(claims.DeviceID)
	}
	w.WriteHeader(http.StatusNoContent)
}

type voiceStateRequest struct {
	Muted    bool `json:"muted"`
	Deafened bool `json:"deafened"`
}

// handleVoiceState turns the caller's microphone or sound off or on.
func (s *Server) handleVoiceState(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	var req voiceStateRequest
	if err := decodeJSON(w, r, &req, 1<<10); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	if s.voice == nil || !s.voice.SetState(claims.DeviceID, req.Muted, req.Deafened) {
		writeErr(w, http.StatusNotFound, "not in a voice channel", s.log)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleActiveVoice lists, for each of the caller's groups with someone
// talking, who is in its channels: what the chat list shows.
func (s *Server) handleActiveVoice(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	type chatVoice struct {
		ChatID string            `json:"chat_id"`
		Rooms  []voice.RoomState `json:"rooms"`
	}
	out := []chatVoice{}
	if s.voice != nil {
		for _, chatID := range s.voice.ActiveChats() {
			member, err := s.store.IsMember(r.Context(), chatID, claims.UserID)
			if err != nil {
				s.log.Error("check membership", "err", err)
				writeErr(w, http.StatusInternalServerError, "internal error", s.log)
				return
			}
			if member {
				out = append(out, chatVoice{ChatID: chatID.String(), Rooms: s.voice.Rooms(chatID)})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": out}, s.log)
}
