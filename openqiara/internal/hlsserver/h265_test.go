package hlsserver

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"
	"time"

	"github.com/bluenviron/mediacommon/v2/pkg/formats/fmp4"
	mp4codecs "github.com/bluenviron/mediacommon/v2/pkg/formats/mp4/codecs"
	"github.com/bluenviron/mediacommon/v2/pkg/formats/mpegts"
	tscodecs "github.com/bluenviron/mediacommon/v2/pkg/formats/mpegts/codecs"

	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
)

// newBench serves a fake hlcamd playing a synthetic stream.
func newBench(t *testing.T, configured, stream nal.Codec) (*Server, *nal.State) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	state := nal.NewState(configured, logger)
	hub := mediahub.New("fake", fakehlcamd.Source(stream, fakehlcamd.Stream(stream), 120, logger), nil, logger)
	hub.SetCodecState(state)
	srv := New(hub, false, logger)
	srv.SetCodecState(state)
	srv.idleStop = 300 * time.Millisecond
	t.Cleanup(func() {
		srv.mu.Lock()
		rn := srv.run
		srv.mu.Unlock()
		if rn != nil {
			rn.cancel()
		}
	})
	return srv, state
}

func getCode(h http.Handler, url string) (int, []byte) {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, url, nil))
	return rec.Code, rec.Body.Bytes()
}

// mediaPlaylist follows the multivariant playlist to the media playlist,
// waiting for its first segment.
func mediaPlaylist(t *testing.T, h http.Handler) (base, playlist string) {
	t.Helper()
	main := get(t, h, "/stream/HLS_TEST.m3u8")
	media := regexp.MustCompile(`(?m)^(\S+_stream\.m3u8)`).FindString(main)
	if media == "" {
		t.Fatalf("no media playlist in:\n%s", main)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		playlist = get(t, h, "/stream/"+media)
		if regexp.MustCompile(`(?m)^\S+\.(ts|mp4)$`).MatchString(playlist) {
			return "/stream/", playlist
		}
		if time.Now().After(deadline) {
			t.Fatalf("no segment in:\n%s", playlist)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// An H.265 camera is served as fragmented MP4: an init segment with the
// hvc1 track and its VPS, SPS and PPS, then moof fragments.
func TestServesH265AsFMP4(t *testing.T) {
	srv, _ := newBench(t, nal.H265, nal.H265)
	base, pl := mediaPlaylist(t, srv)
	m := regexp.MustCompile(`#EXT-X-MAP:URI="([^"]+)"`).FindStringSubmatch(pl)
	if m == nil {
		t.Fatalf("no init segment in:\n%s", pl)
	}
	var init fmp4.Init
	if err := init.Unmarshal(bytes.NewReader([]byte(get(t, srv, base+m[1])))); err != nil {
		t.Fatal(err)
	}
	if len(init.Tracks) != 1 {
		t.Fatalf("%d tracks", len(init.Tracks))
	}
	h, ok := init.Tracks[0].Codec.(*mp4codecs.H265)
	if !ok || len(h.VPS) == 0 || len(h.SPS) == 0 || len(h.PPS) == 0 || nal.Detect(h.SPS) != nal.H265 {
		t.Fatalf("init track codec %T %+v", init.Tracks[0].Codec, init.Tracks[0].Codec)
	}
	seg := regexp.MustCompile(`(?m)^(\S+\.mp4)$`).FindString(pl)
	if seg == "" {
		t.Fatalf("no fMP4 segment in:\n%s", pl)
	}
	b := []byte(get(t, srv, base+seg))
	if len(b) < 8 || string(b[4:8]) != "moof" {
		t.Fatalf("segment does not start with moof: % x", b[:min(16, len(b))])
	}
	if regexp.MustCompile(`(?m)^\S+\.ts$`).MatchString(pl) {
		t.Fatal("an MPEG-TS segment in an H.265 playlist")
	}
}

// The H.264 path on the synthetic stream: MPEG-TS segments whose first
// access unit is the IDR with its SPS and PPS, as the H.264 path always served them.
func TestServesH264AsMPEGTS(t *testing.T) {
	srv, _ := newBench(t, nal.H264, nal.H264)
	base, pl := mediaPlaylist(t, srv)
	seg := regexp.MustCompile(`(?m)^(\S+\.ts)$`).FindString(pl)
	if seg == "" {
		t.Fatalf("no MPEG-TS segment in:\n%s", pl)
	}
	r := &mpegts.Reader{R: bytes.NewReader([]byte(get(t, srv, base+seg)))}
	if err := r.Initialize(); err != nil {
		t.Fatal(err)
	}
	if len(r.Tracks()) != 1 {
		t.Fatalf("%d tracks", len(r.Tracks()))
	}
	if _, ok := r.Tracks()[0].Codec.(*tscodecs.H264); !ok {
		t.Fatalf("track codec %T", r.Tracks()[0].Codec)
	}
	var first [][]byte
	r.OnDataH264(r.Tracks()[0], func(_ int64, _ int64, au [][]byte) error {
		if first == nil {
			first = au
		}
		return nil
	})
	for first == nil {
		if err := r.Read(); err != nil {
			t.Fatal(err)
		}
	}
	var sps, pps, idr bool
	for _, n := range first {
		switch nal.H264Type(n) {
		case nal.H264SPS:
			sps = true
		case nal.H264PPS:
			pps = true
		case nal.H264IDR:
			idr = true
		}
	}
	if !sps || !pps || !idr {
		t.Fatalf("first access unit: sps %v pps %v idr %v", sps, pps, idr)
	}
}

// video.codec says H.264 but the stream is H.265: the muxer started for
// H.264 stops as soon as the stream shows its codec (the request gets a
// 503 at once, not after readyWait), and the next request is served in
// H.265.
func TestMuxerStopsWhenTheCodecChanges(t *testing.T) {
	srv, state := newBench(t, nal.H264, nal.H265)
	t0 := time.Now()
	code, body := getCode(srv, "/stream/HLS_TEST.m3u8")
	if code != http.StatusServiceUnavailable || time.Since(t0) > 5*time.Second {
		t.Fatalf("first request: %d %s after %v", code, body, time.Since(t0))
	}
	if !state.Mismatch() {
		t.Fatal("mismatch not seen")
	}
	_, pl := mediaPlaylist(t, srv)
	if !regexp.MustCompile(`#EXT-X-MAP:URI=`).MatchString(pl) {
		t.Fatalf("second request not served as fMP4:\n%s", pl)
	}
}
