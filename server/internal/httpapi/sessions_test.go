package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/vectrixsecurity/frogster/server/internal/auth"
	"github.com/vectrixsecurity/frogster/server/internal/models"
)

// The sessions screen names the device and the app version it last used,
// and a refresh from an updated app replaces an older user agent.
func TestSessionsShowDeviceAndClient(t *testing.T) {
	f := newAPI(t)
	u := f.user("sess")
	claims, err := f.tokens.Parse(u.token)
	if err != nil {
		t.Fatal(err)
	}

	refresh, _ := auth.NewOpaqueToken()
	if err := f.st.CreateSession(context.Background(), &models.ActiveSession{
		UserID:      u.id,
		DeviceID:    claims.DeviceID,
		RefreshHash: auth.HashToken(refresh),
		UserAgent:   "Dart/3.12 (dart:io)",
		ExpiresAt:   time.Now().Add(time.Hour),
		LastUsedAt:  time.Now(),
	}); err != nil {
		t.Fatal(err)
	}

	body, _ := json.Marshal(map[string]string{"refresh_token": refresh})
	req, _ := http.NewRequest("POST", f.srv.URL+"/v1/token/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "Frogster/1.0.2 (android)")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("refresh: %d", resp.StatusCode)
	}

	var out struct {
		Sessions []sessionJSON `json:"sessions"`
	}
	if status := f.call(u, "GET", "/v1/sessions", nil, &out); status != http.StatusOK {
		t.Fatalf("list: %d", status)
	}
	if len(out.Sessions) != 1 {
		t.Fatalf("got %d sessions", len(out.Sessions))
	}
	s := out.Sessions[0]
	if s.DeviceName != "d" || s.UserAgent != "Frogster/1.0.2 (android)" || !s.Current {
		t.Fatalf("session = %+v", s)
	}
}
