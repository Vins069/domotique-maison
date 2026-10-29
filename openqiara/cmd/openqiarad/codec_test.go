package main

import (
	"io"
	"log/slog"
	"testing"

	"github.com/caligone/openqiara/internal/nal"
)

// The HomeKit camera accessory is published for H.264 only.
func TestHomekitCameraEnabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	for _, c := range []struct {
		enabled bool
		codec   nal.Codec
		want    bool
	}{
		{true, nal.H264, true}, {true, nal.H265, false}, {false, nal.H264, false}, {false, nal.H265, false},
	} {
		if got := homekitCameraEnabled(c.enabled, c.codec, logger); got != c.want {
			t.Errorf("enabled %v, %s: %v", c.enabled, c.codec, got)
		}
	}
}

// The codec part of the diagnostic reading.
func TestCodecDiag(t *testing.T) {
	st := nal.NewState(nal.H264, nil)
	r := codecDiag(st, nil)
	if r["video_codec"] != "H.264" || r["video_codec_configured"] != "H.264" || r["video_codec_mismatch"] != "OFF" {
		t.Fatalf("reading %v", r)
	}
	if _, ok := r["video_nal"]; ok {
		t.Fatal("NAL counts without a hub")
	}
	if codecDiag(nil, nil) != nil {
		t.Fatal("reading without a state")
	}
}
