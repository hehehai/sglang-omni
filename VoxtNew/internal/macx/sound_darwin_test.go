//go:build darwin

package macx

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestStartStop: a sound's Done closes when the player exits, and Stop
// ends it at once. A silent stand-in plays (a script that waits), so the
// test needs no output device and makes no sound.
func TestStartStop(t *testing.T) {
	fake := filepath.Join(t.TempDir(), "afplay")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\nexec sleep \"${SLEEP:-0.3}\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := afplay
	afplay = fake
	defer func() { afplay = old }()

	t0 := time.Now()
	p, err := Start(SoundStart)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.Done():
		if d := time.Since(t0); d < 250*time.Millisecond {
			t.Errorf("ended after %v", d)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("did not end")
	}
	p.Stop() // ended already: nothing

	t.Setenv("SLEEP", "10")
	p, err = Start("Submarine")
	if err != nil {
		t.Fatal(err)
	}
	t0 = time.Now()
	p.Stop()
	select {
	case <-p.Done():
		if d := time.Since(t0); d > 500*time.Millisecond {
			t.Errorf("stopped after %v", d)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("not stopped")
	}
	p.Stop() // again: nothing

	afplay = filepath.Join(t.TempDir(), "missing")
	if _, err := Start(SoundStart); err == nil {
		t.Error("a missing player started")
	}
}
