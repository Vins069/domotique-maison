package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/caligone/openqiara/internal/config"
	"github.com/caligone/openqiara/internal/ota"
)

// A « -claude » version (OpenQIARA Claude) refuses an OTA install from the web UI.
func TestUpdateInstallBloqueePourVersionClaude(t *testing.T) {
	store := config.NewStore(filepath.Join(t.TempDir(), "config.json"))
	staticFS := fstest.MapFS{"static/index.html": &fstest.MapFile{Data: []byte("<html>ui</html>")}}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := NewServer(&stubCamera{}, store, func() bool { return false }, &MQTTCallbacks{}, staticFS, logger)
	v := "v0.1.0-rc.22-claude-v15 (claude-v15, 2026-10-29)"
	s.SetVersion(v)
	c := ota.NewClient(v, logger)
	s.SetOTA(c, ota.NewInstaller(c, ota.InstallConfig{}, nil))
	mux, err := s.routes()
	if err != nil {
		t.Fatalf("routes: %v", err)
	}
	h := s.basicAuth(mux)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/commands/update/install", strings.NewReader(`{"tag":"v0.1.0-rc.23"}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("code %d, attendu 409 ; corps %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "OpenQIARA Claude") {
		t.Fatalf("message inattendu : %s", rec.Body.String())
	}
}

// L'installation automatique ne peut pas être activée pour une version locale (409) ; la couper
// reste possible ; une version publiée l'active normalement.
func TestUpdateAutoBloqueePourVersionClaude(t *testing.T) {
	// la machine de test n'a pas Qiara Plus, quelle qu'elle soit (sur la caméra, le troisième cas donnerait 409)
	installed := qplusInstalled
	qplusInstalled = func() bool { return false }
	defer func() { qplusInstalled = installed }()
	for _, c := range []struct {
		version, body string
		want          int
	}{
		{"v0.1.0-rc.23-claude-v16 (claude-v16, 2026-11-01)", `{"auto":true}`, http.StatusConflict},
		{"v0.1.0-rc.23-claude-v16 (claude-v16, 2026-11-01)", `{"auto":false}`, http.StatusOK},
		{"v0.1.0-rc.23 (ad49dff, 2026-10-31)", `{"auto":true}`, http.StatusOK},
	} {
		store := config.NewStore(filepath.Join(t.TempDir(), "config.json"))
		staticFS := fstest.MapFS{"static/index.html": &fstest.MapFile{Data: []byte("<html>ui</html>")}}
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		s := NewServer(&stubCamera{}, store, func() bool { return false }, &MQTTCallbacks{}, staticFS, logger)
		s.SetVersion(c.version)
		mux, err := s.routes()
		if err != nil {
			t.Fatalf("routes: %v", err)
		}
		req := httptest.NewRequest(http.MethodPut, "/api/v1/config/update", strings.NewReader(c.body))
		rec := httptest.NewRecorder()
		s.basicAuth(mux).ServeHTTP(rec, req)
		if rec.Code != c.want {
			t.Fatalf("%s %s : code %d, attendu %d ; corps %s", c.version, c.body, rec.Code, c.want, rec.Body.String())
		}
		if got := store.Get().Update.Auto; c.want == http.StatusConflict && got {
			t.Fatalf("%s : auto enregistré malgré le refus", c.version)
		}
	}
}
