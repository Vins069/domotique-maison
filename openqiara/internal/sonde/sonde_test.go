package sonde

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func write(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSystemReadsWhatIsThere(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "proc/uptime", "12345.67 9000.00\n")
	write(t, dir, "proc/meminfo", "MemTotal:  129000 kB\nMemAvailable:   40960 kB\n")
	write(t, dir, "proc/net/snmp", "Tcp: RtoAlgorithm OutSegs RetransSegs\nTcp: 1 1000 50\n")
	write(t, dir, "sys/class/thermal/thermal_zone0/temp", "47500\n")
	write(t, dir, "sys/class/net/ssv0/carrier_changes", "6\n")
	s := &Sonde{Proc: filepath.Join(dir, "proc"), Sys: filepath.Join(dir, "sys"), Iface: "ssv0", Media: dir, Data: dir}
	r := s.System()
	check := func(key string, want any) {
		t.Helper()
		if r[key] != want {
			t.Errorf("%s = %v (%T), want %v", key, r[key], r[key], want)
		}
	}
	check("uptime_s", int64(12345))
	check("mem_available_mb", int64(40))
	check("soc_temp_c", 47.5)
	check("wifi_carrier_changes", int64(6))
	check("wifi_drops", int64(3))
	check("tcp_retrans_pct", 5.0)
	if _, ok := r["media_used_pct"]; !ok {
		t.Error("media_used_pct missing on a real directory")
	}
	if _, ok := r["wifi_rssi_dbm"]; ok {
		t.Error("no /proc/net/wireless entry: no RSSI")
	}
}

func TestSystemMissingSourcesLeaveKeysOut(t *testing.T) {
	dir := t.TempDir()
	s := &Sonde{Proc: dir, Sys: dir, Iface: "ssv0", Media: filepath.Join(dir, "nope"), Data: filepath.Join(dir, "nope")}
	// The clock is always told: it needs no file.
	if r := s.System(); len(r) != 1 || r["clock_ok"] != "ON" {
		t.Errorf("nothing readable, got %v", r)
	}
}

// the clock, the boot time, the processor's load and the Wi-Fi
// link quality.
func TestSystemClockLoadAndLink(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "proc/uptime", "3600.00 7000.00\n")
	write(t, dir, "proc/loadavg", "0.52 0.40 0.33 1/120 4567\n")
	write(t, dir, "proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 100 0 100 700 100 0 0 0 0 0\n")
	write(t, dir, "proc/net/wireless", " face | tus | link level noise\n ssv0: 0000   60.  -52.  -256.   0 0 0 0 0 0\n")
	// 1970: the clock is not set, no boot time.
	clock := time.Date(1970, 1, 1, 1, 0, 0, 0, time.UTC)
	s := &Sonde{Proc: filepath.Join(dir, "proc"), Sys: dir, Iface: "ssv0", Media: dir, Data: dir, Now: func() time.Time { return clock }}
	r := s.System()
	if r["clock_ok"] != "OFF" {
		t.Errorf("clock_ok = %v in 1970", r["clock_ok"])
	}
	if _, ok := r["boot_time"]; ok {
		t.Error("a boot time from a 1970 clock")
	}
	if r["load_1m"] != 0.52 || r["wifi_link_quality"] != 60 {
		t.Errorf("load %v link %v", r["load_1m"], r["wifi_link_quality"])
	}
	if _, ok := r["cpu_pct"]; ok {
		t.Error("a processor load at the first pass")
	}
	// The clock set: the boot time is now minus the uptime, fixed from then
	// on; the processor's load is the share busy since the last pass.
	clock = time.Date(2026, 10, 27, 13, 0, 0, 0, time.UTC)
	write(t, dir, "proc/stat", "cpu  220 0 200 760 120 0 0 0 0 0\n") // +300 jiffies, 80 of them idle: 73 % busy
	r = s.System()
	if r["clock_ok"] != "ON" || r["boot_time"] != "2026-10-27T12:00:00Z" {
		t.Errorf("clock_ok %v boot_time %v", r["clock_ok"], r["boot_time"])
	}
	if r["cpu_pct"] != 73 {
		t.Errorf("cpu_pct = %v", r["cpu_pct"])
	}
	clock = clock.Add(90 * time.Second)
	write(t, dir, "proc/uptime", "3690.00 7100.00\n")
	if r = s.System(); r["boot_time"] != "2026-10-27T12:00:00Z" {
		t.Errorf("boot time drifted: %v", r["boot_time"])
	}
	// Counters that went backwards: no figure rather than a wrong one.
	write(t, dir, "proc/stat", "cpu  10 0 10 10 0 0 0 0 0 0\n")
	if r = s.System(); r["cpu_pct"] != nil {
		t.Errorf("cpu_pct from counters gone backwards: %v", r["cpu_pct"])
	}
}

func TestWirelessLevel(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "wireless", "Inter-| sta-|   Quality        |   Discarded packets\n face | tus | link level noise |  nwid\n ssv0: 0000   60.  -52.  -256.   0 0 0 0 0 0\n")
	if lvl, ok := wirelessLevel(filepath.Join(dir, "wireless"), "ssv0"); !ok || lvl != -52 {
		t.Errorf("level = %d, %v", lvl, ok)
	}
	write(t, dir, "w2", " face | tus | link level noise\n ssv0: 0000 60. 204. 0.\n")
	if lvl, ok := wirelessLevel(filepath.Join(dir, "w2"), "ssv0"); !ok || lvl != -52 {
		t.Errorf("unsigned byte level = %d, %v", lvl, ok)
	}
}

func TestParseAir(t *testing.T) {
	r := ParseAir("value:\n    tvoc: 303\n    eco2: 802\n    aqi: good\n    temperature: 41\n    humidity: 21\n")
	want := Reading{"air_tvoc_ppb": 303, "air_eco2_ppm": 802, "air_aqi": 2, "air_quality": "good", "air_quality_fr": "bonne", "board_temp_c": 41, "board_humidity_pct": 21}
	if len(r) != len(want) {
		t.Fatalf("got %v", r)
	}
	for k, v := range want {
		if r[k] != v {
			t.Errorf("%s = %v, want %v", k, r[k], v)
		}
	}
	if got := ParseAir("garbage\ntvoc: abc\naqi: weird\n"); len(got) != 0 {
		t.Errorf("garbage gave %v", got)
	}
}

func TestVendorSurvivesMissingClient(t *testing.T) {
	s := &Sonde{Run: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("not found")
	}}
	if r := s.Vendor(context.Background()); len(r) != 0 {
		t.Errorf("got %v", r)
	}
	dir := t.TempDir()
	write(t, dir, "proc/uptime", "3600.5 7000.1\n")
	s.Proc = filepath.Join(dir, "proc")
	s.Run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("tvoc: 10\n"), nil
	}
	if r := s.Vendor(context.Background()); r["air_tvoc_ppb"] != 10 {
		t.Errorf("got %v", r)
	}
}

// TestVendorAirWarmup: no air reading while the ENS160 warms up
// (uptime < 240 s), nor an impossible one; the board's temperature and
// humidity always go out.
func TestVendorAirWarmup(t *testing.T) {
	dir := t.TempDir()
	out := "value:\n    tvoc: 38\n    eco2: 432\n    aqi: excellent\n    temperature: 46\n    humidity: 17\n"
	s := &Sonde{Proc: filepath.Join(dir, "proc"), Run: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte(out), nil
	}}
	write(t, dir, "proc/uptime", "100.2 150.0\n")
	r := s.Vendor(context.Background())
	if _, ok := r["air_aqi"]; ok || r["board_temp_c"] != 46 || r["board_humidity_pct"] != 17 {
		t.Fatalf("warming up: %v", r)
	}
	write(t, dir, "proc/uptime", "300.0 500.0\n")
	r = s.Vendor(context.Background())
	if r["air_aqi"] != 1 || r["air_eco2_ppm"] != 432 || r["air_tvoc_ppb"] != 38 || r["air_quality_fr"] != "très bonne" {
		t.Fatalf("warmed up: %v", r)
	}
	out = "value:\n    tvoc: 0\n    eco2: 0\n    aqi: excellent\n    temperature: 46\n    humidity: 17\n"
	if r = s.Vendor(context.Background()); r["air_eco2_ppm"] != nil || r["air_aqi"] != nil || r["board_temp_c"] != 46 {
		t.Fatalf("impossible eCO2 published: %v", r)
	}
}

func TestMstarTemperature(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "sys/class/mstar/msys/TEMP_R", "Temperature 62\n")
	s := &Sonde{Sys: filepath.Join(dir, "sys")}
	if v, ok := s.temperature(); !ok || v != 62 {
		t.Errorf("got %v %v", v, ok)
	}
}

func TestFirmware(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "etc/os-release", "NAME=Buildroot\nVERSION=-g326024c\nVERSION_ID=2024.11.1\nPRETTY_NAME=\"Buildroot 2024.11.1\"\n")
	s := &Sonde{Etc: filepath.Join(dir, "etc")}
	if got := s.firmware(); got != "Buildroot 2024.11.1 (-g326024c)" {
		t.Errorf("got %q", got)
	}
	if got := (&Sonde{Etc: dir + "/none"}).firmware(); got != "" {
		t.Errorf("got %q", got)
	}
}
