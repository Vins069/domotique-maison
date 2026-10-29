package mqtt

import (
	"context"
	"testing"

	"github.com/caligone/openqiara/internal/camera"
)

// TestTemperatureEntityOnlyWhenReported: a sensor that never sent
// a temperature gets no temperature entity (an earlier one is removed with
// an empty retained config); the first temperature it sends creates it,
// before the state that feeds it, and only once.
func TestTemperatureEntityOnlyWhenReported(t *testing.T) {
	p, c := newRecordingPublisher()
	p.prefix = "openqiara"
	t24 := 24
	p.sensors = []camera.Sensor{
		{ID: 14, Type: "PIR", Reachable: true},
		{ID: 20, Type: "SRN", Reachable: true, Temperature: &t24},
		{ID: 28, Type: "KPD", Reachable: true, Battery: 100},
	}
	p.republishDiscovery(context.Background())

	got := map[string]string{}
	for _, m := range c.published {
		got[m.topic] = m.payload
	}
	for _, id := range []string{"14", "28"} {
		pl, ok := got["homeassistant/sensor/openqiara_"+id+"_temperature/config"]
		if !ok || pl != "" {
			t.Errorf("sensor %s: temperature entity not removed (published=%v, payload=%q)", id, ok, pl)
		}
	}
	if pl := got["homeassistant/sensor/openqiara_20_temperature/config"]; pl == "" {
		t.Error("siren: temperature entity missing")
	}

	// the motion detector sends its first temperature
	c.published = nil
	t19 := 19
	if err := p.PublishState(context.Background(), camera.Sensor{ID: 14, Type: "PIR", Reachable: true, Temperature: &t19}); err != nil {
		t.Fatal(err)
	}
	if len(c.published) != 2 || c.published[0].topic != "homeassistant/sensor/openqiara_14_temperature/config" ||
		c.published[0].payload == "" || c.published[1].topic != "openqiara/sensor/14/state" {
		t.Fatalf("first temperature: %+v", c.published)
	}
	// the next one only updates the state
	c.published = nil
	if err := p.PublishState(context.Background(), camera.Sensor{ID: 14, Type: "PIR", Reachable: true, Temperature: &t19}); err != nil {
		t.Fatal(err)
	}
	if len(c.published) != 1 || c.published[0].topic != "openqiara/sensor/14/state" {
		t.Fatalf("second temperature: %+v", c.published)
	}
	// a reconnection keeps the entity that has a temperature now
	c.published = nil
	p.republishDiscovery(context.Background())
	for _, m := range c.published {
		if m.topic == "homeassistant/sensor/openqiara_14_temperature/config" && m.payload == "" {
			t.Fatal("reconnection removed the temperature entity of a sensor that reported one")
		}
	}
}

// TestSyncIVEntities: the camera's own detection turned off for
// good, its two entities are removed (empty retained configs and states);
// turned back on, they are published again.
func TestSyncIVEntities(t *testing.T) {
	p, c := newRecordingPublisher()
	p.prefix = "openqiara"
	if err := p.SyncIVEntities(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	want := []string{"homeassistant/binary_sensor/openqiara_iv_human/config", "openqiara/iv/human/state",
		"homeassistant/binary_sensor/openqiara_iv_pet/config", "openqiara/iv/pet/state"}
	if len(c.published) != 4 {
		t.Fatalf("published %+v", c.published)
	}
	for i, m := range c.published {
		if m.topic != want[i] || m.payload != "" || !m.retain {
			t.Errorf("%d: %+v, want an empty retained message on %s", i, m, want[i])
		}
	}
	c.published = nil
	if err := p.SyncIVEntities(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if len(c.published) != 2 || c.published[0].payload == "" || c.published[1].payload == "" {
		t.Fatalf("detection on: %+v", c.published)
	}
}
