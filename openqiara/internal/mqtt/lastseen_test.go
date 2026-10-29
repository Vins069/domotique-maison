package mqtt

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/caligone/openqiara/internal/camera"
)

// TestLastSeenRetainedOwnTopic: the "last heard" time goes on a
// retained topic of its own, published once known and on change only, so
// that Home Assistant keeps the last value across a restart of the camera
// (where the time, kept in memory, starts again from nothing).
func TestLastSeenRetainedOwnTopic(t *testing.T) {
	p, c := newRecordingPublisher()
	p.prefix = "openqiara"
	p.sensors = []camera.Sensor{{ID: 14, Type: "PIR"}, {ID: 20, Type: "SRN"}}
	ctx := context.Background()

	find := func(topic string) (recordedPublish, bool) {
		for _, m := range c.published {
			if m.topic == topic {
				return m, true
			}
		}
		return recordedPublish{}, false
	}

	// after a restart, nothing heard yet: no last-seen state at all
	if err := p.PublishDiag(ctx, map[string]any{"uptime_s": 30}); err != nil {
		t.Fatal(err)
	}
	if _, ok := find("openqiara/sensor/14/last_seen"); ok {
		t.Fatal("a last-seen time published before the sensor was heard")
	}

	seen := map[string]any{"uptime_s": 60, "last_seen": map[string]string{"20": "2026-10-26T19:12:01Z"}}
	if err := p.PublishDiag(ctx, seen); err != nil {
		t.Fatal(err)
	}
	cfg, ok := find("homeassistant/sensor/openqiara_20_lastseen/config")
	if !ok {
		t.Fatal("last-seen entity not discovered")
	}
	var d map[string]any
	if err := json.Unmarshal([]byte(cfg.payload), &d); err != nil {
		t.Fatal(err)
	}
	if d["state_topic"] != "openqiara/sensor/20/last_seen" || d["value_template"] != nil || d["name"] != "Dernier signal" {
		t.Errorf("discovery: %v", d)
	}
	m, ok := find("openqiara/sensor/20/last_seen")
	if !ok || !m.retain || m.payload != "2026-10-26T19:12:01Z" {
		t.Fatalf("last seen: %+v (found %v)", m, ok)
	}
	if _, ok := find("openqiara/sensor/14/last_seen"); ok {
		t.Error("sensor 14 not heard: nothing to publish")
	}

	// same time: not published again; a new one: published
	c.published = nil
	_ = p.PublishDiag(ctx, seen)
	if _, ok := find("openqiara/sensor/20/last_seen"); ok {
		t.Error("unchanged time published again")
	}
	seen["last_seen"] = map[string]string{"20": "2026-10-26T19:20:00Z"}
	_ = p.PublishDiag(ctx, seen)
	if m, ok := find("openqiara/sensor/20/last_seen"); !ok || m.payload != "2026-10-26T19:20:00Z" {
		t.Errorf("new time not published: %+v", m)
	}

	// a new connection publishes the known time once more
	c.published = nil
	p.diagReset.Store(true)
	_ = p.PublishDiag(ctx, seen)
	if _, ok := find("openqiara/sensor/20/last_seen"); !ok {
		t.Error("not republished on a new connection")
	}
}

// TestLastSeenDiscoveredBeforeHeard: a sensor not heard since the
// camera started gets its "last heard" entity discovered all the same, under
// its short name and its own retained topic, so that the discovery an older
// version left retained (name doubled, diagnostic topic) is replaced at once;
// no time is published for it until it is heard.
func TestLastSeenDiscoveredBeforeHeard(t *testing.T) {
	p, c := newRecordingPublisher()
	p.prefix = "openqiara"
	p.sensors = []camera.Sensor{{ID: 14, Type: "PIR"}, {ID: 28, Type: "KPD"}, {ID: 99, Type: "XYZ"}}
	if err := p.PublishDiag(context.Background(), map[string]any{"uptime_s": 30}); err != nil {
		t.Fatal(err)
	}
	got := map[string]recordedPublish{}
	for _, m := range c.published {
		got[m.topic] = m
	}
	for _, id := range []string{"14", "28"} {
		cfg, ok := got["homeassistant/sensor/openqiara_"+id+"_lastseen/config"]
		if !ok || !cfg.retain {
			t.Fatalf("sensor %s: last-seen entity not discovered (%+v)", id, cfg)
		}
		var d map[string]any
		if err := json.Unmarshal([]byte(cfg.payload), &d); err != nil {
			t.Fatal(err)
		}
		if d["name"] != "Dernier signal" || d["state_topic"] != "openqiara/sensor/"+id+"/last_seen" {
			t.Errorf("sensor %s: discovery %v", id, d)
		}
		if _, ok := got["openqiara/sensor/"+id+"/last_seen"]; ok {
			t.Errorf("sensor %s: a time published before it was heard", id)
		}
	}
	if _, ok := got["homeassistant/sensor/openqiara_99_lastseen/config"]; ok {
		t.Error("an unsupported sensor type got a last-seen entity")
	}
}
