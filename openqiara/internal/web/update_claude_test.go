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

// A « -claude » version (OpenQIARA Claude V15) refuses an OTA install from the web UI.
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
	if !strings.Contains(rec.Body.String(), "OpenQIARA Claude V15") {
		t.Fatalf("message inattendu : %s", rec.Body.String())
	}
}
