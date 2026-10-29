// synthrtsp serves the synthetic test stream of internal/camera/fakehlcamd
// over RTSP, H.264 or H.265, through the very code openqiarad uses (media
// hub, codec state, RTSP server), from a development machine: a way to try
// a Frigate, go2rtc or VLC configuration against OpenQiara's H.265 output
// before touching the camera, and to run outils/rtsp_mesure.py
// against a known stream. No camera, no hlcamd involved.
//
//	go run ./cmd/synthrtsp -codec h265 -listen :8554
//	ffplay rtsp://127.0.0.1:8554/openqiara
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/caligone/openqiara/internal/camera/fakehlcamd"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
	"github.com/caligone/openqiara/internal/rtspserver"
)

func main() {
	codecName := flag.String("codec", "h264", "codec of the stream served: h264 or h265")
	configured := flag.String("configured", "", "codec announced before the stream shows its own (video.codec); default: the stream's")
	listen := flag.String("listen", ":8554", "RTSP listen address")
	path := flag.String("path", "openqiara", "RTSP path")
	fps := flag.Int("fps", 30, "frames per second")
	params := flag.String("params-dir", "", "directory for the persisted parameter sets (none: not persisted)")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	codec, ok := nal.ParseCodec(*codecName)
	if !ok {
		fmt.Fprintln(os.Stderr, "synthrtsp: -codec must be h264 or h265")
		os.Exit(2)
	}
	conf := codec
	if *configured != "" {
		if conf, ok = nal.ParseCodec(*configured); !ok {
			fmt.Fprintln(os.Stderr, "synthrtsp: -configured must be h264 or h265")
			os.Exit(2)
		}
	}
	state := nal.NewState(conf, logger)
	hub := mediahub.New("synthetic "+codec.String(), fakehlcamd.Source(codec, fakehlcamd.Stream(codec), *fps, logger), nil, logger)
	hub.SetCodecState(state)
	cfg := rtspserver.Config{Listen: *listen, Path: *path}
	if *params != "" {
		cfg.ParamsFile = *params + "/openqiara_rtsp_h264_params"
		cfg.ParamsFileH265 = *params + "/openqiara_rtsp_h265_params"
	}
	srv := rtspserver.New(cfg, hub, logger)
	srv.SetCodecState(state)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := srv.Start(ctx); err != nil {
		logger.Error("synthrtsp", "error", err)
		os.Exit(1)
	}
	logger.Info("synthrtsp: serving", "url", "rtsp://127.0.0.1"+*listen+"/"+*path, "stream", codec.String(), "configured", conf.String())
	<-ctx.Done()
}
