package rtspserver

import (
	"context"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/bluenviron/gortsplib/v5/pkg/format"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
)

// mixedSource is a fake hlcamd that plays the H.265 stream once (head
// units) and then the H.264 stream over and over: a camera relaunched in
// the other codec while the daemon runs.
func mixedSource(h265 int, fps int, logger *slog.Logger) func(ctx context.Context) (<-chan camera.Sample, error) {
	return func(ctx context.Context) (<-chan camera.Sample, error) {
		conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			return nil, err
		}
		snd, err := fakehlcamd.Dial(conn.LocalAddr().String())
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		samples := camera.VideoFromConn(ctx, conn, logger)
		go func() {
			defer func() { _ = snd.Close() }()
			period := time.Second / time.Duration(fps)
			tick := time.NewTicker(period)
			defer tick.Stop()
			sent := 0
			send := func(c nal.Codec, aus [][][]byte) bool {
				for _, au := range aus {
					if err := snd.SendAU(c, uint64(sent)*uint64(period/time.Microsecond), au); err != nil {
						return false
					}
					sent++
					select {
					case <-ctx.Done():
						return false
					case <-tick.C:
					}
				}
				return true
			}
			head := fakehlcamd.AccessUnits(nal.H265, fakehlcamd.H265(), false)
			if h265 < len(head) {
				head = head[:h265]
			}
			if !send(nal.H265, head) {
				return
			}
			loop := fakehlcamd.AccessUnits(nal.H264, fakehlcamd.H264(), false)
			for send(nal.H264, loop) {
			}
		}()
		return samples, nil
	}
}

// newMixedBench is an RTSP server, configured for codec conf, on a fake
// hlcamd that plays 60 access units of H.265 (2 s), then H.264 for good.
// changes receives what the state's OnChange reports.
func newMixedBench(t *testing.T, conf nal.Codec) (b *bench, changes <-chan nal.Codec) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	state := nal.NewState(conf, logger)
	ch := make(chan nal.Codec, 8)
	state.OnChange = func(c nal.Codec) {
		select {
		case ch <- c:
		default:
		}
	}
	hub := mediahub.New("fake", mixedSource(60, 30, logger), nil, logger)
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
	return &bench{addr: addr, state: state, dir: dir, srv: srv}, ch
}

// wantChanges reads the codecs OnChange reported, in order.
func wantChanges(t *testing.T, changes <-chan nal.Codec, want ...nal.Codec) {
	t.Helper()
	for _, w := range want {
		select {
		case got := <-changes:
			if got != w {
				t.Fatalf("OnChange(%s), want %s", got, w)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("OnChange(%s) not called", w)
		}
	}
}

// h264Only fails on any unit that is no H.264 unit a Baseline encoder
// makes (forbidden bit, unspecified or partition types, reserved types,
// an H.265 header nal.Foreign tells).
func h264Only(t *testing.T, aus [][][]byte) {
	t.Helper()
	for i, au := range aus {
		for _, n := range au {
			typ := nal.H264Type(n)
			if n[0]&0x80 != 0 || typ == 0 || (typ >= 2 && typ <= 4) || typ > 9 || nal.Foreign(nal.H264, n) {
				t.Fatalf("H.264 reader got a NAL of type %d (first bytes % x) in unit %d", typ, n[:min(2, len(n))], i)
			}
		}
	}
}

// video.codec says H.264; hlcamd sends H.265 for 2 s, then H.264 (the
// camera relaunched with the right codec). A reader connected from the
// start keeps its H.264 session throughout: it is never disconnected, gets
// no H.265 unit at all, and its first access unit is the H.264 key picture
// with SPS and PPS. The mismatch is reported (OnChange) and cleared.
func TestRTSPServesTheConfiguredCodecOnly(t *testing.T) {
	b, changes := newMixedBench(t, nal.H264)
	f, aus, closed := b.play(t, 40, 15*time.Second)
	if _, ok := f.(*format.H264); !ok || closed {
		t.Fatalf("description %T, closed %v", f, closed)
	}
	if len(aus) < 40 {
		t.Fatalf("%d access units", len(aus))
	}
	h264Only(t, aus)
	if _, sps, pps, key := kinds(nal.H264, aus[0]); sps != 1 || pps != 1 || key != 1 {
		t.Fatalf("first access unit: sps %d pps %d key %d", sps, pps, key)
	}
	wantChanges(t, changes, nal.H265, nal.H264)
	if b.state.Mismatch() || b.state.Configured() != nal.H264 {
		t.Fatal("mismatch not cleared")
	}
	f2, _, _ := b.play(t, 1, 5*time.Second)
	if _, ok := f2.(*format.H264); !ok {
		t.Fatalf("second description %T", f2)
	}
}

// video.codec says H.265; hlcamd sends H.265 for 2 s, then H.264. The
// reader gets the H.265 access units, then nothing: no H.264 unit is ever
// packetized as H.265, the session stays open and its description H.265.
func TestRTSPDropsTheOtherCodec(t *testing.T) {
	b, changes := newMixedBench(t, nal.H265)
	f, aus, closed := b.play(t, 1000, 5*time.Second)
	if _, ok := f.(*format.H265); !ok || closed {
		t.Fatalf("description %T, closed %v", f, closed)
	}
	if len(aus) == 0 || len(aus) > 60 {
		t.Fatalf("%d access units for 60 of H.265", len(aus))
	}
	for i, au := range aus {
		for _, n := range au {
			// Every H.265 unit of the base layer: even first byte (forbidden
			// bit and nuh_layer_id clear), second byte 1 (temporal id 0):
			// no H.264 unit (0x41, 0x21, 0x01, 0x65, 0x67, 0x68 0xCE...) fits.
			if len(n) < 2 || n[0]&0x81 != 0 || n[1] != 1 || nal.H265Type(n) > 40 {
				t.Fatalf("H.265 reader got a foreign NAL in unit %d: % x", i, n[:min(2, len(n))])
			}
		}
	}
	wantChanges(t, changes, nal.H265, nal.H264)
	if !b.state.Mismatch() || b.state.Detected() != nal.H264 {
		t.Fatal("mismatch not recorded")
	}
	f2, _, _ := b.play(t, 1, 3*time.Second)
	if _, ok := f2.(*format.H265); !ok {
		t.Fatalf("second description %T", f2)
	}
}
