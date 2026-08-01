package ws_test

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// secretMarker is a distinctive string standing in for message content. If it
// ever appears in log output, the no-plaintext-on-server guarantee is broken.
const secretMarker = "TOPSECRET_PLAINTEXT_MARKER_9f3a"

// TestEnvelopeNeverLogsCiphertext is the guard for the project's central
// privacy invariant: the server must never write message content to its logs.
//
// It logs an Envelope the careless way -- passing the whole struct as an
// attribute -- which is exactly the mistake a developer is most likely to
// make. Envelope implements slog.LogValuer, so slog calls that method instead
// of reflecting over the fields, and the ciphertext cannot escape.
func TestEnvelopeNeverLogsCiphertext(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	env := ws.Envelope{
		Version:    1,
		Type:       ws.TypeMessage,
		ID:         "01J8ZZZ",
		ChatID:     uuid.New(),
		Sender:     &ws.Address{UserID: uuid.New(), DeviceID: uuid.New()},
		Ciphertext: []byte(secretMarker),
		Seq:        42,
	}

	// The dangerous call: logging the whole envelope.
	log.Info("frame received", "env", env)

	out := buf.String()
	assertNoLeak(t, out)

	// The log must still be useful for debugging.
	for _, want := range []string{"ciphertext_bytes", "chat_id", "sender_user_id"} {
		if !strings.Contains(out, want) {
			t.Errorf("log is missing diagnostic field %q:\n%s", want, out)
		}
	}
}

// assertNoLeak fails if log output contains the secret in any encoding.
//
// Checking the raw string alone is not enough: slog's JSON handler renders
// []byte as base64, so a leaked payload appears encoded rather than literal.
// A naive substring check would pass while the secret sat in the log.
func assertNoLeak(t *testing.T, out string) {
	t.Helper()

	encodings := map[string]string{
		"raw":         secretMarker,
		"base64(std)": base64.StdEncoding.EncodeToString([]byte(secretMarker)),
		"base64(raw)": base64.RawStdEncoding.EncodeToString([]byte(secretMarker)),
		"base64(url)": base64.URLEncoding.EncodeToString([]byte(secretMarker)),
		"hex":         hex.EncodeToString([]byte(secretMarker)),
	}
	for name, needle := range encodings {
		if strings.Contains(out, needle) {
			t.Fatalf("ciphertext leaked into logs as %s:\n%s", name, out)
		}
	}
}

// TestMessageModelNeverLogsCiphertext applies the same guarantee to the
// persistence model, which is logged from the delivery path.
func TestMessageModelNeverLogsCiphertext(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	msg := models.Message{
		ID:         uuid.New(),
		ChatID:     uuid.New(),
		SenderID:   uuid.New(),
		Seq:        7,
		Ciphertext: []byte(secretMarker),
	}
	log.Info("message persisted", "message", msg)

	assertNoLeak(t, buf.String())
}

// TestMessageDeliveryNeverLogsCiphertext covers the per-device payload used by
// the offline queue.
func TestMessageDeliveryNeverLogsCiphertext(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	d := models.MessageDelivery{
		MessageID:  uuid.New(),
		UserID:     uuid.New(),
		DeviceID:   uuid.New(),
		State:      models.DeliveryPending,
		Ciphertext: []byte(secretMarker),
	}
	log.Info("queued for offline device", "delivery", d)

	assertNoLeak(t, buf.String())
}

// TestGroupSenderKeyNeverLogsCiphertext covers the sealed sender-key
// distribution message.
func TestGroupSenderKeyNeverLogsCiphertext(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	g := models.GroupSenderKeyDistribution{
		ChatID:     uuid.New(),
		Epoch:      3,
		Ciphertext: []byte(secretMarker),
	}
	log.Info("skdm relayed", "skdm", g)

	assertNoLeak(t, buf.String())
}

// TestEnvelopeRoundTripPreservesCiphertext confirms redaction applies only to
// logging: the wire format must still carry the payload intact, or messages
// would not be deliverable at all.
func TestEnvelopeRoundTripPreservesCiphertext(t *testing.T) {
	t.Parallel()

	original := ws.Envelope{
		Version:    1,
		Type:       ws.TypeMessage,
		ChatID:     uuid.New(),
		Ciphertext: []byte(secretMarker),
		CipherType: models.CipherTypeWhisper,
	}

	raw, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded ws.Envelope
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if string(decoded.Ciphertext) != secretMarker {
		t.Errorf("ciphertext altered in transit: got %q", decoded.Ciphertext)
	}
	if decoded.CipherType != models.CipherTypeWhisper {
		t.Errorf("cipher type altered: got %d", decoded.CipherType)
	}
}
