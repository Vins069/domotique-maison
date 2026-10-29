// feedhlcamd plays an Annex B elementary stream (H.264 or H.265, a capture
// of the camera or a synthetic one) on hlcamd's multicast group of the
// loopback, in hlcamd's fragment format, so that a real openqiarad (on an
// ARM bench under qemu, or on a development machine) is fed as the camera
// feeds it. The daemon under test reads 224.0.0.1:9600 on lo: this tool
// sends there through lo (test bench). No camera involved.
//
//	go run ./cmd/feedhlcamd -codec h264 -file capture.h264 -fps 30 -loop
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/net/ipv4"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/nal"
)

func main() {
	codecName := flag.String("codec", "h264", "codec of the stream: h264 or h265")
	file := flag.String("file", "", "Annex B elementary stream to play")
	fps := flag.Int("fps", 30, "frames per second")
	loop := flag.Bool("loop", true, "play over and over")
	addr := flag.String("addr", fmt.Sprintf("%s:%d", camera.MulticastGroup, camera.MulticastVideoMain), "multicast destination")
	ifname := flag.String("if", "lo", "interface the multicast is sent through")
	frag := flag.Int("frag", 24*1024, "fragment data size (hlcamd: up to 24 KiB on the loopback)")
	dur := flag.Duration("duration", 0, "stop after this time (0: until interrupted)")
	flag.Parse()

	codec, ok := nal.ParseCodec(*codecName)
	if !ok || *file == "" {
		fmt.Fprintln(os.Stderr, "feedhlcamd: -codec h264|h265 and -file are required")
		os.Exit(2)
	}
	stream, err := os.ReadFile(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "feedhlcamd:", err)
		os.Exit(1)
	}
	aus := fakehlcamd.AccessUnits(codec, stream, false)
	if len(aus) == 0 {
		fmt.Fprintln(os.Stderr, "feedhlcamd: no access unit found in", *file)
		os.Exit(1)
	}
	ifi, err := net.InterfaceByName(*ifname)
	if err != nil {
		fmt.Fprintln(os.Stderr, "feedhlcamd:", err)
		os.Exit(1)
	}
	dst, err := net.ResolveUDPAddr("udp4", *addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "feedhlcamd:", err)
		os.Exit(1)
	}
	raw, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "feedhlcamd:", err)
		os.Exit(1)
	}
	pc := ipv4.NewPacketConn(raw)
	if err := pc.SetMulticastInterface(ifi); err != nil {
		fmt.Fprintln(os.Stderr, "feedhlcamd: multicast interface:", err)
		os.Exit(1)
	}
	_ = pc.SetMulticastLoopback(true)
	_ = pc.SetMulticastTTL(1)
	snd := &fakehlcamd.Sender{FragmentSize: *frag}
	snd.SetWriter(func(p []byte) error { _, err := raw.WriteTo(p, dst); return err })

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if *dur > 0 {
		ctx, cancel = context.WithTimeout(ctx, *dur)
		defer cancel()
	}
	keys := 0
	for _, au := range aus {
		if fakehlcamd.IsKey(codec, au) {
			keys++
		}
	}
	fmt.Fprintf(os.Stderr, "feedhlcamd: %s, %d access units (%d key pictures), %d fps, to %s via %s, fragments of %d bytes\n",
		codec, len(aus), keys, *fps, dst, ifi.Name, *frag)
	start := time.Now()
	var head, rest [][][]byte
	if *loop {
		rest = aus
	} else {
		head = aus
	}
	sent := snd.PlayAUs(ctx, codec, head, rest, *fps)
	fmt.Fprintf(os.Stderr, "feedhlcamd: %d frames sent in %s\n", sent, time.Since(start).Round(time.Millisecond))
}
