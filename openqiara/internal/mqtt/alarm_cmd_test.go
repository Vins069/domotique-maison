package mqtt

import (
	"io"
	"log/slog"
	"testing"
)

// A retained alarm command (replayed by the broker at every start) never
// reaches the alarm: a retained DISARM would disarm it, or ask Alarmo to,
// after each restart of OpenQiara.
func TestAlarmCommandIgnoresRetained(t *testing.T) {
	p, _ := newRecordingPublisher()
	p.prefix = "openqiara"
	var got []string
	p.SetupAlarmCommandHandler(7, func(cmd string) { got = append(got, cmd) }, slog.New(slog.NewTextHandler(io.Discard, nil)))
	p.subsMu.Lock()
	h := p.subs["openqiara/alarm/set"].handler
	p.subsMu.Unlock()
	if h == nil {
		t.Fatal("no handler registered")
	}
	h(nil, fakeMessage{topic: "openqiara/alarm/set", payload: "DISARM", retained: true})
	h(nil, fakeMessage{topic: "openqiara/alarm/set", payload: "ARM_AWAY"})
	if len(got) != 1 || got[0] != "ARM_AWAY" {
		t.Errorf("commands passed on = %v, want only ARM_AWAY", got)
	}
}
