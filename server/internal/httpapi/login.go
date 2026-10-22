package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
	"github.com/vectrixsecurity/frogster/server/internal/ratelimit"
	"github.com/vectrixsecurity/frogster/server/internal/store"
)

const maxLoginBody = 64 << 10

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`

	// Device is supplied when logging in from a new installation. Omitting it
	// requires DeviceID, which resumes an existing device.
	Device   *deviceJSON `json:"device,omitempty"`
	DeviceID string      `json:"device_id,omitempty"`
}

// handleLogin authenticates a user and issues tokens for a device.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := decodeJSON(w, r, &req, maxLoginBody); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed request body", s.log)
		return
	}

	user, err := s.store.UserByUsername(r.Context(), req.Username)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			// Same response and rough timing as a wrong password, so that this
			// endpoint cannot be used to enumerate accounts.
			auth.VerifyPassword(dummyBcryptHash, req.Password)
			writeErr(w, http.StatusUnauthorized, "invalid credentials", s.log)
			return
		}
		s.log.Error("lookup user", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	if err := auth.VerifyPassword(user.PasswordHash, req.Password); err != nil {
		s.log.Info("failed login", "user_id", user.ID)
		writeErr(w, http.StatusUnauthorized, "invalid credentials", s.log)
		return
	}

	device, err := s.resolveLoginDevice(r, user, &req)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error(), s.log)
		return
	}

	s.log.Info("user logged in", "user_id", user.ID, "device_id", device.ID)
	s.issueTokens(w, r, user, device)
}

// resolveLoginDevice returns the device this login is for, registering a new
// one when the client supplied fresh key material.
func (s *Server) resolveLoginDevice(r *http.Request, user *models.User, req *loginRequest) (*models.Device, error) {
	switch {
	case req.Device != nil:
		if err := validateDevice(req.Device); err != nil {
			return nil, err
		}
		device, spk, otps := buildDeviceModels(req.Device)
		device.UserID = user.ID
		if err := s.store.AddDevice(r.Context(), device, spk, otps); err != nil {
			s.log.Error("add device", "err", err, "user_id", user.ID)
			return nil, errBadKey("could not register device")
		}

		// Tell the user's other devices and their contacts. Detached from the
		// request context so the fan-out is not cancelled when this response
		// is written.
		if s.notifier != nil {
			go s.notifier.NotifyDeviceAdded(
				context.WithoutCancel(r.Context()), user.ID, device.ID,
			)
		}
		return device, nil

	case req.DeviceID != "":
		id, err := parseUUID(req.DeviceID)
		if err != nil {
			return nil, errBadKey("device_id is not a valid UUID")
		}
		device, err := s.store.DeviceByID(r.Context(), id)
		if err != nil {
			return nil, errBadKey("unknown device")
		}
		if device.UserID != user.ID || !device.IsActive() {
			return nil, errBadKey("unknown device")
		}
		return device, nil

	default:
		return nil, errBadKey("either device or device_id is required")
	}
}

// issueTokens mints an access/refresh pair and records the session.
func (s *Server) issueTokens(w http.ResponseWriter, r *http.Request, user *models.User, device *models.Device) {
	access, err := s.tokens.IssueAccess(user.ID, device.ID, user.TokenVersion)
	if err != nil {
		s.log.Error("issue access token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	refresh, err := auth.NewOpaqueToken()
	if err != nil {
		s.log.Error("generate refresh token", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	now := time.Now()
	sess := &models.ActiveSession{
		UserID:      user.ID,
		DeviceID:    device.ID,
		RefreshHash: auth.HashToken(refresh),
		UserAgent:   truncate(r.UserAgent(), 256),
		IPHash:      auth.HashIP(ratelimit.ClientIP(r), s.cfg.JWTSecret),
		ExpiresAt:   now.Add(s.tokens.RefreshTTL()),
		LastUsedAt:  now,
	}
	if err := s.store.CreateSession(r.Context(), sess); err != nil {
		s.log.Error("create session", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal error", s.log)
		return
	}

	writeJSON(w, http.StatusOK, tokenResponse{
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresAt:    now.Add(s.tokens.AccessTTL()),
		UserID:       user.ID.String(),
		DeviceID:     device.ID.String(),
	}, s.log)
}

// dummyBcryptHash is compared against when the username is unknown, so that
// the response time resembles a real verification.
const dummyBcryptHash = "$2a$12$C6UzMDM.H6dfI/f/IKcEe.k1Aq7yYlqbCUnLLBoPKQjZBHRxKzsHy"

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
