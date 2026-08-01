package auth_test

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
)

const testCost = 10 // keep tests fast; production uses 12

func TestPasswordHashAndVerify(t *testing.T) {
	t.Parallel()

	hash, err := auth.HashPassword("correct horse battery", testCost)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}

	if err := auth.VerifyPassword(hash, "correct horse battery"); err != nil {
		t.Errorf("correct password rejected: %v", err)
	}
	if err := auth.VerifyPassword(hash, "wrong password"); err == nil {
		t.Error("wrong password accepted")
	}
}

// TestPasswordHashIsSalted verifies that identical passwords produce different
// digests, so a leaked database does not reveal which users share a password.
func TestPasswordHashIsSalted(t *testing.T) {
	t.Parallel()

	a, err := auth.HashPassword("same-password", testCost)
	if err != nil {
		t.Fatalf("hash a: %v", err)
	}
	b, err := auth.HashPassword("same-password", testCost)
	if err != nil {
		t.Fatalf("hash b: %v", err)
	}
	if a == b {
		t.Error("identical passwords produced identical hashes; salt is missing")
	}
}

// TestPasswordTooLongRejected guards against silent truncation: bcrypt ignores
// input past 72 bytes, so two distinct long passwords would otherwise become
// interchangeable.
func TestPasswordTooLongRejected(t *testing.T) {
	t.Parallel()

	long := strings.Repeat("a", 73)
	if _, err := auth.HashPassword(long, testCost); err == nil {
		t.Error("password over 72 bytes was accepted; bcrypt would truncate it")
	}
}

func TestAccessTokenRoundTrip(t *testing.T) {
	t.Parallel()

	m := auth.NewManager([]byte("test-secret-at-least-32-bytes-long!!"), 15*time.Minute, time.Hour)
	userID, deviceID := uuid.New(), uuid.New()

	tok, err := m.IssueAccess(userID, deviceID, 3)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	claims, err := m.Parse(tok)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if claims.UserID != userID {
		t.Errorf("user id: got %s, want %s", claims.UserID, userID)
	}
	if claims.DeviceID != deviceID {
		t.Errorf("device id: got %s, want %s", claims.DeviceID, deviceID)
	}
	if claims.TokenVer != 3 {
		t.Errorf("token version: got %d, want 3", claims.TokenVer)
	}
}

func TestTokenSignedWithOtherSecretRejected(t *testing.T) {
	t.Parallel()

	issuer := auth.NewManager([]byte("secret-one-at-least-32-bytes-long!!!"), time.Minute, time.Hour)
	verifier := auth.NewManager([]byte("secret-two-at-least-32-bytes-long!!!"), time.Minute, time.Hour)

	tok, err := issuer.IssueAccess(uuid.New(), uuid.New(), 1)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if _, err := verifier.Parse(tok); err == nil {
		t.Error("token signed with a different secret was accepted")
	}
}

func TestExpiredTokenRejected(t *testing.T) {
	t.Parallel()

	m := auth.NewManager([]byte("test-secret-at-least-32-bytes-long!!"), -time.Minute, time.Hour)
	tok, err := m.IssueAccess(uuid.New(), uuid.New(), 1)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if _, err := m.Parse(tok); err == nil {
		t.Error("expired token was accepted")
	}
}

// TestNoneAlgorithmRejected covers the classic JWT forgery: a token whose
// header claims "alg":"none" must never be trusted, or anyone could mint
// arbitrary identities.
func TestNoneAlgorithmRejected(t *testing.T) {
	t.Parallel()

	m := auth.NewManager([]byte("test-secret-at-least-32-bytes-long!!"), time.Minute, time.Hour)

	claims := jwt.MapClaims{
		"uid": uuid.New().String(),
		"did": uuid.New().String(),
		"tv":  1,
		"iss": "frogster",
		"exp": time.Now().Add(time.Hour).Unix(),
	}
	forged, err := jwt.NewWithClaims(jwt.SigningMethodNone, claims).
		SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("build unsigned token: %v", err)
	}

	if _, err := m.Parse(forged); err == nil {
		t.Fatal("token with alg=none was accepted")
	}
}

// TestTamperedTokenRejected confirms the signature actually covers the claims.
func TestTamperedTokenRejected(t *testing.T) {
	t.Parallel()

	m := auth.NewManager([]byte("test-secret-at-least-32-bytes-long!!"), time.Minute, time.Hour)
	tok, err := m.IssueAccess(uuid.New(), uuid.New(), 1)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	// Flip a character in the payload segment.
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("unexpected token shape: %d segments", len(parts))
	}
	body := []byte(parts[1])
	body[0] ^= 'A' ^ 'B'
	tampered := parts[0] + "." + string(body) + "." + parts[2]

	if _, err := m.Parse(tampered); err == nil {
		t.Error("tampered token was accepted")
	}
}

func TestOpaqueTokensAreUniqueAndHashed(t *testing.T) {
	t.Parallel()

	a, err := auth.NewOpaqueToken()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	b, err := auth.NewOpaqueToken()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if a == b {
		t.Error("two refresh tokens collided")
	}

	h := auth.HashToken(a)
	if h == a {
		t.Error("hash equals the token; the raw token would be stored")
	}
	if len(h) != 64 {
		t.Errorf("hash length %d, want 64 hex chars", len(h))
	}
	if auth.HashToken(a) != h {
		t.Error("hashing is not deterministic")
	}
}
