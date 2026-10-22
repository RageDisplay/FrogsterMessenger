package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// ErrInvalidToken covers every rejection reason for an access token. Callers
// deliberately cannot distinguish expiry from tampering.
var ErrInvalidToken = errors.New("invalid token")

// Claims is the access-token payload.
//
// Tokens are bound to a device, not just a user: each device runs its own
// ratchet sessions, so authorization must identify which device is speaking.
type Claims struct {
	jwt.RegisteredClaims
	UserID   uuid.UUID `json:"uid"`
	DeviceID uuid.UUID `json:"did"`

	// TokenVer mirrors User.TokenVersion. Bumping the stored version
	// invalidates every previously issued token without tracking them.
	TokenVer int `json:"tv"`
}

// Manager issues and validates access tokens.
type Manager struct {
	secret     []byte
	accessTTL  time.Duration
	refreshTTL time.Duration
}

// NewManager builds a token manager.
func NewManager(secret []byte, accessTTL, refreshTTL time.Duration) *Manager {
	return &Manager{secret: secret, accessTTL: accessTTL, refreshTTL: refreshTTL}
}

// RefreshTTL reports the configured refresh-token lifetime.
func (m *Manager) RefreshTTL() time.Duration { return m.refreshTTL }

// AccessTTL reports the configured access-token lifetime.
func (m *Manager) AccessTTL() time.Duration { return m.accessTTL }

// IssueAccess mints a short-lived access token for a (user, device) pair.
func (m *Manager) IssueAccess(userID, deviceID uuid.UUID, tokenVer int) (string, error) {
	now := time.Now()
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			ID:        uuid.NewString(),
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(m.accessTTL)),
			Issuer:    "frogster",
		},
		UserID:   userID,
		DeviceID: deviceID,
		TokenVer: tokenVer,
	}

	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString(m.secret)
	if err != nil {
		return "", fmt.Errorf("sign access token: %w", err)
	}
	return signed, nil
}

// Parse validates a token's signature and time bounds and returns its claims.
//
// The signing method is pinned to HMAC so that a token forged with "alg":"none"
// or an asymmetric algorithm is rejected outright.
func (m *Manager) Parse(token string) (*Claims, error) {
	parsed, err := jwt.ParseWithClaims(token, &Claims{},
		func(t *jwt.Token) (any, error) {
			if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, fmt.Errorf("unexpected signing method %v", t.Header["alg"])
			}
			return m.secret, nil
		},
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer("frogster"),
	)
	if err != nil {
		return nil, ErrInvalidToken
	}

	claims, ok := parsed.Claims.(*Claims)
	if !ok || !parsed.Valid {
		return nil, ErrInvalidToken
	}
	if claims.UserID == uuid.Nil || claims.DeviceID == uuid.Nil {
		return nil, ErrInvalidToken
	}
	return claims, nil
}
