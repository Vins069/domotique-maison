package mqtt

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/caligone/openqiara/internal/videoparams"
)

// Every image setting has an entity of its own: a number within the list's
// bounds in shown units, typed (no slider), or a select over the options;
// all tied to the camera being on the broker.
func TestVideoDiscovery(t *testing.T) {
	p := &HAPublisher{prefix: "openqiara"}
	seen := map[string]bool{}
	for _, prm := range videoparams.Params {
		topic := videoEntityTopic(prm)
		d := p.videoDiscovery(prm)
		if seen[topic] || seen[d.UniqueID] {
			t.Fatalf("duplicate %s", topic)
		}
		seen[topic], seen[d.UniqueID] = true, true
		if d.CommandTopic != "openqiara/video/"+prm.ID+"/set" || d.StateTopic != "openqiara/video/state" || d.EntityCategory != "config" {
			t.Errorf("%s: %+v", prm.ID, d)
		}
		if len(d.Availability) != 1 || d.Availability[0].Topic != "openqiara/status" || d.Device.Identifiers[0] != cameraDeviceID {
			t.Errorf("%s: availability %+v device %+v", prm.ID, d.Availability, d.Device)
		}
		data, err := json.Marshal(d)
		if err != nil {
			t.Fatal(err)
		}
		if prm.IsChoice() {
			if !strings.HasPrefix(topic, "homeassistant/select/") || len(d.Options) != len(prm.Options) || d.Min != nil {
				t.Errorf("%s: select %s %+v", prm.ID, topic, d)
			}
			continue
		}
		if !strings.HasPrefix(topic, "homeassistant/number/") || d.Min == nil || d.Max == nil || d.Step == nil || d.Mode != "box" {
			t.Errorf("%s: number %s %s", prm.ID, topic, data)
		}
		if *d.Min != float64(prm.Min)/float64(prm.Scale) || *d.Max != float64(prm.Max)/float64(prm.Scale) {
			t.Errorf("%s: bounds %v..%v", prm.ID, *d.Min, *d.Max)
		}
	}
	gain, _ := videoparams.ByID("night_max_sensor_gain")
	d := p.videoDiscovery(gain)
	if *d.Min != 1 || *d.Max != 8000 || d.UnitOfMeasurement != "x" {
		t.Errorf("gain shown as a factor: %v..%v %s", *d.Min, *d.Max, d.UnitOfMeasurement)
	}
	// The extras: three flags (night, day, all), the native summary, three
	// restore buttons (night, day, all), each with a unique id of its own.
	flags, native, buttons := videoExtraTopics()
	if len(flags) != 3 || len(buttons) != 3 {
		t.Fatalf("%d flags, %d buttons", len(flags), len(buttons))
	}
	for i := range videoFlags {
		dd := p.videoFlagDiscovery(i)
		if dd.StateTopic != "openqiara/video/state" || dd.PayloadOn != "true" || !strings.Contains(flags[i], "binary_sensor") || !strings.Contains(dd.ValueTemplate, videoFlags[i].key) || seen[dd.UniqueID] {
			t.Errorf("flag %d: %s %+v", i, flags[i], dd)
		}
		seen[dd.UniqueID] = true
	}
	if nd := p.videoNativeDiscovery(); nd.JSONAttributesTopic != "openqiara/video/native" || !strings.Contains(native, "/sensor/") {
		t.Errorf("native entity: %s %+v", native, nd)
	}
	orders := map[string]bool{}
	for i := range videoButtons {
		var b map[string]any
		if err := json.Unmarshal(p.videoRestoreDiscovery(i), &b); err != nil {
			t.Fatal(err)
		}
		if b["command_topic"] != "openqiara/video/cmd" || !strings.HasPrefix(buttons[i], "homeassistant/button/") || seen[b["unique_id"].(string)] {
			t.Errorf("button %d: %s %v", i, buttons[i], b)
		}
		seen[b["unique_id"].(string)] = true
		orders[b["payload_press"].(string)] = true
	}
	if !orders[videoRestoreOrder] || !orders[videoRestoreNightOrder] || !orders[videoRestoreDayOrder] {
		t.Errorf("orders = %v", orders)
	}
}

// Served, the entities are published at each connection; not served, every
// topic an earlier run may have left is emptied.
func TestVideoDiscoveryServedOrRemoved(t *testing.T) {
	c := &recordingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	p.SetVideoParams(true)
	p.publishVideoDiscovery(context.Background())
	want := len(videoparams.Params) + 3 + 1 + 3 + 1 // parameters, flags, native, buttons, night-vision select
	if len(c.published) != want {
		t.Fatalf("%d publishes, want %d", len(c.published), want)
	}
	for _, m := range c.published {
		if !m.retain || m.payload == "" || !strings.HasPrefix(m.topic, "homeassistant/") {
			t.Errorf("served: %+v", m)
		}
	}
	c.published = nil
	p.SetVideoParams(false)
	p.publishVideoDiscovery(context.Background())
	if len(c.published) != want+3 {
		t.Fatalf("%d removals, want %d (the state topics too: video state, native, night vision)", len(c.published), want+3)
	}
	for _, m := range c.published {
		if !m.retain || m.payload != "" {
			t.Errorf("removal: %+v", m)
		}
	}
}

func TestPublishVideoState(t *testing.T) {
	c := &recordingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	snap := videoparams.Snapshot{
		Values:        map[string]any{"night_max_shutter_us": int64(10000), "d2n_threshold": int64(-50000)},
		Defaults:      false,
		NightDefaults: false,
		DayDefaults:   true,
		Native: map[string]videoparams.Native{
			"config.sensor.night.MaxShutterUS": {Val: 10000, Def: 14000, Min: 1, Max: 33333, HasVal: true, HasDef: true, HasMin: true, HasMax: true},
			"config.sensor.night_day_mode":     {Val: 1, HasVal: true},
			"eupid":                            {Val: 42, HasVal: true}, // not a config.* parameter: kept off the broker
		},
		ReadAt: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC),
	}
	if err := p.PublishVideoState(context.Background(), snap); err != nil {
		t.Fatal(err)
	}
	if len(c.published) != 2 || c.published[0].topic != "openqiara/video/state" || c.published[1].topic != "openqiara/video/native" || !c.published[0].retain || !c.published[1].retain {
		t.Fatalf("published %+v", c.published)
	}
	var state map[string]any
	if err := json.Unmarshal([]byte(c.published[0].payload), &state); err != nil {
		t.Fatal(err)
	}
	if state["night_max_shutter_us"] != float64(10000) || state["d2n_threshold"] != float64(-50000) || state["defaults"] != false || state["night_defaults"] != false || state["day_defaults"] != true || state["read_at"] != "2026-10-27T12:00:00Z" {
		t.Errorf("state = %v", state)
	}
	var native videoNativePayload
	if err := json.Unmarshal([]byte(c.published[1].payload), &native); err != nil {
		t.Fatal(err)
	}
	if native.Count != 2 || len(native.Parameters) != 2 || native.Parameters["config.sensor.night.MaxShutterUS"]["max"] != float64(33333) {
		t.Errorf("native = %+v", native)
	}
	if _, ok := native.Parameters["config.sensor.night_day_mode"]["def"]; ok {
		t.Error("a default the file lacks was published")
	}
	if _, ok := native.Parameters["eupid"]; ok {
		t.Error("a parameter outside config.* was published")
	}
}

// fakeSetter records what the handler asked for.
type fakeSetter struct {
	mu       sync.Mutex
	sets     []string
	restores int
	groups   []string
	err      error
}

func (f *fakeSetter) SetText(_ context.Context, id, payload string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sets = append(f.sets, id+"="+payload)
	return f.err
}

func (f *fakeSetter) RestoreDefaults(ctx context.Context) error { return f.RestoreGroup(ctx, "") }

func (f *fakeSetter) RestoreGroup(_ context.Context, group string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.restores++
	f.groups = append(f.groups, group)
	return f.err
}

func (f *fakeSetter) wait(t *testing.T, sets, restores int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		f.mu.Lock()
		ok := len(f.sets) == sets && f.restores == restores
		f.mu.Unlock()
		if ok {
			return
		}
		if time.Now().After(deadline) {
			f.mu.Lock()
			defer f.mu.Unlock()
			t.Fatalf("sets %v restores %d, want %d and %d", f.sets, f.restores, sets, restores)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Only a parameter of the list reaches the setter, by its id from the
// topic; a retained command (replayed at every start) never does, nor an
// unknown order.
func TestVideoCommandHandler(t *testing.T) {
	c := &recordingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	setter := &fakeSetter{}
	p.SetupVideoCommandHandler(context.Background(), setter, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if len(c.subscribed) != 2 || c.subscribed[0] != "openqiara/video/+/set" || c.subscribed[1] != "openqiara/video/cmd" {
		t.Fatalf("subscribed %v", c.subscribed)
	}
	p.subsMu.Lock()
	set := p.subs["openqiara/video/+/set"].handler
	cmd := p.subs["openqiara/video/cmd"].handler
	p.subsMu.Unlock()

	set(nil, fakeMessage{topic: "openqiara/video/night_max_shutter_us/set", payload: "10000"})
	setter.wait(t, 1, 0)
	set(nil, fakeMessage{topic: "openqiara/video/d2n_threshold/set", payload: "-30000"})
	setter.wait(t, 2, 0)
	// The day/night mode is the shutter's: dropped before the setter.
	set(nil, fakeMessage{topic: "openqiara/video/night_day_mode/set", payload: "jour forcé"})
	// Dropped before the setter.
	set(nil, fakeMessage{topic: "openqiara/video/night_max_shutter_us/set", payload: "10000", retained: true})
	set(nil, fakeMessage{topic: "openqiara/video/rotation/set", payload: "1"})
	set(nil, fakeMessage{topic: "openqiara/video/config.sensor.night.MaxShutterUS/set", payload: "1"})
	set(nil, fakeMessage{topic: "openqiara/video/a/b/set", payload: "1"})
	cmd(nil, fakeMessage{topic: "openqiara/video/cmd", payload: "reboot"})
	cmd(nil, fakeMessage{topic: "openqiara/video/cmd", payload: videoRestoreOrder, retained: true})
	cmd(nil, fakeMessage{topic: "openqiara/video/cmd", payload: videoRestoreOrder})
	setter.wait(t, 2, 1)
	cmd(nil, fakeMessage{topic: "openqiara/video/cmd", payload: videoRestoreNightOrder})
	setter.wait(t, 2, 2)
	cmd(nil, fakeMessage{topic: "openqiara/video/cmd", payload: videoRestoreDayOrder})
	setter.wait(t, 2, 3)
	time.Sleep(20 * time.Millisecond)
	setter.mu.Lock()
	defer setter.mu.Unlock()
	if strings.Join(setter.sets, ",") != "night_max_shutter_us=10000,d2n_threshold=-30000" || setter.restores != 3 || strings.Join(setter.groups, ",") != ",night,day" {
		t.Errorf("sets %v restores %d groups %v", setter.sets, setter.restores, setter.groups)
	}
	// An error of the setter is logged, nothing else happens.
	setter.err = errors.New("bounds")
	setter.mu.Unlock()
	set(nil, fakeMessage{topic: "openqiara/video/d2n_threshold/set", payload: "0"})
	setter.wait(t, 3, 3)
	setter.mu.Lock()
}

func TestVideoIDFromTopic(t *testing.T) {
	for topic, want := range map[string]string{
		"openqiara/video/d2n_threshold/set": "d2n_threshold",
		"openqiara/video//set":              "",
		"openqiara/video/x/y/set":           "",
		"openqiara/video/x/sett":            "",
		"other/video/x/set":                 "",
	} {
		if got := videoIDFromTopic("openqiara", topic); got != want {
			t.Errorf("%s: %q, want %q", topic, got, want)
		}
	}
}

// fakeMessage is a received MQTT message.
type fakeMessage struct {
	topic    string
	payload  string
	retained bool
}

func (m fakeMessage) Duplicate() bool   { return false }
func (m fakeMessage) Qos() byte         { return 1 }
func (m fakeMessage) Retained() bool    { return m.retained }
func (m fakeMessage) Topic() string     { return m.topic }
func (m fakeMessage) MessageID() uint16 { return 0 }
func (m fakeMessage) Payload() []byte   { return []byte(m.payload) }
func (m fakeMessage) Ack()              {}

// TestPublishVideoStateEmptySnapshot: a snapshot never read
// (zero ReadAt) is published without a panic.
func TestPublishVideoStateEmptySnapshot(t *testing.T) {
	c := &recordingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := p.PublishVideoState(context.Background(), videoparams.Snapshot{}); err != nil {
		t.Fatal(err)
	}
	if len(c.published) != 2 {
		t.Fatalf("published %+v", c.published)
	}
}

// TestNightVisionMapping checks the night-vision label↔wish mapping and the
// select's command handler.
func TestNightVisionMapping(t *testing.T) {
	cases := map[string]string{"Automatique": "auto", "Forcée": "forced", "Coupée": "off", "n'importe": "auto"}
	for label, want := range cases {
		if got := NightVisionWish(label); got != want {
			t.Errorf("NightVisionWish(%q) = %q, want %q", label, got, want)
		}
	}
	for _, w := range []string{"auto", "forced", "off"} {
		if got := NightVisionWish(nightVisionLabel(w)); got != w {
			t.Errorf("round trip %q -> %q -> %q", w, nightVisionLabel(w), got)
		}
	}

	c := &recordingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	setter := &fakeNightSetter{done: make(chan string, 4)}
	p.SetupNightVisionHandler(context.Background(), setter, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if len(c.subscribed) != 1 || c.subscribed[0] != "openqiara/night_vision/set" {
		t.Fatalf("subscribed %v", c.subscribed)
	}
	p.subsMu.Lock()
	h := p.subs["openqiara/night_vision/set"].handler
	p.subsMu.Unlock()

	h(nil, fakeMessage{topic: "openqiara/night_vision/set", payload: "Forcée"})
	if got := <-setter.done; got != "forced" {
		t.Errorf("wish = %q", got)
	}
	// A retained command (replayed at start) is ignored.
	h(nil, fakeMessage{topic: "openqiara/night_vision/set", payload: "Coupée", retained: true})
	select {
	case got := <-setter.done:
		t.Errorf("retained command reached the setter: %q", got)
	case <-time.After(30 * time.Millisecond):
	}
}

type fakeNightSetter struct{ done chan string }

func (f *fakeNightSetter) SetNightVision(_ context.Context, wish string) error {
	f.done <- wish
	return nil
}
