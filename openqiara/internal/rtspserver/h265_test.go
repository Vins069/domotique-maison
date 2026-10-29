package rtspserver

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph265"
	"github.com/pion/rtp"

	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
)

// bench is an RTSP server on a fake hlcamd playing a synthetic stream:
// the codec configured may differ from the stream's.
type bench struct {
	addr  string
	state *nal.State
	dir   string
	srv   *Server
}

func newBench(t *testing.T, configured, stream nal.Codec) *bench {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	state := nal.NewState(configured, logger)
	hub := mediahub.New("fake", fakehlcamd.Source(stream, fakehlcamd.Stream(stream), 120, logger), nil, logger)
	hub.SetCodecState(state)
	dir := t.TempDir()
	srv := New(Config{Listen: addr, Path: "openqiara",
		ParamsFile: filepath.Join(dir, "h264"), ParamsFileH265: filepath.Join(dir, "h265")}, hub, logger)
	srv.SetCodecState(state)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if err := srv.Start(ctx); err != nil {
		t.Fatal(err)
	}
	return &bench{addr: addr, state: state, dir: dir, srv: srv}
}

// decoder is what turns the packets of either codec back into access units.
type decoder interface {
	Decode(*rtp.Packet) ([][]byte, error)
}

func newDecoder(t *testing.T, f format.Format) (decoder, nal.Codec) {
	t.Helper()
	switch f := f.(type) {
	case *format.H264:
		d, err := f.CreateDecoder()
		if err != nil {
			t.Fatal(err)
		}
		return d, nal.H264
	case *format.H265:
		d, err := f.CreateDecoder()
		if err != nil {
			t.Fatal(err)
		}
		return d, nal.H265
	}
	t.Fatalf("video format %T", f)
	return nil, nal.Unknown
}

// play reads the stream with a real client for up to wait or n access
// units, and returns the video format advertised and the access units
// decoded. closed is whether the server ended the session.
func (b *bench) play(t *testing.T, n int, wait time.Duration) (f format.Format, aus [][][]byte, closed bool) {
	t.Helper()
	c := gortsplib.Client{Scheme: "rtsp", Host: b.addr}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	u, err := base.ParseURL("rtsp://" + b.addr + "/openqiara")
	if err != nil {
		t.Fatal(err)
	}
	desc, _, err := c.Describe(u)
	if err != nil {
		t.Fatal(err)
	}
	var medi *description.Media
	for _, m := range desc.Medias {
		if m.Type == description.MediaTypeVideo {
			medi = m
		}
	}
	if medi == nil || len(medi.Formats) != 1 {
		t.Fatalf("medias %+v", desc.Medias)
	}
	f = medi.Formats[0]
	dec, _ := newDecoder(t, f)
	if err := c.SetupAll(desc.BaseURL, desc.Medias); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	done := make(chan struct{})
	c.OnPacketRTP(medi, f, func(pkt *rtp.Packet) {
		au, err := dec.Decode(pkt)
		if errors.Is(err, rtph264.ErrMorePacketsNeeded) || errors.Is(err, rtph265.ErrMorePacketsNeeded) {
			return
		}
		if err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		mu.Lock()
		aus = append(aus, au)
		if len(aus) == n {
			close(done)
		}
		mu.Unlock()
	})
	if _, err := c.Play(nil); err != nil {
		t.Fatal(err)
	}
	ended := make(chan error, 1)
	go func() { ended <- c.Wait() }()
	select {
	case <-done:
	case err := <-ended:
		closed = err != nil
	case <-time.After(wait):
	}
	mu.Lock()
	defer mu.Unlock()
	return f, aus, closed
}

// kinds counts the parameter sets and key pictures of an access unit.
func kinds(c nal.Codec, au [][]byte) (vps, sps, pps, key int) {
	for _, n := range au {
		switch {
		case c == nal.H265 && nal.H265Type(n) == nal.H265VPS:
			vps++
		case nal.Type(c, n) == paramTypeSPS(c):
			sps++
		case nal.Type(c, n) == paramTypePPS(c):
			pps++
		case nal.IsKey(c, n):
			key++
		}
	}
	return
}

func lines(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return len(strings.Fields(string(b)))
}

// An H.265 camera served as configured: the description is H265, the
// first access unit a reader gets is a key picture with VPS, SPS and PPS,
// the parameter sets are persisted and advertised to the next DESCRIBE.
func TestRTSPServesH265(t *testing.T) {
	b := newBench(t, nal.H265, nal.H265)
	f, aus, closed := b.play(t, 35, 15*time.Second)
	if _, ok := f.(*format.H265); !ok || closed {
		t.Fatalf("format %T, closed %v", f, closed)
	}
	if len(aus) < 35 {
		t.Fatalf("%d access units", len(aus))
	}
	if vps, sps, pps, key := kinds(nal.H265, aus[0]); vps != 1 || sps != 1 || pps != 1 || key != 1 {
		t.Fatalf("first access unit: vps %d sps %d pps %d key %d", vps, sps, pps, key)
	}
	keys := 0
	for _, au := range aus {
		if _, _, _, k := kinds(nal.H265, au); k > 0 {
			keys++
		}
	}
	if keys < 2 {
		t.Fatalf("%d key pictures in %d access units", keys, len(aus))
	}
	if lines(t, filepath.Join(b.dir, "h265")) != 3 || lines(t, filepath.Join(b.dir, "h264")) != 0 {
		t.Fatal("H.265 parameter sets not persisted as three lines")
	}
	f2, _, _ := b.play(t, 1, 5*time.Second)
	if h := f2.(*format.H265); len(h.VPS) == 0 || len(h.SPS) == 0 || len(h.PPS) == 0 || h.FMTP()["sprop-vps"] == "" {
		t.Fatalf("parameter sets not advertised: %v", h.FMTP())
	}
	if b.state.Mismatch() || b.state.Detected() != nal.H265 {
		t.Fatal("state")
	}
}

// The H.264 path on the synthetic stream, as earlier versions served it: SPS and
// PPS ahead of the IDR, profile-level-id advertised once seen.
func TestRTSPServesH264Stream(t *testing.T) {
	b := newBench(t, nal.H264, nal.H264)
	f, aus, closed := b.play(t, 35, 15*time.Second)
	if _, ok := f.(*format.H264); !ok || closed {
		t.Fatalf("format %T, closed %v", f, closed)
	}
	if len(aus) < 35 {
		t.Fatalf("%d access units", len(aus))
	}
	if vps, sps, pps, key := kinds(nal.H264, aus[0]); vps != 0 || sps != 1 || pps != 1 || key != 1 {
		t.Fatalf("first access unit: sps %d pps %d key %d", sps, pps, key)
	}
	if lines(t, filepath.Join(b.dir, "h264")) != 2 || lines(t, filepath.Join(b.dir, "h265")) != 0 {
		t.Fatal("H.264 parameter sets not persisted as two lines")
	}
	f2, _, _ := b.play(t, 1, 5*time.Second)
	if h := f2.(*format.H264); h.FMTP()["profile-level-id"] != "42C00B" {
		t.Fatalf("FMTP %v", h.FMTP())
	}
}

// video.codec says H.264 but hlcamd makes H.265: the first reader, set up
// for H.264, gets no video and is disconnected as soon as the stream shows
// its SPS; the next one reads an H265 description and decodes.
func TestRTSPSwitchesToTheStreamCodec(t *testing.T) {
	b := newBench(t, nal.H264, nal.H265)
	f, aus, closed := b.play(t, 5, 15*time.Second)
	if _, ok := f.(*format.H264); !ok {
		t.Fatalf("first description %T", f)
	}
	if len(aus) != 0 || !closed {
		t.Fatalf("H.264 reader got %d access units of H.265, closed %v", len(aus), closed)
	}
	if !b.state.Mismatch() || b.state.Effective() != nal.H265 {
		t.Fatal("mismatch not recorded")
	}
	f2, aus2, closed2 := b.play(t, 5, 15*time.Second)
	if _, ok := f2.(*format.H265); !ok || closed2 || len(aus2) < 5 {
		t.Fatalf("second reader: %T, closed %v, %d access units", f2, closed2, len(aus2))
	}
	if vps, sps, pps, key := kinds(nal.H265, aus2[0]); vps != 1 || sps != 1 || pps != 1 || key != 1 {
		t.Fatalf("first access unit after the switch: vps %d sps %d pps %d key %d", vps, sps, pps, key)
	}
}

// Persisted parameter sets: an H.264 file is never read as H.265, a
// damaged file is ignored.
func TestParamsH265RoundTrip(t *testing.T) {
	var vps, sps, pps []byte
	for _, au := range fakehlcamd.AccessUnits(nal.H265, fakehlcamd.H265(), false)[:1] {
		for _, n := range au {
			switch nal.H265Type(n) {
			case nal.H265VPS:
				vps = n
			case nal.H265SPS:
				sps = n
			case nal.H265PPS:
				pps = n
			}
		}
	}
	path := filepath.Join(t.TempDir(), "h265")
	if _, _, _, ok := loadParamsH265(path); ok {
		t.Fatal("missing file loaded")
	}
	if err := saveParamSets(path, vps, sps, pps); err != nil {
		t.Fatal(err)
	}
	if gv, gs, gp, ok := loadParamsH265(path); !ok || string(gv) != string(vps) || string(gs) != string(sps) || string(gp) != string(pps) {
		t.Fatal("round trip")
	}
	if _, _, ok := loadParams(path); ok {
		t.Fatal("an H.265 file read as H.264")
	}
	if err := saveParamSets(path, []byte{0x67, 0x42, 0xc0, 0x0b}, []byte{0x68, 0xce}, pps); err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := loadParamsH265(path); ok {
		t.Fatal("H.264 sets read as H.265")
	}
	if err := os.WriteFile(path, []byte("not base64\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := loadParamsH265(path); ok {
		t.Fatal("damaged file loaded")
	}
}

// A reader joining mid-GOP gets the parameter sets ahead of the next key
// picture even when the stream carried them only once, at its start
// (earlier versions did it for H.264 SPS/PPS; VPS joins them in H.265): the
// first reader has made the server cache them, the second gets them
// prepended.
func TestRTSPPrependsParamsForLateReaders(t *testing.T) {
	for _, c := range []nal.Codec{nal.H264, nal.H265} {
		aus := fakehlcamd.AccessUnits(c, fakehlcamd.Stream(c), false)
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := l.Addr().String()
		_ = l.Close()
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		state := nal.NewState(c, logger)
		hub := mediahub.New("once", fakehlcamd.SourceAUs(c, aus[:1], fakehlcamd.WithoutParams(c, aus[1:]), 120, logger), nil, logger)
		hub.SetCodecState(state)
		srv := New(Config{Listen: addr, Path: "openqiara"}, hub, logger)
		srv.SetCodecState(state)
		ctx, cancel := context.WithCancel(context.Background())
		if err := srv.Start(ctx); err != nil {
			t.Fatal(err)
		}
		b := &bench{addr: addr, state: state}
		// The first reader stays for the whole test: the pipeline runs and
		// has seen the parameter sets of the first access unit.
		first := make(chan struct{})
		go func() {
			defer close(first)
			b.play(t, 400, 20*time.Second)
		}()
		time.Sleep(1500 * time.Millisecond) // past the first access unit, and past a key picture
		_, late, _ := b.play(t, 40, 10*time.Second)
		cancel()
		<-first
		// The late reader gets the slices in flight (as earlier versions sent
		// them), then its first key picture, which must carry the sets.
		found := false
		for i, au := range late {
			vps, sps, pps, key := kinds(c, au)
			if key == 0 {
				continue
			}
			if sps != 1 || pps != 1 || (c == nal.H265 && vps != 1) {
				t.Fatalf("%s: late reader's first key picture (access unit %d): vps %d sps %d pps %d", c, i, vps, sps, pps)
			}
			found = true
			break
		}
		if !found {
			t.Fatalf("%s: no key picture in %d access units", c, len(late))
		}
	}
}

// A reader still counted when the stream shows another codec than the one
// served: the sessions a switch closes leave only when gortsplib
// runs their close handler, and a client reconnecting before that (go2rtc
// and Frigate do so at once) finds the reader count above zero, so no new
// pipeline starts for it. The running pipeline must then packetize the new
// codec itself rather than drop every access unit until the count reaches
// zero. The lingering reader is simulated by OnPlay without a session.
func TestRTSPPipelineFollowsTheCodecWithReadersLeft(t *testing.T) {
	b := newBench(t, nal.H264, nal.H265)
	if _, err := b.srv.OnPlay(nil); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(b.srv.onReaderGone)
	deadline := time.Now().Add(10 * time.Second)
	for !b.state.Mismatch() {
		if time.Now().After(deadline) {
			t.Fatal("the stream never showed its codec")
		}
		time.Sleep(20 * time.Millisecond)
	}
	f, aus, closed := b.play(t, 40, 8*time.Second)
	if _, ok := f.(*format.H265); !ok || closed {
		t.Fatalf("description %T, closed %v", f, closed)
	}
	if len(aus) < 40 {
		t.Fatalf("reader joining during the switch got %d access units", len(aus))
	}
	// Joining mid-GOP, it gets the slices in flight (as earlier versions sent them),
	// then a key picture, which must carry the parameter sets the pipeline
	// cached again after the switch.
	for i, au := range aus {
		vps, sps, pps, key := kinds(nal.H265, au)
		if key == 0 {
			continue
		}
		if vps != 1 || sps != 1 || pps != 1 {
			t.Fatalf("first key picture (access unit %d): vps %d sps %d pps %d", i, vps, sps, pps)
		}
		return
	}
	t.Fatalf("no key picture in %d access units", len(aus))
}
