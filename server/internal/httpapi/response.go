// Package httpapi implements the REST surface: registration, login, and
// public-key distribution.
package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// errorBody is the uniform error shape returned to clients.
type errorBody struct {
	Error string `json:"error"`
}

// writeJSON serialises v as the response body.
func writeJSON(w http.ResponseWriter, status int, v any, log *slog.Logger) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(v); err != nil {
		// The status line is already sent, so this can only be logged.
		log.Error("encode response", "err", err)
	}
}

// writeErr returns a JSON error with the given status.
//
// Messages are deliberately generic for auth failures so that responses do not
// reveal whether an account exists.
func writeErr(w http.ResponseWriter, status int, msg string, log *slog.Logger) {
	writeJSON(w, status, errorBody{Error: msg}, log)
}

// decodeJSON reads and validates a JSON request body, capping its size so a
// large body cannot exhaust memory.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any, maxBytes int64) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}
