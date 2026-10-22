package storagecrypto

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func newSealer(t *testing.T) *Sealer {
	t.Helper()
	s, err := New(bytes.Repeat([]byte{7}, KeySize))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestRoundTrip(t *testing.T) {
	s := newSealer(t)
	chat := uuid.New()
	sealed, err := s.Seal(chat, PurposeMessage, 42, []byte("привет"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("привет")) {
		t.Fatal("plaintext visible in sealed value")
	}
	got, err := s.Open(chat, PurposeMessage, 42, sealed)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "привет" {
		t.Fatalf("got %q", got)
	}
}

// A ciphertext copied into another row must not open there: otherwise
// someone with write access to the database could make one message show the
// content of another.
func TestValueIsBoundToItsPlace(t *testing.T) {
	s := newSealer(t)
	chat, other := uuid.New(), uuid.New()
	sealed, err := s.Seal(chat, PurposeMessage, 5, []byte("body"))
	if err != nil {
		t.Fatal(err)
	}

	cases := map[string]func() ([]byte, error){
		"another seq":     func() ([]byte, error) { return s.Open(chat, PurposeMessage, 6, sealed) },
		"another chat":    func() ([]byte, error) { return s.Open(other, PurposeMessage, 5, sealed) },
		"another purpose": func() ([]byte, error) { return s.Open(chat, PurposeTitle, 5, sealed) },
	}
	for name, open := range cases {
		if _, err := open(); !errors.Is(err, ErrOpen) {
			t.Errorf("%s: want ErrOpen, got %v", name, err)
		}
	}
}

func TestTamperingIsDetected(t *testing.T) {
	s := newSealer(t)
	chat := uuid.New()
	sealed, _ := s.Seal(chat, PurposeMessage, 1, []byte("body"))
	for i := range sealed {
		mutated := append([]byte(nil), sealed...)
		mutated[i] ^= 0x01
		if _, err := s.Open(chat, PurposeMessage, 1, mutated); err == nil {
			t.Fatalf("flipping byte %d went unnoticed", i)
		}
	}
	if _, err := s.Open(chat, PurposeMessage, 1, sealed[:10]); !errors.Is(err, ErrOpen) {
		t.Fatalf("truncated value: %v", err)
	}
}

func TestAnotherMasterKeyCannotOpen(t *testing.T) {
	chat := uuid.New()
	sealed, _ := newSealer(t).Seal(chat, PurposeMessage, 1, []byte("body"))
	other, _ := New(bytes.Repeat([]byte{8}, KeySize))
	if _, err := other.Open(chat, PurposeMessage, 1, sealed); !errors.Is(err, ErrOpen) {
		t.Fatalf("want ErrOpen, got %v", err)
	}
}

// Edits re-seal the same position, so nonces must not repeat for it.
func TestNoncesDoNotRepeat(t *testing.T) {
	s := newSealer(t)
	chat := uuid.New()
	a, _ := s.Seal(chat, PurposeMessage, 1, []byte("same"))
	b, _ := s.Seal(chat, PurposeMessage, 1, []byte("same"))
	if bytes.Equal(a, b) {
		t.Fatal("two seals of the same value are identical: the nonce repeats")
	}
	if bytes.Equal(a[1:13], b[1:13]) {
		t.Fatal("nonce repeated")
	}
}

func TestParseKey(t *testing.T) {
	if _, err := ParseKey(strings.Repeat("ab", 32)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "zz", strings.Repeat("ab", 16)} {
		if _, err := ParseKey(bad); err == nil {
			t.Errorf("ParseKey(%q) accepted", bad)
		}
	}
	if _, err := New(make([]byte, 16)); err == nil {
		t.Fatal("short master key accepted")
	}
}
