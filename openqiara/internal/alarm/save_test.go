package alarm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The state file is written whole or not at all: a temporary file
// renamed over the old one, never a truncated file for Load to choke on
// after a power cut.
func TestSaveIsAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "alarm.json")
	siren := &fakeSiren{}
	e := New(path, siren, nil, nil, nil)
	t.Cleanup(e.Close)
	e.HandleCommand("arm_away", SourceRemote)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var p persistedState
	if err := json.Unmarshal(b, &p); err != nil || p.State != StateArmedAway {
		t.Fatalf("state file = %s (%v)", b, err)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temporary file left behind: %v", err)
	}
	// A directory that cannot be written: logged, nothing else (the engine
	// keeps its state in memory).
	e2 := New(filepath.Join(dir, "missing", "alarm.json"), siren, nil, nil, nil)
	t.Cleanup(e2.Close)
	e2.HandleCommand("arm_night", SourceRemote)
	if e2.Snapshot().State != StateArmedNight {
		t.Error("state lost on a failed write")
	}
	// Loaded back by a new engine.
	e3 := New(path, &fakeSiren{}, nil, nil, nil)
	t.Cleanup(e3.Close)
	if err := e3.Load(); err != nil || e3.Snapshot().State != StateArmedAway {
		t.Fatalf("reload: %v, state %s", err, e3.Snapshot().State)
	}
}
