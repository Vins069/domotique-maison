package camera

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"log/slog"
	"net"
	"testing"
	"time"
)

// fragments cuts a frame the way hlcamd does (24-byte header, then data):
// the writer of the fake hlcamd, which these tests hold to the parser.
func fragments(ts uint64, seq uint32, frame []byte, size int) [][]byte {
	return EncodeMulticastFragments(ts, seq, false, frame, size)
}

// The writer lays the header out as the parser reads it, field by field
// (the fake hlcamd of the RTSP and HLS tests relies on it).
func TestEncodeMulticastFragmentsHeader(t *testing.T) {
	frame := bytes.Repeat([]byte{7}, 700)
	frags := EncodeMulticastFragments(123_456_789, 42, true, frame, 300)
	if len(frags) != 3 {
		t.Fatalf("%d fragments, want 3", len(frags))
	}
	for i, p := range frags {
		if len(p) < MulticastHeaderSize {
			t.Fatalf("fragment %d too short", i)
		}
		if binary.LittleEndian.Uint64(p[0:]) != 123_456_789 || p[8] != multicastKeyFlag ||
			p[9] != byte(i+1)|3<<4 || binary.LittleEndian.Uint32(p[10:]) != 42 ||
			binary.LittleEndian.Uint32(p[14:]) != uint32(300*i) || binary.LittleEndian.Uint32(p[18:]) != 700 {
			t.Fatalf("fragment %d header: % x", i, p[:MulticastHeaderSize])
		}
		f, err := parseMulticastFragment(p)
		if err != nil {
			t.Fatal(err)
		}
		if int(binary.LittleEndian.Uint16(p[22:])) != len(f.data) {
			t.Fatalf("fragment %d: data_size %d, data %d", i, binary.LittleEndian.Uint16(p[22:]), len(f.data))
		}
	}
	if p := EncodeMulticastFragments(1, 1, false, nil, 300); len(p) != 1 || p[0][8] != 0 || len(p[0]) != MulticastHeaderSize {
		t.Fatalf("empty frame: %d fragments, % x", len(p), p[0])
	}
}

func TestFrameAssembler(t *testing.T) {
	frame := bytes.Repeat([]byte{0, 0, 0, 1, 0x65, 1, 2, 3}, 100)
	var a frameAssembler
	frags := fragments(1_000_000, 7, frame, 300)
	for i, p := range frags {
		f, err := parseMulticastFragment(p)
		if err != nil {
			t.Fatal(err)
		}
		got, ok := a.add(f)
		if ok != (i == len(frags)-1) {
			t.Fatalf("fragment %d: complete=%v", i, ok)
		}
		if ok && !bytes.Equal(got, frame) {
			t.Fatal("frame differs")
		}
	}
}

func TestFrameAssemblerDropsIncomplete(t *testing.T) {
	var a frameAssembler
	first := fragments(1, 1, make([]byte, 600), 300)
	second := fragments(2, 2, []byte{9, 9, 9}, 300)
	f, _ := parseMulticastFragment(first[0]) // the rest of frame 1 is lost
	if _, ok := a.add(f); ok {
		t.Fatal("incomplete frame returned")
	}
	f, _ = parseMulticastFragment(second[0])
	got, ok := a.add(f)
	if !ok || !bytes.Equal(got, []byte{9, 9, 9}) {
		t.Fatalf("next frame = %v %v", got, ok)
	}
}

func TestParseMulticastFragmentBounds(t *testing.T) {
	p := fragments(1, 1, []byte{1, 2, 3}, 300)[0]
	binary.LittleEndian.PutUint16(p[22:], 10)
	if _, err := parseMulticastFragment(p); err == nil {
		t.Fatal("data_size past the packet accepted")
	}
	if _, err := parseMulticastFragment(p[:10]); err == nil {
		t.Fatal("short packet accepted")
	}
	q := fragments(1, 1, []byte{1, 2, 3}, 300)[0]
	binary.LittleEndian.PutUint32(q[18:], 1<<30)
	if _, err := parseMulticastFragment(q); err == nil {
		t.Fatal("oversized frame accepted")
	}
	q = fragments(1, 1, []byte{1, 2, 3}, 300)[0]
	binary.LittleEndian.PutUint32(q[18:], maxFrameSize)
	if _, err := parseMulticastFragment(q); err != nil {
		t.Fatalf("frame at the limit refused: %v", err)
	}
}

func TestReadMulticastVideo(t *testing.T) {
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	samples := readMulticast(ctx, conn, "video", slog.New(slog.NewTextHandler(io.Discard, nil)), emitNALs)

	tx, err := net.Dial("udp4", conn.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	frame := []byte{0, 0, 0, 1, 0x67, 0x42, 0x1f, 0, 0, 0, 1, 0x65, 0xaa}
	for _, p := range fragments(2_000_000, 3, frame, 5) {
		if _, err := tx.Write(p); err != nil {
			t.Fatal(err)
		}
	}
	for _, want := range [][]byte{{0x67, 0x42, 0x1f}, {0x65, 0xaa}} {
		select {
		case s := <-samples:
			if !s.IsVideo || s.PTS != 180_000 || !bytes.Equal(s.Data, want) {
				t.Fatalf("sample = %+v, want NAL % x", s, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("no sample")
		}
	}
	cancel()
	for range samples { // closes once ctx ends
	}
}
