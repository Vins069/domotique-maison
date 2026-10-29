package mediahub

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/nal"
)

// newTestHub returns a hub with no pipeline running (subs map ready) so we
// can exercise broadcast/subscribe/unsubscribe without touching disk.
func newTestHub() *Hub {
	return New("test", freezingSource(0), nil, nil)
}

func TestBroadcastFanout(t *testing.T) {
	h := newTestHub()
	// Attach two subscribers directly (bypass Subscribe so no pipeline
	// goroutine spins up on this fake path).
	s1 := &subscription{ch: make(chan camera.Sample, subBuffer), hub: h}
	s2 := &subscription{ch: make(chan camera.Sample, subBuffer), hub: h}
	h.subs[s1] = struct{}{}
	h.subs[s2] = struct{}{}

	want := camera.Sample{IsVideo: true, PTS: 42, Data: []byte{0x65}}
	h.broadcast(want)

	for i, s := range []*subscription{s1, s2} {
		select {
		case got := <-s.ch:
			if got.PTS != want.PTS || got.IsVideo != want.IsVideo {
				t.Fatalf("sub %d: got %+v, want %+v", i, got, want)
			}
		default:
			t.Fatalf("sub %d: expected a sample, channel empty", i)
		}
	}
}

func TestBroadcastLossyDoesNotBlock(t *testing.T) {
	h := newTestHub()
	slow := &subscription{ch: make(chan camera.Sample, subBuffer), hub: h}
	h.subs[slow] = struct{}{}

	// Fill the buffer, then push one more: broadcast must not block and
	// the overflow sample is silently dropped for this subscriber.
	for i := 0; i < subBuffer; i++ {
		h.broadcast(camera.Sample{IsVideo: true, PTS: int64(i)})
	}
	done := make(chan struct{})
	go func() {
		h.broadcast(camera.Sample{IsVideo: true, PTS: 9999}) // must not block
		close(done)
	}()
	<-done // if broadcast blocked, the test hangs and fails via timeout

	if len(slow.ch) != subBuffer {
		t.Fatalf("buffer len = %d, want %d (overflow should be dropped)", len(slow.ch), subBuffer)
	}
}

func TestUnsubscribeClosesChannel(t *testing.T) {
	h := newTestHub()
	sub := &subscription{ch: make(chan camera.Sample, subBuffer), hub: h}
	h.subs[sub] = struct{}{}

	h.unsubscribe(sub)

	if _, ok := <-sub.ch; ok {
		t.Fatal("channel should be closed after unsubscribe")
	}
	if len(h.subs) != 0 {
		t.Fatalf("subs not empty after unsubscribe: %d", len(h.subs))
	}
	// Double unsubscribe is a no-op, not a panic.
	h.unsubscribe(sub)
}

// The hub sees the codec on the parameter sets before any subscriber does:
// a consumer told of the change by the state is never behind
// the sample that proves it.
func TestHubObservesTheCodec(t *testing.T) {
	h := newTestHub()
	st := nal.NewState(nal.H264, nil)
	h.SetCodecState(st)
	sub := &subscription{ch: make(chan camera.Sample, subBuffer), hub: h}
	h.subs[sub] = struct{}{}
	if h.Codec() != nal.H264 {
		t.Fatal("configured H.264 not served before any sample")
	}
	for _, au := range fakehlcamd.AccessUnits(nal.H265, fakehlcamd.H265(), false)[:2] {
		for _, n := range au {
			h.broadcast(camera.Sample{IsVideo: true, PTS: 0, Data: n})
			if got := <-sub.ch; nal.H265Type(got.Data) == nal.H265SPS && h.Codec() != nal.H265 {
				t.Fatal("SPS delivered before the codec changed")
			}
		}
	}
	if h.Codec() != nal.H265 || !st.Mismatch() {
		t.Fatalf("codec %s, mismatch %v", h.Codec(), st.Mismatch())
	}
	// The VPS came before the SPS proved the codec: read under the H.264
	// setting, it is still counted as the VPS it is (its two first bytes
	// are no H.264 unit); everything after the SPS as H.265.
	c := h.NALCounts()
	if c["other"] != 0 || c["sps"] != 1 || c["pps"] != 1 || c["sei"] != 1 || c["key"] != 1 || c["slice"] != 1 || c["vps"] != 1 {
		t.Fatalf("counts %v", c)
	}
	if newTestHub().Codec() != nal.H264 {
		t.Fatal("a hub without a state must serve H.264")
	}
}

// The probe at start learns the codec from the stream and leaves the
// pipeline stopped; a silent stream leaves it Unknown.
func TestProbeCodec(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New("fake", fakehlcamd.Source(nal.H265, fakehlcamd.H265(), 300, logger), nil, logger)
	st := nal.NewState(nal.H264, logger)
	h.SetCodecState(st)
	if got := h.ProbeCodec(context.Background(), 10*time.Second); got != nal.H265 {
		t.Fatalf("probe = %s", got)
	}
	h.mu.Lock()
	running := h.cancel != nil
	h.mu.Unlock()
	if running {
		t.Fatal("pipeline left running after the probe")
	}
	if got := h.ProbeCodec(context.Background(), time.Second); got != nal.H265 { // already known: no pipeline
		t.Fatalf("second probe = %s", got)
	}
	silent := New("silent", freezingSource(0), nil, logger)
	silent.SetCodecState(nal.NewState(nal.H265, logger))
	if got := silent.ProbeCodec(context.Background(), 200*time.Millisecond); got != nal.Unknown {
		t.Fatalf("silent probe = %s", got)
	}
	if got := New("none", freezingSource(0), nil, logger).ProbeCodec(context.Background(), time.Second); got != nal.Unknown {
		t.Fatalf("probe without a state = %s", got)
	}
}
