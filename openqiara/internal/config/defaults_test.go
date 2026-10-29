package config

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The installer's defaults land where the configuration says nothing, once,
// and never override a choice already made on the camera.
func TestApplyDefaultsFile(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "openqiara.json")
	defPath := filepath.Join(dir, "openqiara-defauts.json")
	// An existing camera: MQTT set up, the image settings locked and RTSP
	// turned off on purpose.
	if err := os.WriteFile(cfgPath, []byte(`{"mqtt":{"broker":"tcp://ha:1883","topic_prefix":"openqiara"},"video":{"lock":true},"rtsp":{"enabled":false}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	def := `{"video":{"lock":false,"codec":"h265","bitrate":2500000,"gop_denum":1,"iv_detection":true},"rtsp_enabled":true}`
	if err := os.WriteFile(defPath, []byte(def), 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewStore(cfgPath)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	set, err := s.ApplyDefaultsFile(defPath)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(set, ",")
	if got != "video.codec,video.bitrate,video.gop_denum,video.iv_detection" {
		t.Fatalf("fields set: %s", got)
	}
	c := s.Get()
	if !c.Video.Locked() {
		t.Fatal("the lock chosen on the camera was overridden")
	}
	if c.Video.Codec != "h265" || c.Video.Bitrate != 2500000 || c.Video.GopDenum != 1 || !c.Video.IVWanted() {
		t.Fatalf("defaults not applied: %+v", c.Video)
	}
	if c.RTSP.Enabled {
		t.Fatal("RTSP turned off on the camera was turned back on by the defaults")
	}
	if c.MQTT.Broker != "tcp://ha:1883" {
		t.Fatal("MQTT settings lost")
	}
	// Saved, and the file set aside: a second start does nothing.
	if _, err := os.Stat(defPath); !os.IsNotExist(err) {
		t.Fatal("defaults file still in place")
	}
	if _, err := os.Stat(defPath + ".applique"); err != nil {
		t.Fatal("defaults file not renamed .applique")
	}
	b, _ := os.ReadFile(cfgPath)
	var onDisk Config
	if err := json.Unmarshal(b, &onDisk); err != nil || onDisk.Video.Bitrate != 2500000 {
		t.Fatalf("not saved: %s", b)
	}
	if set, err := s.ApplyDefaultsFile(defPath); err != nil || set != nil {
		t.Fatalf("second pass: %v %v", set, err)
	}
}

// Out-of-range numbers are not applied; a broken file is set aside, not fatal.
func TestApplyDefaultsFileBounds(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(filepath.Join(dir, "openqiara.json"))
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "d.json")
	os.WriteFile(p, []byte(`{"video":{"bitrate":90000000,"gop_denum":99,"lock":false}}`), 0o644)
	set, err := s.ApplyDefaultsFile(p)
	if err != nil || strings.Join(set, ",") != "video.lock" {
		t.Fatalf("bounds: %v %v", set, err)
	}
	if v := s.Get().Video; v.Bitrate != 0 || v.GopDenum != 0 || v.Locked() {
		t.Fatalf("out of range applied: %+v", v)
	}
	os.WriteFile(p, []byte(`{"video":`), 0o644)
	if _, err := s.ApplyDefaultsFile(p); err == nil {
		t.Fatal("broken file accepted")
	}
	if _, err := os.Stat(p + ".refuse"); err != nil {
		t.Fatal("broken file not set aside")
	}
}

// A settings change replaces what the configuration says, H.265 back to
// H.264 included, and the image settings can be locked again.
func TestApplySettingsFile(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "openqiara.json")
	os.WriteFile(cfgPath, []byte(`{"video":{"lock":false,"codec":"h265","bitrate":2500000,"gop_denum":1},"rtsp":{"enabled":true}}`), 0o600)
	s := NewStore(cfgPath)
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "openqiara-reglages.json")
	os.WriteFile(p, []byte(`{"video":{"codec":"h264","bitrate":1500000,"lock":true,"iv_detection":false}}`), 0o644)
	set, err := s.ApplySettingsFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(set, ",") != "video.lock,video.codec,video.bitrate,video.iv_detection" {
		t.Fatalf("fields set: %v", set)
	}
	v := s.Get().Video
	if v.Codec != "h264" || v.Bitrate != 1500000 || v.GopDenum != 1 || !v.Locked() || v.IVWanted() || !s.Get().RTSP.Enabled {
		t.Fatalf("settings: %+v", v)
	}
	if _, err := os.Stat(p + ".applique"); err != nil {
		t.Fatal("settings file not set aside")
	}
}

// A settings file is kept in place when the configuration cannot be saved,
// so that the next start tries again.
func TestApplySettingsFileSaveFails(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, "cfg")
	os.Mkdir(cfgDir, 0o755)
	s := NewStore(filepath.Join(cfgDir, "openqiara.json"))
	if err := s.Load(); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "openqiara-reglages.json")
	os.WriteFile(p, []byte(`{"video":{"codec":"h264"}}`), 0o644)
	os.RemoveAll(cfgDir) // the save (temporary file, then rename) can only fail now
	if _, err := s.ApplySettingsFile(p); err == nil {
		t.Fatal("save failure not reported")
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatal("settings file set aside although nothing was saved")
	}
}

// Contract with the installer: the defaults file written by the
// distribution's commun.sh (fichier_defauts) is accepted as is.
func TestInstallerDefaultsContract(t *testing.T) {
	commun, _ := filepath.Abs("../../../installation/commun.sh")
	if _, err := os.Stat(commun); err != nil {
		t.Skip("distribution installer not found next to the source tree")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not found")
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "openqiara-defauts.json")
	for _, tc := range []struct {
		env, codec string
		iv, lock   bool
		gop        int
	}{
		{"CODEC=h265 DEBIT=2500000 IMAGE_CLE=1 DETECTION=oui REGLAGES=deverrouilles", "h265", true, false, 1},
		{"CODEC=h264 DEBIT=1500000 IMAGE_CLE=2 DETECTION=non REGLAGES=verrouilles", "h264", false, true, 2},
	} {
		cmd := exec.Command(bash, "-c", ". \"$1\"; "+tc.env+"; fichier_defauts \"$2\"", "x", commun, out)
		if b, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("fichier_defauts: %v %s", err, b)
		}
		s := NewStore(filepath.Join(dir, "openqiara.json"))
		os.Remove(filepath.Join(dir, "openqiara.json"))
		if err := s.Load(); err != nil {
			t.Fatal(err)
		}
		set, err := s.ApplyDefaultsFile(out)
		if err != nil || len(set) != 5 {
			raw, _ := os.ReadFile(out + ".refuse")
			t.Fatalf("installer defaults refused: %v %v %s", set, err, raw)
		}
		v := s.Get().Video
		if v.Codec != tc.codec || v.GopDenum != tc.gop || v.IVWanted() != tc.iv || v.Locked() != tc.lock || v.Bitrate < MinBitrate {
			t.Fatalf("%s: %+v", tc.env, v)
		}
		os.Remove(out + ".applique")
	}
}

// The boot script reads the same bounds as the configuration: a value Go
// accepts must reach hlcamd, and one it refuses must not.
func TestBootScriptBounds(t *testing.T) {
	b, err := os.ReadFile("../../scripts/camera_boot.sh")
	if err != nil {
		t.Skip("camera_boot.sh not found")
	}
	s := string(b)
	for _, want := range []string{
		fmt.Sprintf(`"$BITRATE" -ge %d ] && [ "$BITRATE" -le %d ]`, MinBitrate, MaxBitrate),
		fmt.Sprintf(`"$GOPDENUM" -ge 1 ] && [ "$GOPDENUM" -le %d ]`, MaxGopDenum),
	} {
		if !strings.Contains(s, want) {
			t.Errorf("camera_boot.sh does not check %s", want)
		}
	}
}
