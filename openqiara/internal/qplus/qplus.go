// Package qplus is OpenQiara's side of « Qiara Plus », the camera's
// reliability layer (launcher with three slots, guard, update tool, all in
// shell on the camera, see qp/ in the sources). OpenQiara:
//
//   - writes its health to /tmp/qp/health every few seconds, so that the
//     guard can tell a frozen process from a busy one (in RAM: nothing is
//     written to the SD card);
//   - reads what the guard and the update tool record, for the diagnostic
//     entities of Home Assistant;
//   - turns Home Assistant's buttons into orders for the guard (one empty
//     file per order in /tmp/qp/cmd/), from a fixed list: Home Assistant
//     cannot make the camera run anything else.
//
// Every function here is a no-op, or reports nothing, when Qiara Plus is
// not installed: the same binary runs as a plain OpenQiara.
package qplus

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"runtime/metrics"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// Paths, overridable by tests.
type Paths struct {
	Run   string // /tmp/qp : health, orders, guard status (RAM)
	State string // /data/qp/state : slot chosen, trial
	Guard string // /data/qp/qp-guard : present when Qiara Plus is installed
	Proc  string // /proc
}

// Default are the camera's paths. QP and QP_RUN, the variables the shell
// side reads, move them (a trial in RAM runs everything under /tmp).
var Default = defaultPaths()

func defaultPaths() Paths {
	qp, run := os.Getenv("QP"), os.Getenv("QP_RUN")
	if qp == "" {
		qp = "/data/qp"
	}
	if run == "" {
		run = "/tmp/qp"
	}
	return Paths{Run: run, State: filepath.Join(qp, "state"), Guard: filepath.Join(qp, "qp-guard"), Proc: "/proc"}
}

// Installed tells whether Qiara Plus is on the camera.
func (p Paths) Installed() bool {
	_, err := os.Stat(p.Guard)
	return err == nil
}

// Health is one health record.
type Health struct {
	OK   bool   // the gateway, the alarm and the radio answer, hlcamd runs
	Err  string // why not, when not OK
	MQTT bool   // connected to the broker (written only when MQTTConf)
	// MQTTConf: a broker is configured. Without one, no mqtt= line: the
	// guard would take mqtt=0 for a broken link and restart OpenQiara.
	MQTTConf bool
	// While MQTT is down: BrokerKnown says the broker was probed, BrokerUp
	// that it accepts TCP connections (mqtt_broker= line, read by the guard).
	BrokerKnown, BrokerUp bool
	Version               string
}

// uptime reads the seconds since boot, the clock the guard measures with
// (the wall clock starts in 1970 and jumps when NTP sets it).
func (p Paths) uptime() int64 {
	b, err := os.ReadFile(filepath.Join(p.Proc, "uptime"))
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return int64(v)
}

var memSamples = []metrics.Sample{
	{Name: "/memory/classes/total:bytes"},
	{Name: "/memory/classes/heap/objects:bytes"},
}

// WriteHealth writes the health record, atomically (a temporary file in the
// same directory, then a rename): the guard never reads half a record.
func (p Paths) WriteHealth(h Health) error {
	if err := os.MkdirAll(p.Run, 0o755); err != nil {
		return err
	}
	metrics.Read(memSamples)
	var total, heap uint64
	if memSamples[0].Value.Kind() == metrics.KindUint64 {
		total = memSamples[0].Value.Uint64()
	}
	if memSamples[1].Value.Kind() == metrics.KindUint64 {
		heap = memSamples[1].Value.Uint64()
	}
	var b strings.Builder
	fmt.Fprintf(&b, "ts=%d\nup=%d\napp_ok=%d\n", time.Now().Unix(), p.uptime(), b2i(h.OK))
	if h.MQTTConf {
		fmt.Fprintf(&b, "mqtt=%d\n", b2i(h.MQTT))
		if !h.MQTT && h.BrokerKnown {
			fmt.Fprintf(&b, "mqtt_broker=%d\n", b2i(h.BrokerUp))
		}
	}
	fmt.Fprintf(&b, "go_total_kb=%d\ngo_heap_kb=%d\ngoroutines=%d\n", total/1024, heap/1024, runtime.NumGoroutine())
	if h.Version != "" {
		fmt.Fprintf(&b, "version=%s\n", oneLine(h.Version))
	}
	if !h.OK && h.Err != "" {
		fmt.Fprintf(&b, "app_err=%s\n", oneLine(h.Err))
	}
	tmp := filepath.Join(p.Run, ".health.tmp")
	if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(p.Run, "health"))
}

func b2i(v bool) int {
	if v {
		return 1
	}
	return 0
}

// oneLine keeps a value on one line of at most 120 bytes.
func oneLine(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '=' {
			return ' '
		}
		return r
	}, s)
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

// readKV reads a key=value file. A missing file is no error: nothing to say.
func readKV(path string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()
	kv := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if ok && k != "" {
			kv[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return kv
}

func readLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.TrimSpace(line)
}

// Diag is what Qiara Plus adds to the diagnostic reading. Empty when it is
// not installed, or when the guard has not written its status yet.
func (p Paths) Diag() map[string]any {
	if !p.Installed() {
		return nil
	}
	r := map[string]any{}
	if s := readLine(filepath.Join(p.State, "active")); s != "" {
		r["qp_slot_active"] = s
	}
	if s := readLine(filepath.Join(p.State, "running_slot")); s != "" {
		r["qp_slot"] = s
	}
	_, err := os.Stat(filepath.Join(p.State, "trial"))
	r["qp_trial"] = onOff(err == nil)
	// The result of the last update: in memory (Run) since its tools write
	// it there, kept on the card (State) so that a restart
	// does not leave the entity unknown; "aucun" when there never was one.
	res := readLine(filepath.Join(p.Run, "last_update_result"))
	if res == "" {
		res = readLine(filepath.Join(p.State, "last_update_result"))
	}
	if res == "" {
		res = "aucun"
	}
	r["qp_update_result"] = stateText(res)
	// The guard beats every 10 s (guard_beat = its uptime): a minute without
	// a beat, or no beat at all while Qiara Plus is installed, is a guard gone.
	beat, berr := strconv.ParseInt(readLine(filepath.Join(p.Run, "guard_beat")), 10, 64)
	age := p.uptime() - beat
	r["qp_guard_ok"] = onOff(berr == nil && age >= 0 && age < 60)
	g := readKV(filepath.Join(p.Run, "guard-status"))
	if g == nil {
		return r
	}
	if v, ok := g["net_ok"]; ok {
		r["qp_gateway_ok"] = onOff(v == "1")
	}
	if g["ssh22"] == "1" || g["ssh22"] == "0" {
		// ssh2222 is the guard's spare SSH listener; "off" when it is not
		// configured (SSH_SECOURS_PORT=0, the distribution's default).
		r["qp_ssh_ok"] = onOff(g["ssh22"] == "1" && (g["ssh2222"] == "1" || g["ssh2222"] == "off"))
	}
	if s := g["last_reboot"]; s != "" {
		r["qp_last_auto_reboot"] = stateText(s)
	}
	if n, err := strconv.Atoi(g["hang_kills"]); err == nil {
		r["qp_hang_kills"] = n
	}
	switch g["video_iv"] {
	case "0":
		r["video_iv_on"] = onOff(false)
	case "1":
		r["video_iv_on"] = onOff(true)
	}
	if n, err := strconv.Atoi(g["video_bitrate"]); err == nil {
		r["video_bitrate_kbps"] = n / 1000
	} else if g["video_bitrate"] == "defaut" {
		r["video_bitrate_kbps"] = 1000 // no --1080p-bitrate: hlcamd's own 1 Mbit/s (measured 24/10/2026)
	}
	if n, err := strconv.Atoi(g["video_gop_denum"]); err == nil {
		r["video_gop_denum"] = n
	} else if g["video_gop_denum"] == "defaut" {
		r["video_gop_denum"] = 2 // no --gop-denum: hlcamd's own key frame every 0.5 s at 30 fps (measured 25/10/2026)
	}
	// The optional H.264 encoder library (qiara_shim), loaded into hlcamd by
	// some installations: reported only when it is in use, so that a camera
	// without it shows no entity that would stay "off" for good.
	if g["video_shim"] == "1" {
		r["video_shim_on"] = onOff(true)
	}
	// The codec hlcamd was launched with (v8 of the guard reads its command
	// line): what camera_boot.sh asked for, against what the stream shows
	// (video_codec, from the daemon). "defaut": neither --use-h264 nor
	// --use-h265 on the line; left out while hlcamd is gone, or with a
	// guard before v8.
	switch g["video_codec"] {
	case "h264":
		r["video_codec_hlcamd"] = "H.264"
	case "h265":
		r["video_codec_hlcamd"] = "H.265"
	case "defaut":
		r["video_codec_hlcamd"] = "defaut"
	}
	// The black box of the SSH inquiry: kept running by the guard
	// once enabled; left out while it is not enabled.
	switch g["bb"] {
	case "0", "1":
		r["qp_bb_on"] = onOff(g["bb"] == "1")
	}
	return r
}

// stateText keeps a text within Home Assistant's 255-character state limit
// (beyond it the state becomes "unknown"), cut on a character boundary.
func stateText(s string) string {
	if len(s) <= 250 {
		return s
	}
	cut := 250
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut]
}

func onOff(v bool) string {
	if v {
		return "ON"
	}
	return "OFF"
}

// Orders the guard knows. Nothing else can be asked for. ssh-restart
// (guard v8) relaunches both dropbear listeners, 22 and 2222.
var Orders = []string{"wifi-bounce", "wifi-driver", "restart-app", "update-rollback", "use-prev", "reboot", "ssh-restart"}

// ErrUnknownOrder is an order outside Orders.
var ErrUnknownOrder = errors.New("qplus: unknown order")

// Order leaves an order for the guard, which carries it out within 10 s
// (and applies its own limits: reboots are capped, for one).
func (p Paths) Order(name string) error {
	known := false
	for _, o := range Orders {
		if o == name {
			known = true
		}
	}
	if !known {
		return ErrUnknownOrder
	}
	if !p.Installed() {
		return errors.New("qplus: Qiara Plus is not installed")
	}
	// The guard beats every 10 s: an order left while it is gone would wait
	// in /tmp/qp/cmd and run whenever it comes back (a reboot hours later).
	beat, err := strconv.ParseInt(readLine(filepath.Join(p.Run, "guard_beat")), 10, 64)
	if age := p.uptime() - beat; err != nil || age < 0 || age > 120 {
		return ErrGuardAbsent
	}
	dir := filepath.Join(p.Run, "cmd")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// O_EXCL|O_NOFOLLOW: never truncate what a link planted there points at;
	// an order already waiting is the same order.
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if errors.Is(err, os.ErrExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return f.Close()
}

// ErrGuardAbsent: the guard has not beaten for 2 minutes, nobody would
// carry the order out now.
var ErrGuardAbsent = errors.New("qplus: the guard is not running")

// RunHealth writes the health record every period until ctx ends. read is
// called in this goroutine: if it blocks (a deadlock in the gateway), the
// record ages and the guard restarts OpenQiara, which is the point.
func (p Paths) RunHealth(ctx context.Context, every time.Duration, read func() Health) {
	if !p.Installed() {
		return
	}
	t := time.NewTicker(every)
	defer t.Stop()
	failing := false
	for {
		// A failed write ages the record and the guard ends up restarting
		// OpenQiara: say why, once per run of failures.
		if err := p.WriteHealth(read()); err != nil && !failing {
			failing = true
			slog.Warn("qplus: health record not written", "error", err)
		} else if err == nil {
			failing = false
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// ProcMemoryKB reads VmRSS and RssAnon (kB) of a process, "self" or a pid.
// RssAnon is what the kernel can never reclaim (no swap on the camera).
func (p Paths) ProcMemoryKB(pid string) (rss, anon int64, ok bool) {
	f, err := os.Open(filepath.Join(p.Proc, pid, "status"))
	if err != nil {
		return 0, 0, false
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, found := strings.Cut(sc.Text(), ":")
		if !found {
			continue
		}
		fields := strings.Fields(v)
		if len(fields) == 0 {
			continue
		}
		n, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			continue
		}
		switch k {
		case "VmRSS":
			rss, ok = n, true
		case "RssAnon":
			anon = n
		}
	}
	return rss, anon, ok
}

// FindProcess returns the pid of the first process named comm, or "".
func (p Paths) FindProcess(comm string) string {
	entries, err := os.ReadDir(p.Proc)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if e.Name()[0] < '0' || e.Name()[0] > '9' {
			continue
		}
		if b, err := os.ReadFile(filepath.Join(p.Proc, e.Name(), "comm")); err == nil && strings.TrimSpace(string(b)) == comm {
			return e.Name()
		}
	}
	return ""
}

// MemoryDiag is the memory of OpenQiara and hlcamd, in MB, for the
// diagnostic reading. It does not need Qiara Plus.
func (p Paths) MemoryDiag() map[string]any {
	r := map[string]any{}
	if rss, anon, ok := p.ProcMemoryKB("self"); ok {
		r["openqiara_rss_mb"] = mb(rss)
		r["openqiara_anon_mb"] = mb(anon)
	}
	pid := p.FindProcess("hlcamd")
	// The video daemon running at all: its memory says nothing
	// when it is gone, this does.
	r["hlcamd_running"] = onOff(pid != "")
	if pid != "" {
		if rss, _, ok := p.ProcMemoryKB(pid); ok {
			r["hlcamd_rss_mb"] = mb(rss)
		}
		// How long hlcamd has run: a relaunch of the video daemon
		// is what precedes the SSH cut-offs seen on the camera (15 to 60 min
		// after each one), and what the owner wants kept rare. A drop of this
		// figure is a relaunch, whoever did it.
		if up, ok := p.ProcUptimeS(pid); ok {
			r["hlcamd_uptime_s"] = up
		}
	}
	return r
}

// userHZ is the unit of the start time in /proc/<pid>/stat: USER_HZ, fixed
// at 100 on Linux whatever the kernel's tick.
const userHZ = 100

// ProcUptimeS is how long a process has run, in seconds: the system's
// uptime less the process's start time (field 22 of /proc/<pid>/stat, in
// USER_HZ ticks since boot).
func (p Paths) ProcUptimeS(pid string) (int64, bool) {
	b, err := os.ReadFile(filepath.Join(p.Proc, pid, "stat"))
	if err != nil {
		return 0, false
	}
	// The command name, field 2, is in parentheses and may hold spaces:
	// the fields are counted after the closing one.
	i := strings.LastIndexByte(string(b), ')')
	if i < 0 {
		return 0, false
	}
	f := strings.Fields(string(b[i+1:]))
	// f[0] is field 3 (state); the start time, field 22, is f[19].
	if len(f) < 20 {
		return 0, false
	}
	start, err := strconv.ParseInt(f[19], 10, 64)
	if err != nil {
		return 0, false
	}
	up := p.uptime() - start/userHZ
	if up < 0 {
		return 0, false
	}
	return up, true
}

// mb turns kB (KiB, as /proc gives them) into MB (10^6 bytes, the unit Home
// Assistant shows), rounded to 0.1.
func mb(kb int64) float64 { return math.Round(float64(kb)*1024/100000) / 10 }
