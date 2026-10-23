// Package storagecrypto encrypts cloud-chat content before it reaches the
// database.
//
// Cloud chats are readable by the server by design -- that is what lets their
// history follow the user to a new device. What this layer adds is that the
// database alone is not enough to read them: a leaked dump, a stolen backup or
// a misconfigured replica yields ciphertext. It does not protect against an
// attacker who controls the running server, which holds the key; secret chats
// exist for that threat.
//
// Each chat gets its own key, derived from the master key with HKDF, and every
// sealed value is bound to where it belongs through the AEAD associated data:
// the chat, the message's position in it and what the value is. Moving a
// ciphertext to another row, another chat or another column therefore makes it
// fail to open instead of silently showing the wrong content.
package storagecrypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/google/uuid"
	"golang.org/x/crypto/hkdf"
)

// KeySize is the length of the master key in bytes.
const KeySize = 32

// version prefixes every sealed value so the format can change later without
// guessing what an old row contains.
const version byte = 1

// Purposes a sealed value can have. Part of the associated data, so a message
// body cannot be passed off as a chat title or the other way round.
const (
	PurposeMessage = "msg"
	PurposeTitle   = "title"
	PurposeAvatar  = "avatar"
)

// ErrOpen is returned when a value fails to authenticate: it was tampered
// with, sealed under a different key, or belongs to a different place.
var ErrOpen = errors.New("storagecrypto: value does not authenticate")

// Sealer seals and opens values with keys derived from one master key.
type Sealer struct {
	master []byte
}

// New builds a Sealer from a 32-byte master key.
func New(master []byte) (*Sealer, error) {
	if len(master) != KeySize {
		return nil, fmt.Errorf("storagecrypto: master key must be %d bytes, got %d", KeySize, len(master))
	}
	return &Sealer{master: append([]byte(nil), master...)}, nil
}

// ParseKey decodes a master key given as 64 hex characters, the form the
// installer generates.
func ParseKey(s string) ([]byte, error) {
	key, err := hex.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return nil, fmt.Errorf("storagecrypto: key is not hex: %w", err)
	}
	if len(key) != KeySize {
		return nil, fmt.Errorf("storagecrypto: key must be %d bytes (%d hex characters), got %d bytes",
			KeySize, KeySize*2, len(key))
	}
	return key, nil
}

// Seal encrypts plaintext for (chat, purpose, position).
//
// position is the message seq for message bodies and 0 for chat-level values.
// The nonce is random: one chat key seals many values, including several
// versions of one edited message at the same position, so a nonce derived
// from the position would repeat.
func (s *Sealer) Seal(chatID uuid.UUID, purpose string, position int64, plaintext []byte) ([]byte, error) {
	aead, err := s.aead(chatID)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("storagecrypto: nonce: %w", err)
	}

	out := make([]byte, 0, 1+len(nonce)+len(plaintext)+aead.Overhead())
	out = append(out, version)
	out = append(out, nonce...)
	return aead.Seal(out, nonce, plaintext, associatedData(chatID, purpose, position)), nil
}

// Open reverses Seal. It fails with ErrOpen unless the value was sealed with
// this key for exactly this chat, purpose and position.
func (s *Sealer) Open(chatID uuid.UUID, purpose string, position int64, sealed []byte) ([]byte, error) {
	aead, err := s.aead(chatID)
	if err != nil {
		return nil, err
	}
	n := aead.NonceSize()
	if len(sealed) < 1+n+aead.Overhead() || sealed[0] != version {
		return nil, ErrOpen
	}
	plaintext, err := aead.Open(nil, sealed[1:1+n], sealed[1+n:], associatedData(chatID, purpose, position))
	if err != nil {
		return nil, ErrOpen
	}
	return plaintext, nil
}

// aead derives the chat's key. Deriving per chat means one chat's key, if it
// ever leaked from memory, says nothing about any other chat.
func (s *Sealer) aead(chatID uuid.UUID) (cipher.AEAD, error) {
	key := make([]byte, KeySize)
	r := hkdf.New(sha256.New, s.master, nil, append([]byte("frogster/storage/chat/v1/"), chatID[:]...))
	if _, err := io.ReadFull(r, key); err != nil {
		return nil, fmt.Errorf("storagecrypto: derive key: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("storagecrypto: cipher: %w", err)
	}
	return cipher.NewGCM(block)
}

// associatedData binds a value to where it is stored.
func associatedData(chatID uuid.UUID, purpose string, position int64) []byte {
	ad := make([]byte, 0, 16+8+1+len(purpose))
	ad = append(ad, chatID[:]...)
	ad = binary.BigEndian.AppendUint64(ad, uint64(position))
	ad = append(ad, byte(len(purpose)))
	return append(ad, purpose...)
}
