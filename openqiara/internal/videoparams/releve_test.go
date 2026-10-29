package videoparams

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The reading Q179 of the 27/10/2026, 14 h 48 (read-only, passed on by the
// owner): hlcamd's file as it is, one line, {"parameters":{...},"ts":N}.
// Every entry has a "type"; the numeric ones have def, max, min and val;
// config.motion-detection.ignore-grid is a "vec<uint32>" with an empty val
// and width/height, and no def/min/max. The values of
// config.motion-detection.min-time-ms were not passed on: placeholders in
// the file, which no test reads. The night and day values are those of the
// reading Q177b of the same day.
var releves = []string{"testdata/releve-q179-hlcamd-parameters.json"}

func TestReleveParse(t *testing.T) {
	for _, f := range releves {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		n, err := Parse(b)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		// 21 entries, one of them (the grid) without a number: 20 read;
		// "ts" at the top level is no parameter.
		if len(n) != 20 {
			t.Errorf("%s: %d parameters, want 20", f, len(n))
		}
		if _, ok := n["config.motion-detection.ignore-grid"]; ok {
			t.Errorf("%s: the vec<uint32> grid read as a number", f)
		}
		if _, ok := n["ts"]; ok {
			t.Errorf("%s: ts read as a parameter", f)
		}
		if h := n["config.h265-enabled"]; !h.HasVal || h.Val != 1 || h.Min != 1 || h.Max != 1 {
			t.Errorf("%s: h265-enabled = %+v", f, h)
		}
		sh := n["config.sensor.night.MaxShutterUS"]
		if !sh.HasVal || sh.Val != 14000 || sh.Def != 14000 || sh.Min != 0 || sh.Max != 4294967295 {
			t.Errorf("%s: MaxShutterUS = %+v", f, sh)
		}
		d2n := n["config.sensor.d2n-threshold"]
		if d2n.Val != -50000 || d2n.Min != -50000 || d2n.Max != -20000 {
			t.Errorf("%s: d2n = %+v", f, d2n)
		}
		if n["config.sensor.day.brightness"].Val != 51 || n["config.sensor.day.brightness"].Def != 75 || n["config.sensor.day.saturation"].Val != 50 {
			t.Errorf("%s: day values %+v %+v", f, n["config.sensor.day.brightness"], n["config.sensor.day.saturation"])
		}
		if n["config.video.rotation.mode"].Val != 2 || n["config.video.rotation.mode"].Def != 0 {
			t.Errorf("%s: rotation = %+v", f, n["config.video.rotation.mode"])
		}
		// Every parameter of the list is in the file, under its key.
		for _, p := range Params {
			if _, ok := n[p.Key]; !ok {
				t.Errorf("%s: %s (%s) not in the reading", f, p.ID, p.Key)
			}
		}
	}
}

// The camera as read: the night at the vendor's defaults, the day image
// moved (brightness 51, saturation 50), so the day flag and the overall
// flag are off while the night flag is on.
func TestReleveSnapshot(t *testing.T) {
	for _, f := range releves {
		content, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		b := newBench(t, string(content))
		if err := b.Refresh(); err != nil {
			t.Fatal(err)
		}
		snap, ok := b.Current()
		if !ok {
			t.Fatal("no snapshot")
		}
		if !snap.NightDefaults || snap.DayDefaults || snap.Defaults {
			t.Errorf("%s: flags night %v day %v all %v", f, snap.NightDefaults, snap.DayDefaults, snap.Defaults)
		}
		want := map[string]any{
			"night_max_shutter_us": int64(14000), "night_max_sensor_gain": int64(8000), "night_max_isp_gain": int64(16383),
			"d2n_threshold":  int64(-50000),
			"day_brightness": int64(51), "day_contrast": int64(50), "day_saturation": int64(50), "day_lightness": int64(55),
		}
		for k, v := range want {
			if snap.Values[k] != v {
				t.Errorf("%s: %s = %v, want %v", f, k, snap.Values[k], v)
			}
		}
		if len(snap.Values) != len(Params) {
			t.Errorf("%s: %d values for %d parameters", f, len(snap.Values), len(Params))
		}
	}
}

// With hlcamd's own bounds at 0 and 4294967295 for the night keys, the
// list's bounds are the only protection: they hold. The day image takes
// its native 0 to 100. The restore orders write the file's factory
// defaults (brightness 75, saturation 75), per group.
func TestReleveWrites(t *testing.T) {
	content, err := os.ReadFile(releves[0])
	if err != nil {
		t.Fatal(err)
	}
	b := newBench(t, string(content))
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	refused := []struct{ id, payload string }{
		{"night_max_shutter_us", "500"},       // below the floor, though hlcamd's min is 0
		{"night_max_shutter_us", "20000"},     // above the vendor's default, though hlcamd's max is 4294967295
		{"night_max_sensor_gain", "9000"},     // 9 216 000, above the default
		{"night_max_isp_gain", "0"},           // hlcamd's min, below the floor
		{"night_max_isp_gain", "20000"},       // above the default
		{"d2n_threshold", "-10000"},           // outside both
		{"day_brightness", "101"},             // above the native 100
		{"day_saturation", "-1"},              // below the native 0
		{"day_contrast", "clair"},             // not a number
		{"day_dynamic_light_management", "1"}, // not in the list
	}
	for _, r := range refused {
		b.clock = b.clock.Add(2 * time.Second)
		if err := b.SetText(ctx, r.id, r.payload); err == nil || !(errors.Is(err, ErrBounds) || errors.Is(err, ErrUnknown)) {
			t.Errorf("%s=%s: %v", r.id, r.payload, err)
		}
	}
	if len(b.calls) != 0 {
		t.Fatalf("a refused value reached fbxbusctl: %v", b.calls)
	}
	accepted := []struct {
		id, payload string
		key         string
		raw         int64
	}{
		{"night_max_shutter_us", "10000", "config.sensor.night.MaxShutterUS", 10000},
		{"night_max_sensor_gain", "4000", "config.sensor.night.MaxSensorGain", 4096000},
		{"night_max_isp_gain", "8000", "config.sensor.night.MaxISPGain", 8000},
		{"d2n_threshold", "-30000", "config.sensor.d2n-threshold", -30000},
		{"day_brightness", "60", "config.sensor.day.brightness", 60},
		{"day_contrast", "0", "config.sensor.day.contrast", 0},
		{"day_saturation", "100", "config.sensor.day.saturation", 100},
		{"day_lightness", "55", "config.sensor.day.lightness", 55},
	}
	for _, a := range accepted {
		b.clock = b.clock.Add(2 * time.Second)
		if err := b.SetText(ctx, a.id, a.payload); err != nil {
			t.Fatalf("%s=%s: %v", a.id, a.payload, err)
		}
		if k, v := b.lastSet(t); k != a.key || v != a.raw {
			t.Errorf("%s=%s wrote %s=%d, want %s=%d", a.id, a.payload, k, v, a.key, a.raw)
		}
	}
	// The night restore writes the four night keys and only them; the day
	// restore the four day keys, at the file's factory defaults.
	b.calls = nil
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.RestoreGroup(ctx, GroupNight); err != nil {
		t.Fatal(err)
	}
	if got := writtenKeys(t, b.calls); len(got) != 5 || got["config.sensor.night.MaxSensorGain"] != 8192000 || got["config.sensor.dark-room.hint"] != 1 || got["config.sensor.day.brightness"] != 0 {
		t.Errorf("night restore wrote %v", got)
	}
	snap, _ := b.Current()
	if !snap.NightDefaults || snap.DayDefaults {
		t.Errorf("after the night restore: night %v day %v", snap.NightDefaults, snap.DayDefaults)
	}
	b.calls = nil
	if err := b.RestoreGroup(ctx, GroupDay); err != nil {
		t.Fatal(err)
	}
	if got := writtenKeys(t, b.calls); len(got) != 5 || got["config.sensor.day.brightness"] != 75 || got["config.sensor.day.saturation"] != 75 || got["config.sensor.day.contrast"] != 50 || got["config.sensor.day.lightness"] != 55 || got["config.sensor.day.dynamic.light.management"] != 1 {
		t.Errorf("day restore wrote %v", got)
	}
	if snap, _ := b.Current(); !snap.Defaults || !snap.DayDefaults {
		t.Errorf("after both restores: %+v", snap)
	}
	if err := b.RestoreGroup(ctx, "all"); !errors.Is(err, ErrUnknown) {
		t.Errorf("unknown group: %v", err)
	}
	// Written as the file would then be read back: the day image at its
	// factory defaults is told so, once the file says it.
	moved := strings.Replace(string(content), `"def":75,"max":100,"min":0,"type":"uint32","val":51`, `"def":75,"max":100,"min":0,"type":"uint32","val":75`, 1)
	moved = strings.Replace(moved, `"def":75,"max":100,"min":0,"type":"uint32","val":50`, `"def":75,"max":100,"min":0,"type":"uint32","val":75`, 1)
	if err := os.WriteFile(b.File, []byte(moved), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if snap, _ := b.Current(); !snap.Defaults {
		t.Errorf("file at factory defaults not told: %+v", snap)
	}
}

// writtenKeys reads the keys and values of the recorded fbxbusctl calls.
func writtenKeys(t *testing.T, calls []string) map[string]int64 {
	t.Helper()
	got := map[string]int64{}
	for _, c := range calls {
		var doc struct {
			Parameters map[string]struct{ Val int64 } `json:"parameters"`
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(c, "fbxbusctl set hlcamd video_settings ")), &doc); err != nil {
			t.Fatalf("call %q: %v", c, err)
		}
		for k, v := range doc.Parameters {
			got[k] = v.Val
		}
	}
	return got
}

// The test data file is the reading as transmitted: one line, the
// "parameters" envelope, a "ts" number beside it, a "type" in every entry.
func TestReleveFilesShape(t *testing.T) {
	for _, f := range releves {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Count(strings.TrimSpace(string(b)), "\n") != 0 {
			t.Errorf("%s: more than one line", f)
		}
		if filepath.Ext(f) != ".json" {
			t.Errorf("%s: not .json", f)
		}
		var doc struct {
			Parameters map[string]map[string]any `json:"parameters"`
			TS         int64                     `json:"ts"`
		}
		if err := json.Unmarshal(b, &doc); err != nil {
			t.Fatal(err)
		}
		if doc.TS == 0 || len(doc.Parameters) != 21 {
			t.Errorf("%s: ts %d, %d entries", f, doc.TS, len(doc.Parameters))
		}
		for k, e := range doc.Parameters {
			if _, ok := e["type"].(string); !ok {
				t.Errorf("%s: %s has no type", f, k)
			}
		}
		grid := doc.Parameters["config.motion-detection.ignore-grid"]
		if grid["type"] != "vec<uint32>" || grid["width"] != float64(96) || grid["height"] != float64(72) {
			t.Errorf("%s: grid = %v", f, grid)
		}
	}
}
