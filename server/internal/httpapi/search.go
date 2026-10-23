package httpapi

import (
	"net/http"
	"strings"
	"unicode/utf8"
)

type searchHitJSON struct {
	ChatID  string      `json:"chat_id"`
	Message messageJSON `json:"message"`
}

// handleSearchMessages searches the caller's cloud history on the server,
// including what their device never loaded. Secret chats are searched on
// the device: the server cannot read them.
//
// GET /v1/search?q=<text>
func (s *Server) handleSearchMessages(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if n := utf8.RuneCountInString(q); n < 2 || n > 64 {
		writeErr(w, http.StatusBadRequest, "query must be 2-64 characters", s.log)
		return
	}
	hits, err := s.store.SearchCloud(r.Context(), claims.UserID, q, 50)
	if err != nil {
		s.log.Error("search messages", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}
	out := make([]searchHitJSON, 0, len(hits))
	for i := range hits {
		out = append(out, searchHitJSON{
			ChatID:  hits[i].ChatID.String(),
			Message: messageToJSON(&hits[i].CloudMessage),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": out}, s.log)
}
