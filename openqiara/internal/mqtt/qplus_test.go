package mqtt

import (
	"encoding/json"
	"github.com/caligone/openqiara/internal/camera"
	"strings"
	"testing"

	"github.com/caligone/openqiara/internal/qplus"
)

// The buttons and the guard share one fixed list of orders.
func TestQPlusButtonsMatchGuardOrders(t *testing.T) {
	if len(qplusButtons) != len(qplus.Orders) {
		t.Fatalf("%d buttons, %d orders", len(qplusButtons), len(qplus.Orders))
	}
	for i, b := range qplusButtons {
		if b.Order != qplus.Orders[i] {
			t.Errorf("button %d: %s, order %s", i, b.Order, qplus.Orders[i])
		}
	}
}

func TestQPlusButtonDiscovery(t *testing.T) {
	p := &HAPublisher{prefix: "openqiara"}
	seen := map[string]bool{}
	for _, b := range qplusButtons {
		topic, data := p.qplusButtonDiscovery(b)
		if !strings.HasPrefix(topic, "homeassistant/button/openqiara_qp_") || seen[topic] {
			t.Fatalf("topic %s", topic)
		}
		seen[topic] = true
		var m map[string]any
		if err := json.Unmarshal(data, &m); err != nil {
			t.Fatal(err)
		}
		if m["command_topic"] != "openqiara/qplus/cmd" || m["payload_press"] != b.Order || m["entity_category"] != "config" {
			t.Errorf("%s: %v", b.Order, m)
		}
		if _, ok := m["state_topic"]; ok {
			t.Errorf("%s: a button has no state topic", b.Order)
		}
	}
}

// Qiara Plus's binary entities read ON/OFF, Home Assistant's defaults.
func TestQPlusDiagFieldsKnown(t *testing.T) {
	keys := map[string]string{}
	for _, f := range diagFields {
		keys[f.Key] = f.Domain
	}
	for _, k := range []string{"qp_trial", "qp_guard_ok", "qp_gateway_ok", "qp_ssh_ok", "video_iv_on", "video_shim_on"} {
		if keys[k] != "binary_sensor" {
			t.Errorf("%s: domain %q", k, keys[k])
		}
	}
	for _, k := range []string{"qp_slot", "qp_update_result", "video_bitrate_kbps", "openqiara_rss_mb", "openqiara_anon_mb", "hlcamd_rss_mb"} {
		if keys[k] != "sensor" {
			t.Errorf("%s: domain %q", k, keys[k])
		}
	}
}

func TestAirAndBoardFields(t *testing.T) {
	p := &HAPublisher{prefix: "openqiara"}
	byKey := map[string]diagField{}
	for _, f := range diagFields {
		byKey[f.Key] = f
	}
	q, ok := byKey["air_quality_fr"]
	if !ok || q.DeviceClass != "enum" || len(q.Options) != 5 || q.Options[1] != "bonne" {
		t.Fatalf("air quality enum = %+v", q)
	}
	_, d := p.diagDiscovery(q)
	data, _ := json.Marshal(d)
	if !strings.Contains(string(data), `"options":["très bonne","bonne","correcte","mauvaise","très mauvaise"]`) {
		t.Errorf("options missing: %s", data)
	}
	// the vendor's index is not the ENS160's AQI-UBA but its eCO2 scale; "UBA" left the name
	// (the entity keeps its unique_id, hence its entity_id in Home Assistant)
	if byKey["air_aqi"].DeviceClass != "aqi" || strings.Contains(byKey["air_aqi"].Name, "UBA") {
		t.Errorf("air_aqi: aqi class , no UBA in the name: %+v", byKey["air_aqi"])
	}
	for _, k := range []string{"board_temp_c", "board_humidity_pct"} {
		if byKey[k].Category != "diagnostic" {
			t.Errorf("%s: the case's own sensor is a diagnostic, not the room's air", k)
		}
	}
}

func TestCameraDeviceInfo(t *testing.T) {
	SetCameraInfo("v0.1.0-rc.22-claude5", "http://192.0.2.67/")
	defer SetCameraInfo("", "")
	d := cameraDevice()
	data, _ := json.Marshal(d)
	if !strings.Contains(string(data), `"sw_version":"v0.1.0-rc.22-claude5"`) || !strings.Contains(string(data), `"configuration_url":"http://192.0.2.67/"`) {
		t.Fatalf("device = %s", data)
	}
	SetCameraInfo("", "")
	data, _ = json.Marshal(cameraDevice())
	if strings.Contains(string(data), "sw_version") || strings.Contains(string(data), "configuration_url") {
		t.Fatalf("empty info must be left out: %s", data)
	}
}

type fakeMsg struct {
	payload  string
	retained bool
}

func (m fakeMsg) Duplicate() bool   { return false }
func (m fakeMsg) Qos() byte         { return 1 }
func (m fakeMsg) Retained() bool    { return m.retained }
func (m fakeMsg) Topic() string     { return "openqiara/qplus/cmd" }
func (m fakeMsg) MessageID() uint16 { return 1 }
func (m fakeMsg) Payload() []byte   { return []byte(m.payload) }
func (m fakeMsg) Ack()              {}

// Only a known order, pressed now (not replayed from a retained message),
// reaches the guard.
func TestQPlusCommandHandlerFilters(t *testing.T) {
	p, _ := newRecordingPublisher()
	p.prefix = "openqiara"
	var got []string
	p.SetupQPlusCommandHandler(func(o string) error { got = append(got, o); return nil }, p.log)
	h := p.subs["openqiara/qplus/cmd"].handler
	for _, m := range []fakeMsg{{payload: "reboot"}, {payload: "restart-app", retained: true}, {payload: "rm -rf /"}, {payload: "update-promote"}, {payload: "REBOOT"}} {
		h(nil, m)
	}
	if len(got) != 1 || got[0] != "reboot" {
		t.Fatalf("orders passed on: %v", got)
	}
}

// A retained siren or shutter command (replayed at every start) is ignored:
// a retained "true" would sound the siren, a retained "open" open the
// privacy shutter, at each boot.
func TestRetainedSirenAndShutterCommandsIgnored(t *testing.T) {
	p, _ := newRecordingPublisher()
	p.prefix = "openqiara"
	var siren []string
	p.SetupSirenCommandHandler([]camera.Sensor{{ID: 32, Type: "SRN"}}, func(id int, c string) { siren = append(siren, c) }, p.log)
	hs := p.subs["openqiara/siren/32/set"].handler
	hs(nil, fakeMsg{payload: "true", retained: true})
	hs(nil, fakeMsg{payload: "false"})
	if len(siren) != 1 || siren[0] != "false" {
		t.Fatalf("siren commands passed on: %v", siren)
	}
	var shutter []bool
	p.SetupShutterCommandHandler(func(open bool) { shutter = append(shutter, open) }, p.log)
	hh := p.subs["openqiara/shutter/set"].handler
	hh(nil, fakeMsg{payload: "open", retained: true})
	hh(nil, fakeMsg{payload: "close"})
	if len(shutter) != 1 || shutter[0] {
		t.Fatalf("shutter commands passed on: %v", shutter)
	}
}

// The video codec entities and what the Qiara Plus cleanup
// removes: the guard's keys, never the daemon's codec keys.
func TestVideoCodecFields(t *testing.T) {
	byKey := map[string]diagField{}
	for _, f := range diagFields {
		byKey[f.Key] = f
	}
	for _, k := range []string{"video_codec", "video_codec_configured"} {
		f, ok := byKey[k]
		if !ok || f.Domain != "sensor" || f.DeviceClass != "enum" || len(f.Options) != 2 || f.Options[1] != "H.265" {
			t.Errorf("%s = %+v", k, f)
		}
	}
	if f := byKey["video_codec_mismatch"]; f.Domain != "binary_sensor" || f.DeviceClass != "problem" {
		t.Errorf("video_codec_mismatch = %+v", f)
	}
	for k, want := range map[string]bool{
		"qp_slot": true, "video_iv_on": true, "video_bitrate_kbps": true, "video_gop_denum": true, "video_shim_on": true,
		"video_codec_hlcamd": true, "video_codec": false, "video_codec_configured": false, "video_codec_mismatch": false, "uptime_s": false,
	} {
		if guardFed(k) != want {
			t.Errorf("guardFed(%s) = %v", k, !want)
		}
	}
}
