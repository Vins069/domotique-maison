package videoparams

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A file as the study describes it: parameters by key, each with its value,
// default, minimum and maximum.
const fileA = `{"parameters":{
  "config.sensor.night.MaxShutterUS":{"val":14000,"def":14000,"min":1,"max":33333},
  "config.sensor.night.MaxSensorGain":{"val":8192000,"def":8192000,"min":1024,"max":8192000},
  "config.sensor.night.MaxISPGain":{"val":16383,"def":16383,"min":1,"max":16383},
  "config.sensor.night.MinShutterUS":{"val":1,"def":1,"min":1,"max":33333},
  "config.sensor.d2n-threshold":{"val":-50000,"def":-50000,"min":-50000,"max":-20000},
  "config.sensor.night_day_mode":{"val":1,"def":1,"min":0,"max":2},
  "config.sensor.day.brightness":{"val":75,"def":75,"min":0,"max":100},
  "config.sensor.day.contrast":{"val":50,"def":50,"min":0,"max":100},
  "config.sensor.day.saturation":{"val":75,"def":75,"min":0,"max":100},
  "config.sensor.day.lightness":{"val":55,"def":55,"min":0,"max":100},
  "config.sensor.day.dynamic.light.management":{"val":1,"def":1,"min":0,"max":1},
  "config.sensor.dark-room.hint":{"val":1,"def":1,"min":0,"max":1},
  "config.video.rotation.mode":{"val":2,"def":0,"min":0,"max":3},
  "config.some.text":{"val":"abc"}
}}`

// restorable is the count of parameters the restore orders touch (NoRestore
// excluded): the rotation is kept out so a restore never turns the picture.
func restorable() int {
	n := 0
	for _, p := range Params {
		if !p.NoRestore {
			n++
		}
	}
	return n
}

func TestParseShapes(t *testing.T) {
	n, err := Parse([]byte(fileA))
	if err != nil {
		t.Fatal(err)
	}
	if len(n) != 13 {
		t.Fatalf("%d numeric parameters, want 13 (the text one left out): %v", len(n), n)
	}
	sh := n["config.sensor.night.MaxShutterUS"]
	if !sh.HasVal || sh.Val != 14000 || !sh.HasMax || sh.Max != 33333 || sh.Min != 1 {
		t.Errorf("MaxShutterUS = %+v", sh)
	}
	// The same parameters at the top level, with floats and strings.
	flat := `{"config.sensor.d2n-threshold":{"val":-50000.0,"def":"-50000"}}`
	n, err = Parse([]byte(flat))
	if err != nil || n["config.sensor.d2n-threshold"].Val != -50000 || !n["config.sensor.d2n-threshold"].HasDef {
		t.Errorf("flat: %v %v", n, err)
	}
	// A list of objects naming their key.
	list := `[{"name":"config.sensor.night.MaxISPGain","val":100,"max":16383},{"key":"x","val":1},{"val":3}]`
	n, err = Parse([]byte(list))
	if err != nil || len(n) != 2 || n["config.sensor.night.MaxISPGain"].Val != 100 || n["x"].Val != 1 {
		t.Errorf("list: %v %v", n, err)
	}
	for _, bad := range []string{"", "nope", "42", `{"parameters":{"k":{"val":1.5}}}`} {
		n, err := Parse([]byte(bad))
		if err == nil && len(n) != 0 {
			t.Errorf("%q: %v", bad, n)
		}
	}
}

// The list's own invariants: unique ids and keys, defaults within bounds,
// a maximum never beyond the vendor's default.
func TestParamsInvariants(t *testing.T) {
	ids, keys := map[string]bool{}, map[string]bool{}
	for _, p := range Params {
		if ids[p.ID] || keys[p.Key] || p.ID == "" || !strings.HasPrefix(p.Key, "config.") {
			t.Errorf("duplicate or malformed: %+v", p)
		}
		ids[p.ID], keys[p.Key] = true, true
		if !p.allowed(p.Def) {
			t.Errorf("%s: default %d outside %d..%d", p.ID, p.Def, p.Min, p.Max)
		}
		if p.Scale < 1 {
			t.Errorf("%s: scale %d", p.ID, p.Scale)
		}
		if strings.Contains(p.Key, "Max") && !p.IsChoice() && p.Max != p.Def {
			t.Errorf("%s: a maximum must stop at the vendor's default (%d), has %d", p.ID, p.Def, p.Max)
		}
		if !p.IsChoice() && p.Step <= 0 {
			t.Errorf("%s: step %d", p.ID, p.Step)
		}
	}
	for _, id := range []string{"night_max_shutter_us", "night_max_sensor_gain", "night_max_isp_gain", "d2n_threshold"} {
		if !ids[id] {
			t.Errorf("%s missing", id)
		}
	}
}

func TestShown(t *testing.T) {
	gain, _ := ByID("night_max_sensor_gain")
	if v := gain.Shown(8192000); v != int64(8000) {
		t.Errorf("gain shown = %v", v)
	}
	if v := gain.Shown(1536); v != int64(2) { // 1.5x rounds to 2
		t.Errorf("gain 1536 shown = %v", v)
	}
	// The day/night mode belongs to the shutter: not in the list.
	if _, ok := ByID("night_day_mode"); ok {
		t.Error("night_day_mode is the shutter's, not an entity")
	}
	if _, ok := ByID("config.sensor.night.MaxShutterUS"); ok {
		t.Error("a key is not an id")
	}
}

// bench is a service over a file in a temporary directory, with a recorded
// fbxbusctl.
type bench struct {
	*Service
	calls []string
	snaps []Snapshot
	clock time.Time
}

func newBench(t *testing.T, content string) *bench {
	t.Helper()
	dir := t.TempDir()
	b := &bench{clock: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)}
	b.Service = New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	b.File = filepath.Join(dir, "hlcamd-parameters.json")
	b.now = func() time.Time { return b.clock }
	b.Exec = func(_ context.Context, name string, args ...string) ([]byte, error) {
		b.calls = append(b.calls, name+" "+strings.Join(args, " "))
		return nil, nil
	}
	b.OnChange = func(s Snapshot) { b.snaps = append(b.snaps, s) }
	if content != "" {
		if err := os.WriteFile(b.File, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return b
}

func (b *bench) lastSet(t *testing.T) (key string, val int64) {
	t.Helper()
	if len(b.calls) == 0 {
		t.Fatal("no fbxbusctl call")
	}
	c := b.calls[len(b.calls)-1]
	const head = "fbxbusctl set hlcamd video_settings "
	if !strings.HasPrefix(c, head) {
		t.Fatalf("call %q", c)
	}
	var doc struct {
		Parameters map[string]struct{ Val int64 } `json:"parameters"`
	}
	if err := json.Unmarshal([]byte(strings.TrimPrefix(c, head)), &doc); err != nil {
		t.Fatalf("settings not JSON: %v: %s", err, c)
	}
	if len(doc.Parameters) != 1 {
		t.Fatalf("%d parameters in one set", len(doc.Parameters))
	}
	for k, v := range doc.Parameters {
		return k, v.Val
	}
	return "", 0
}

func TestRefreshAndSnapshot(t *testing.T) {
	b := newBench(t, fileA)
	if !b.Available() {
		t.Fatal("file not seen")
	}
	if _, ok := b.Current(); ok {
		t.Fatal("a snapshot before the first read")
	}
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	snap, ok := b.Current()
	if !ok || !snap.Defaults {
		t.Fatalf("snapshot = %+v", snap)
	}
	if snap.Values["night_max_sensor_gain"] != int64(8000) || snap.Values["d2n_threshold"] != int64(-50000) {
		t.Errorf("values = %v", snap.Values)
	}
	if _, ok := snap.Native["config.video.rotation.mode"]; !ok {
		t.Error("every numeric parameter is in Native")
	}
	if len(b.snaps) != 1 {
		t.Fatalf("%d changes told after the first read", len(b.snaps))
	}
	// The same file again: no change told.
	if err := b.Refresh(); err != nil || len(b.snaps) != 1 {
		t.Errorf("unchanged file told a change (%d), err %v", len(b.snaps), err)
	}
	// A value moved by hand (or the vendor's app): told, no longer defaults.
	if err := os.WriteFile(b.File, []byte(strings.Replace(fileA, `"val":8192000`, `"val":4096000`, 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := b.Refresh(); err != nil || len(b.snaps) != 2 || b.snaps[1].Defaults || b.snaps[1].Values["night_max_sensor_gain"] != int64(4000) {
		t.Errorf("changed file: %d snaps, last %+v, err %v", len(b.snaps), b.snaps[len(b.snaps)-1], err)
	}
}

func TestSetWritesWithinBounds(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	// Before the first read nothing is written: the bounds are not known.
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); !errors.Is(err, ErrNoFile) {
		t.Fatalf("before read: %v", err)
	}
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); err != nil {
		t.Fatal(err)
	}
	if k, v := b.lastSet(t); k != "config.sensor.night.MaxShutterUS" || v != 10000 {
		t.Errorf("set %s=%d", k, v)
	}
	// The written value shows at once, pending the file.
	snap, _ := b.Current()
	if snap.Values["night_max_shutter_us"] != int64(10000) || snap.Defaults {
		t.Errorf("after write: %+v", snap)
	}
	// Shown units are converted: a gain factor of 4000 is 4 096 000.
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "night_max_sensor_gain", "4000"); err != nil {
		t.Fatal(err)
	}
	if k, v := b.lastSet(t); k != "config.sensor.night.MaxSensorGain" || v != 4096000 {
		t.Errorf("set %s=%d", k, v)
	}
	calls := len(b.calls)
	refused := []struct{ id, payload string }{
		{"night_max_shutter_us", "14500"}, // above the vendor's default
		{"night_max_shutter_us", "999"},   // below the floor
		{"night_max_sensor_gain", "8001"},
		{"night_max_sensor_gain", "0"},
		{"d2n_threshold", "-19000"},
		{"d2n_threshold", "-51000"},
		{"night_day_mode", "auto"}, // the shutter's, not an entity
		{"night_max_isp_gain", "abc"},
		{"night_max_isp_gain", "NaN"},
		{"night_max_isp_gain", "1e30"},
		{"config.sensor.night.MaxShutterUS", "5000"}, // a key is not an id
		{"rotation", "1"},
	}
	for _, r := range refused {
		b.clock = b.clock.Add(2 * time.Second)
		err := b.SetText(ctx, r.id, r.payload)
		if err == nil || !(errors.Is(err, ErrBounds) || errors.Is(err, ErrUnknown)) {
			t.Errorf("%s=%s: %v", r.id, r.payload, err)
		}
	}
	if len(b.calls) != calls {
		t.Errorf("a refused value reached fbxbusctl: %v", b.calls[calls:])
	}
}

// hlcamd's own bounds, when narrower than this file's, win too.
func TestNativeBoundsNarrower(t *testing.T) {
	narrow := strings.Replace(fileA, `"val":14000,"def":14000,"min":1,"max":33333`, `"val":14000,"def":14000,"min":5000,"max":12000`, 1)
	b := newBench(t, narrow)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if err := b.SetText(ctx, "night_max_shutter_us", "4000"); !errors.Is(err, ErrBounds) {
		t.Errorf("below hlcamd's min: %v", err)
	}
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "night_max_shutter_us", "13000"); !errors.Is(err, ErrBounds) {
		t.Errorf("above hlcamd's max: %v", err)
	}
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "night_max_shutter_us", "8000"); err != nil {
		t.Errorf("within both: %v", err)
	}
	// A parameter the file lacks is not written: nothing to check it against.
	without := strings.Replace(fileA, `"config.sensor.night.MaxISPGain":{"val":16383,"def":16383,"min":1,"max":16383},`, "", 1)
	b2 := newBench(t, without)
	if err := b2.Refresh(); err != nil {
		t.Fatal(err)
	}
	if err := b2.SetText(ctx, "night_max_isp_gain", "1000"); !errors.Is(err, ErrNotReady) {
		t.Errorf("absent parameter: %v", err)
	}
	if len(b2.calls) != 0 {
		t.Error("written all the same")
	}
}

func TestLockAndRate(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	b.Lock = true
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); !errors.Is(err, ErrLocked) {
		t.Errorf("locked: %v", err)
	}
	if err := b.RestoreDefaults(ctx); !errors.Is(err, ErrLocked) {
		t.Errorf("locked restore: %v", err)
	}
	b.Lock = false
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); err != nil {
		t.Fatal(err)
	}
	// A second write within a second is a slider's stream: refused.
	if err := b.SetText(ctx, "night_max_shutter_us", "11000"); !errors.Is(err, ErrTooFast) {
		t.Errorf("fast second write: %v", err)
	}
	// Sixty an hour at most.
	for i := 0; i < maxPerHour-1; i++ {
		b.clock = b.clock.Add(2 * time.Second)
		if err := b.SetText(ctx, "night_max_shutter_us", "10000"); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
	}
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); !errors.Is(err, ErrTooFast) {
		t.Errorf("61st write in the hour: %v", err)
	}
	b.clock = b.clock.Add(time.Hour)
	if err := b.SetText(ctx, "night_max_shutter_us", "10000"); err != nil {
		t.Errorf("an hour later: %v", err)
	}
	if len(b.calls) != maxPerHour+1 {
		t.Errorf("%d calls", len(b.calls))
	}
}

func TestRestoreDefaults(t *testing.T) {
	// hlcamd's defaults differ from the study's for one parameter, within
	// bounds (taken), and for another, outside them (the study's kept).
	content := strings.Replace(fileA, `"val":14000,"def":14000,"min":1,"max":33333`, `"val":9000,"def":12000,"min":1,"max":33333`, 1)
	content = strings.Replace(content, `"val":-50000,"def":-50000,"min":-50000,"max":-20000`, `"val":-30000,"def":-10000,"min":-50000,"max":-20000`, 1)
	b := newBench(t, content)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if snap, _ := b.Current(); snap.Defaults {
		t.Error("defaults with a moved value")
	}
	if err := b.RestoreDefaults(ctx); err != nil {
		t.Fatal(err)
	}
	if len(b.calls) != restorable() {
		t.Fatalf("%d calls for %d restorable parameters", len(b.calls), restorable())
	}
	got := map[string]int64{}
	for _, c := range b.calls {
		var doc struct {
			Parameters map[string]struct{ Val int64 } `json:"parameters"`
		}
		_ = json.Unmarshal([]byte(strings.TrimPrefix(c, "fbxbusctl set hlcamd video_settings ")), &doc)
		for k, v := range doc.Parameters {
			got[k] = v.Val
		}
	}
	if got["config.sensor.night.MaxShutterUS"] != 12000 {
		t.Errorf("hlcamd's default within bounds not used: %v", got)
	}
	if got["config.sensor.d2n-threshold"] != -50000 {
		t.Errorf("hlcamd's default outside bounds used: %v", got)
	}
	if got["config.sensor.night.MaxSensorGain"] != 8192000 {
		t.Errorf("defaults: %v", got)
	}
	if snap, _ := b.Current(); !snap.Defaults {
		t.Errorf("not at defaults after restore: %+v", snap)
	}
}

// A write the file does not confirm goes back to what the file says.
func TestPendingDroppedByFile(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if err := b.SetText(ctx, "night_max_isp_gain", "1000"); err != nil {
		t.Fatal(err)
	}
	if snap, _ := b.Current(); snap.Values["night_max_isp_gain"] != int64(1000) {
		t.Fatalf("pending not shown: %v", snap.Values)
	}
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	if snap, _ := b.Current(); snap.Values["night_max_isp_gain"] != int64(16383) || !snap.Defaults {
		t.Errorf("file not the truth: %+v", snap)
	}
}

// fbxbusctl failing leaves the state as it was.
func TestSetFailure(t *testing.T) {
	b := newBench(t, fileA)
	b.Exec = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("error: no such method\n"), errors.New("exit status 1")
	}
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	err := b.SetText(ctx, "night_max_shutter_us", "10000")
	if err == nil || !strings.Contains(err.Error(), "no such method") {
		t.Fatalf("err = %v", err)
	}
	if snap, _ := b.Current(); snap.Values["night_max_shutter_us"] != int64(14000) {
		t.Errorf("state moved on a failed write: %v", snap.Values)
	}
}

// Run reads at start, then soon after a kick.
func TestRunKick(t *testing.T) {
	b := newBench(t, fileA)
	b.ConfirmDelay = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { b.Run(ctx, time.Hour); close(done) }()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, ok := b.Current(); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no first read")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := os.WriteFile(b.File, []byte(strings.Replace(fileA, `"val":16383`, `"val":100`, 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	b.Kick()
	for {
		if snap, _ := b.Current(); snap.Values["night_max_isp_gain"] == int64(100) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("kick did not read the file")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	// Without the file, Available says so and Run keeps going.
	b2 := newBench(t, "")
	if b2.Available() {
		t.Error("available without a file")
	}
	if err := b2.Refresh(); err == nil {
		t.Error("read a missing file")
	}
}

// TestOneWriteAtATime: a burst of commands while a bus call is
// in progress starts no second fbxbusctl; the others are refused at once
// with ErrBusy, whatever the goroutine count.
func TestOneWriteAtATime(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	running, maxRunning := 0, 0
	release := make(chan struct{})
	b.Exec = func(_ context.Context, name string, args ...string) ([]byte, error) {
		mu.Lock()
		running++
		if running > maxRunning {
			maxRunning = running
		}
		mu.Unlock()
		<-release
		mu.Lock()
		running--
		mu.Unlock()
		return nil, nil
	}
	const burst = 200
	errs := make(chan error, burst)
	var wg sync.WaitGroup
	for i := 0; i < burst; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if i%2 == 0 {
				errs <- b.SetText(ctx, "night_max_shutter_us", "10000")
			} else {
				errs <- b.RestoreGroup(ctx, GroupNight)
			}
		}(i)
	}
	// Let every goroutine reach the slot, then free the one bus call.
	time.Sleep(200 * time.Millisecond)
	mu.Lock()
	inFlight := running
	mu.Unlock()
	if inFlight != 1 {
		t.Fatalf("%d bus calls in flight during the burst, want 1", inFlight)
	}
	close(release)
	wg.Wait()
	close(errs)
	ok, busy := 0, 0
	for err := range errs {
		switch {
		case err == nil:
			ok++
		case errors.Is(err, ErrBusy):
			busy++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if ok != 1 || busy != burst-1 || maxRunning != 1 {
		t.Errorf("ok %d busy %d, max concurrent bus calls %d", ok, busy, maxRunning)
	}
}

// TestRotationNotRestored checks the rotation (NoRestore): it is shown, it
// can be set, but a "restore all" never writes it and it never flips the
// "at defaults" flags.
func TestRotationNotRestored(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	// fileA has rotation at 2 (mounted upside down), factory default 0: the
	// snapshot must still read "at defaults" and show the rotation.
	snap, _ := b.Current()
	if !snap.Defaults || !snap.DayDefaults {
		t.Fatalf("rotation at 2 must not flip defaults: %+v", snap)
	}
	if snap.Values["image_rotation"] != "Retournée (2)" {
		t.Errorf("rotation shown = %v", snap.Values["image_rotation"])
	}
	// A restore-all does not touch the rotation.
	b.calls = nil
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.RestoreDefaults(ctx); err != nil {
		t.Fatal(err)
	}
	for _, c := range b.calls {
		if strings.Contains(c, "config.video.rotation.mode") {
			t.Errorf("restore touched the rotation: %s", c)
		}
	}
	// The rotation can still be set on its own.
	b.calls = nil
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "image_rotation", "Normale (0)"); err != nil {
		t.Fatal(err)
	}
	if k, v := b.lastSet(t); k != "config.video.rotation.mode" || v != 0 {
		t.Errorf("rotation set wrote %s=%d", k, v)
	}
}

// TestDayToggleWrites checks the two new day/night toggles write 0/1.
func TestDayToggleWrites(t *testing.T) {
	b := newBench(t, fileA)
	ctx := context.Background()
	if err := b.Refresh(); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		id, label, key string
		raw            int64
	}{
		{"day_dynamic_light", "Désactivée", "config.sensor.day.dynamic.light.management", 0},
		{"dark_room_hint", "Désactivée", "config.sensor.dark-room.hint", 0},
		{"day_dynamic_light", "Activée", "config.sensor.day.dynamic.light.management", 1},
	}
	for _, c := range cases {
		b.clock = b.clock.Add(2 * time.Second)
		if err := b.SetText(ctx, c.id, c.label); err != nil {
			t.Fatalf("%s=%s: %v", c.id, c.label, err)
		}
		if k, v := b.lastSet(t); k != c.key || v != c.raw {
			t.Errorf("%s=%s wrote %s=%d, want %s=%d", c.id, c.label, k, v, c.key, c.raw)
		}
	}
	// An unknown label is refused.
	b.clock = b.clock.Add(2 * time.Second)
	if err := b.SetText(ctx, "day_dynamic_light", "Peut-être"); err == nil {
		t.Error("unknown select label accepted")
	}
}
