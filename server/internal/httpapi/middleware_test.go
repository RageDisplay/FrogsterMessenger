package httpapi

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestStatusRecorderPreservesHijacker guards the WebSocket upgrade path.
//
// Wrapping an http.ResponseWriter hides the optional interfaces the original
// implements. gorilla/websocket needs http.Hijacker to take over the TCP
// connection, so a recorder that does not forward Hijack breaks every
// WebSocket handshake with a 500 while leaving ordinary HTTP handlers working
// -- a failure that only shows up in realtime traffic.
func TestStatusRecorderPreservesHijacker(t *testing.T) {
	t.Parallel()

	var (
		sawHijacker bool
		sawFlusher  bool
	)

	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, sawHijacker = w.(http.Hijacker)
		_, sawFlusher = w.(http.Flusher)
		w.WriteHeader(http.StatusOK)
	})

	// httptest.NewRecorder does not implement Hijacker, so exercise the
	// wrapper against a ResponseWriter that does.
	srv := httptest.NewServer(requestLogger(discardLogger())(h))
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()

	if !sawHijacker {
		t.Error("wrapped ResponseWriter lost http.Hijacker; WebSocket upgrades would fail with 500")
	}
	if !sawFlusher {
		t.Error("wrapped ResponseWriter lost http.Flusher; streaming responses would buffer")
	}
}

// TestStatusRecorderCapturesStatus confirms the wrapper still does its job.
func TestStatusRecorderCapturesStatus(t *testing.T) {
	t.Parallel()

	rec := httptest.NewRecorder()
	sr := &statusRecorder{ResponseWriter: rec, status: http.StatusOK}

	sr.WriteHeader(http.StatusTeapot)
	if sr.status != http.StatusTeapot {
		t.Errorf("recorded status %d, want %d", sr.status, http.StatusTeapot)
	}

	// A second call must not overwrite the first, matching net/http semantics.
	sr.WriteHeader(http.StatusInternalServerError)
	if sr.status != http.StatusTeapot {
		t.Errorf("status changed on second WriteHeader: got %d", sr.status)
	}
}

// discardLogger returns a logger that writes nowhere, for tests that only
// care about handler behaviour.
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
