package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

// ErrInvalidCredentials is returned for both unknown usernames and wrong
// passwords, so that responses do not reveal which accounts exist.
var ErrInvalidCredentials = errors.New("invalid credentials")

// bcryptMaxInput is bcrypt's hard input limit. Longer passwords are rejected
// rather than silently truncated, which would make distinct passwords
// equivalent.
const bcryptMaxInput = 72

// HashPassword returns a bcrypt digest at the configured cost.
func HashPassword(password string, cost int) (string, error) {
	if len(password) > bcryptMaxInput {
		return "", fmt.Errorf("password exceeds %d bytes", bcryptMaxInput)
	}
	h, err := bcrypt.GenerateFromPassword([]byte(password), cost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(h), nil
}

// VerifyPassword compares a candidate password against a stored digest.
//
// bcrypt.CompareHashAndPassword is constant-time with respect to the digest,
// so this does not leak information through timing.
func VerifyPassword(hash, password string) error {
	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)); err != nil {
		return ErrInvalidCredentials
	}
	return nil
}

// NewOpaqueToken returns a cryptographically random refresh token.
//
// Refresh tokens carry no claims: they are random strings looked up by hash,
// so a database leak yields nothing usable and revocation is immediate.
func NewOpaqueToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// HashToken returns the hex-encoded SHA-256 of a token. Only this value is
// persisted.
//
// SHA-256 (not bcrypt) is right here: the input is already 256 bits of
// entropy, so it is not brute-forceable, and lookups must be fast.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// HashIP returns a salted hash of a client IP for session display, so that raw
// addresses are not retained.
func HashIP(ip string, salt []byte) string {
	h := sha256.New()
	h.Write(salt)
	h.Write([]byte(ip))
	return hex.EncodeToString(h.Sum(nil))
}
