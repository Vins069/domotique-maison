// Package sonde reads the camera's own health, for Home Assistant: the Wi-Fi
// link (signal, lost associations), memory, storage, temperature and the air
// quality sensor the vendor firmware drives. Every reading is optional: a
// source that is missing or answers badly leaves its key out, it never
// fails the others.
package sonde

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Reading is one pass of the probes, JSON-ready. A key is absent when its
// source gave nothing.
type Reading map[string]any

// Sonde holds where the probes read. The zero value reads the camera's
// usual places; tests point them at a directory.
type Sonde struct {
	Proc  string // /proc
	Sys   string // /sys
	Iface string // Wi-Fi interface, ssv0
	Media string // mount point of the media partition
	Data  string // mount point of the data partition
	Etc   string // where os-release lives

	// Run runs a command and returns what it printed; nil runs it for real.
	Run func(ctx context.Context, name string, args ...string) ([]byte, error)
	// Now gives the wall clock; nil is time.Now.
	Now func() time.Time

	// prevCPU is the last /proc/stat sample, for the processor's load
	// between two passes; bootTime is fixed once the clock is set.
	prevCPU  cpuSample
	bootTime time.Time
}

// New returns a Sonde reading the camera's usual places.
func New() *Sonde {
	return &Sonde{Proc: "/proc", Sys: "/sys", Iface: "ssv0", Media: "/media", Data: "/data", Etc: "/etc"}
}

// System reads what needs no vendor service: uptime, memory, storage,
// temperature, and the Wi-Fi link counters.
func (s *Sonde) System() Reading {
	r := Reading{}
	if up, ok := firstField(s.Proc+"/uptime", 0); ok {
		r["uptime_s"] = int64(up)
	}
	if mem, ok := meminfo(s.Proc+"/meminfo", "MemAvailable"); ok {
		r["mem_available_mb"] = mem / 1024
	}
	if fw := s.firmware(); fw != "" {
		r["firmware"] = fw
	}
	if pct, ok := usedPercent(s.Media); ok {
		r["media_used_pct"] = pct
	}
	if pct, ok := usedPercent(s.Data); ok {
		r["data_used_pct"] = pct
	}
	if t, ok := s.temperature(); ok {
		r["soc_temp_c"] = t
	}
	base := s.Sys + "/class/net/" + s.Iface
	if n, ok := readInt(base + "/carrier_changes"); ok {
		// carrier_changes counts up and down: two per lost association.
		r["wifi_carrier_changes"] = n
		r["wifi_drops"] = n / 2
	}
	if pct, ok := tcpRetransPercent(s.Proc + "/net/snmp"); ok {
		r["tcp_retrans_pct"] = pct
	}
	if lvl, ok := wirelessLevel(s.Proc+"/net/wireless", s.Iface); ok {
		r["wifi_rssi_dbm"] = lvl
	}
	if q, ok := wirelessLink(s.Proc+"/net/wireless", s.Iface); ok {
		r["wifi_link_quality"] = q
	}
	if load, ok := firstField(s.Proc+"/loadavg", 0); ok {
		r["load_1m"] = load
	}
	if pct, ok := s.cpuPercent(); ok {
		r["cpu_pct"] = pct
	}
	// The clock: the camera has no RTC and starts in 1970 until
	// NTP sets it. Once set, when the camera booted, fixed at the first
	// reading so that the timestamp entity does not drift by a second.
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	t := now()
	clockOK := t.Year() >= 2020
	r["clock_ok"] = onOff(clockOK)
	if clockOK {
		if up, ok := firstField(s.Proc+"/uptime", 0); ok && s.bootTime.IsZero() {
			s.bootTime = t.Add(-time.Duration(up * float64(time.Second))).Truncate(time.Second)
		}
		if !s.bootTime.IsZero() {
			r["boot_time"] = s.bootTime.UTC().Format(time.RFC3339)
		}
	}
	return r
}

func onOff(v bool) string {
	if v {
		return "ON"
	}
	return "OFF"
}

// cpuSample is the "cpu" line of /proc/stat: jiffies spent, and idle ones.
type cpuSample struct {
	total, idle uint64
	ok          bool
}

// cpuPercent is the share of the processor busy since the last pass, from
// /proc/stat ("cpu user nice system idle iowait irq softirq steal"); nothing
// at the first pass, or when the counters went backwards (a reboot of the
// camera restarts OpenQiara too, so that never happens in practice).
func (s *Sonde) cpuPercent() (int, bool) {
	b, err := os.ReadFile(s.Proc + "/stat")
	if err != nil {
		return 0, false
	}
	var cur cpuSample
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 5 || f[0] != "cpu" {
			continue
		}
		for i, v := range f[1:] {
			n, err := strconv.ParseUint(v, 10, 64)
			if err != nil {
				return 0, false
			}
			cur.total += n
			if i == 3 || i == 4 { // idle, iowait
				cur.idle += n
			}
		}
		cur.ok = true
		break
	}
	if !cur.ok {
		return 0, false
	}
	prev := s.prevCPU
	s.prevCPU = cur
	if !prev.ok || cur.total <= prev.total || cur.idle < prev.idle {
		return 0, false
	}
	dt, di := cur.total-prev.total, cur.idle-prev.idle
	return int(((dt-di)*100 + dt/2) / dt), true
}

// wirelessLink is the link quality /proc/net/wireless gives for iface, as
// the driver counts it (no fixed scale across drivers).
func wirelessLink(path, iface string) (int, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, iface+":") {
			continue
		}
		fs := strings.Fields(strings.TrimPrefix(line, iface+":"))
		if len(fs) < 2 {
			return 0, false
		}
		v, err := strconv.ParseFloat(strings.TrimSuffix(fs[1], "."), 64)
		if err != nil || v < 0 {
			return 0, false
		}
		return int(v), true
	}
	return 0, false
}

// temperature is the SoC's, in °C: the SigmaStar sensor
// (/sys/class/mstar/msys/TEMP_R, "Temperature 62"), else the hottest thermal
// zone of a kernel that has them.
func (s *Sonde) temperature() (float64, bool) {
	if b, err := os.ReadFile(s.Sys + "/class/mstar/msys/TEMP_R"); err == nil {
		f := strings.Fields(string(b))
		if len(f) >= 2 && f[0] == "Temperature" {
			if t, err := strconv.ParseFloat(f[1], 64); err == nil && t > -40 && t < 150 {
				return t, true
			}
		}
	}
	ents, err := os.ReadDir(s.Sys + "/class/thermal")
	if err != nil {
		return 0, false
	}
	best, found := 0.0, false
	for _, e := range ents {
		if !strings.HasPrefix(e.Name(), "thermal_zone") {
			continue
		}
		milli, ok := readInt(s.Sys + "/class/thermal/" + e.Name() + "/temp")
		if !ok || milli <= 0 {
			continue
		}
		if t := float64(milli) / 1000; !found || t > best {
			best, found = t, true
		}
	}
	return best, found
}

func readInt(path string) (int64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return n, err == nil
}

func firstField(path string, i int) (float64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	f := strings.Fields(string(b))
	if i >= len(f) {
		return 0, false
	}
	v, err := strconv.ParseFloat(f[i], 64)
	return v, err == nil
}

// meminfo returns a /proc/meminfo field in kB.
func meminfo(path, key string) (int64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, key+":") {
			continue
		}
		fs := strings.Fields(strings.TrimPrefix(line, key+":"))
		if len(fs) == 0 {
			return 0, false
		}
		n, err := strconv.ParseInt(fs[0], 10, 64)
		return n, err == nil
	}
	return 0, false
}

// usedPercent is how full the filesystem at path is, as df shows it.
func usedPercent(path string) (int, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil || st.Blocks == 0 {
		return 0, false
	}
	used := uint64(st.Blocks) - uint64(st.Bfree)
	avail := uint64(st.Bavail)
	if used+avail == 0 {
		return 0, false
	}
	return int((used*100 + (used+avail)/2) / (used + avail)), true
}

// tcpRetransPercent is TCP segments retransmitted over segments sent since
// boot: a link that loses packets shows here before anything breaks.
func tcpRetransPercent(path string) (float64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	var names, vals []string
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "Tcp:") {
			continue
		}
		if names == nil {
			names = strings.Fields(line)
		} else {
			vals = strings.Fields(line)
			break
		}
	}
	if len(names) == 0 || len(names) != len(vals) {
		return 0, false
	}
	var out, retr float64
	for i, n := range names {
		v, err := strconv.ParseFloat(vals[i], 64)
		if err != nil {
			continue
		}
		switch n {
		case "OutSegs":
			out = v
		case "RetransSegs":
			retr = v
		}
	}
	if out <= 0 {
		return 0, false
	}
	return float64(int(retr/out*1000+0.5)) / 10, true
}

// wirelessLevel is the signal level /proc/net/wireless gives for iface, in
// dBm (a driver that reports it as an unsigned byte, 256 less, is read too).
func wirelessLevel(path, iface string) (int, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, iface+":") {
			continue
		}
		fs := strings.Fields(strings.TrimPrefix(line, iface+":"))
		if len(fs) < 3 {
			return 0, false
		}
		v, err := strconv.ParseFloat(strings.TrimSuffix(fs[2], "."), 64)
		if err != nil {
			return 0, false
		}
		lvl := int(v)
		if lvl > 0 {
			lvl -= 256
		}
		if lvl == 0 || lvl < -120 {
			return 0, false
		}
		return lvl, true
	}
	return 0, false
}

// aqiLevels is what the vendor daemon calls the air quality, with its index
// (1 to 5). The daemon does not pass on the ENS160's own AQI-UBA (a TVOC
// index): it derives its index from the eCO2 reading (/usr/bin/ens160,
// ECO2_to_AQI, disassembled 26/10/2026), on the ENS160 datasheet's eCO2 scale
// (Table 5: 400-600 excellent, 600-800 good, 800-1000 fair, 1000-1500 poor,
// above 1500 bad) with a 50 ppm hysteresis between levels: at most 600 ppm 1,
// 650 to 750 2, 850 to 950 3, 1050 to 1450 4, from 1500 5, and in between the
// level stays the one it was.
var aqiLevels = map[string]int{"excellent": 1, "good": 2, "moderate": 3, "poor": 4, "unhealthy": 5}

// aqiFrench is the same level in words, for Home Assistant's enum sensor.
var aqiFrench = map[string]string{"excellent": "très bonne", "good": "bonne", "moderate": "correcte", "poor": "mauvaise", "unhealthy": "très mauvaise"}

// AirQualityOptions are the enum sensor's states, best first.
var AirQualityOptions = []string{"très bonne", "bonne", "correcte", "mauvaise", "très mauvaise"}

// Vendor reads what the vendor services know, through their command-line
// clients: the air quality sensor (ens160). A client that is missing, slow
// or answers badly leaves its keys out.
func (s *Sonde) Vendor(ctx context.Context) Reading {
	r := Reading{}
	run := s.Run
	if run == nil {
		run = runCommand
	}
	cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if out, err := run(cctx, "ens160ctl", "get", "value"); err == nil {
		air := ParseAir(string(out))
		if !s.airReady(air) {
			// Warming up, or a reading the ENS160 cannot give: the air
			// entities say "unknown" rather than a false figure. The board's
			// own temperature and humidity (ENS210) need no warm-up.
			for _, k := range airKeys {
				delete(air, k)
			}
		}
		for k, v := range air {
			r[k] = v
		}
	}
	return r
}

// airKeys are the ENS160's own readings.
var airKeys = []string{"air_tvoc_ppb", "air_eco2_ppm", "air_aqi", "air_quality", "air_quality_fr"}

// AirWarmup is how long after power-on the ENS160 is left to warm up before
// its readings are published: 3 minutes in standard mode (ScioSense ENS160
// datasheet, "Warm-up"), plus a minute for the vendor daemon to start it.
const AirWarmup = 240 * time.Second

// airReady tells whether the air readings can be published: the
// sensor has warmed up (system uptime, the sensor being powered at boot), and
// the figures are within what the ENS160 gives (eCO2 400 to 65000 ppm, TVOC
// 0 to 65000 ppb). The vendor daemon tells nothing of its validity flag.
func (s *Sonde) airReady(air Reading) bool {
	if up, ok := firstField(s.Proc+"/uptime", 0); !ok || time.Duration(up*float64(time.Second)) < AirWarmup {
		return false
	}
	if v, ok := air["air_eco2_ppm"].(int); ok && (v < 400 || v > 65000) {
		return false
	}
	if v, ok := air["air_tvoc_ppb"].(int); ok && (v < 0 || v > 65000) {
		return false
	}
	return true
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

// ParseAir reads what `ens160ctl get value` prints:
//
//	value:
//	    tvoc: 303
//	    eco2: 802
//	    aqi: good
//	    temperature: 41
//	    humidity: 21
//
// tvoc is in ppb, eco2 in ppm; temperature and humidity are what the board
// feeds the sensor to compensate, the inside of the camera, not the room.
func ParseAir(out string) Reading {
	r := Reading{}
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch k {
		case "tvoc", "eco2", "temperature", "humidity":
			n, err := strconv.Atoi(v)
			if err != nil {
				continue
			}
			key := map[string]string{"tvoc": "air_tvoc_ppb", "eco2": "air_eco2_ppm", "temperature": "board_temp_c", "humidity": "board_humidity_pct"}[k]
			r[key] = n
		case "aqi":
			if lvl, ok := aqiLevels[strings.ToLower(v)]; ok {
				r["air_aqi"] = lvl
				r["air_quality"] = strings.ToLower(v)
				r["air_quality_fr"] = aqiFrench[strings.ToLower(v)]
			}
		}
	}
	return r
}

// firmware names the vendor system image, from os-release: the vendor's own
// version service (hlsystem) is not running on the camera.
func (s *Sonde) firmware() string {
	b, err := os.ReadFile(s.Etc + "/os-release")
	if err != nil {
		return ""
	}
	kv := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			kv[k] = strings.Trim(v, `"`)
		}
	}
	name := kv["NAME"] + " " + kv["VERSION_ID"]
	if v := kv["VERSION"]; v != "" {
		name += " (" + v + ")"
	}
	return strings.TrimSpace(name)
}
