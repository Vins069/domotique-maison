package mqtt

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"

	mqtt "github.com/eclipse/paho.mqtt.golang"

	"github.com/caligone/openqiara/internal/camera"
)

func TestDiagDiscoveryUniqueAndAvailable(t *testing.T) {
	p := &HAPublisher{prefix: "openqiara"}
	seenID := map[string]bool{}
	seenTopic := map[string]bool{}
	for _, f := range diagFields {
		topic, d := p.diagDiscovery(f)
		if seenID[d.UniqueID] || seenTopic[topic] {
			t.Fatalf("duplicate unique_id or topic for %s", f.Key)
		}
		seenID[d.UniqueID], seenTopic[topic] = true, true
		if len(d.Availability) != 1 || d.Availability[0].Topic != "openqiara/status" {
			t.Errorf("%s: availability = %+v", f.Key, d.Availability)
		}
		if d.Device.Identifiers[0] != cameraDeviceID {
			t.Errorf("%s: wrong device %v", f.Key, d.Device.Identifiers)
		}
		if _, err := json.Marshal(d); err != nil {
			t.Errorf("%s: %v", f.Key, err)
		}
	}
}

func TestOnlineEntityHasNoAvailability(t *testing.T) {
	p := &HAPublisher{prefix: "openqiara"}
	_, d := p.onlineDiscovery()
	if len(d.Availability) != 0 {
		t.Fatalf("the online entity is the availability, it cannot depend on it: %+v", d.Availability)
	}
	if d.StateTopic != "openqiara/status" || d.PayloadOn != "online" || d.PayloadOff != "offline" {
		t.Fatalf("unexpected status wiring: %+v", d)
	}
	data, _ := json.Marshal(d)
	if strings.Contains(string(data), `"value_template"`) {
		t.Errorf("an empty value_template must be left out: %s", data)
	}
}

// The alarm's sensors keep no availability: a camera that drops off the
// Wi-Fi must not turn them "unavailable" under Alarmo.
func TestAlarmSensorsKeepNoAvailability(t *testing.T) {
	for _, typ := range []string{"DWS", "PIR", "SRN"} {
		d, ok := buildDiscoveryPayload("openqiara", camera.Sensor{ID: 7, Type: typ})
		if !ok {
			t.Fatal(typ)
		}
		if len(d.Availability) != 0 {
			t.Errorf("%s: availability = %+v", typ, d.Availability)
		}
	}
}

// the radio link follows the camera (its hub): unavailable while the
// camera is off the broker, instead of a stale "connected". The battery and the
// temperature keep their last value (the siren's battery is watched by the
// "security sensor unavailable" alert as it is).
func TestRadioLinkFollowsCamera(t *testing.T) {
	for _, typ := range []string{"PIR", "SRN", "KPD"} {
		for _, e := range buildExtraDiscoveryTopics("openqiara", camera.Sensor{ID: 7, Type: typ}) {
			switch e.Payload.UniqueID {
			case "openqiara_" + strings.ToLower(typ) + "_7_reachable":
				if len(e.Payload.Availability) != 1 || e.Payload.Availability[0].Topic != "openqiara/status" {
					t.Errorf("%s link: availability = %+v", typ, e.Payload.Availability)
				}
			default:
				if len(e.Payload.Availability) != 0 {
					t.Errorf("%s %s: availability = %+v", typ, e.Payload.UniqueID, e.Payload.Availability)
				}
			}
		}
	}
}

func TestNoticeDiscovery(t *testing.T) {
	kpd := camera.Sensor{ID: 29, Type: "KPD", Label: "Clavier"}
	topic, d := noticeDiscovery("openqiara", kpd)
	if topic != "homeassistant/event/openqiara_29_notice/config" {
		t.Errorf("topic = %s", topic)
	}
	if !contains(d.EventTypes, camera.NoticeEmergency) || !contains(d.EventTypes, camera.NoticeTamper) {
		t.Errorf("keypad event types = %v", d.EventTypes)
	}
	_, pir := noticeDiscovery("openqiara", camera.Sensor{ID: 20, Type: "PIR"})
	if contains(pir.EventTypes, camera.NoticeEmergency) {
		t.Errorf("only the keypad has an emergency key: %v", pir.EventTypes)
	}
}

func contains(l []string, v string) bool {
	for _, x := range l {
		if x == v {
			return true
		}
	}
	return false
}

// Home Assistant's MQTT siren reads its state through state_value_template
// only (value_template is an unknown key there, dropped).
func TestSirenStateTemplate(t *testing.T) {
	d, _ := buildDiscoveryPayload("openqiara", camera.Sensor{ID: 20, Type: "SRN"})
	data, _ := json.Marshal(d)
	if d.StateValueTemplate == "" || strings.Contains(string(data), `"value_template"`) {
		t.Fatalf("siren discovery: %s", data)
	}
}

// failingClient: the broker is gone, every publish times out.
type failingClient struct{ recordingClient }

func (c *failingClient) Publish(topic string, q byte, retain bool, payload any) mqtt.Token {
	c.recordingClient.Publish(topic, q, retain, payload)
	return failToken{}
}

type failToken struct{ doneToken }

func (failToken) Error() error { return errors.New("publish timeout") }

// A pass stops at the first failed publish: with the broker gone, each would
// wait publishTimeout under p.mu (minutes for some fifty entities).
func TestPublishDiagStopsAtFirstFailure(t *testing.T) {
	c := &failingClient{}
	p := &HAPublisher{client: c, prefix: "openqiara", log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	reading := map[string]any{"qp_slot": "good"}
	for _, f := range diagFields {
		reading[f.Key] = 1
	}
	if err := p.PublishDiag(context.Background(), reading); err == nil {
		t.Fatal("no error")
	}
	if len(c.published) != 1 {
		t.Fatalf("%d publishes attempted after a failure", len(c.published))
	}
}
