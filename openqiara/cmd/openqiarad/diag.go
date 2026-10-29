package main

import (
	"context"
	"log/slog"
	"strconv"
	"time"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
	"github.com/caligone/openqiara/internal/publisher"
	"github.com/caligone/openqiara/internal/qplus"
	"github.com/caligone/openqiara/internal/sonde"
)

// diagPeriod is how often the camera's health goes to Home Assistant.
const diagPeriod = time.Minute

// serveDiagnostics publishes, every minute, what the camera knows of its own
// health: Wi-Fi link, memory, storage, temperature, air quality, and when
// each sensor was last heard. It rides on the MQTT connection and stops with
// ctx; a minute with no connection is skipped, the next one tells all. The
// video codec goes with it: configured, served, and whether the
// two differ; kick asks for a reading now (the codec just changed).
func serveDiagnostics(ctx context.Context, pub *publisher.MQTTPublisher, cam camera.Client, version string,
	codec *nal.State, hub *mediahub.Hub, kick <-chan struct{}, logger *slog.Logger) {
	probe := sonde.New()
	ha := pub.HAPublisher()
	tick := time.NewTicker(diagPeriod)
	defer tick.Stop()
	first := time.After(20 * time.Second) // let the broker connect first
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
		case <-tick.C:
		case <-kick:
		}
		if !ha.IsConnected() {
			continue
		}
		reading := map[string]any(probe.System())
		for k, v := range codecDiag(codec, hub) {
			reading[k] = v
		}
		for k, v := range probe.Vendor(ctx) {
			reading[k] = v
		}
		for k, v := range qplus.Default.MemoryDiag() {
			reading[k] = v
		}
		for k, v := range qplus.Default.Diag() {
			reading[k] = v
		}
		reading["version"] = version
		reading["mqtt_reconnects"] = ha.Reconnects()
		seen := map[string]string{}
		for _, s := range cam.CachedSensors() {
			if s.LastSeen > 0 {
				seen[strconv.Itoa(s.ID)] = time.Unix(s.LastSeen, 0).UTC().Format(time.RFC3339)
			}
		}
		if len(seen) > 0 {
			reading["last_seen"] = seen
		}
		if err := ha.PublishDiag(ctx, reading); err != nil {
			logger.Debug("diagnostics not published", "error", err)
		}
	}
}

// codecDiag is the video codec's part of the diagnostic reading: the codec
// served (video_codec, what RTSP and HLS carry), the one configured, and a
// problem flag when the stream contradicts the setting; the NAL counts
// since the start as an attribute map (no entity of its own).
func codecDiag(codec *nal.State, hub *mediahub.Hub) map[string]any {
	if codec == nil {
		return nil
	}
	r := map[string]any{
		"video_codec":            codec.Effective().String(),
		"video_codec_configured": codec.Configured().String(),
		"video_codec_mismatch":   "OFF",
	}
	if codec.Mismatch() {
		r["video_codec_mismatch"] = "ON"
	}
	if hub != nil {
		r["video_nal"] = hub.NALCounts()
	}
	return r
}
