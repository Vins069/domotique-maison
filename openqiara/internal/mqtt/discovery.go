package mqtt

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/caligone/openqiara/internal/camera"
)

// cameraDeviceID is the identifier of the camera's device in Home Assistant.
const cameraDeviceID = "openqiara_camera"

// sensorMeta describes how a sensor type maps to HA auto-discovery.
type sensorMeta struct {
	domain      string // HA domain: "binary_sensor", "siren"
	deviceClass string // HA device_class or ""
	stateField  string // JSON field used in value_template
}

var sensorTypeMap = map[string]sensorMeta{
	"DWS": {domain: "binary_sensor", deviceClass: "opening", stateField: "open"},
	"PIR": {domain: "binary_sensor", deviceClass: "motion", stateField: "motion"},
	"SRN": {domain: "siren", deviceClass: "", stateField: "active"},
}

func sensorDisplayName(sensor camera.Sensor) string {
	if sensor.Label != "" {
		return sensor.Label
	}
	return fmt.Sprintf("OpenQiara %s %d", sensor.Type, sensor.ID)
}

func sensorDevice(sensor camera.Sensor) haDevice {
	return haDevice{
		Identifiers:  []string{fmt.Sprintf("openqiara_%d", sensor.ID)},
		Name:         sensorDisplayName(sensor),
		Manufacturer: "Qiara/Cofidur",
		Model:        modelForType(sensor.Type),
		// The camera is the sensors' hub: Home Assistant draws the link.
		ViaDevice: cameraDeviceID,
	}
}

// buildDiscoveryTopic returns the HA auto-discovery config topic for a sensor.
func buildDiscoveryTopic(sensor camera.Sensor) (string, bool) {
	meta, ok := sensorTypeMap[sensor.Type]
	if !ok {
		return "", false
	}
	return fmt.Sprintf("homeassistant/%s/openqiara_%d/config", meta.domain, sensor.ID), true
}

// buildDiscoveryPayload returns the HA auto-discovery JSON payload for a sensor.
func buildDiscoveryPayload(prefix string, sensor camera.Sensor) (discoveryPayload, bool) {
	meta, ok := sensorTypeMap[sensor.Type]
	if !ok {
		return discoveryPayload{}, false
	}

	typeLower := strings.ToLower(sensor.Type)
	uniqueID := fmt.Sprintf("openqiara_%s_%d", typeLower, sensor.ID)
	name := sensorDisplayName(sensor)
	st := stateTopic(prefix, sensor.ID)
	// A state left out (a door not heard since the start) renders nothing:
	// Home Assistant then keeps the entity as it is.
	valueTemplate := fmt.Sprintf("{{ value_json.%[1]s | lower if value_json.%[1]s is defined else '' }}", meta.stateField)

	p := discoveryPayload{
		Name:                   name,
		UniqueID:               uniqueID,
		DeviceClass:            meta.deviceClass,
		StateTopic:             st,
		ValueTemplate:          valueTemplate,
		PayloadOn:              "true",
		PayloadOff:             "false",
		JSONAttributesTopic:    st,
		JSONAttributesTemplate: `{"battery": {{ value_json.battery }}, "reachable": {{ value_json.reachable | lower }}}`,
		Device:                 sensorDevice(sensor),
	}

	if sensor.Type == "SRN" {
		p.CommandTopic = fmt.Sprintf("%s/siren/%d/set", prefix, sensor.ID)
		// The MQTT siren reads its state through state_value_template only:
		// with value_template (ignored) it parsed the whole JSON, found no
		// "true"/"false" state and warned on the other keys at every report.
		p.ValueTemplate = ""
		p.StateValueTemplate = "{{ value_json.active | lower }}"
		// state: alert_over is an alarm set off that no longer wails.
		p.JSONAttributesTemplate = `{"battery": {{ value_json.battery }}, "reachable": {{ value_json.reachable | lower }}, "state": "{{ value_json.state | default('') }}"}`
		p.PayloadOn = "true"
		p.PayloadOff = "false"
		no := false
		p.SupportDuration, p.SupportVolumeSet = &no, &no
	}

	return p, true
}

// ExtraDiscovery holds a topic and its JSON payload bytes.
type ExtraDiscovery struct {
	Topic   string
	Payload []byte
}

// BuildExtraDiscoveryTopics returns additional HA discovery configs (battery, temperature), JSON-encoded.
func BuildExtraDiscoveryTopics(prefix string, sensor camera.Sensor) []ExtraDiscovery {
	extras := buildExtraDiscoveryTopics(prefix, sensor)
	result := make([]ExtraDiscovery, 0, len(extras))
	for _, e := range extras {
		data, err := json.Marshal(e.Payload)
		if err != nil {
			continue
		}
		result = append(result, ExtraDiscovery{Topic: e.Topic, Payload: data})
	}
	return result
}

// buildExtraDiscoveryTopics returns additional HA discovery configs (battery, temperature).
func buildExtraDiscoveryTopics(prefix string, sensor camera.Sensor) []struct {
	Topic   string
	Payload discoveryPayload
} {
	st := stateTopic(prefix, sensor.ID)
	device := sensorDevice(sensor)
	// the extras are named by what they are only. Home Assistant puts
	// the device name in front ("OpenQiara PIR 14 Liaison radio"); with the
	// name in the entity name too it came twice.
	typeLower := strings.ToLower(sensor.Type)

	var extras []struct {
		Topic   string
		Payload discoveryPayload
	}

	// Battery sensor
	extras = append(extras, struct {
		Topic   string
		Payload discoveryPayload
	}{
		Topic: fmt.Sprintf("homeassistant/sensor/openqiara_%d_battery/config", sensor.ID),
		Payload: discoveryPayload{
			Name:                "Batterie",
			UniqueID:            fmt.Sprintf("openqiara_%s_%d_battery", typeLower, sensor.ID),
			DeviceClass:         "battery",
			UnitOfMeasurement:   "%",
			StateClass:          "measurement",
			EntityCategory:      "diagnostic",
			StateTopic:          st,
			ValueTemplate:       "{{ value_json.battery }}",
			JSONAttributesTopic: st,
			Device:              device,
		},
	})

	// Temperature sensor: only for a sensor that has sent one. The
	// motion detector and the keypad never have (relevé du 26/10/2026 : no
	// temperature saved for them since the 24/10), and an entity that stays
	// unknown for good is noise; it is created the day one comes.
	if sensor.Temperature != nil {
		topic, payload := temperatureDiscovery(prefix, sensor)
		extras = append(extras, struct {
			Topic   string
			Payload discoveryPayload
		}{Topic: topic, Payload: payload})
	}

	// Radio reachability: the sensor heard (or not) within its silence limit.
	// An entity of its own, so that an automation can notify of a sensor that
	// went quiet, without reading the attributes of another. Tied to
	// the camera being on the broker. The camera is the radio's hub: while it
	// is off the network nobody hears the sensor, and the entity said
	// "connected" all the same (seen on a real camera). Not the
	// alarm's own entities, which keep no availability under Alarmo.
	extras = append(extras, struct {
		Topic   string
		Payload discoveryPayload
	}{
		Topic: fmt.Sprintf("homeassistant/binary_sensor/openqiara_%d_reachable/config", sensor.ID),
		Payload: discoveryPayload{
			Name:           "Liaison radio",
			UniqueID:       fmt.Sprintf("openqiara_%s_%d_reachable", typeLower, sensor.ID),
			DeviceClass:    "connectivity",
			EntityCategory: "diagnostic",
			StateTopic:     st,
			ValueTemplate:  "{{ value_json.reachable | lower }}",
			PayloadOn:      "true",
			PayloadOff:     "false",
			Availability:   cameraAvailability(prefix),
			Device:         device,
		},
	})

	return extras
}

// temperatureTopic is where a sensor's temperature entity is discovered.
func temperatureTopic(sensorID int) string {
	return fmt.Sprintf("homeassistant/sensor/openqiara_%d_temperature/config", sensorID)
}

// temperatureDiscovery is the temperature entity of a sensor that reports one.
func temperatureDiscovery(prefix string, sensor camera.Sensor) (string, discoveryPayload) {
	st := stateTopic(prefix, sensor.ID)
	return temperatureTopic(sensor.ID), discoveryPayload{
		Name:                "Température",
		UniqueID:            fmt.Sprintf("openqiara_%s_%d_temperature", strings.ToLower(sensor.Type), sensor.ID),
		DeviceClass:         "temperature",
		UnitOfMeasurement:   "°C",
		StateClass:          "measurement",
		StateTopic:          st,
		ValueTemplate:       "{{ value_json.temperature if value_json.temperature is defined else None }}",
		JSONAttributesTopic: st,
		Device:              sensorDevice(sensor),
	}
}

func modelForType(sensorType string) string {
	models := map[string]string{
		"DWS": "HOMELABDWS",
		"PIR": "HOMELABPIR",
		"SRN": "HOMELABSRN",
		"KPD": "HOMELABKPD",
	}
	if m, ok := models[sensorType]; ok {
		return m
	}
	return sensorType
}

func stateTopic(prefix string, sensorID int) string {
	return fmt.Sprintf("%s/sensor/%d/state", prefix, sensorID)
}

// CameraDiscoveryPayload is not used — HLS streams should be added
// as generic camera in HA with URL: http://<camera_ip>:8080/stream/HLS_TEST.m3u8

// ShutterDiscoveryPayload returns the HA auto-discovery config for the camera shutter as a switch.
func ShutterDiscoveryPayload(prefix string) (string, []byte) {
	topic := "homeassistant/switch/openqiara_shutter/config"
	payload := discoveryPayload{
		Name:          "OpenQiara Shutter",
		UniqueID:      "openqiara_shutter",
		StateTopic:    prefix + "/shutter/state",
		CommandTopic:  prefix + "/shutter/set",
		ValueTemplate: "{{ value_json.state }}",
		PayloadOn:     "open",
		PayloadOff:    "closed",
		Device: haDevice{
			Identifiers:  []string{"openqiara_camera"},
			Name:         "OpenQiara Caméra",
			Manufacturer: "Qiara/Cofidur",
			Model:        "HOMELABCAM",
		},
	}
	data, _ := json.Marshal(payload)
	return topic, data
}

// IVDetectionDiscoveryPayload retourne la config auto-discovery HA pour
// un binary_sensor de détection IntelliVision (humain ou animal).
//
// kind est "human" ou "pet" — utilisé pour le suffixe topic + unique_id
// + nom convivial + device_class HA (motion/occupancy).
func IVDetectionDiscoveryPayload(prefix, kind string) (string, []byte) {
	displayName := "Humain détecté"
	deviceClass := "motion"
	if kind == "pet" {
		displayName = "Animal détecté"
		deviceClass = "occupancy"
	}
	topic := "homeassistant/binary_sensor/openqiara_iv_" + kind + "/config"
	payload := discoveryPayload{
		Name:                   displayName,
		UniqueID:               "openqiara_iv_" + kind,
		DeviceClass:            deviceClass,
		StateTopic:             prefix + "/iv/" + kind + "/state",
		ValueTemplate:          "{{ value_json.detected | lower }}",
		PayloadOn:              "true",
		PayloadOff:             "false",
		JSONAttributesTopic:    prefix + "/iv/" + kind + "/state",
		JSONAttributesTemplate: "{\"confidence\": {{ value_json.confidence }}, \"object_id\": \"{{ value_json.object_id }}\"}",
		Device: haDevice{
			Identifiers:  []string{"openqiara_camera"},
			Name:         "OpenQiara Caméra",
			Manufacturer: "Qiara/Cofidur",
			Model:        "HOMELABCAM",
		},
	}
	data, _ := json.Marshal(payload)
	return topic, data
}
