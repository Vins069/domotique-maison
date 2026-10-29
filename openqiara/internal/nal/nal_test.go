package nal_test

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/nal"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

// paramSets picks the first VPS, SPS and PPS of a synthetic stream.
func paramSets(t *testing.T, c nal.Codec) (vps, sps, pps []byte) {
	t.Helper()
	for _, n := range camera.SplitNALUnits(fakehlcamd.Stream(c)) {
		switch {
		case c == nal.H265 && nal.H265Type(n) == nal.H265VPS && vps == nil:
			vps = n
		case nal.Type(c, n) == map[nal.Codec]uint8{nal.H264: nal.H264SPS, nal.H265: nal.H265SPS}[c] && sps == nil:
			sps = n
		case nal.Type(c, n) == map[nal.Codec]uint8{nal.H264: nal.H264PPS, nal.H265: nal.H265PPS}[c] && pps == nil:
			pps = n
		}
	}
	if sps == nil || pps == nil || (c == nal.H265 && vps == nil) {
		t.Fatalf("%s: parameter sets missing (vps %d, sps %d, pps %d)", c, len(vps), len(sps), len(pps))
	}
	return
}

func TestHeaders(t *testing.T) {
	if nal.H264Type([]byte{0x67, 0x42}) != nal.H264SPS || nal.H264Type([]byte{0x65}) != nal.H264IDR || nal.H264Type(nil) != 0 {
		t.Fatal("H.264 types")
	}
	if nal.H265Type([]byte{0x40, 0x01}) != nal.H265VPS || nal.H265Type([]byte{0x42, 0x01}) != nal.H265SPS ||
		nal.H265Type([]byte{0x44, 0x01}) != nal.H265PPS || nal.H265Type([]byte{0x26, 0x01}) != nal.H265IDRWRADL ||
		nal.H265Type([]byte{0x40}) != nal.H265Unreadable {
		t.Fatal("H.265 types")
	}
	for _, c := range []struct {
		codec nal.Codec
		nal   []byte
		key   bool
	}{
		{nal.H264, []byte{0x65, 0x88}, true}, {nal.H264, []byte{0x41, 0x9a}, false}, {nal.H264, []byte{0x67, 0x42}, false},
		{nal.H265, []byte{0x26, 0x01}, true}, {nal.H265, []byte{0x28, 0x01}, true}, {nal.H265, []byte{0x2a, 0x01}, true}, // IDR_W_RADL, IDR_N_LP, CRA
		{nal.H265, []byte{0x20, 0x01}, true}, {nal.H265, []byte{0x2e, 0x01}, true}, // BLA_W_LP (16), RSV_IRAP_VCL23
		{nal.H265, []byte{0x02, 0x01}, false}, {nal.H265, []byte{0x30, 0x01}, false}, {nal.H265, []byte{0x42, 0x01}, false}, // TRAIL_R, RSV_VCL24, SPS
		{nal.H265, []byte{0x26}, false}, // header cut
	} {
		if got := nal.IsKey(c.codec, c.nal); got != c.key {
			t.Errorf("IsKey(%s, % x) = %v", c.codec, c.nal, got)
		}
	}
	if !nal.IsParam(nal.H265, []byte{0x40, 0x01}) || nal.IsParam(nal.H265, []byte{0x46, 0x01}) || !nal.IsAUD(nal.H265, []byte{0x46, 0x01}) ||
		!nal.IsVCL(nal.H265, []byte{0x02, 0x01}) || nal.IsVCL(nal.H265, []byte{0x40, 0x01}) || !nal.IsVCL(nal.H264, []byte{0x41}) {
		t.Fatal("IsParam/IsAUD/IsVCL")
	}
	if c, ok := nal.ParseCodec("H265"); !ok || c != nal.H265 {
		t.Fatal("ParseCodec H265")
	}
	if c, ok := nal.ParseCodec("h.264"); !ok || c != nal.H264 {
		t.Fatal("ParseCodec h.264")
	}
	if _, ok := nal.ParseCodec("h266"); ok {
		t.Fatal("ParseCodec h266")
	}
	if nal.H264.Option() != "h264" || nal.H265.Option() != "h265" || nal.Unknown.String() != "inconnu" {
		t.Fatal("names")
	}
}

// The synthetic streams carry real parameter sets: each SPS is detected as
// its codec, and nothing else of either stream is.
func TestDetectOnSyntheticStreams(t *testing.T) {
	for _, c := range []nal.Codec{nal.H264, nal.H265} {
		_, sps, _ := paramSets(t, c)
		if got := nal.Detect(sps); got != c {
			t.Fatalf("%s SPS detected as %s", c, got)
		}
		if w, h := nal.Dimensions(c, sps); w != 160 || h != 90 {
			t.Fatalf("%s: %dx%d", c, w, h)
		}
		n := 0
		for _, u := range camera.SplitNALUnits(fakehlcamd.Stream(c)) {
			switch nal.Detect(u) {
			case c:
				n++
			case nal.Unknown:
			default:
				t.Fatalf("%s stream: % x detected as the other codec", c, u[:min(4, len(u))])
			}
		}
		if n != 3 { // one SPS before each of the 3 key pictures
			t.Fatalf("%s: %d SPS detected, want 3", c, n)
		}
	}
}

// Look-alikes never decide: an H.264 slice whose header reads as an H.265
// VPS, an H.265 SPS on a layer above 0, a cut SPS.
func TestDetectRejectsLookalikes(t *testing.T) {
	_, sps265, _ := paramSets(t, nal.H265)
	_, sps264, _ := paramSets(t, nal.H264)
	for _, n := range [][]byte{
		{0x41, 0x9a, 0x00, 0x12, 0x34},            // H.264 non-IDR slice: 0x41 reads as H.265 type 32
		append([]byte{0x43, 0x01}, sps265[2:]...), // H.265 SPS with nuh_layer_id's high bit set
		append([]byte{0x42, 0x09}, sps265[2:]...), // nuh_layer_id 1
		append([]byte{0x42, 0x00}, sps265[2:]...), // nuh_temporal_id_plus1 0
		append([]byte{0xe7}, sps264[1:]...),       // forbidden_zero_bit set
		sps264[:3], sps265[:3],                    // too short
		{0x67, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, // an SPS that does not parse
	} {
		if got := nal.Detect(n); got != nal.Unknown {
			t.Errorf("% x detected as %s", n[:min(6, len(n))], got)
		}
	}
	if nal.MayBeSPS([]byte{0x41, 0x9a, 0x00, 0x12}) || !nal.MayBeSPS(sps264) || !nal.MayBeSPS(sps265) {
		t.Fatal("MayBeSPS")
	}
}

func TestStateFollowsTheStream(t *testing.T) {
	s := nal.NewState(nal.H264, quiet)
	changes := make(chan nal.Codec, 4)
	s.OnChange = func(c nal.Codec) { changes <- c }
	if s.Effective() != nal.H264 || s.Detected() != nal.Unknown || s.Mismatch() {
		t.Fatal("initial state")
	}
	_, sps264, _ := paramSets(t, nal.H264)
	vps265, sps265, pps265 := paramSets(t, nal.H265)
	if s.Observe([]byte{0x41, 0x9a, 0x00, 0x12}) || s.Observe(vps265) || s.Observe(pps265) || s.Detected() != nal.Unknown {
		t.Fatal("a slice, a VPS or a PPS decided")
	}
	if !s.Observe(sps265) || s.Detected() != nal.H265 || s.Effective() != nal.H265 || !s.Mismatch() {
		t.Fatal("H.265 SPS not detected")
	}
	if s.Observe(sps265) { // same codec again: nothing changes, no parse
		t.Fatal("change reported twice")
	}
	if !s.Observe(sps264) || s.Detected() != nal.H264 || s.Mismatch() {
		t.Fatal("back to H.264 not detected")
	}
	for _, want := range []nal.Codec{nal.H265, nal.H264} {
		select {
		case got := <-changes:
			if got != want {
				t.Fatalf("OnChange(%s), want %s", got, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("OnChange not called")
		}
	}
	// A configured H.265 stream seen as H.265: no mismatch, one change.
	s2 := nal.NewState(nal.H265, quiet)
	if !s2.Observe(sps265) || s2.Mismatch() || s2.Effective() != nal.H265 {
		t.Fatal("configured H.265")
	}
	if nal.NewState(nal.Unknown, nil).Configured() != nal.H264 {
		t.Fatal("no setting must mean H.264")
	}
}

func TestCounter(t *testing.T) {
	var k nal.Counter
	for _, n := range camera.SplitNALUnits(fakehlcamd.H265()) {
		k.Add(nal.H265, n)
	}
	c := k.Snapshot()
	if c["vps"] != 3 || c["sps"] != 3 || c["pps"] != 3 || c["key"] != 3 || c["aud"] != 90 || c["slice"] != 87 {
		t.Fatalf("H.265 counts %v", c)
	}
	var j nal.Counter
	for _, n := range camera.SplitNALUnits(fakehlcamd.H264()) {
		j.Add(nal.H264, n)
	}
	c = j.Snapshot()
	if c["sps"] != 3 || c["pps"] != 3 || c["key"] != 3 || c["aud"] != 90 || c["slice"] != 87 || c["vps"] != 0 {
		t.Fatalf("H.264 counts %v", c)
	}
	if len(k.Attrs()) != 16 {
		t.Fatal("Attrs")
	}
}
