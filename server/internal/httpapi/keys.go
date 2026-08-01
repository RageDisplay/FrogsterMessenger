package httpapi

import (
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

// deviceBundleJSON is one device's X3DH key bundle.
type deviceBundleJSON struct {
	DeviceID       string `json:"device_id"`
	RegistrationID uint32 `json:"registration_id"`
	DeviceName     string `json:"device_name"`

	// IdentityKey is used for Diffie-Hellman; IdentityKeyEd25519 verifies the
	// signed prekey signature.
	IdentityKey        []byte `json:"identity_key"`
	IdentityKeyEd25519 []byte `json:"identity_key_ed25519,omitempty"`

	SignedPreKey  signedPreKeyJSON `json:"signed_pre_key"`
	OneTimePreKey *preKeyJSON      `json:"one_time_pre_key"`
}

type keyBundleResponse struct {
	UserID   string             `json:"user_id"`
	Username string             `json:"username"`
	Devices  []deviceBundleJSON `json:"devices"`
}

// handleGetKeys returns the key bundles a peer needs to start X3DH sessions.
//
// Each bundle consumes one of the target device's one-time prekeys. That makes
// this endpoint a drain vector, which is why it is rate limited per caller: an
// unbounded caller could exhaust a victim's pool and force every subsequent
// session to start without a one-time prekey.
func (s *Server) handleGetKeys(w http.ResponseWriter, r *http.Request) {
	username := r.PathValue("username")
	if username == "" {
		writeErr(w, http.StatusBadRequest, "username is required", s.log)
		return
	}

	user, err := s.store.UserByUsername(r.Context(), username)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "user not found", s.log)
			return
		}
		s.log.Error("lookup user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	devices, err := s.store.ActiveDevices(r.Context(), user.ID)
	if err != nil {
		s.log.Error("list devices", "err", err, "user_id", user.ID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	// Optionally narrow to a single device.
	if want := r.URL.Query().Get("device"); want != "" {
		id, err := uuid.Parse(want)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "device is not a valid UUID", s.log)
			return
		}
		devices = filterDevices(devices, id)
		if len(devices) == 0 {
			writeErr(w, http.StatusNotFound, "device not found", s.log)
			return
		}
	}

	bundles := make([]deviceBundleJSON, 0, len(devices))
	for _, d := range devices {
		bundle, err := s.buildBundle(r, d)
		if err != nil {
			s.log.Error("build key bundle", "err", err, "device_id", d.ID)
			continue // a device without an active signed prekey is unusable
		}
		bundles = append(bundles, *bundle)
	}

	if len(bundles) == 0 {
		writeErr(w, http.StatusNotFound, "no usable key bundles for user", s.log)
		return
	}

	writeJSON(w, http.StatusOK, keyBundleResponse{
		UserID:   user.ID.String(),
		Username: user.Username,
		Devices:  bundles,
	}, s.log)
}

// buildBundle assembles one device's bundle, consuming a one-time prekey when
// the pool still has any.
func (s *Server) buildBundle(r *http.Request, d models.Device) (*deviceBundleJSON, error) {
	spk, err := s.store.ActiveSignedPreKey(r.Context(), d.ID)
	if err != nil {
		return nil, err
	}

	bundle := &deviceBundleJSON{
		DeviceID:           d.ID.String(),
		RegistrationID:     d.RegistrationID,
		DeviceName:         d.DeviceName,
		IdentityKey:        d.IdentityKeyPub,
		IdentityKeyEd25519: d.IdentityKeyEd25519,
		SignedPreKey: signedPreKeyJSON{
			KeyID:     spk.KeyID,
			PublicKey: spk.PublicKey,
			Signature: spk.Signature,
		},
	}

	// A drained pool is not an error: X3DH proceeds without a one-time prekey,
	// trading some forward secrecy on the session's first message.
	otp, err := s.store.PopOneTimePreKey(r.Context(), d.ID)
	switch {
	case err == nil:
		bundle.OneTimePreKey = &preKeyJSON{KeyID: otp.KeyID, PublicKey: otp.PublicKey}
	case errors.Is(err, store.ErrNoPreKeyAvailable):
		s.log.Warn("one-time prekey pool exhausted", "device_id", d.ID)
	default:
		return nil, err
	}

	return bundle, nil
}

func filterDevices(devices []models.Device, id uuid.UUID) []models.Device {
	for _, d := range devices {
		if d.ID == id {
			return []models.Device{d}
		}
	}
	return nil
}

// handlePreKeyCount lets a device check its own pool depth so it knows when to
// upload more.
func (s *Server) handlePreKeyCount(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	n, err := s.store.CountAvailablePreKeys(r.Context(), claims.DeviceID)
	if err != nil {
		s.log.Error("count prekeys", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"available":        n,
		"low_water_mark":   models.PreKeyLowWaterMark,
		"should_replenish": n < models.PreKeyLowWaterMark,
	}, s.log)
}

// handleUploadPreKeys accepts additional one-time prekeys for the calling
// device.
func (s *Server) handleUploadPreKeys(w http.ResponseWriter, r *http.Request) {
	claims, ok := claimsOrUnauthorized(w, r, s)
	if !ok {
		return
	}

	var req struct {
		OneTimePreKeys []preKeyJSON `json:"one_time_pre_keys"`
	}
	if err := decodeJSON(w, r, &req, maxRegisterBody); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}
	if len(req.OneTimePreKeys) == 0 || len(req.OneTimePreKeys) > maxPreKeyUpload {
		writeErr(w, http.StatusBadRequest, "expected 1-200 one-time prekeys", s.log)
		return
	}

	keys := make([]models.OneTimePreKey, 0, len(req.OneTimePreKeys))
	for _, k := range req.OneTimePreKeys {
		if len(k.PublicKey) != curve25519PubLen {
			writeErr(w, http.StatusBadRequest, "public_key must be 33 bytes", s.log)
			return
		}
		keys = append(keys, models.OneTimePreKey{KeyID: k.KeyID, PublicKey: k.PublicKey})
	}

	if err := s.store.AddOneTimePreKeys(r.Context(), claims.DeviceID, keys); err != nil {
		s.log.Error("add prekeys", "err", err, "device_id", claims.DeviceID)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	s.log.Info("prekeys uploaded", "device_id", claims.DeviceID, "count", len(keys))
	writeJSON(w, http.StatusOK, map[string]any{"accepted": len(keys)}, s.log)
}
