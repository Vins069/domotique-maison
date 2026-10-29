// Package fakehlcamd is the hlcamd of the tests: it sends an Annex B
// stream, H.264 or H.265, in the format the real hlcamd multicasts on the
// loopback (internal/camera/multicast.go: a 24-byte header before each
// fragment, one frame per sequence number, the PTS in microseconds), over
// plain UDP to a camera.VideoFromConn reader. The streams are the
// synthetic ones of testdata/ (ffmpeg's test pattern, see gen.sh), kept as
// base64 text.
package fakehlcamd

import (
	"context"
	_ "embed"
	"encoding/base64"
	"fmt"
	"log/slog"
	"net"
	"strings"
	"time"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/nal"
)

//go:embed testdata/h264-testsrc.b64
var h264b64 string

//go:embed testdata/h265-testsrc.b64
var h265b64 string

func decode(b64 string) []byte {
	b, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(b64), ""))
	if err != nil {
		panic("fakehlcamd: testdata: " + err.Error())
	}
	return b
}

// H264 is the synthetic H.264 stream (Constrained Baseline, 160x90, 90
// frames at 30 fps, an IDR every 30 frames), Annex B.
func H264() []byte { return decode(h264b64) }

// H265 is the synthetic H.265 stream (Main, 160x90, 90 frames at 30 fps,
// an IDR every 30 frames), Annex B.
func H265() []byte { return decode(h265b64) }

// Stream is what Codec gives for either codec.
func Stream(c nal.Codec) []byte {
	if c == nal.H265 {
		return H265()
	}
	return H264()
}

// firstSlice tells whether a VCL NAL unit opens a picture: H.264's
// first_mb_in_slice is 0 (ue(v): first bit set) ; H.265's
// first_slice_segment_in_pic_flag is the first bit after the header.
func firstSlice(c nal.Codec, n []byte) bool {
	switch c {
	case nal.H264:
		return len(n) >= 2 && n[1]&0x80 != 0
	case nal.H265:
		return len(n) >= 3 && n[2]&0x80 != 0
	}
	return false
}

// AccessUnits cuts an Annex B stream into access units, each a list of
// NAL units without start codes, as the frames hlcamd sends. An access
// unit starts at an access unit delimiter when the stream has them, else
// at a parameter set or SEI following a slice, or at the first slice of a
// picture. The delimiters themselves are dropped unless keepAUD: hlcamd's
// frames carry none (the multicast captures of 2026-10-10 show SPS, PPS
// and the IDR, see internal/hlsserver's fake camera).
func AccessUnits(c nal.Codec, annexB []byte, keepAUD bool) [][][]byte {
	var out [][][]byte
	var cur [][]byte
	sawVCL := false
	flush := func() {
		if len(cur) > 0 {
			out = append(out, cur)
		}
		cur, sawVCL = nil, false
	}
	for _, n := range camera.SplitNALUnits(annexB) {
		switch {
		case nal.IsAUD(c, n):
			flush()
			if !keepAUD {
				continue
			}
		case nal.IsVCL(c, n):
			if firstSlice(c, n) && sawVCL {
				flush()
			}
			sawVCL = true
		default: // a parameter set or an SEI after a picture opens the next one
			if sawVCL {
				flush()
			}
		}
		cur = append(cur, n)
	}
	flush()
	return out
}

// IsKey tells whether an access unit holds a key picture.
func IsKey(c nal.Codec, au [][]byte) bool {
	for _, n := range au {
		if nal.IsKey(c, n) {
			return true
		}
	}
	return false
}

// Sender sends frames to one address in hlcamd's format.
type Sender struct {
	conn net.Conn
	seq  uint32
	// FragmentSize is the data size of a fragment (hlcamd: up to 24 KiB on
	// the loopback; here 1400 so that the frames are cut).
	FragmentSize int
	write        func([]byte) error
}

// Dial opens the UDP socket to the reader's address.
func Dial(addr string) (*Sender, error) {
	conn, err := net.Dial("udp4", addr)
	if err != nil {
		return nil, fmt.Errorf("fakehlcamd: %w", err)
	}
	return &Sender{conn: conn, FragmentSize: 1400}, nil
}

// SetWriter makes the sender write its fragments through w instead of its
// socket (a multicast socket bound to an interface, for instance).
func (s *Sender) SetWriter(w func([]byte) error) { s.write = w }

// Close closes the socket, if any.
func (s *Sender) Close() error {
	if s.conn == nil {
		return nil
	}
	return s.conn.Close()
}

// SendFrame sends one frame (Annex B, as hlcamd sends it) with its PTS in
// microseconds.
func (s *Sender) SendFrame(ptsMicro uint64, key bool, frame []byte) error {
	s.seq++
	for _, p := range camera.EncodeMulticastFragments(ptsMicro, s.seq, key, frame, s.FragmentSize) {
		if s.write != nil {
			if err := s.write(p); err != nil {
				return err
			}
			continue
		}
		if _, err := s.conn.Write(p); err != nil {
			return err
		}
	}
	return nil
}

// SendAU sends one access unit, its NAL units joined by 4-byte start codes.
func (s *Sender) SendAU(c nal.Codec, ptsMicro uint64, au [][]byte) error {
	var frame []byte
	for _, n := range au {
		frame = append(frame, 0, 0, 0, 1)
		frame = append(frame, n...)
	}
	return s.SendFrame(ptsMicro, IsKey(c, au), frame)
}

// Play sends the stream's access units at fps, over and over while loop is
// set, until ctx ends; the PTS keeps growing across loops. It returns the
// number of frames sent.
func (s *Sender) Play(ctx context.Context, c nal.Codec, stream []byte, fps int, loop bool) int {
	aus := AccessUnits(c, stream, false)
	if fps <= 0 {
		fps = 30
	}
	period := time.Second / time.Duration(fps)
	tick := time.NewTicker(period)
	defer tick.Stop()
	sent := 0
	for {
		for _, au := range aus {
			pts := uint64(sent) * uint64(period/time.Microsecond)
			if err := s.SendAU(c, pts, au); err != nil {
				return sent
			}
			sent++
			select {
			case <-ctx.Done():
				return sent
			case <-tick.C:
			}
		}
		if !loop {
			return sent
		}
	}
}

// PlayAUs sends once (head), then over and over (loop) until ctx ends,
// at fps, with a PTS that keeps growing. It returns the number of frames
// sent.
func (s *Sender) PlayAUs(ctx context.Context, c nal.Codec, head, loop [][][]byte, fps int) int {
	if fps <= 0 {
		fps = 30
	}
	period := time.Second / time.Duration(fps)
	tick := time.NewTicker(period)
	defer tick.Stop()
	sent := 0
	send := func(aus [][][]byte) bool {
		for _, au := range aus {
			if err := s.SendAU(c, uint64(sent)*uint64(period/time.Microsecond), au); err != nil {
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
	if !send(head) {
		return sent
	}
	for len(loop) > 0 && send(loop) {
	}
	return sent
}

// Source returns a hub source fed by a fake hlcamd playing stream at fps
// in a loop: the reader listens on a UDP port of the loopback, the sender
// plays to it until ctx ends. The source's signature is mediahub.Source's.
func Source(c nal.Codec, stream []byte, fps int, logger *slog.Logger) func(ctx context.Context) (<-chan camera.Sample, error) {
	return SourceAUs(c, nil, AccessUnits(c, stream, false), fps, logger)
}

// SourceAUs is Source for given access units: head once, then loop over
// and over (a stream carrying its parameter sets only at the start is
// head = its first access unit, loop = the rest without them).
func SourceAUs(c nal.Codec, head, loop [][][]byte, fps int, logger *slog.Logger) func(ctx context.Context) (<-chan camera.Sample, error) {
	return func(ctx context.Context) (<-chan camera.Sample, error) {
		conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			return nil, err
		}
		snd, err := Dial(conn.LocalAddr().String())
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		samples := camera.VideoFromConn(ctx, conn, logger)
		go func() {
			defer func() { _ = snd.Close() }()
			snd.PlayAUs(ctx, c, head, loop, fps)
		}()
		return samples, nil
	}
}

// WithoutParams returns the access units with their parameter sets (VPS,
// SPS, PPS) removed: a stream that carries them only once at its start.
func WithoutParams(c nal.Codec, aus [][][]byte) [][][]byte {
	var out [][][]byte
	for _, au := range aus {
		var kept [][]byte
		for _, n := range au {
			if !nal.IsParam(c, n) {
				kept = append(kept, n)
			}
		}
		out = append(out, kept)
	}
	return out
}
