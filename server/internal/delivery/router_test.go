package delivery

import (
	"testing"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/ws"
)

// TestCiphertextForPrefersPerDevicePayload is the guard for the multi-device
// delivery invariant.
//
// Every device runs its own Double Ratchet session, so a payload encrypted for
// one device is undecryptable by any other. If delivery fell back to a shared
// ciphertext, exactly one recipient device would read the message and every
// other would silently fail to decrypt -- with no error anywhere on the
// server, because the server cannot tell ciphertext apart from noise.
func TestCiphertextForPrefersPerDevicePayload(t *testing.T) {
	t.Parallel()

	shared := []byte("group sender-key ciphertext")
	perDevice := []byte("ciphertext for this device only")

	msg := &models.Message{Ciphertext: shared}

	withPayload := models.MessageDelivery{Ciphertext: perDevice}
	if got := ciphertextFor(withPayload, msg); string(got) != string(perDevice) {
		t.Errorf("got %q, want the per-device payload", got)
	}

	// A group message has no per-device payload and shares one sender-key
	// ciphertext, which every member can decrypt.
	withoutPayload := models.MessageDelivery{}
	if got := ciphertextFor(withoutPayload, msg); string(got) != string(shared) {
		t.Errorf("got %q, want the shared group ciphertext", got)
	}
}

// TestCipherTypeForFallsBackToMessage checks that a per-device cipher type
// overrides the envelope's, since the first message of a session is a prekey
// message for one device and an ordinary one for another.
func TestCipherTypeForFallsBackToMessage(t *testing.T) {
	t.Parallel()

	deviceA := uuid.New()
	deviceB := uuid.New()

	perDevice := map[uuid.UUID]ws.DevicePayload{
		deviceA: {DeviceID: deviceA, CipherType: models.CipherTypePreKey},
		deviceB: {DeviceID: deviceB}, // no explicit type
	}

	if got := cipherTypeFor(perDevice, deviceA, models.CipherTypeWhisper); got != models.CipherTypePreKey {
		t.Errorf("device A: got %d, want the per-device prekey type", got)
	}
	if got := cipherTypeFor(perDevice, deviceB, models.CipherTypeWhisper); got != models.CipherTypeWhisper {
		t.Errorf("device B: got %d, want the message fallback", got)
	}

	unknown := uuid.New()
	if got := cipherTypeFor(perDevice, unknown, models.CipherTypeSenderKey); got != models.CipherTypeSenderKey {
		t.Errorf("unknown device: got %d, want the fallback", got)
	}
}

// TestWireIDKeepsSenderID confirms every delivery carries the id the sender
// generated, so the sender's optimistically rendered copy, the recipients'
// copies and any later reply or reaction all refer to one message.
func TestWireIDKeepsSenderID(t *testing.T) {
	t.Parallel()

	clientID := "client-generated"
	msg := &models.Message{ID: uuid.New(), ClientID: &clientID}
	if got := msg.WireID(); got != clientID {
		t.Errorf("got %q, want the sender's id", got)
	}

	legacy := &models.Message{ID: uuid.New()}
	if got := legacy.WireID(); got != legacy.ID.String() {
		t.Errorf("got %q, want the server id when the sender supplied none", got)
	}
}

// TestDevicePayloadNeverLogsCiphertext extends the no-plaintext guarantee to
// the per-device payload type added for multi-device delivery.
func TestDevicePayloadNeverLogsCiphertext(t *testing.T) {
	t.Parallel()

	payload := ws.DevicePayload{
		UserID:     uuid.New(),
		DeviceID:   uuid.New(),
		Ciphertext: []byte("SECRET_PAYLOAD_MARKER"),
	}

	rendered := payload.LogValue().String()
	if contains(rendered, "SECRET_PAYLOAD_MARKER") {
		t.Fatalf("ciphertext leaked into log value: %s", rendered)
	}
	if !contains(rendered, "ciphertext_bytes") {
		t.Errorf("log value lost its size diagnostic: %s", rendered)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) &&
		(haystack == needle ||
			len(needle) == 0 ||
			indexOf(haystack, needle) >= 0)
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
