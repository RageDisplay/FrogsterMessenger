// Package logging provides the server logger and the redaction helpers that
// enforce the project's central privacy invariant.
//
// The server is a ciphertext router: it must never emit message contents to
// logs. Rather than relying on developer discipline at every call site, types
// that carry ciphertext implement slog.LogValuer so that logging them yields
// only identifiers and sizes. See Redacted and Size below.
package logging

import (
	"log/slog"
	"os"
	"strings"
)

// New builds the application logger. In dev it emits human-readable text; in
// production it emits JSON for ingestion.
func New(env string, level slog.Level) *slog.Logger {
	opts := &slog.HandlerOptions{Level: level}

	var h slog.Handler
	if env == "dev" {
		h = slog.NewTextHandler(os.Stdout, opts)
	} else {
		h = slog.NewJSONHandler(os.Stdout, opts)
	}
	return slog.New(h)
}

// Redacted wraps a value that must never reach the logs. Logging it prints a
// fixed placeholder regardless of the underlying content.
type Redacted struct{}

// LogValue implements slog.LogValuer.
func (Redacted) LogValue() slog.Value { return slog.StringValue("[REDACTED]") }

// Size describes an opaque payload by length only. Use it in place of the
// payload itself so that logs remain useful for debugging without ever
// carrying ciphertext or plaintext.
type Size int

// LogValue implements slog.LogValuer.
func (s Size) LogValue() slog.Value { return slog.IntValue(int(s)) }

// forbidden are attribute keys that must never appear in a log record,
// because they would signal that payload data is being logged.
var forbidden = []string{
	"ciphertext", "plaintext", "body", "content", "payload",
	"message_body", "text", "password", "private_key", "token",
}

// IsForbiddenKey reports whether an attribute key is disallowed. It backs the
// redaction test that guards the no-plaintext invariant in CI.
func IsForbiddenKey(key string) bool {
	k := strings.ToLower(key)
	for _, f := range forbidden {
		if k == f {
			return true
		}
	}
	return false
}
