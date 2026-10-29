package mqtt

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	mqtt "github.com/eclipse/paho.mqtt.golang"

	"github.com/caligone/openqiara/internal/videoparams"
)

// The camera's image settings: hlcamd's night exposure limits,
// day/night threshold and mode, as Home Assistant number and select
// entities, with a button that restores every default. The values come from
// hlcamd's own parameters file; a change goes to hlcamd through fbxbusctl,
// within the bounds of internal/videoparams, and nothing else can be asked
// for (the topic names the parameter, the list is closed).

// VideoSetter is what the command handler drives (internal/videoparams).
type VideoSetter interface {
	SetText(ctx context.Context, id, payload string) error
	RestoreDefaults(ctx context.Context) error
	RestoreGroup(ctx context.Context, group string) error
}

// The buttons' payloads: every default, the night's, the day's.
const (
	videoRestoreOrder      = "restore-defaults"
	videoRestoreNightOrder = "restore-night"
	videoRestoreDayOrder   = "restore-day"
)

// videoButtons are the restore buttons: order, unique id suffix, name.
var videoButtons = []struct{ order, id, name, icon string }{
	{videoRestoreNightOrder, "restore_night", "Restaurer les réglages de nuit par défaut", "mdi:weather-night"},
	{videoRestoreDayOrder, "restore_day", "Restaurer les réglages de jour par défaut", "mdi:white-balance-sunny"},
	{videoRestoreOrder, "restore", "Restaurer tous les réglages d'image par défaut", "mdi:image-refresh"},
}

// videoFlags are the "at defaults" binary sensors: state key, unique id
// suffix, name.
var videoFlags = []struct{ key, id, name string }{
	{"night_defaults", "night_defaults", "Réglages de nuit par défaut"},
	{"day_defaults", "day_defaults", "Réglages de jour par défaut"},
	{"defaults", "defaults", "Réglages d'image par défaut"},
}

func videoStateTopic(prefix string) string  { return prefix + "/video/state" }
func videoNativeTopic(prefix string) string { return prefix + "/video/native" }
func videoCmdTopic(prefix string) string    { return prefix + "/video/cmd" }
func videoSetTopic(prefix, id string) string {
	return prefix + "/video/" + id + "/set"
}

// Night vision: a select over the person's wish for hlcamd's
// day/night mode while the shutter is open. Unlike the other image settings
// it is kept in OpenQiara's config, not hlcamd's file (the shutter rewrites
// that file's mode when it closes), so it has its own topics and state. The
// topics sit OUTSIDE <prefix>/video/<id>/set so that the image command
// handler's wildcard subscription (<prefix>/video/+/set) does not also catch
// them (which would log an "unknown parameter" warning on every change).
func nightVisionStateTopic(prefix string) string { return prefix + "/night_vision/state" }
func nightVisionSetTopic(prefix string) string   { return prefix + "/night_vision/set" }

const nightVisionEntityTopic = "homeassistant/select/openqiara_video_night_vision/config"

// nightVisionOptions map the select's labels to the config wish; the order is
// the select's order in Home Assistant.
var nightVisionOptions = []struct{ label, wish string }{
	{"Automatique", "auto"},
	{"Forcée", "forced"},
	{"Coupée", "off"},
}

// NightVisionWish returns the config wish for a select label, auto for an
// unknown one.
func NightVisionWish(label string) string {
	for _, o := range nightVisionOptions {
		if o.label == label {
			return o.wish
		}
	}
	return "auto"
}

// nightVisionLabel returns the select label for a config wish.
func nightVisionLabel(wish string) string {
	for _, o := range nightVisionOptions {
		if o.wish == wish {
			return o.label
		}
	}
	return nightVisionOptions[0].label
}

// videoEntityTopic is the discovery topic of a parameter's entity.
func videoEntityTopic(p videoparams.Param) string {
	domain := "number"
	if p.IsChoice() {
		domain = "select"
	}
	return fmt.Sprintf("homeassistant/%s/openqiara_video_%s/config", domain, p.ID)
}

// videoDiscovery is the discovery payload of a parameter: a number within
// the list's bounds (shown units), or a select over its options.
func (p *HAPublisher) videoDiscovery(prm videoparams.Param) discoveryPayload {
	d := discoveryPayload{
		Name:           prm.Name,
		UniqueID:       "openqiara_video_" + prm.ID,
		StateTopic:     videoStateTopic(p.prefix),
		CommandTopic:   videoSetTopic(p.prefix, prm.ID),
		ValueTemplate:  fmt.Sprintf("{{ value_json.%[1]s if value_json.%[1]s is defined else None }}", prm.ID),
		EntityCategory: "config",
		Icon:           prm.Icon,
		Availability:   p.availability(),
		Device:         cameraDevice(),
	}
	if prm.IsChoice() {
		for _, o := range prm.Options {
			d.Options = append(d.Options, o.Label)
		}
		return d
	}
	lo, hi, step := float64(prm.Min)/float64(prm.Scale), float64(prm.Max)/float64(prm.Scale), float64(prm.Step)
	d.Min, d.Max, d.Step = &lo, &hi, &step
	d.Mode = "box" // a typed value, not a slider: each change is a write on the camera
	d.UnitOfMeasurement = prm.Unit
	return d
}

// videoExtraTopics are the discovery topics beside the parameters: the
// "at defaults" flags, the native parameters' summary and the restore
// buttons.
func videoExtraTopics() (flags []string, native string, buttons []string) {
	for _, f := range videoFlags {
		flags = append(flags, "homeassistant/binary_sensor/openqiara_video_"+f.id+"/config")
	}
	for _, b := range videoButtons {
		buttons = append(buttons, "homeassistant/button/openqiara_video_"+b.id+"/config")
	}
	return flags, "homeassistant/sensor/openqiara_video_native/config", buttons
}

// videoFlagDiscovery is an "at defaults" flag: every parameter of the
// group as the vendor's file defaults it.
func (p *HAPublisher) videoFlagDiscovery(i int) discoveryPayload {
	f := videoFlags[i]
	return discoveryPayload{
		Name:           f.name,
		UniqueID:       "openqiara_video_" + f.id,
		StateTopic:     videoStateTopic(p.prefix),
		ValueTemplate:  fmt.Sprintf("{{ value_json.%[1]s | lower if value_json.%[1]s is defined else None }}", f.key),
		PayloadOn:      "true",
		PayloadOff:     "false",
		EntityCategory: "diagnostic",
		Icon:           "mdi:image-check",
		Availability:   p.availability(),
		Device:         cameraDevice(),
	}
}

// videoNativeDiscovery is the count of hlcamd's numeric parameters, with
// every one of them (value, default, min, max) as attributes: how the names
// and ranges hlcamd knows can be read from Home Assistant.
func (p *HAPublisher) videoNativeDiscovery() discoveryPayload {
	return discoveryPayload{
		Name:                "Paramètres d'image natifs",
		UniqueID:            "openqiara_video_native",
		StateTopic:          videoNativeTopic(p.prefix),
		ValueTemplate:       "{{ value_json.count }}",
		JSONAttributesTopic: videoNativeTopic(p.prefix),
		EntityCategory:      "diagnostic",
		Icon:                "mdi:format-list-numbered",
		Availability:        p.availability(),
		Device:              cameraDevice(),
	}
}

// videoRestoreDiscovery is one restore button.
func (p *HAPublisher) videoRestoreDiscovery(i int) []byte {
	b := videoButtons[i]
	data, _ := json.Marshal(buttonPayload{
		Name:           b.name,
		UniqueID:       "openqiara_video_" + b.id,
		CommandTopic:   videoCmdTopic(p.prefix),
		PayloadPress:   b.order,
		EntityCategory: "config",
		Icon:           b.icon,
		Availability:   p.availability(),
		Device:         cameraDevice(),
	})
	return data
}

// nightVisionDiscovery is the night-vision select's discovery payload.
func (p *HAPublisher) nightVisionDiscovery() discoveryPayload {
	d := discoveryPayload{
		Name:           "Vision de nuit",
		UniqueID:       "openqiara_video_night_vision",
		StateTopic:     nightVisionStateTopic(p.prefix),
		CommandTopic:   nightVisionSetTopic(p.prefix),
		EntityCategory: "config",
		Icon:           "mdi:weather-night",
		Availability:   p.availability(),
		Device:         cameraDevice(),
	}
	for _, o := range nightVisionOptions {
		d.Options = append(d.Options, o.label)
	}
	return d
}

// PublishNightVision publishes the night-vision wish as the select's state
// (retained), so Home Assistant shows what OpenQiara will apply when the
// shutter opens.
func (p *HAPublisher) PublishNightVision(ctx context.Context, wish string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.publish(ctx, nightVisionStateTopic(p.prefix), []byte(nightVisionLabel(wish)), retained)
}

// NightVisionSetter receives the select's command (internal/camera + config).
type NightVisionSetter interface {
	SetNightVision(ctx context.Context, wish string) error
}

// SetupNightVisionHandler receives the night-vision select's command: a label
// of the list. Anything else is logged and dropped.
func (p *HAPublisher) SetupNightVisionHandler(ctx context.Context, setter NightVisionSetter, logger *slog.Logger) {
	p.subscribe(nightVisionSetTopic(p.prefix), 1, func(_ mqtt.Client, msg mqtt.Message) {
		label := string(msg.Payload())
		if msg.Retained() {
			logger.Warn("video: retained night-vision command ignored")
			return
		}
		wish := NightVisionWish(label)
		go func() {
			if err := setter.SetNightVision(ctx, wish); err != nil {
				logger.Warn("video: night vision not set", "wish", wish, "error", err)
				return
			}
			logger.Info("video: night vision set from Home Assistant", "wish", wish)
		}()
	})
}

// SetVideoParams says whether the image settings are served (hlcamd's
// parameters file is there). Fixed for the process's life. When they are
// not, the entities an earlier run may have left are removed at each
// connection.
func (p *HAPublisher) SetVideoParams(served bool) { p.videoServed.Store(served) }

// publishVideoDiscovery publishes (or removes) the image settings' entities.
// Called from republishDiscovery: no p.mu.
func (p *HAPublisher) publishVideoDiscovery(ctx context.Context) {
	flags, native, buttons := videoExtraTopics()
	if !p.videoServed.Load() {
		for _, prm := range videoparams.Params {
			_ = p.publish(ctx, videoEntityTopic(prm), []byte{}, retained)
		}
		topics := append(append(flags, buttons...), native, videoStateTopic(p.prefix), videoNativeTopic(p.prefix),
			nightVisionEntityTopic, nightVisionStateTopic(p.prefix))
		for _, t := range topics {
			_ = p.publish(ctx, t, []byte{}, retained)
		}
		return
	}
	if data, err := json.Marshal(p.nightVisionDiscovery()); err == nil {
		if err := p.publish(ctx, nightVisionEntityTopic, data, retained); err != nil {
			p.log.Warn("video discovery publish failed", "topic", nightVisionEntityTopic, "error", err)
		}
	}
	for _, prm := range videoparams.Params {
		data, err := json.Marshal(p.videoDiscovery(prm))
		if err != nil {
			continue
		}
		if err := p.publish(ctx, videoEntityTopic(prm), data, retained); err != nil {
			p.log.Warn("video discovery publish failed", "id", prm.ID, "error", err)
		}
	}
	extras := []struct {
		topic string
		d     discoveryPayload
	}{{native, p.videoNativeDiscovery()}}
	for i := range videoFlags {
		extras = append(extras, struct {
			topic string
			d     discoveryPayload
		}{flags[i], p.videoFlagDiscovery(i)})
	}
	for _, e := range extras {
		data, err := json.Marshal(e.d)
		if err != nil {
			continue
		}
		if err := p.publish(ctx, e.topic, data, retained); err != nil {
			p.log.Warn("video discovery publish failed", "topic", e.topic, "error", err)
		}
	}
	for i := range videoButtons {
		if err := p.publish(ctx, buttons[i], p.videoRestoreDiscovery(i), retained); err != nil {
			p.log.Warn("video discovery publish failed", "topic", buttons[i], "error", err)
		}
	}
}

// videoNativePayload is what the native parameters' topic carries.
type videoNativePayload struct {
	Count      int                       `json:"count"`
	ReadAt     string                    `json:"read_at"`
	Parameters map[string]map[string]any `json:"parameters"`
}

// PublishVideoState publishes a snapshot of the image settings, retained:
// the parameters' shown values and the defaults flag on one topic, hlcamd's
// numeric parameters (config.* only) on another.
func (p *HAPublisher) PublishVideoState(ctx context.Context, s videoparams.Snapshot) error {
	state := map[string]any{"defaults": s.Defaults, "night_defaults": s.NightDefaults, "day_defaults": s.DayDefaults}
	for id, v := range s.Values {
		state[id] = v
	}
	readAt := ""
	if !s.ReadAt.IsZero() {
		readAt = s.ReadAt.UTC().Format("2006-01-02T15:04:05Z07:00")
		state["read_at"] = readAt
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	native := videoNativePayload{Parameters: map[string]map[string]any{}, ReadAt: readAt}
	for key, n := range s.Native {
		if !strings.HasPrefix(key, "config.") {
			continue
		}
		m := map[string]any{}
		if n.HasVal {
			m["val"] = n.Val
		}
		if n.HasDef {
			m["def"] = n.Def
		}
		if n.HasMin {
			m["min"] = n.Min
		}
		if n.HasMax {
			m["max"] = n.Max
		}
		native.Parameters[key] = m
	}
	native.Count = len(native.Parameters)
	nativeData, err := json.Marshal(native)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if err := p.publish(ctx, videoStateTopic(p.prefix), data, retained); err != nil {
		return err
	}
	return p.publish(ctx, videoNativeTopic(p.prefix), nativeData, retained)
}

// SetupVideoCommandHandler receives the entities' commands: a value for a
// parameter (<prefix>/video/<id>/set) or the restore order
// (<prefix>/video/cmd). The id must be one of the list; anything else is
// logged and dropped. The write runs in its own goroutine: it is a bus call
// with a timeout, not something to hold the message router on.
func (p *HAPublisher) SetupVideoCommandHandler(ctx context.Context, setter VideoSetter, logger *slog.Logger) {
	p.subscribe(videoSetTopic(p.prefix, "+"), 1, func(_ mqtt.Client, msg mqtt.Message) {
		payload := string(msg.Payload())
		// A retained command is replayed at every subscription, i.e. at
		// every start: a value is a moment, never a state to replay.
		if msg.Retained() {
			logger.Warn("video: retained command ignored", "topic", msg.Topic())
			return
		}
		id := videoIDFromTopic(p.prefix, msg.Topic())
		if _, ok := videoparams.ByID(id); !ok {
			logger.Warn("video: unknown parameter dropped", "topic", msg.Topic())
			return
		}
		go func() {
			if err := setter.SetText(ctx, id, payload); err != nil {
				logger.Warn("video: parameter not written", "id", id, "error", err)
				return
			}
			logger.Info("video: parameter set from Home Assistant", "id", id)
		}()
	})
	p.subscribe(videoCmdTopic(p.prefix), 1, func(_ mqtt.Client, msg mqtt.Message) {
		order := string(msg.Payload())
		if msg.Retained() {
			logger.Warn("video: retained order ignored", "payload_len", len(order))
			return
		}
		var group string
		switch order {
		case videoRestoreOrder:
			group = ""
		case videoRestoreNightOrder:
			group = videoparams.GroupNight
		case videoRestoreDayOrder:
			group = videoparams.GroupDay
		default:
			logger.Warn("video: unknown order dropped", "payload_len", len(order))
			return
		}
		go func() {
			if err := setter.RestoreGroup(ctx, group); err != nil {
				logger.Warn("video: defaults not restored", "group", group, "error", err)
				return
			}
			logger.Info("video: defaults restored from Home Assistant", "group", group)
		}()
	})
}

// videoIDFromTopic reads the parameter id of <prefix>/video/<id>/set.
func videoIDFromTopic(prefix, topic string) string {
	rest, ok := strings.CutPrefix(topic, prefix+"/video/")
	if !ok {
		return ""
	}
	id, ok := strings.CutSuffix(rest, "/set")
	if !ok || strings.Contains(id, "/") {
		return ""
	}
	return id
}
