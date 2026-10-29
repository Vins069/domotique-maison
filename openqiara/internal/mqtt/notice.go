package mqtt

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/caligone/openqiara/internal/camera"
)

// eventDiscoveryPayload is the auto-discovery config of an MQTT event entity
// (Home Assistant 2023.8 and later).
type eventDiscoveryPayload struct {
	Name          string   `json:"name"`
	UniqueID      string   `json:"unique_id"`
	StateTopic    string   `json:"state_topic"`
	ValueTemplate string   `json:"value_template,omitempty"`
	EventTypes    []string `json:"event_types"`
	DeviceClass   string   `json:"device_class,omitempty"`
	Icon          string   `json:"icon,omitempty"`
	Device        haDevice `json:"device"`
}

func noticeTopic(prefix string, sensorID int) string {
	return fmt.Sprintf("%s/sensor/%d/notice", prefix, sensorID)
}

// noticeTypes is what a sensor of this type can raise. The keypad alone has
// a star key (emergency).
func noticeTypes(sensorType string) []string {
	if sensorType == "KPD" {
		return []string{camera.NoticeEmergency, camera.NoticeTamper, camera.NoticeRebooted}
	}
	return []string{camera.NoticeTamper, camera.NoticeRebooted}
}

// noticeDiscovery returns the event entity of a sensor: tamper, reboot and,
// for the keypad, the star key. Not retained as a state: an event is a
// moment, not a state.
func noticeDiscovery(prefix string, sensor camera.Sensor) (string, eventDiscoveryPayload) {
	typeLower := strings.ToLower(sensor.Type)
	label := "Événements"
	if sensor.Type == "KPD" {
		label = "Touches spéciales"
	}
	return fmt.Sprintf("homeassistant/event/openqiara_%d_notice/config", sensor.ID), eventDiscoveryPayload{
		Name:        label,
		UniqueID:    fmt.Sprintf("openqiara_%s_%d_notice", typeLower, sensor.ID),
		StateTopic:  noticeTopic(prefix, sensor.ID),
		EventTypes:  noticeTypes(sensor.Type),
		DeviceClass: "button",
		Icon:        "mdi:alert-decagram-outline",
		Device:      sensorDevice(sensor),
	}
}

// PublishNoticeDiscovery publishes the event entity of every sensor.
func (p *HAPublisher) PublishNoticeDiscovery(ctx context.Context) {
	for _, s := range p.sensors {
		if _, ok := sensorTypeMap[s.Type]; !ok && s.Type != "KPD" {
			continue
		}
		topic, payload := noticeDiscovery(p.prefix, s)
		data, err := json.Marshal(payload)
		if err != nil {
			continue
		}
		if err := p.publish(ctx, topic, data, retained); err != nil {
			p.log.Warn("notice discovery publish failed", "sensor_id", s.ID, "error", err)
		}
	}
}

// PublishNotice sends one event ("tamper", "emergency", "rebooted") of a
// sensor. Never retained: a retained event would replay at each restart.
func (p *HAPublisher) PublishNotice(ctx context.Context, sensor camera.Sensor, notice string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	payload, err := json.Marshal(map[string]string{"event_type": notice})
	if err != nil {
		return err
	}
	return p.publish(ctx, noticeTopic(p.prefix, sensor.ID), payload, notRetained)
}
