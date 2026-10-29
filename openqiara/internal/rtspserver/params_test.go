package rtspserver

import (
	"bytes"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/bluenviron/gortsplib/v5/pkg/format"
)

func TestParamsRoundTripAndDescribe(t *testing.T) {
	path := filepath.Join(t.TempDir(), "params")
	sps := []byte{0x67, 0x42, 0xc0, 0x28, 0xda, 0x01, 0xe0}
	pps := []byte{0x68, 0xce, 0x3c, 0x80}

	if _, _, ok := loadParams(path); ok {
		t.Fatal("missing file must not load")
	}
	if err := saveParams(path, sps, pps); err != nil {
		t.Fatal(err)
	}
	gs, gp, ok := loadParams(path)
	if !ok || !bytes.Equal(gs, sps) || !bytes.Equal(gp, pps) {
		t.Fatalf("round trip failed: %x %x %v", gs, gp, ok)
	}

	s := &Server{
		cfg:   Config{ParamsFile: path},
		log:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		forma: &format.H264{PayloadTyp: 96, PacketizationMode: 1},
	}
	s.sps, s.pps = sps, pps
	s.publishParams()
	fmtp := s.forma.FMTP()
	if fmtp["profile-level-id"] != "42C028" || fmtp["sprop-parameter-sets"] == "" {
		t.Fatalf("FMTP not updated: %v", fmtp)
	}
}

// TestKeepAUResync: after a dropped packet, frames are skipped
// until the next key frame, which goes out and ends the wait.
func TestKeepAUResync(t *testing.T) {
	s := &Server{}
	if !s.keepAU(false) || !s.keepAU(true) {
		t.Fatal("frames skipped with no drop")
	}
	s.resync.Store(true)
	if s.keepAU(false) || s.keepAU(false) {
		t.Fatal("frame sent while waiting for a key frame")
	}
	if !s.keepAU(true) {
		t.Fatal("key frame not sent")
	}
	if !s.keepAU(false) {
		t.Fatal("frame after the key frame skipped")
	}
	if n := s.skipped.Load(); n != 2 {
		t.Fatalf("skipped = %d, want 2", n)
	}
}
