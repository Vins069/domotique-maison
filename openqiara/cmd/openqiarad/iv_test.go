package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/caligone/openqiara/internal/config"
)

func TestIVDetectionWanted(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "hlcamd_options")
	if !ivDetectionWanted(config.VideoConfig{}, p) {
		t.Fatal("no setting, no options file: the vendor's settings, detection on")
	}
	off := false
	if ivDetectionWanted(config.VideoConfig{IVDetection: &off}, p) {
		t.Fatal(`"iv_detection": false must turn detection off`)
	}
	for body, want := range map[string]bool{
		"--iv-detection 0 --gop-denum 2\n":    false,
		"--gop-denum 2\n":                     true,
		"--iv-detection 1\n":                  true,
		"--iv-detection 0 --iv-detection 1\n": true, // the last one counts, as for hlcamd
		"--iv-detection":                      true, // no value: ignored
	} {
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := ivDetectionWanted(config.VideoConfig{}, p); got != want {
			t.Errorf("%q: %v, want %v", body, got, want)
		}
	}
}
