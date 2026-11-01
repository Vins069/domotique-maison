package mediahub

import (
	"testing"

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

// The hub serves the configured codec only: a stream in the
// other codec reaches no subscriber, the mismatch is recorded and counted,
// and the configured codec goes out again once the stream is back to it.
func TestHubDropsTheOtherCodec(t *testing.T) {
	h := newTestHub()
	st := nal.NewState(nal.H264, nil)
	changes := 0
	st.OnChange = func(nal.Codec) { changes++ }
	h.SetCodecState(st)
	sub := &subscription{ch: make(chan camera.Sample, 1024), hub: h}
	h.subs[sub] = struct{}{}
	send := func(c nal.Codec) (sent int) {
		for _, au := range fakehlcamd.AccessUnits(c, fakehlcamd.Stream(c), false) {
			for _, n := range au {
				h.broadcast(camera.Sample{IsVideo: true, Data: n})
				sent++
			}
		}
		return sent
	}
	drain := func() (got []camera.Sample) {
		for {
			select {
			case s := <-sub.ch:
				got = append(got, s)
			default:
				return got
			}
		}
	}
	n264 := send(nal.H264)
	if got := drain(); len(got) != n264 || st.Mismatch() || changes != 1 {
		t.Fatalf("H.264 stream: %d of %d units delivered, mismatch %v, %d changes", len(got), n264, st.Mismatch(), changes)
	}
	n265 := send(nal.H265)
	if got := drain(); len(got) != 0 {
		t.Fatalf("%d H.265 units delivered under the H.264 setting (first % x)", len(got), got[0].Data[:2])
	}
	if !st.Mismatch() || st.Detected() != nal.H265 || st.Configured() != nal.H264 || changes != 2 {
		t.Fatalf("mismatch %v, detected %s, configured %s, %d changes", st.Mismatch(), st.Detected(), st.Configured(), changes)
	}
	// Audio is no video unit: it goes on.
	h.broadcast(camera.Sample{PTS: 1, Data: []byte{1, 2}})
	if got := drain(); len(got) != 1 || got[0].IsVideo {
		t.Fatal("audio not delivered during the mismatch")
	}
	c := h.NALCounts()
	if c["foreign"] != uint64(n265) || c["vps"] != 0 || c["sps"] != 3 || c["key"] != 3 {
		t.Fatalf("counts %v (%d H.265 units sent)", c, n265)
	}
	// Back to H.264: served again from its SPS, a key picture first.
	send(nal.H264)
	got := drain()
	if st.Mismatch() || changes != 3 || len(got) == 0 || nal.H264Type(got[0].Data) != nal.H264SPS {
		t.Fatalf("back to H.264: mismatch %v, %d changes, %d units", st.Mismatch(), changes, len(got))
	}
	for _, s := range got {
		if nal.Foreign(nal.H264, s.Data) {
			t.Fatalf("foreign unit delivered: % x", s.Data[:2])
		}
	}
	// No state: every sample goes out.
	plain := newTestHub()
	ps := &subscription{ch: make(chan camera.Sample, 1024), hub: plain}
	plain.subs[ps] = struct{}{}
	plain.broadcast(camera.Sample{IsVideo: true, Data: []byte{0x40, 0x01, 0x0c}})
	if len(ps.ch) != 1 {
		t.Fatal("a hub without a state filtered a sample")
	}
}
