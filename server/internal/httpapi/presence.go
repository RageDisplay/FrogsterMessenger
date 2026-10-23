package httpapi

import (
	"net/http"
	"strings"

	"github.com/google/uuid"
)

// maxPresenceQuery bounds one presence request: a chat list's worth.
const maxPresenceQuery = 200

type presenceJSON struct {
	UserID   string `json:"user_id"`
	Status   string `json:"status"`
	LastSeen int64  `json:"last_seen,omitempty"`
}

// handlePresence reports who of the given users is online, as the caller
// may see it. Users who share no chat with the caller are left out.
//
// GET /v1/presence?users=<id>,<id>,...
func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	if s.presence == nil {
		writeJSON(w, http.StatusOK, map[string]any{"presence": []presenceJSON{}}, s.log)
		return
	}
	var ids []uuid.UUID
	for _, raw := range strings.Split(r.URL.Query().Get("users"), ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		id, err := uuid.Parse(raw)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "users must be a list of ids", s.log)
			return
		}
		ids = append(ids, id)
	}
	if len(ids) > maxPresenceQuery {
		writeErr(w, http.StatusBadRequest, "at most 200 users at a time", s.log)
		return
	}
	statuses, err := s.presence.Statuses(r.Context(), claims.UserID, ids)
	if err != nil {
		s.log.Error("presence", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	out := make([]presenceJSON, 0, len(statuses))
	for _, st := range statuses {
		p := presenceJSON{UserID: st.UserID.String(), Status: st.Status}
		if st.LastSeen != nil {
			p.LastSeen = st.LastSeen.UnixMilli()
		}
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"presence": out}, s.log)
}
