// Package voice runs the voice channels of cloud groups: who is in which
// channel, and the relay that carries their sound to each other.
//
// Sound travels as small datagrams, over UDP when the network lets it and
// over a WebSocket when it does not. Each one is sealed with AES-256-GCM
// under a key the member was handed, over TLS, when joining; the relay opens
// what a member sends and seals it again for every listener. Like cloud
// chats, voice is protected on the wire, not from the server.
//
// Wire format, both directions:
//
//	0       version (1)
//	1..8    tag: which member's keys the datagram is under
//	9..16   counter, big-endian; never repeats under one key
//	17..    AES-256-GCM ciphertext, the header above as associated data
//
// Each member has two keys, one per direction, derived from the secret it
// was given, so the client's and the relay's counters can never produce the
// same nonce under the same key.
//
// Plaintext, from a client: kind 1 (audio) seq(2) opus | kind 2 (ping) body.
// From the relay: kind 1 (audio) member(4) seq(2) opus | kind 3 (pong) body.
package voice

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/hkdf"
)

const (
	wireVersion = 1
	tagSize     = 8
	headerSize  = 1 + tagSize + 8

	// MaxPacket bounds a datagram: one Opus frame of speech is a few
	// hundred bytes at most, and anything near the path MTU gets dropped.
	MaxPacket = 1400

	kindAudio = 1
	kindPing  = 2
	kindPong  = 3

	// maxPingBody bounds what a ping may ask to have echoed, so a ping
	// cannot be used to make the relay send more than it received.
	maxPingBody = 32
)

// Tag names a member on the wire.
type Tag [tagSize]byte

// Secret is what a member is handed when joining, from which both of its
// keys are derived.
type Secret [32]byte

type keys struct {
	up   cipher.AEAD // client to relay
	down cipher.AEAD // relay to client
}

func deriveKeys(secret Secret) (keys, error) {
	up, err := aeadFor(secret, "frogster/voice/v1/up")
	if err != nil {
		return keys{}, err
	}
	down, err := aeadFor(secret, "frogster/voice/v1/down")
	if err != nil {
		return keys{}, err
	}
	return keys{up: up, down: down}, nil
}

func aeadFor(secret Secret, info string) (cipher.AEAD, error) {
	key := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, secret[:], nil, []byte(info)), key); err != nil {
		return nil, fmt.Errorf("voice: derive key: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("voice: cipher: %w", err)
	}
	return cipher.NewGCM(block)
}

func nonceFor(counter uint64) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[4:], counter)
	return n
}

// seal makes a datagram.
func seal(aead cipher.AEAD, tag Tag, counter uint64, plaintext []byte) []byte {
	out := make([]byte, headerSize, headerSize+len(plaintext)+aead.Overhead())
	out[0] = wireVersion
	copy(out[1:], tag[:])
	binary.BigEndian.PutUint64(out[1+tagSize:], counter)
	return aead.Seal(out, nonceFor(counter), plaintext, out[:headerSize])
}

var errMalformed = errors.New("voice: malformed datagram")

// header reads a datagram's tag and counter without trusting either.
func header(pkt []byte) (Tag, uint64, error) {
	if len(pkt) < headerSize+16 || len(pkt) > MaxPacket || pkt[0] != wireVersion {
		return Tag{}, 0, errMalformed
	}
	var tag Tag
	copy(tag[:], pkt[1:])
	return tag, binary.BigEndian.Uint64(pkt[1+tagSize:]), nil
}

// open authenticates and decrypts a datagram whose header was read.
func open(aead cipher.AEAD, counter uint64, pkt []byte) ([]byte, error) {
	return aead.Open(nil, nonceFor(counter), pkt[headerSize:], pkt[:headerSize])
}

// replayWindow accepts each counter once, tolerating the reordering a
// network does: anything up to 64 behind the newest seen is still taken if
// it has not been seen.
type replayWindow struct {
	newest uint64
	seen   uint64 // bit i: newest-i was seen
}

// accept records counter and reports whether it was new. Only called for
// datagrams that authenticated, so a forger cannot move the window.
func (w *replayWindow) accept(counter uint64) bool {
	if counter == 0 {
		return false // counters start at 1
	}
	if counter > w.newest {
		if shift := counter - w.newest; shift >= 64 {
			w.seen = 1
		} else {
			w.seen = w.seen<<shift | 1
		}
		w.newest = counter
		return true
	}
	behind := w.newest - counter
	if behind >= 64 || w.seen&(1<<behind) != 0 {
		return false
	}
	w.seen |= 1 << behind
	return true
}
