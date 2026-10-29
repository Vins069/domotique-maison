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

// TestAUCodec: an access unit proves its codec by its SPS only.
func TestAUCodec(t *testing.T) {
	h264 := fakehlcamd.AccessUnits(nal.H264, fakehlcamd.H264(), false)
	h265 := fakehlcamd.AccessUnits(nal.H265, fakehlcamd.H265(), false)
	if c := auCodec(h264[0]); c != nal.H264 {
		t.Fatalf("H.264 key picture: %s", c)
	}
	if c := auCodec(h265[0]); c != nal.H265 {
		t.Fatalf("H.265 key picture: %s", c)
	}
	if c := auCodec(h264[1]); c != nal.Unknown {
		t.Fatalf("H.264 slice alone: %s", c)
	}
	if c := auCodec(h265[1]); c != nal.Unknown {
		t.Fatalf("H.265 slice alone: %s", c)
	}
	if c := auCodec(nil); c != nal.Unknown {
		t.Fatalf("empty unit: %s", c)
	}
}

// TestRTSPSwitchToH264DropsTheOldCodecsUnit: hlcamd relaunched in H.264
// while the daemon served H.265. The hub switches on the SPS of the first
// H.264 key picture, which is the sample that flushes the last buffered
// H.265 unit: that unit must not be packetized as H.264. A reader counted
// present during the switch keeps the pipeline alive (as the test
// does), and a reader joining right after gets an H.264 description and
// nothing but H.264 units, starting with a key picture carrying SPS and
// PPS.
func TestRTSPSwitchToH264DropsTheOldCodecsUnit(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	state := nal.NewState(nal.H265, logger)
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
	b := &bench{addr: addr, state: state, dir: dir, srv: srv}
	if _, err := b.srv.OnPlay(nil); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.onReaderGone)
	// The first reader sees H.265 and is closed by the switch.
	f, aus, closed := b.play(t, 1000, 8*time.Second)
	if _, ok := f.(*format.H265); !ok {
		t.Fatalf("first description %T", f)
	}
	if !closed {
		t.Fatalf("the switch did not close the H.265 reader (%d units)", len(aus))
	}
	for i, au := range aus {
		for _, n := range au {
			// Every H.265 unit of the base layer: even first byte (forbidden
			// bit and nuh_layer_id clear), second byte 1 (temporal id 0):
			// no H.264 unit (0x41, 0x21, 0x01, 0x65, 0x67, 0x68 0xCE...) fits.
			if len(n) < 2 || n[0]&0x81 != 0 || n[1] != 1 || nal.H265Type(n) > 40 {
				t.Fatalf("H.265 reader got a foreign NAL in unit %d: %x", i, n[:2])
			}
		}
	}
	// A reader joining right after gets clean H.264.
	f, aus, closed = b.play(t, 40, 8*time.Second)
	if _, ok := f.(*format.H264); !ok || closed {
		t.Fatalf("second description %T, closed %v", f, closed)
	}
	if len(aus) < 40 {
		t.Fatalf("reader joining after the switch got %d access units", len(aus))
	}
	for i, au := range aus {
		for _, n := range au {
			typ := nal.H264Type(n)
			if n[0]&0x80 != 0 || typ == 0 || (typ >= 2 && typ <= 4) || typ > 9 {
				t.Fatalf("H.264 reader got a NAL of type %d (first byte %x) in unit %d", typ, n[0], i)
			}
		}
	}
	for i, au := range aus {
		_, sps, pps, key := kinds(nal.H264, au)
		if key == 0 {
			continue
		}
		if sps != 1 || pps != 1 {
			t.Fatalf("first H.264 key picture (unit %d): sps %d pps %d", i, sps, pps)
		}
		return
	}
	t.Fatalf("no key picture in %d H.264 access units", len(aus))
}
