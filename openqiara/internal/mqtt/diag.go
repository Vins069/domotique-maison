package mqtt

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/sonde"
)

// diagField describes one health entity of the camera, fed by a key of the
// diagnostic reading (<prefix>/diag/state).
type diagField struct {
	Key         string
	Name        string
	Domain      string // sensor or binary_sensor
	DeviceClass string
	Unit        string
	StateClass  string
	Category    string // entity_category
	Icon        string
	PayloadOn   string   // binary_sensor
	Options     []string // sensor with DeviceClass "enum"
}

// diagFields is every entity the diagnostic reading can feed. An entity is
// discovered the first time its key shows in a reading, so that a source the
// camera lacks (no thermal zone, no air quality sensor) leaves no entity
// "unknown" behind.
var diagFields = []diagField{
	{Key: "uptime_s", Name: "Durée de fonctionnement", Domain: "sensor", DeviceClass: "duration", Unit: "s", StateClass: "measurement", Category: "diagnostic"},
	{Key: "wifi_rssi_dbm", Name: "Signal Wi-Fi", Domain: "sensor", DeviceClass: "signal_strength", Unit: "dBm", StateClass: "measurement", Category: "diagnostic"},
	{Key: "wifi_drops", Name: "Pertes de liaison Wi-Fi", Domain: "sensor", StateClass: "total_increasing", Category: "diagnostic", Icon: "mdi:wifi-off"},
	{Key: "tcp_retrans_pct", Name: "Paquets réémis", Domain: "sensor", Unit: "%", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:swap-horizontal"},
	{Key: "mqtt_reconnects", Name: "Reconnexions MQTT", Domain: "sensor", StateClass: "total_increasing", Category: "diagnostic", Icon: "mdi:connection"},
	{Key: "mem_available_mb", Name: "Mémoire disponible", Domain: "sensor", DeviceClass: "data_size", Unit: "MB", StateClass: "measurement", Category: "diagnostic"},
	{Key: "media_used_pct", Name: "Carte SD occupée", Domain: "sensor", Unit: "%", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:sd"},
	{Key: "data_used_pct", Name: "Données occupées", Domain: "sensor", Unit: "%", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:database"},
	{Key: "soc_temp_c", Name: "Température du processeur", Domain: "sensor", DeviceClass: "temperature", Unit: "°C", StateClass: "measurement", Category: "diagnostic"},
	// The ENS160 rates the air on the UBA scale, 1 (excellent) to 5 (unhealthy). Home Assistant's "aqi"
	// class is "air quality index, without a unit" (no scale imposed): the class is kept,
	// the scale is in the name.
	{Key: "air_aqi", Name: "Indice de qualité de l'air (1 à 5)", Domain: "sensor", DeviceClass: "aqi", StateClass: "measurement"},
	{Key: "air_quality_fr", Name: "Qualité de l'air", Domain: "sensor", DeviceClass: "enum", Options: sonde.AirQualityOptions, Icon: "mdi:air-filter"},
	{Key: "air_tvoc_ppb", Name: "Composés organiques volatils", Domain: "sensor", DeviceClass: "volatile_organic_compounds_parts", Unit: "ppb", StateClass: "measurement"},
	{Key: "air_eco2_ppm", Name: "CO₂ équivalent", Domain: "sensor", DeviceClass: "carbon_dioxide", Unit: "ppm", StateClass: "measurement"},
	// The ENS160's companion sensor sits inside the case, warmed by the board: not the room's air.
	{Key: "board_temp_c", Name: "Température interne du boîtier", Domain: "sensor", DeviceClass: "temperature", Unit: "°C", StateClass: "measurement", Category: "diagnostic"},
	{Key: "board_humidity_pct", Name: "Humidité interne du boîtier", Domain: "sensor", DeviceClass: "humidity", Unit: "%", StateClass: "measurement", Category: "diagnostic"},
	{Key: "version", Name: "Version OpenQiara", Domain: "sensor", Category: "diagnostic", Icon: "mdi:tag"},
	{Key: "firmware", Name: "Microgiciel constructeur", Domain: "sensor", Category: "diagnostic", Icon: "mdi:chip"},
	// Memory of OpenQiara itself, and of hlcamd (the video): what to watch to keep the camera's RAM in check.
	{Key: "openqiara_rss_mb", Name: "Mémoire d'OpenQiara", Domain: "sensor", DeviceClass: "data_size", Unit: "MB", StateClass: "measurement", Category: "diagnostic"},
	{Key: "openqiara_anon_mb", Name: "Mémoire d'OpenQiara non récupérable", Domain: "sensor", DeviceClass: "data_size", Unit: "MB", StateClass: "measurement", Category: "diagnostic"},
	{Key: "hlcamd_rss_mb", Name: "Mémoire de la vidéo (hlcamd)", Domain: "sensor", DeviceClass: "data_size", Unit: "MB", StateClass: "measurement", Category: "diagnostic"},
	{Key: "hlcamd_running", Name: "Vidéo (hlcamd) en marche", Domain: "binary_sensor", DeviceClass: "running", Category: "diagnostic"},
	{Key: "hlcamd_uptime_s", Name: "Durée de fonctionnement de la vidéo (hlcamd)", Domain: "sensor", DeviceClass: "duration", Unit: "s", StateClass: "measurement", Category: "diagnostic"},
	// the clock (no RTC: 1970 until NTP), when the camera booted, the processor's load, the Wi-Fi link quality.
	{Key: "clock_ok", Name: "Horloge synchronisée", Domain: "binary_sensor", Category: "diagnostic", Icon: "mdi:clock-check-outline"},
	{Key: "boot_time", Name: "Dernier démarrage", Domain: "sensor", DeviceClass: "timestamp", Category: "diagnostic"},
	{Key: "cpu_pct", Name: "Processeur occupé", Domain: "sensor", Unit: "%", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:chip"},
	{Key: "load_1m", Name: "Charge système (1 min)", Domain: "sensor", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:gauge"},
	{Key: "wifi_link_quality", Name: "Qualité de liaison Wi-Fi", Domain: "sensor", StateClass: "measurement", Category: "diagnostic", Icon: "mdi:wifi-strength-2"},
	// Qiara Plus (present only when it is installed).
	{Key: "qp_slot", Name: "Version en service", Domain: "sensor", Category: "diagnostic", Icon: "mdi:source-branch"},
	{Key: "qp_trial", Name: "Mise à jour en essai", Domain: "binary_sensor", Category: "diagnostic", Icon: "mdi:flask-outline"},
	{Key: "qp_update_result", Name: "Dernière mise à jour", Domain: "sensor", Category: "diagnostic", Icon: "mdi:update"},
	{Key: "qp_guard_ok", Name: "Surveillant actif", Domain: "binary_sensor", DeviceClass: "running", Category: "diagnostic"},
	{Key: "qp_gateway_ok", Name: "Box joignable", Domain: "binary_sensor", DeviceClass: "connectivity", Category: "diagnostic"},
	{Key: "qp_ssh_ok", Name: "Administration SSH à l'écoute", Domain: "binary_sensor", DeviceClass: "running", Category: "diagnostic"},
	{Key: "qp_hang_kills", Name: "Blocages corrigés", Domain: "sensor", Category: "diagnostic", Icon: "mdi:restart"},
	{Key: "qp_last_auto_reboot", Name: "Dernier redémarrage automatique", Domain: "sensor", Category: "diagnostic", Icon: "mdi:restart-alert"},
	{Key: "qp_bb_on", Name: "Boîte noire (enquête SSH)", Domain: "binary_sensor", DeviceClass: "running", Category: "diagnostic"},
	{Key: "video_iv_on", Name: "Détection de personnes interne", Domain: "binary_sensor", Category: "diagnostic", Icon: "mdi:account-search"},
	{Key: "video_bitrate_kbps", Name: "Débit vidéo", Domain: "sensor", DeviceClass: "data_rate", Unit: "kbit/s", StateClass: "measurement", Category: "diagnostic"},
	{Key: "video_gop_denum", Name: "Diviseur d'image clé", Domain: "sensor", Category: "diagnostic", Icon: "mdi:key-variant"},
	{Key: "video_shim_on", Name: "Réglage d'encodage (profil High)", Domain: "binary_sensor", Category: "diagnostic", Icon: "mdi:video-high-definition"},
	// Qiara Plus v8: the codec option hlcamd runs with, read on its command line by the guard.
	{Key: "video_codec_hlcamd", Name: "Codec vidéo demandé à hlcamd", Domain: "sensor", DeviceClass: "enum", Options: []string{"H.264", "H.265", "defaut"}, Category: "diagnostic", Icon: "mdi:video-input-component"},
	// the codec the camera's stream is served in (what RTSP and HLS carry), the one
	// video.codec asks hlcamd for, and whether the two differ (the stream is served as it is).
	{Key: "video_codec", Name: "Codec vidéo", Domain: "sensor", DeviceClass: "enum", Options: videoCodecOptions, Category: "diagnostic", Icon: "mdi:video"},
	{Key: "video_codec_configured", Name: "Codec vidéo configuré", Domain: "sensor", DeviceClass: "enum", Options: videoCodecOptions, Category: "diagnostic", Icon: "mdi:video-outline"},
	{Key: "video_codec_mismatch", Name: "Codec vidéo différent du réglage", Domain: "binary_sensor", DeviceClass: "problem", Category: "diagnostic"},
}

// videoCodecOptions are the values of the codec entities (internal/nal's names).
var videoCodecOptions = []string{"H.264", "H.265"}

// guardFed tells whether a diagnostic key comes from Qiara Plus's guard:
// those entities are removed from Home Assistant when Qiara Plus is not
// installed. The video_codec* keys come from the daemon itself and stay.
func guardFed(key string) bool {
	if strings.HasPrefix(key, "qp_") {
		return true
	}
	switch key {
	case "video_iv_on", "video_bitrate_kbps", "video_gop_denum", "video_shim_on", "video_codec_hlcamd":
		return true
	}
	return false
}

func diagStateTopic(prefix string) string { return prefix + "/diag/state" }

// cameraInfo is what the camera's device block adds once known: the
// version and the web interface's address (Home Assistant shows both on
// the device's page). Set once at start, before the first discovery.
var cameraInfo struct{ swVersion, url string }

// SetCameraInfo records the version and the web interface's address.
func SetCameraInfo(version, url string) { cameraInfo.swVersion, cameraInfo.url = version, url }

// cameraDevice is the camera's own device block.
func cameraDevice() haDevice {
	return haDevice{
		Identifiers:      []string{cameraDeviceID},
		Name:             "OpenQiara Caméra",
		Manufacturer:     "Qiara/Cofidur",
		Model:            "HOMELABCAM",
		SWVersion:        cameraInfo.swVersion,
		ConfigurationURL: cameraInfo.url,
	}
}

func (p *HAPublisher) availability() []availabilityItem { return cameraAvailability(p.prefix) }

// cameraAvailability ties an entity to the camera being on the broker.
func cameraAvailability(prefix string) []availabilityItem {
	return []availabilityItem{{
		Topic:               statusTopic(prefix),
		PayloadAvailable:    statusOnline,
		PayloadNotAvailable: statusOffline,
	}}
}

// diagDiscovery is the auto-discovery payload of a diagnostic field.
func (p *HAPublisher) diagDiscovery(f diagField) (string, discoveryPayload) {
	d := discoveryPayload{
		Name:              f.Name,
		UniqueID:          "openqiara_diag_" + f.Key,
		DeviceClass:       f.DeviceClass,
		StateTopic:        diagStateTopic(p.prefix),
		ValueTemplate:     fmt.Sprintf("{{ value_json.%[1]s if value_json.%[1]s is defined else None }}", f.Key),
		UnitOfMeasurement: f.Unit,
		StateClass:        f.StateClass,
		EntityCategory:    f.Category,
		Icon:              f.Icon,
		Options:           f.Options,
		Availability:      p.availability(),
		Device:            cameraDevice(),
	}
	return fmt.Sprintf("homeassistant/%s/openqiara_diag_%s/config", f.Domain, f.Key), d
}

// onlineDiscovery is the camera's "online" entity: the status topic as it
// stands, with no availability of its own (it is the availability).
func (p *HAPublisher) onlineDiscovery() (string, discoveryPayload) {
	return "homeassistant/binary_sensor/openqiara_diag_online/config", discoveryPayload{
		Name:           "En ligne",
		UniqueID:       "openqiara_diag_online",
		DeviceClass:    "connectivity",
		StateTopic:     statusTopic(p.prefix),
		PayloadOn:      statusOnline,
		PayloadOff:     statusOffline,
		EntityCategory: "diagnostic",
		Device:         cameraDevice(),
	}
}

// lastSeenTopic carries a sensor's "last heard" time, retained.
// The time lives in memory only: read from the diagnostics document, as up to
// Before, it went back to unknown at every restart until the sensor next
// spoke (the motion detector: until someone walks past). Retained by the
// broker on a topic of its own and published only once known, it keeps its
// last value across restarts of the camera and of Home Assistant.
func lastSeenTopic(prefix string, sensorID int) string {
	return fmt.Sprintf("%s/sensor/%d/last_seen", prefix, sensorID)
}

// lastSeenDiscovery is the "last heard" timestamp of a sensor.
func (p *HAPublisher) lastSeenDiscovery(s camera.Sensor) (string, discoveryPayload) {
	typeLower := strings.ToLower(s.Type)
	return fmt.Sprintf("homeassistant/sensor/openqiara_%d_lastseen/config", s.ID), discoveryPayload{
		Name:           "Dernier signal",
		UniqueID:       fmt.Sprintf("openqiara_%s_%d_lastseen", typeLower, s.ID),
		DeviceClass:    "timestamp",
		StateTopic:     lastSeenTopic(p.prefix, s.ID),
		EntityCategory: "diagnostic",
		Availability:   p.availability(),
		Device:         sensorDevice(s),
	}
}

// PublishDiag sends a diagnostic reading, retained, and discovers the
// entities its keys feed the first time they show. reading["last_seen"] is a
// map of sensor id (as text) to an RFC 3339 time.
func (p *HAPublisher) PublishDiag(ctx context.Context, reading map[string]any) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	// IsConnectionOpen, not IsConnected: the latter stays true while paho
	// retries, and each publish would then wait publishTimeout under p.mu.
	if p.client == nil || !p.client.IsConnectionOpen() {
		return fmt.Errorf("mqtt client not connected")
	}
	if p.diagReset.Swap(false) || p.diagKnown == nil {
		p.diagKnown = map[string]bool{} // a new connection: discover again
		p.seenSent = map[int]string{}
		p.qpCleaned = false
	}
	var failed error // the first failure ends the pass: the next ones would wait as long
	discover := func(topic string, d discoveryPayload, mark string) {
		if p.diagKnown[mark] || failed != nil {
			return
		}
		data, err := json.Marshal(d)
		if err != nil {
			return
		}
		if err := p.publish(ctx, topic, data, retained); err != nil {
			p.log.Warn("diag discovery publish failed", "topic", topic, "error", err)
			failed = err
			return
		}
		p.diagKnown[mark] = true
	}
	topic, d := p.onlineDiscovery()
	discover(topic, d, "online")
	for _, f := range diagFields {
		if _, ok := reading[f.Key]; !ok {
			continue
		}
		topic, d := p.diagDiscovery(f)
		discover(topic, d, f.Key)
	}
	if _, ok := reading["qp_slot"]; ok {
		for _, b := range qplusButtons {
			if p.diagKnown["button_"+b.Order] || failed != nil {
				continue
			}
			topic, data := p.qplusButtonDiscovery(b)
			if err := p.publish(ctx, topic, data, retained); err != nil {
				p.log.Warn("button discovery publish failed", "topic", topic, "error", err)
				failed = err
				continue
			}
			p.diagKnown["button_"+b.Order] = true
		}
	}
	// every sensor's "last heard" entity is discovered, heard or not
	// since the camera started. One not heard yet keeps its retained time (or
	// shows "unknown" until first heard) under its own short name, instead of
	// the discovery an earlier version left retained (name doubled by Home
	// Assistant, state read from the diagnostic topic).
	seen, _ := reading["last_seen"].(map[string]string)
	for _, s := range p.sensors {
		if _, supported := sensorTypeMap[s.Type]; !supported && s.Type != "KPD" {
			continue
		}
		mark := fmt.Sprintf("lastseen_%d", s.ID)
		topic, d := p.lastSeenDiscovery(s)
		discover(topic, d, mark)
		at, heard := seen[fmt.Sprint(s.ID)]
		if !heard || failed != nil || !p.diagKnown[mark] || p.seenSent[s.ID] == at {
			continue
		}
		if err := p.publish(ctx, lastSeenTopic(p.prefix, s.ID), []byte(at), retained); err != nil {
			p.log.Warn("last seen publish failed", "sensor", s.ID, "error", err)
			failed = err
			continue
		}
		p.seenSent[s.ID] = at
	}
	if failed != nil {
		return failed
	}
	// Qiara Plus absent (never installed, or removed): its buttons and
	// entities, retained by the broker from an earlier version, are removed
	// once per connection (an empty retained config deletes an entity).
	if !p.qpInstalled.Load() && !p.qpCleaned {
		for _, b := range qplusButtons {
			_ = p.publish(ctx, "homeassistant/button/openqiara_qp_"+b.Order+"/config", []byte{}, retained)
		}
		for _, f := range diagFields {
			if guardFed(f.Key) {
				_ = p.publish(ctx, fmt.Sprintf("homeassistant/%s/openqiara_diag_%s/config", f.Domain, f.Key), []byte{}, retained)
				delete(p.diagKnown, f.Key)
			}
		}
		p.qpCleaned = true
	}
	payload, err := json.Marshal(reading)
	if err != nil {
		return err
	}
	return p.publish(ctx, diagStateTopic(p.prefix), payload, retained)
}

// Reconnects is how many times the connection came back after the first.
func (p *HAPublisher) Reconnects() int64 {
	if n := p.reconnects.Load(); n > 1 {
		return n - 1
	}
	return 0
}
