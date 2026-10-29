package fakehlcamd

import (
	"context"
	"testing"
	"time"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/nal"
)

// Each synthetic stream is 90 access units, a key picture with its
// parameter sets every 30, no delimiter left, in Annex B.
func TestAccessUnits(t *testing.T) {
	for _, c := range []nal.Codec{nal.H264, nal.H265} {
		aus := AccessUnits(c, Stream(c), false)
		if len(aus) != 90 {
			t.Fatalf("%s: %d access units, want 90", c, len(aus))
		}
		keys := 0
		for i, au := range aus {
			if IsKey(c, au) {
				keys++
				params := 0
				for _, n := range au {
					if nal.IsParam(c, n) {
						params++
					}
				}
				if want := map[nal.Codec]int{nal.H264: 2, nal.H265: 3}[c]; params != want {
					t.Fatalf("%s: key access unit %d carries %d parameter sets, want %d", c, i, params, want)
				}
				if i%30 != 0 {
					t.Fatalf("%s: key picture at %d", c, i)
				}
			}
			vcl := 0
			for _, n := range au {
				if nal.IsAUD(c, n) {
					t.Fatalf("%s: delimiter left in access unit %d", c, i)
				}
				if nal.IsVCL(c, n) {
					vcl++
				}
			}
			if vcl == 0 {
				t.Fatalf("%s: access unit %d has no slice", c, i)
			}
		}
		if keys != 3 {
			t.Fatalf("%s: %d key pictures, want 3", c, keys)
		}
		if n := len(AccessUnits(c, Stream(c), true)); n != 90 {
			t.Fatalf("%s: %d access units with delimiters kept", c, n)
		}
		// Without delimiters the pictures are still told apart.
		var noAUD []byte
		for _, n := range camera.SplitNALUnits(Stream(c)) {
			if !nal.IsAUD(c, n) {
				noAUD = append(noAUD, 0, 0, 0, 1)
				noAUD = append(noAUD, n...)
			}
		}
		if n := len(AccessUnits(c, noAUD, false)); n != 90 {
			t.Fatalf("%s: %d access units without delimiters in the stream", c, n)
		}
	}
}

// The source delivers every NAL unit through the real multicast parser,
// with hlcamd's PTS (microseconds to the 90 kHz clock), key pictures first.
func TestSourceThroughTheRealParser(t *testing.T) {
	for _, c := range []nal.Codec{nal.H264, nal.H265} {
		ctx, cancel := context.WithCancel(context.Background())
		samples, err := Source(c, Stream(c), 300, nil)(ctx)
		if err != nil {
			t.Fatal(err)
		}
		aus := AccessUnits(c, Stream(c), false)
		var got []camera.Sample
		deadline := time.After(10 * time.Second)
		for len(got) < len(aus[0])+len(aus[1]) {
			select {
			case s := <-samples:
				got = append(got, s)
			case <-deadline:
				t.Fatalf("%s: %d samples", c, len(got))
			}
		}
		cancel()
		for range samples {
		}
		if nal.Type(c, got[0].Data) != map[nal.Codec]uint8{nal.H264: nal.H264SPS, nal.H265: nal.H265VPS}[c] || got[0].PTS != 0 {
			t.Fatalf("%s: first sample type %d pts %d", c, nal.Type(c, got[0].Data), got[0].PTS)
		}
		next := got[len(aus[0])]
		if next.PTS != 3333*90/1000 || !nal.IsVCL(c, next.Data) { // 300 fps: 3333 µs a frame
			t.Fatalf("%s: second picture pts %d, type %d", c, next.PTS, nal.Type(c, next.Data))
		}
	}
}
