package qplus

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func testPaths(t *testing.T, installed bool) Paths {
	t.Helper()
	d := t.TempDir()
	p := Paths{Run: filepath.Join(d, "run"), State: filepath.Join(d, "state"), Guard: filepath.Join(d, "qp-guard"), Proc: filepath.Join(d, "proc")}
	for _, dir := range []string{p.Run, p.State, p.Proc} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(p.Proc, "uptime"), []byte("1234.56 999.00\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if installed {
		if err := os.WriteFile(p.Guard, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return p
}

func TestWriteHealth(t *testing.T) {
	p := testPaths(t, true)
	if err := p.WriteHealth(Health{OK: false, Err: "radio\nsilent=x", MQTT: true, MQTTConf: true, Version: "v1"}); err != nil {
		t.Fatal(err)
	}
	kv := readKV(filepath.Join(p.Run, "health"))
	if kv["up"] != "1234" || kv["app_ok"] != "0" || kv["mqtt"] != "1" || kv["version"] != "v1" {
		t.Fatalf("health = %v", kv)
	}
	if kv["app_err"] != "radio silent x" {
		t.Fatalf("app_err not on one line: %q", kv["app_err"])
	}
	if kv["go_total_kb"] == "" || kv["go_total_kb"] == "0" {
		t.Fatalf("Go memory missing: %v", kv)
	}
	if _, err := os.Stat(filepath.Join(p.Run, ".health.tmp")); !os.IsNotExist(err) {
		t.Fatal("temporary file left behind")
	}
}

// Without a broker in the config, no mqtt= line: the guard reads mqtt=0 as
// a broken link and restarts OpenQiara after MQTT_RESTART_SEC.
func TestWriteHealthWithoutBroker(t *testing.T) {
	p := testPaths(t, true)
	if err := p.WriteHealth(Health{OK: true}); err != nil {
		t.Fatal(err)
	}
	if _, ok := readKV(filepath.Join(p.Run, "health"))["mqtt"]; ok {
		t.Fatal("mqtt= written with no broker configured")
	}
}

func TestRunHealthNotInstalled(t *testing.T) {
	p := testPaths(t, false)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p.RunHealth(ctx, time.Second, func() Health { return Health{OK: true} })
	if _, err := os.Stat(filepath.Join(p.Run, "health")); !os.IsNotExist(err) {
		t.Fatal("health written without Qiara Plus")
	}
}

func TestRunHealthWrites(t *testing.T) {
	p := testPaths(t, true)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	n := 0
	p.RunHealth(ctx, 20*time.Millisecond, func() Health { n++; return Health{OK: true} })
	if n < 3 {
		t.Fatalf("health read %d times", n)
	}
	if readKV(filepath.Join(p.Run, "health"))["app_ok"] != "1" {
		t.Fatal("app_ok not 1")
	}
}

func TestDiag(t *testing.T) {
	p := testPaths(t, false)
	if p.Diag() != nil {
		t.Fatal("diag without Qiara Plus")
	}
	p = testPaths(t, true)
	must := func(path, s string) {
		if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must(filepath.Join(p.State, "active"), "good\n")
	must(filepath.Join(p.State, "running_slot"), "good\n")
	must(filepath.Join(p.Run, "last_update_result"), "ok: 1234abcd valide\n")
	must(filepath.Join(p.Run, "guard_beat"), "1230\n")
	must(filepath.Join(p.Run, "guard-status"), strings.Join([]string{
		"ts=1", "up=1200", "net_ok=1", "ssh22=1", "ssh2222=0", "hang_kills=2", "last_reboot=aucun",
		"video_iv=1", "video_bitrate=defaut", "video_gop_denum=defaut", "video_shim=0", "video_codec=h265"}, "\n"))
	d := p.Diag()
	want := map[string]any{
		"qp_slot_active": "good", "qp_slot": "good", "qp_trial": "OFF", "qp_update_result": "ok: 1234abcd valide",
		"qp_guard_ok": "ON", "qp_gateway_ok": "ON", "qp_ssh_ok": "OFF", "qp_hang_kills": 2, "qp_last_auto_reboot": "aucun",
		"video_iv_on": "ON", "video_bitrate_kbps": 1000, "video_gop_denum": 2, "video_codec_hlcamd": "H.265",
	}
	for k, v := range want {
		if d[k] != v {
			t.Errorf("%s = %v, want %v", k, d[k], v)
		}
	}
	if _, ok := d["video_shim_on"]; ok {
		t.Fatalf("video_shim=0: no encoder library entity expected, got %v", d["video_shim_on"])
	}
	// the spare SSH listener not configured (distribution default): port 22 alone is enough
	must(filepath.Join(p.Run, "guard-status"), "up=1200\nssh22=1\nssh2222=off\n")
	if d = p.Diag(); d["qp_ssh_ok"] != "ON" {
		t.Fatalf("ssh22=1 ssh2222=off: qp_ssh_ok = %v, want ON", d["qp_ssh_ok"])
	}
	must(filepath.Join(p.Run, "guard-status"), "up=1200\nssh22=0\nssh2222=off\n")
	if d = p.Diag(); d["qp_ssh_ok"] != "OFF" {
		t.Fatalf("ssh22=0 ssh2222=off: qp_ssh_ok = %v, want OFF", d["qp_ssh_ok"])
	}
	// a guard that no longer beats is reported
	must(filepath.Join(p.Run, "guard_beat"), "100\n")
	must(filepath.Join(p.Run, "guard-status"), "up=100\nvideo_iv=0\nvideo_bitrate=4000000\nvideo_gop_denum=2\nvideo_shim=1\nvideo_codec=defaut\n")
	d = p.Diag()
	if d["qp_guard_ok"] != "OFF" || d["video_iv_on"] != "OFF" || d["video_bitrate_kbps"] != 4000 || d["video_gop_denum"] != 2 || d["video_shim_on"] != "ON" || d["video_codec_hlcamd"] != "defaut" {
		t.Fatalf("diag = %v", d)
	}
	if _, ok := d["qp_bb_on"]; ok {
		t.Fatalf("black box reported while not enabled: %v", d["qp_bb_on"])
	}
	// after a restart the result in memory is gone ; the one kept on the card is read,
	// and with neither the entity says "aucun" rather than staying unknown
	if err := os.Remove(filepath.Join(p.Run, "last_update_result")); err != nil {
		t.Fatal(err)
	}
	if d = p.Diag(); d["qp_update_result"] != "aucun" {
		t.Fatalf("no result anywhere: %v", d["qp_update_result"])
	}
	must(filepath.Join(p.State, "last_update_result"), "ok: 5678abcd valide\n")
	if d = p.Diag(); d["qp_update_result"] != "ok: 5678abcd valide" {
		t.Fatalf("result kept on the card not read: %v", d["qp_update_result"])
	}
	must(filepath.Join(p.Run, "last_update_result"), "essai en cours : 9999\n")
	if d = p.Diag(); d["qp_update_result"] != "essai en cours : 9999" {
		t.Fatalf("result in memory must win: %v", d["qp_update_result"])
	}
	for v, want := range map[string]any{"1": "ON", "0": "OFF"} {
		must(filepath.Join(p.Run, "guard-status"), "up=100\nbb="+v+"\n")
		if d = p.Diag(); d["qp_bb_on"] != want {
			t.Fatalf("bb=%s : %v", v, d["qp_bb_on"])
		}
	}
}

func TestOrder(t *testing.T) {
	p := testPaths(t, true)
	if err := p.Order("reboot"); err != ErrGuardAbsent {
		t.Fatalf("order left with no guard beating: %v", err)
	}
	if err := os.WriteFile(filepath.Join(p.Run, "guard_beat"), []byte("1230\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := p.Order("rm -rf /"); err != ErrUnknownOrder {
		t.Fatalf("unknown order accepted: %v", err)
	}
	if err := p.Order("../x"); err != ErrUnknownOrder {
		t.Fatal("path accepted as an order")
	}
	for _, o := range Orders {
		if err := p.Order(o); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(p.Run, "cmd", o)); err != nil {
			t.Fatalf("order %s not left: %v", o, err)
		}
	}
	q := testPaths(t, false)
	if err := q.Order("reboot"); err == nil {
		t.Fatal("order accepted without Qiara Plus")
	}
}

func TestMemoryDiag(t *testing.T) {
	p := testPaths(t, false)
	for _, pr := range []struct{ pid, comm, status string }{
		{"self", "openqiarad", "Name:\topenqiarad\nVmRSS:\t   18424 kB\nRssAnon:\t   16760 kB\n"},
		{"1083", "hlcamd", "Name:\thlcamd\nVmRSS:\t   19528 kB\nRssAnon:\t   13020 kB\n"},
	} {
		d := filepath.Join(p.Proc, pr.pid)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		_ = os.WriteFile(filepath.Join(d, "status"), []byte(pr.status), 0o644)
		_ = os.WriteFile(filepath.Join(d, "comm"), []byte(pr.comm+"\n"), 0o644)
	}
	m := p.MemoryDiag()
	// kB (KiB) to MB (10^6 bytes), rounded: 18424 kB = 18.87 MB
	if m["openqiara_rss_mb"] != 18.9 || m["openqiara_anon_mb"] != 17.2 || m["hlcamd_rss_mb"] != 20.0 || m["hlcamd_running"] != "ON" {
		t.Fatalf("memory = %v", m)
	}
	// hlcamd's running time: the system's uptime (3600 s) less its start
	// time (field 22 of its stat, 120000 ticks of 1/100 s = 1200 s).
	_ = os.WriteFile(filepath.Join(p.Proc, "uptime"), []byte("3600.50 7000.00\n"), 0o644)
	_ = os.WriteFile(filepath.Join(p.Proc, "1083", "stat"), []byte("1083 (hlcamd) S 1 1083 1083 0 -1 4194560 1000 0 0 0 500 300 0 0 20 0 9 0 120000 20000000 4882 4294967295 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n"), 0o644)
	m = p.MemoryDiag()
	if m["hlcamd_uptime_s"] != int64(2400) {
		t.Fatalf("hlcamd_uptime_s = %v", m["hlcamd_uptime_s"])
	}
	// A stat with the name holding a space is read all the same.
	_ = os.WriteFile(filepath.Join(p.Proc, "1083", "stat"), []byte("1083 (hl camd) S 1 1083 1083 0 -1 4194560 1000 0 0 0 500 300 0 0 20 0 9 0 300000 20000000 4882 4294967295 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n"), 0o644)
	if up, ok := p.ProcUptimeS("1083"); !ok || up != 600 {
		t.Fatalf("uptime with a spaced name = %d %v", up, ok)
	}
	if _, ok := p.ProcUptimeS("nope"); ok {
		t.Fatal("uptime of a missing process")
	}
	// hlcamd gone: said so, no memory figure for it.
	if err := os.RemoveAll(filepath.Join(p.Proc, "1083")); err != nil {
		t.Fatal(err)
	}
	m = p.MemoryDiag()
	if m["hlcamd_running"] != "OFF" || m["hlcamd_rss_mb"] != nil {
		t.Fatalf("without hlcamd: %v", m)
	}
}

func TestStateTextBounded(t *testing.T) {
	long := strings.Repeat("é", 200) // 400 bytes
	got := stateText(long)
	if len(got) > 250 || !utf8.ValidString(got) {
		t.Fatalf("len=%d valid=%v", len(got), utf8.ValidString(got))
	}
	if stateText("court") != "court" {
		t.Fatal("short text changed")
	}
}

func TestHealthBrokerLine(t *testing.T) {
	p := testPaths(t, true)
	for _, c := range []struct {
		h    Health
		want string
	}{
		{Health{OK: true, MQTTConf: true, MQTT: true, BrokerKnown: true, BrokerUp: true}, ""},
		{Health{OK: true, MQTTConf: true, MQTT: false, BrokerKnown: true, BrokerUp: true}, "1"},
		{Health{OK: true, MQTTConf: true, MQTT: false, BrokerKnown: true, BrokerUp: false}, "0"},
		{Health{OK: true, MQTTConf: true, MQTT: false}, ""},
	} {
		if err := p.WriteHealth(c.h); err != nil {
			t.Fatal(err)
		}
		if got := readKV(filepath.Join(p.Run, "health"))["mqtt_broker"]; got != c.want {
			t.Errorf("%+v: mqtt_broker=%q, want %q", c.h, got, c.want)
		}
	}
}

// The guard's codec reading (v8): hlcamd gone, or a guard before v8,
// leaves the entity out; h264 and h265 are named as the daemon names them.
func TestDiagVideoCodecHlcamd(t *testing.T) {
	p := testPaths(t, true)
	for status, want := range map[string]string{"video_codec=h264\n": "H.264", "video_codec=h265\n": "H.265", "video_codec=defaut\n": "defaut", "video_codec=absent\n": "", "video_iv=0\n": ""} {
		if err := os.WriteFile(filepath.Join(p.Run, "guard-status"), []byte("up=100\n"+status), 0o644); err != nil {
			t.Fatal(err)
		}
		got, ok := p.Diag()["video_codec_hlcamd"]
		if (want == "") != !ok || (ok && got != want) {
			t.Errorf("%q: %v (%v), want %q", status, got, ok, want)
		}
	}
}

// ssh-restart is an order the guard v8 knows.
func TestSSHRestartOrder(t *testing.T) {
	found := false
	for _, o := range Orders {
		if o == "ssh-restart" {
			found = true
		}
	}
	if !found {
		t.Fatal("ssh-restart missing from the orders")
	}
}
