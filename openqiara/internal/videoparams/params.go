// Package videoparams exposes, within fixed bounds, the image settings of
// hlcamd (the vendor's video daemon) that Home Assistant may change: the
// night exposure limits (shutter, gains), the day/night threshold and the
// day/night mode.
//
// hlcamd keeps its parameters in /data/hlcamd-parameters.json with, for each
// one, its value, its default and its native minimum and maximum (study of
// the 27/10/2026, fable/NOTE-etude-image.md). OpenQiara reads that file
// (nothing else: no write of its own on the card) and writes a parameter the
// way the vendor's app and the privacy shutter already do:
//
//	fbxbusctl set hlcamd video_settings '{"parameters":{"<key>":{"val":N}}}'
//
// Every write goes through a closed list of parameters, each with the
// bounds of this file (never beyond the vendor's default for a maximum) and
// the native bounds hlcamd records, when they could be read. Anything else
// is refused. A "restore defaults" order writes every parameter's default
// back, so that a change is reversible from Home Assistant at any time.
package videoparams

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Option is one allowed value of a parameter that is a choice.
type Option struct {
	Label string // what Home Assistant shows and sends
	Value int64  // what hlcamd takes
}

// Param is one parameter of the closed list.
type Param struct {
	// ID names the parameter in MQTT topics and Home Assistant.
	ID string
	// Key is hlcamd's own name (config.sensor.night.MaxShutterUS).
	Key string
	// Name is the entity's label.
	Name string
	// Min, Max and Def are the bounds and the default, in hlcamd's units.
	// Max never exceeds the vendor's default of a maximum. For a choice
	// (Options set) they are unused.
	Min, Max, Def int64
	// Step is Home Assistant's step, in shown units.
	Step int64
	// Unit is Home Assistant's unit of measurement, "" for none.
	Unit string
	// Scale divides hlcamd's value for display: a gain is in 1024ths.
	Scale int64
	// Options, when set, are the only values allowed (a select entity).
	Options []Option
	Icon    string
	// Group is "night" (exposure limits, threshold, mode), "day" (the day
	// image) or "image" (settings that belong to neither, like the mounting
	// rotation): each of night and day has its own defaults flag and restore
	// order, so that an automation about the night never touches the day
	// image. The "image" group has neither.
	Group string
	// NoRestore keeps a parameter out of the restore orders and the "at
	// defaults" flags: the image rotation is set to match how the camera is
	// mounted (2 for a camera fixed upside down), so a "restore defaults"
	// must never put it back to the factory 0 and turn the picture over.
	NoRestore bool
}

// Groups of the list.
const (
	GroupNight = "night"
	GroupDay   = "day"
	GroupImage = "image"
)

// Params is the closed list: what OpenQiara may write, and nothing else.
// The defaults and bounds are those read on the camera on the 27/10/2026
// (fable/NOTE-etude-image.md, constat 1; reading Q177b, testdata/). The
// night maxima stop at the vendor's defaults: hlcamd's own bounds for the
// night.* keys are 0 to 4294967295, which protect nothing, so the bounds
// here are the only ones. The minima below the defaults were not read on
// the camera, they are floors chosen to keep an image (a limit at 0 would
// leave the night black). The day image's bounds are hlcamd's own, 0 to
// 100; its defaults are the factory ones of the file, not the values in
// service.
var Params = []Param{
	{
		ID: "night_max_shutter_us", Key: "config.sensor.night.MaxShutterUS",
		Name: "Temps de pose maximal (nuit)", Group: GroupNight,
		Min: 1000, Max: 14000, Def: 14000, Step: 500, Unit: "µs", Scale: 1,
		Icon: "mdi:camera-timer",
	},
	{
		ID: "night_max_sensor_gain", Key: "config.sensor.night.MaxSensorGain",
		Name: "Gain capteur maximal (nuit)", Group: GroupNight,
		// 1024 = 1x: shown as a factor, 1 to 8000.
		Min: 1024, Max: 8192000, Def: 8192000, Step: 1, Unit: "x", Scale: 1024,
		Icon: "mdi:brightness-6",
	},
	{
		ID: "night_max_isp_gain", Key: "config.sensor.night.MaxISPGain",
		Name: "Gain numérique maximal (nuit)", Group: GroupNight,
		Min: 1, Max: 16383, Def: 16383, Step: 1, Scale: 1,
		Icon: "mdi:brightness-7",
	},
	{
		ID: "d2n_threshold", Key: "config.sensor.d2n-threshold",
		Name: "Seuil de passage en mode nuit", Group: GroupNight,
		// The native range read on the camera: -50 000 to -20 000.
		Min: -50000, Max: -20000, Def: -50000, Step: 1000, Scale: 1,
		Icon: "mdi:theme-light-dark",
	},
	// config.sensor.night_day_mode is deliberately not in this list:
	// the privacy shutter owns it (internal/camera.SetShutter: the day
	// position while closed, so that the IR-cut relay does not click all
	// night behind the shutter; the person's stored wish when open).
	// Offered here, a "restore defaults" with the shutter closed would have
	// set it back, and the "at defaults" flags would have been off whenever
	// the shutter is closed. The person's wish has its own select entity
	// (mqtt night-vision), kept in the config, not written here.
	// The day image (reading Q177b of the 27/10/2026): 0 to 100 each.
	{
		ID: "day_brightness", Key: "config.sensor.day.brightness",
		Name: "Luminosité (jour)", Group: GroupDay,
		Min: 0, Max: 100, Def: 75, Step: 1, Scale: 1, Icon: "mdi:brightness-5",
	},
	{
		ID: "day_contrast", Key: "config.sensor.day.contrast",
		Name: "Contraste (jour)", Group: GroupDay,
		Min: 0, Max: 100, Def: 50, Step: 1, Scale: 1, Icon: "mdi:contrast-circle",
	},
	{
		ID: "day_saturation", Key: "config.sensor.day.saturation",
		Name: "Saturation (jour)", Group: GroupDay,
		Min: 0, Max: 100, Def: 75, Step: 1, Scale: 1, Icon: "mdi:palette",
	},
	{
		ID: "day_lightness", Key: "config.sensor.day.lightness",
		Name: "Clarté (jour)", Group: GroupDay,
		Min: 0, Max: 100, Def: 55, Step: 1, Scale: 1, Icon: "mdi:white-balance-sunny",
	},
	{
		ID: "day_dynamic_light", Key: "config.sensor.day.dynamic.light.management",
		Name: "Adaptation à la lumière ambiante (jour)", Group: GroupDay,
		Def: 1, Scale: 1, Icon: "mdi:brightness-auto",
		Options: []Option{{Label: "Activée", Value: 1}, {Label: "Désactivée", Value: 0}},
	},
	{
		ID: "dark_room_hint", Key: "config.sensor.dark-room.hint",
		Name: "Pièce sombre (vision de nuit plus tôt)", Group: GroupNight,
		Def: 1, Scale: 1, Icon: "mdi:lightbulb-night",
		Options: []Option{{Label: "Activée", Value: 1}, {Label: "Désactivée", Value: 0}},
	},
	// The mounting rotation: 0 for a camera standing on its base, 2 for one
	// fixed upside down (tried on a real camera: 2 turns the picture over,
	// 1 and 3 flip or tilt it). Kept out of restore and the defaults flags
	// (NoRestore) so that "restore defaults" never turns the picture over.
	{
		ID: "image_rotation", Key: "config.video.rotation.mode",
		Name: "Rotation de l'image", Group: GroupImage, NoRestore: true,
		Def: 0, Scale: 1, Icon: "mdi:screen-rotation",
		Options: []Option{
			{Label: "Normale (0)", Value: 0},
			{Label: "Variante 1", Value: 1},
			{Label: "Retournée (2)", Value: 2},
			{Label: "Variante 3", Value: 3},
		},
	},
}

// ByID returns the parameter named id.
func ByID(id string) (Param, bool) {
	for _, p := range Params {
		if p.ID == id {
			return p, true
		}
	}
	return Param{}, false
}

// IsChoice tells whether the parameter is a select.
func (p Param) IsChoice() bool { return len(p.Options) > 0 }

// Shown converts hlcamd's value to what Home Assistant shows.
func (p Param) Shown(raw int64) any {
	if p.IsChoice() {
		for _, o := range p.Options {
			if o.Value == raw {
				return o.Label
			}
		}
		return strconv.FormatInt(raw, 10)
	}
	if p.Scale > 1 {
		return int64(math.Round(float64(raw) / float64(p.Scale)))
	}
	return raw
}

// Native is what hlcamd's file says of a parameter.
type Native struct {
	Val, Def, Min, Max             int64
	HasVal, HasDef, HasMin, HasMax bool
}

// Snapshot is what the entities show: each parameter of the list as Home
// Assistant sees it, whether all are at their default, and hlcamd's
// numeric parameters as read.
type Snapshot struct {
	Values   map[string]any // by ID, shown units; a parameter the file lacks is absent
	Defaults bool           // every parameter of the list at its default
	// NightDefaults and DayDefaults are the same, per group.
	NightDefaults, DayDefaults bool
	Native                     map[string]Native // by hlcamd key, every numeric parameter read
	ReadAt                     time.Time
}

// Errors of Set.
var (
	ErrUnknown  = errors.New("videoparams: unknown parameter")
	ErrBounds   = errors.New("videoparams: value out of bounds")
	ErrLocked   = errors.New("videoparams: writes are locked by the configuration")
	ErrTooFast  = errors.New("videoparams: too many writes, try again later")
	ErrNoFile   = errors.New("videoparams: hlcamd's parameters file not read")
	ErrNotReady = errors.New("videoparams: the parameter is not in hlcamd's file")
	ErrBusy     = errors.New("videoparams: a write is in progress, try again later")
)

// Write limits: a change is a deliberate act, never a stream (each one is a
// bus call and, as far as the study tells, a write on the card by hlcamd).
// One write at a time: a burst of commands never starts more
// than one fbxbusctl, the others are refused with ErrBusy, and the
// per-hour budget is counted under the same lock.
const (
	minInterval = time.Second
	maxPerHour  = 60
	execTimeout = 8 * time.Second
)

// Service reads hlcamd's parameters and writes the ones of the list.
type Service struct {
	// File is hlcamd's parameters file.
	File string
	// Lock refuses every write (openqiara.json: video.lock).
	Lock bool
	// Exec runs a command and returns what it printed; nil runs it for real.
	Exec func(ctx context.Context, name string, args ...string) ([]byte, error)
	// OnChange is called with each new snapshot (the file changed, or a
	// write was made). May be nil.
	OnChange func(Snapshot)
	// ConfirmDelay is how long after a write the file is read again. Zero:
	// a second.
	ConfirmDelay time.Duration
	Log          *slog.Logger

	mu      sync.Mutex
	native  map[string]Native
	pending map[string]int64 // writes not seen in the file yet, by key
	readAt  time.Time
	last    []byte // the file as last read
	writes  []time.Time
	kick    chan struct{}
	now     func() time.Time
	// slot is the one write (or group restore) in flight: taken without
	// waiting, so that a burst never piles up goroutines or bus calls.
	slot chan struct{}
}

// DefaultFile is where hlcamd keeps its parameters on the camera.
const DefaultFile = "/data/hlcamd-parameters.json"

// New returns a service reading hlcamd's file on the camera.
func New(logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{File: DefaultFile, Log: logger, kick: make(chan struct{}, 1), now: time.Now, slot: make(chan struct{}, 1)}
}

// acquire takes the write slot without waiting; release gives it back.
func (s *Service) acquire() error {
	if s.slot == nil {
		s.mu.Lock()
		if s.slot == nil {
			s.slot = make(chan struct{}, 1)
		}
		s.mu.Unlock()
	}
	select {
	case s.slot <- struct{}{}:
		return nil
	default:
		return ErrBusy
	}
}

func (s *Service) release() { <-s.slot }

// Available tells whether hlcamd's file is there: without it the entities
// are not offered (a development machine, another firmware).
func (s *Service) Available() bool {
	_, err := os.Stat(s.File)
	return err == nil
}

// Refresh reads the file and tells the change, if any.
func (s *Service) Refresh() error {
	b, err := os.ReadFile(s.File)
	if err != nil {
		return err
	}
	native, err := Parse(b)
	if err != nil {
		return err
	}
	s.mu.Lock()
	changed := !bytes.Equal(b, s.last) || s.readAt.IsZero()
	s.last = b
	s.native = native
	s.readAt = s.now()
	// A write the file now shows is confirmed; one it does not is dropped
	// too: the file is the truth, and the entity goes back to what hlcamd
	// kept (seen in the log).
	for key, want := range s.pending {
		n, ok := native[key]
		if !ok || !n.HasVal || n.Val != want {
			s.Log.Warn("videoparams: write not found in hlcamd's file", "key", key, "written", want, "file", n.Val)
		}
		delete(s.pending, key)
		changed = true
	}
	snap := s.snapshot()
	s.mu.Unlock()
	if changed && s.OnChange != nil {
		s.OnChange(snap)
	}
	return nil
}

// Current returns the last snapshot, false before the first read.
func (s *Service) Current() (Snapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readAt.IsZero() {
		return Snapshot{}, false
	}
	return s.snapshot(), true
}

// snapshot builds the snapshot (caller holds mu).
func (s *Service) snapshot() Snapshot {
	snap := Snapshot{Values: map[string]any{}, Defaults: true, NightDefaults: true, DayDefaults: true, Native: s.native, ReadAt: s.readAt}
	moved := func(p Param) {
		snap.Defaults = false
		switch p.Group {
		case GroupNight:
			snap.NightDefaults = false
		case GroupDay:
			snap.DayDefaults = false
		}
	}
	for _, p := range Params {
		n, ok := s.native[p.Key]
		raw, have := n.Val, ok && n.HasVal
		if v, pending := s.pending[p.Key]; pending {
			raw, have = v, true
		}
		// A NoRestore parameter (the rotation) is shown but never counts in
		// the "at defaults" flags: being at its mounting value is not "moved".
		if p.NoRestore {
			if have {
				snap.Values[p.ID] = p.Shown(raw)
			}
			continue
		}
		if !have {
			moved(p)
			continue
		}
		snap.Values[p.ID] = p.Shown(raw)
		if raw != s.defaultOf(p) {
			moved(p)
		}
	}
	return snap
}

// defaultOf is the parameter's default: hlcamd's when the file gives one
// within this file's bounds, else the one read on the camera.
func (s *Service) defaultOf(p Param) int64 {
	if n, ok := s.native[p.Key]; ok && n.HasDef && p.allowed(n.Def) {
		return n.Def
	}
	return p.Def
}

// allowed tells whether raw is within the parameter's own bounds.
func (p Param) allowed(raw int64) bool {
	if p.IsChoice() {
		for _, o := range p.Options {
			if o.Value == raw {
				return true
			}
		}
		return false
	}
	return raw >= p.Min && raw <= p.Max
}

// Parse reads hlcamd's parameters file: every parameter with a numeric
// value, by key. The file's shape is taken as {"parameters": {key: {val,
// def, min, max}}}; a map of keys at the top level, or a list of objects
// with a "name" or "key", are read too, since the exact shape was not
// recorded in the study. A parameter without a numeric val, def, min or max
// is left out.
func Parse(b []byte) (map[string]Native, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("videoparams: parse: %w", err)
	}
	out := map[string]Native{}
	switch d := doc.(type) {
	case map[string]any:
		if inner, ok := d["parameters"].(map[string]any); ok {
			d = inner
		}
		for key, v := range d {
			if n, ok := nativeOf(v); ok {
				out[key] = n
			}
		}
	case []any:
		for _, item := range d {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			key, _ := m["name"].(string)
			if key == "" {
				key, _ = m["key"].(string)
			}
			if n, ok := nativeOf(m); ok && key != "" {
				out[key] = n
			}
		}
	default:
		return nil, errors.New("videoparams: parse: unexpected document")
	}
	return out, nil
}

// nativeOf reads val/def/min/max from a parameter's object.
func nativeOf(v any) (Native, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return Native{}, false
	}
	var n Native
	n.Val, n.HasVal = number(m["val"])
	n.Def, n.HasDef = number(m["def"])
	n.Min, n.HasMin = number(m["min"])
	n.Max, n.HasMax = number(m["max"])
	return n, n.HasVal || n.HasDef || n.HasMin || n.HasMax
}

// number reads an integer from a JSON number, a float with no fraction, or
// a string of digits.
func number(v any) (int64, bool) {
	var s string
	switch x := v.(type) {
	case json.Number:
		s = x.String()
	case string:
		s = strings.TrimSpace(x)
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	default:
		return 0, false
	}
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i, true
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || f != math.Trunc(f) || math.Abs(f) > math.MaxInt32 {
		return 0, false
	}
	return int64(f), true
}

// SetText applies what Home Assistant sent for a parameter: a number in
// shown units, or an option's label for a choice.
func (s *Service) SetText(ctx context.Context, id, payload string) error {
	p, ok := ByID(id)
	if !ok {
		return ErrUnknown
	}
	payload = strings.TrimSpace(payload)
	var raw int64
	if p.IsChoice() {
		found := false
		for _, o := range p.Options {
			if strings.EqualFold(o.Label, payload) {
				raw, found = o.Value, true
			}
		}
		if !found {
			return fmt.Errorf("%w: %s", ErrBounds, oneLine(payload))
		}
	} else {
		f, err := strconv.ParseFloat(payload, 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return fmt.Errorf("%w: %s", ErrBounds, oneLine(payload))
		}
		shown := math.Round(f)
		if math.Abs(shown) > math.MaxInt32 {
			return fmt.Errorf("%w: %s", ErrBounds, oneLine(payload))
		}
		raw = int64(shown) * p.Scale
	}
	if err := s.acquire(); err != nil {
		return err
	}
	defer s.release()
	s.mu.Lock()
	if n := s.now(); len(s.writes) > 0 && n.Sub(s.writes[len(s.writes)-1]) < minInterval {
		s.mu.Unlock()
		return ErrTooFast
	}
	s.mu.Unlock()
	return s.write(ctx, p, raw)
}

// RestoreDefaults writes every parameter's default back.
func (s *Service) RestoreDefaults(ctx context.Context) error { return s.RestoreGroup(ctx, "") }

// RestoreGroup writes the defaults of one group ("night" or "day") back;
// "" means every parameter.
func (s *Service) RestoreGroup(ctx context.Context, group string) error {
	if group != "" && group != GroupNight && group != GroupDay {
		return fmt.Errorf("%w: group %q", ErrUnknown, group)
	}
	if s.Lock {
		return ErrLocked
	}
	if err := s.acquire(); err != nil {
		return err
	}
	defer s.release()
	for _, p := range Params {
		if p.NoRestore {
			continue
		}
		if group != "" && p.Group != group {
			continue
		}
		s.mu.Lock()
		def := s.defaultOf(p)
		s.mu.Unlock()
		if err := s.write(ctx, p, def); err != nil {
			return fmt.Errorf("%s: %w", p.ID, err)
		}
	}
	return nil
}

// write checks raw against every bound, then writes it through fbxbusctl.
// The caller holds the write slot (acquire): one bus call at a time.
func (s *Service) write(ctx context.Context, p Param, raw int64) error {
	if s.Lock {
		return ErrLocked
	}
	if !p.allowed(raw) {
		return fmt.Errorf("%w: %s=%d", ErrBounds, p.ID, raw)
	}
	s.mu.Lock()
	if s.readAt.IsZero() {
		s.mu.Unlock()
		return ErrNoFile
	}
	n, known := s.native[p.Key]
	if !known {
		s.mu.Unlock()
		return fmt.Errorf("%w: %s", ErrNotReady, p.Key)
	}
	if (n.HasMin && raw < n.Min) || (n.HasMax && raw > n.Max) {
		s.mu.Unlock()
		return fmt.Errorf("%w: %s=%d outside hlcamd's %d..%d", ErrBounds, p.ID, raw, n.Min, n.Max)
	}
	now := s.now()
	keep := s.writes[:0]
	for _, t := range s.writes {
		if now.Sub(t) < time.Hour {
			keep = append(keep, t)
		}
	}
	s.writes = keep
	if len(s.writes) >= maxPerHour {
		s.mu.Unlock()
		return ErrTooFast
	}
	s.writes = append(s.writes, now)
	s.mu.Unlock()

	settings := fmt.Sprintf(`{"parameters":{%s:{"val":%d}}}`, strconv.Quote(p.Key), raw)
	run := s.Exec
	if run == nil {
		run = runCommand
	}
	cctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()
	out, err := run(cctx, "fbxbusctl", "set", "hlcamd", "video_settings", settings)
	if err != nil {
		return fmt.Errorf("videoparams: fbxbusctl set %s: %w: %s", p.Key, err, oneLine(string(out)))
	}
	s.Log.Info("videoparams: parameter written", "key", p.Key, "val", raw)
	s.mu.Lock()
	if s.pending == nil {
		s.pending = map[string]int64{}
	}
	s.pending[p.Key] = raw
	snap := s.snapshot()
	s.mu.Unlock()
	if s.OnChange != nil {
		s.OnChange(snap)
	}
	s.Kick()
	return nil
}

// Kick asks for an early read of the file (after a write, or after the
// shutter set the day/night mode).
func (s *Service) Kick() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// Run reads the file every period, and soon after each Kick, until ctx ends.
func (s *Service) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	confirm := s.ConfirmDelay
	if confirm == 0 {
		confirm = time.Second
	}
	failing := false
	read := func() {
		if err := s.Refresh(); err != nil {
			if !failing {
				s.Log.Warn("videoparams: hlcamd's parameters not read", "file", s.File, "error", err)
			}
			failing = true
			return
		}
		failing = false
	}
	read()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			read()
		case <-s.kick:
			select {
			case <-ctx.Done():
				return
			case <-time.After(confirm):
			}
			read()
		}
	}
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// oneLine keeps a text on one line of at most 120 bytes, for the log.
func oneLine(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' {
			return ' '
		}
		return r
	}, strings.TrimSpace(s))
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}
