package httpapi

import (
	"errors"
	"net/http"
	"regexp"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// Key sizes fixed by the protocol: Curve25519 public keys are 32 bytes plus a
// one-byte DJB type prefix; Ed25519 public keys are 32 bytes with no prefix;
// Ed25519 signatures are 64 bytes.
const (
	curve25519PubLen = 33
	ed25519PubLen    = 32
	signatureLen     = 64
)

const (
	maxRegisterBody = 64 << 10 // 100 prekeys plus metadata fits comfortably
	minPasswordLen  = 10
	maxPasswordLen  = 72 // bcrypt's hard limit
	maxPreKeyUpload = 200
)

var usernameRe = regexp.MustCompile(`^[a-zA-Z0-9_]{3,32}$`)

// preKeyJSON is an uploaded one-time prekey.
type preKeyJSON struct {
	KeyID     uint32 `json:"key_id"`
	PublicKey []byte `json:"public_key"` // base64 in JSON
}

// signedPreKeyJSON is an uploaded signed prekey and its XEdDSA signature.
type signedPreKeyJSON struct {
	KeyID     uint32 `json:"key_id"`
	PublicKey []byte `json:"public_key"`
	Signature []byte `json:"signature"`
}

// deviceJSON is the key material a client publishes for one device.
type deviceJSON struct {
	Name           string `json:"name"`
	RegistrationID uint32 `json:"registration_id"`

	// IdentityKey is the Curve25519 DH key (33 bytes, DJB-prefixed).
	IdentityKey []byte `json:"identity_key"`

	// IdentityKeyEd25519 is the Ed25519 signing key (32 bytes). Optional for
	// backwards compatibility with devices registered before signing keys
	// existed; such devices cannot have their signed prekeys verified.
	IdentityKeyEd25519 []byte `json:"identity_key_ed25519,omitempty"`

	SignedPreKey   signedPreKeyJSON `json:"signed_pre_key"`
	OneTimePreKeys []preKeyJSON     `json:"one_time_pre_keys"`
}

type registerRequest struct {
	Username string     `json:"username"`
	Password string     `json:"password"`
	Device   deviceJSON `json:"device"`
}

type tokenResponse struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
	UserID       string    `json:"user_id"`
	DeviceID     string    `json:"device_id"`
}

// handleRegister creates an account and its first device.
//
// The server stores the uploaded public keys verbatim and does not verify that
// the client holds the corresponding private keys -- it has no way to. That is
// the intended trust model, and it is why clients must pin peer identity keys
// on first use and block on safety-number changes.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := decodeJSON(w, r, &req, maxRegisterBody); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}

	if !usernameRe.MatchString(req.Username) {
		writeErr(w, http.StatusBadRequest,
			"username must be 3-32 characters of a-z, A-Z, 0-9 or underscore", s.log)
		return
	}
	if len(req.Password) < minPasswordLen || len(req.Password) > maxPasswordLen {
		writeErr(w, http.StatusBadRequest, "password must be 10-72 bytes", s.log)
		return
	}
	if err := validateDevice(&req.Device); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error(), s.log)
		return
	}

	hash, err := auth.HashPassword(req.Password, s.cfg.BcryptCost)
	if err != nil {
		s.log.Error("hash password", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	user := &models.User{
		Username:     req.Username,
		DisplayName:  req.Username,
		PasswordHash: hash,
		TokenVersion: 1,
	}
	device, spk, otps := buildDeviceModels(&req.Device)

	if err := s.store.CreateUserWithDevice(r.Context(), user, device, spk, otps); err != nil {
		if errors.Is(err, store.ErrUsernameTaken) {
			writeErr(w, http.StatusConflict, "username already taken", s.log)
			return
		}
		s.log.Error("create user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	s.log.Info("user registered",
		"user_id", user.ID, "device_id", device.ID, "prekeys", len(otps))

	s.issueTokens(w, r, user, device)
}

// validateDevice checks the shape of uploaded key material.
//
// This rejects malformed uploads early; it is an integrity check, not a proof
// that the uploader controls the corresponding private keys.
func validateDevice(d *deviceJSON) error {
	if len(d.IdentityKey) != curve25519PubLen {
		return errBadKey("identity_key must be 33 bytes")
	}
	if len(d.SignedPreKey.PublicKey) != curve25519PubLen {
		return errBadKey("signed_pre_key.public_key must be 33 bytes")
	}
	if len(d.SignedPreKey.Signature) != signatureLen {
		return errBadKey("signed_pre_key.signature must be 64 bytes")
	}
	if len(d.IdentityKeyEd25519) != 0 && len(d.IdentityKeyEd25519) != ed25519PubLen {
		return errBadKey("identity_key_ed25519 must be 32 bytes")
	}
	if len(d.OneTimePreKeys) > maxPreKeyUpload {
		return errBadKey("too many one-time prekeys")
	}
	seen := make(map[uint32]struct{}, len(d.OneTimePreKeys))
	for _, k := range d.OneTimePreKeys {
		if len(k.PublicKey) != curve25519PubLen {
			return errBadKey("one_time_pre_keys[].public_key must be 33 bytes")
		}
		if _, dup := seen[k.KeyID]; dup {
			return errBadKey("duplicate one-time prekey key_id")
		}
		seen[k.KeyID] = struct{}{}
	}
	if len(d.Name) > 64 {
		return errBadKey("device name too long")
	}
	return nil
}

type badKeyError string

func (e badKeyError) Error() string { return string(e) }

func errBadKey(msg string) error { return badKeyError(msg) }

// buildDeviceModels converts the wire representation into storage models.
func buildDeviceModels(d *deviceJSON) (*models.Device, *models.SignedPreKey, []models.OneTimePreKey) {
	name := d.Name
	if name == "" {
		name = "unnamed device"
	}
	device := &models.Device{
		RegistrationID:     d.RegistrationID,
		DeviceName:         name,
		IdentityKeyPub:     d.IdentityKey,
		IdentityKeyEd25519: d.IdentityKeyEd25519,
	}
	spk := &models.SignedPreKey{
		KeyID:     d.SignedPreKey.KeyID,
		PublicKey: d.SignedPreKey.PublicKey,
		Signature: d.SignedPreKey.Signature,
	}
	otps := make([]models.OneTimePreKey, 0, len(d.OneTimePreKeys))
	for _, k := range d.OneTimePreKeys {
		otps = append(otps, models.OneTimePreKey{KeyID: k.KeyID, PublicKey: k.PublicKey})
	}
	return device, spk, otps
}
