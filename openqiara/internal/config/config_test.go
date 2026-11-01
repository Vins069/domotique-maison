package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/caligone/openqiara/internal/nal"
)

// video.codec: absent is H.264, h265 is H.265, anything else is
// H.264 and flagged.
func TestVideoCodecSetting(t *testing.T) {
	for _, c := range []struct {
		file  string
		want  nal.Codec
		known bool
	}{
		{`{}`, nal.H264, true},
		{`{"video":{"lock":false}}`, nal.H264, true},
		{`{"video":{"codec":"h264"}}`, nal.H264, true},
		{`{"video":{"codec":"h265"}}`, nal.H265, true},
		{`{"video":{"codec":"H265"}}`, nal.H265, true},
		{`{"video":{"codec":"hevc"}}`, nal.H265, true},
		{`{"video":{"codec":"mpeg2"}}`, nal.H264, false},
	} {
		path := filepath.Join(t.TempDir(), "config.json")
		if err := os.WriteFile(path, []byte(c.file), 0o644); err != nil {
			t.Fatal(err)
		}
		s := NewStore(path)
		if err := s.Load(); err != nil {
			t.Fatal(err)
		}
		got, known := s.Get().Video.VideoCodec()
		if got != c.want || known != c.known {
			t.Errorf("%s: %s (known %v), want %s (known %v)", c.file, got, known, c.want, c.known)
		}
	}
	// The setting survives a save untouched; absent, it stays absent.
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"video":{"codec":"h265"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	if err := s.Update(func(c *Config) { c.MQTT.Broker = "tcp://192.0.2.1:1883" }); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), `"codec": "h265"`) {
		t.Fatalf("setting lost on save:\n%s", b)
	}
}

func TestStoreLoadDefault(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(filepath.Join(dir, "config.json"))

	if err := s.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}

	cfg := s.Get()
	if cfg.MQTT.TopicPrefix != "openqiara" {
		t.Errorf("TopicPrefix = %q, want openqiara", cfg.MQTT.TopicPrefix)
	}
}

func TestStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	s := NewStore(path)

	if err := s.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}

	err := s.Update(func(c *Config) {
		c.MQTT.Broker = "tcp://10.0.0.1:1883"
		c.Sensors = append(c.Sensors, SensorEntry{
			ID: 33, Type: "DWS", Model: "HOMELABDWS00ACFD", Label: "Porte entrée",
		})
	})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	s2 := NewStore(path)
	if err := s2.Load(); err != nil {
		t.Fatalf("Load after save: %v", err)
	}

	cfg := s2.Get()
	if cfg.MQTT.Broker != "tcp://10.0.0.1:1883" {
		t.Errorf("Broker = %q", cfg.MQTT.Broker)
	}
	if len(cfg.Sensors) != 1 || cfg.Sensors[0].ID != 33 {
		t.Errorf("Sensors = %+v", cfg.Sensors)
	}
}

func TestStoreLoadExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	data := `{"mqtt":{"broker":"tcp://test:1883","topic_prefix":"custom"}}`
	if err := os.WriteFile(path, []byte(data), 0644); err != nil {
		t.Fatal(err)
	}

	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}

	cfg := s.Get()
	if cfg.MQTT.Broker != "tcp://test:1883" {
		t.Errorf("Broker = %q", cfg.MQTT.Broker)
	}
	if cfg.MQTT.TopicPrefix != "custom" {
		t.Errorf("TopicPrefix = %q", cfg.MQTT.TopicPrefix)
	}
}

func TestHashAdminPassword(t *testing.T) {
	hash, err := HashAdminPassword("hunter2")
	if err != nil {
		t.Fatalf("HashAdminPassword: %v", err)
	}
	if hash == "" {
		t.Fatal("hash is empty")
	}
	if hash == "hunter2" {
		t.Fatal("hash equals plaintext")
	}

	ac := AdminConfig{PasswordHash: hash}
	if !ac.CheckPassword("hunter2") {
		t.Error("CheckPassword should accept the correct password")
	}
	if ac.CheckPassword("hunter3") {
		t.Error("CheckPassword should reject a wrong password")
	}
	if ac.CheckPassword("") {
		t.Error("CheckPassword should reject empty")
	}

	// Empty plaintext → empty hash, AuthEnabled=false.
	emptyHash, _ := HashAdminPassword("")
	if emptyHash != "" {
		t.Errorf("HashAdminPassword(\"\") = %q, want empty", emptyHash)
	}
	if (AdminConfig{}).AuthEnabled() {
		t.Error("empty config should not have auth enabled")
	}
}

func TestAdminConfigLegacyFallback(t *testing.T) {
	// Config legacy : Password en clair, pas de hash. CheckPassword doit
	// fonctionner en attendant la migration.
	ac := AdminConfig{Password: "legacy123"}
	if !ac.AuthEnabled() {
		t.Error("legacy config should report auth enabled")
	}
	if !ac.CheckPassword("legacy123") {
		t.Error("legacy CheckPassword should accept the clear-text match")
	}
	if ac.CheckPassword("wrong") {
		t.Error("legacy CheckPassword should reject wrong")
	}
}

func TestStoreLoadMigratesLegacyPassword(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	// Écrit un config legacy avec password en clair.
	data := `{"admin":{"password":"legacy"}}`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}

	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}

	cfg := s.Get()
	if cfg.Admin.Password != "" {
		t.Errorf("legacy Password field still set after migration: %q", cfg.Admin.Password)
	}
	if cfg.Admin.PasswordHash == "" {
		t.Error("PasswordHash should be set after migration")
	}
	if !cfg.Admin.CheckPassword("legacy") {
		t.Error("migrated config should accept the original password")
	}
}

// TestGetSharesNothing: an Update that edits a sensor in place must not
// show through a copy taken before (the radio client reads copies while
// the web server edits).
func TestGetSharesNothing(t *testing.T) {
	s := NewStore(filepath.Join(t.TempDir(), "config.json"))
	if err := s.Update(func(c *Config) { c.Sensors = []SensorEntry{{ID: 14, KPDCodes: []KPDCode{{Password: "1234"}}}} }); err != nil {
		t.Fatal(err)
	}
	before := s.Get()
	if err := s.Update(func(c *Config) { c.Sensors[0].KPDCodes[0].Password = "5678" }); err != nil {
		t.Fatal(err)
	}
	if got := before.Sensors[0].KPDCodes[0].Password; got != "1234" {
		t.Errorf("copy changed to %q", got)
	}
}

// TestFailedUpdateChangesNothing: when the config cannot be written, the
// file and the store keep the previous config.
func TestFailedUpdateChangesNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	s := NewStore(path)
	if err := s.Update(func(c *Config) { c.DeletedIDs = []int{7} }); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil { // no new file in dir
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(dir, 0o700) }()
	if err := s.Update(func(c *Config) { c.DeletedIDs = []int{8} }); err == nil {
		t.Skip("directory still writable (running as root?)")
	}
	if len(s.Get().DeletedIDs) != 1 || s.Get().DeletedIDs[0] != 7 {
		t.Errorf("store kept %v, want [7]", s.Get().DeletedIDs)
	}
	reread := NewStore(path)
	if err := reread.Load(); err != nil || len(reread.Get().DeletedIDs) != 1 || reread.Get().DeletedIDs[0] != 7 {
		t.Errorf("file holds %v (%v), want [7]", reread.Get().DeletedIDs, err)
	}
}

// TestMigrateNightAlarm: fbxhome's night_alarm flag, which overrode
// night_allowed, becomes its opposite night_allowed; the other fbxhome
// flags are dropped.
func TestMigrateNightAlarm(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	old := `{"sensors": [
		{"id": 17, "type": "PIR", "night_alarm": false, "day_alarm": true},
		{"id": 23, "type": "DWS", "night_allowed": true, "night_alarm": true},
		{"id": 29, "type": "SRN", "night_allowed": true}
	]}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	want := map[int]bool{17: true, 23: false, 29: true}
	for _, se := range s.Get().Sensors {
		if se.NightAllowed != want[se.ID] {
			t.Errorf("sensor %d: night_allowed = %v, want %v", se.ID, se.NightAllowed, want[se.ID])
		}
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	saved, _ := os.ReadFile(path)
	if strings.Contains(string(saved), "night_alarm") || strings.Contains(string(saved), "day_alarm") {
		t.Errorf("fbxhome flags still saved:\n%s", saved)
	}
}

// TestMigrateKPDCode: a keypad's single kpd_code becomes its code list,
// and is no longer saved; a file that has kpd_codes keeps them.
func TestMigrateKPDCode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	old := `{"sensors": [
		{"id": 14, "type": "KPD", "kpd_code": "1234", "kpd_code_label": "Moi"},
		{"id": 15, "type": "KPD", "kpd_code": "1234", "kpd_codes": [{"password": "1234"}, {"password": "5678"}]},
		{"id": 23, "type": "DWS"}
	]}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	want := map[int][]KPDCode{
		14: {{Password: "1234", Label: "Moi"}},
		15: {{Password: "1234"}, {Password: "5678"}},
		23: nil,
	}
	for _, se := range s.Get().Sensors {
		if !slices.Equal(se.KPDCodes, want[se.ID]) {
			t.Errorf("sensor %d: codes = %+v, want %+v", se.ID, se.KPDCodes, want[se.ID])
		}
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	saved, _ := os.ReadFile(path)
	// the first code is still written to kpd_code, for a binary
	// older than rc.23 after a roll back (it reads only kpd_code).
	var legacy struct {
		Sensors []struct {
			ID    int    `json:"id"`
			Code  string `json:"kpd_code"`
			Label string `json:"kpd_code_label"`
		} `json:"sensors"`
	}
	if err := json.Unmarshal(saved, &legacy); err != nil {
		t.Fatal(err)
	}
	wantLegacy := map[int][2]string{14: {"1234", "Moi"}, 15: {"1234", ""}, 23: {"", ""}}
	for _, l := range legacy.Sensors {
		if got := [2]string{l.Code, l.Label}; got != wantLegacy[l.ID] {
			t.Errorf("sensor %d: kpd_code/label saved = %q, want %q", l.ID, got, wantLegacy[l.ID])
		}
	}
	if n := strings.Count(string(saved), `"sensors"`); n != 1 {
		t.Errorf("%d sensors keys saved, want 1:\n%s", n, saved)
	}
	// Read back: kpd_codes wins over kpd_code.
	s2 := NewStore(path)
	if err := s2.Load(); err != nil {
		t.Fatal(err)
	}
	for _, se := range s2.Get().Sensors {
		if !slices.Equal(se.KPDCodes, want[se.ID]) {
			t.Errorf("reload, sensor %d: codes = %+v, want %+v", se.ID, se.KPDCodes, want[se.ID])
		}
	}
}

// TestVideoLockedByDefault: the image settings are read-only
// unless openqiara.json says "lock": false, and a save keeps the choice.
func TestVideoLockedByDefault(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	for _, c := range []struct {
		name, json string
		locked     bool
	}{
		{"absent", `{}`, true},
		{"video without lock", `{"video":{}}`, true},
		{"lock true", `{"video":{"lock":true}}`, true},
		{"lock false", `{"video":{"lock":false}}`, false},
	} {
		if err := os.WriteFile(path, []byte(c.json), 0o600); err != nil {
			t.Fatal(err)
		}
		s := NewStore(path)
		if err := s.Load(); err != nil {
			t.Fatalf("%s: Load: %v", c.name, err)
		}
		if got := s.Get().Video.Locked(); got != c.locked {
			t.Errorf("%s: Locked() = %v, want %v", c.name, got, c.locked)
		}
	}
	// An explicit unlock survives a round trip through the store.
	if err := os.WriteFile(path, []byte(`{"video":{"lock":false}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	s := NewStore(path)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), `"lock": false`) && !strings.Contains(string(b), `"lock":false`) {
		t.Errorf("unlock lost on save: %s", b)
	}
}
