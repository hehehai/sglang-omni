//go:build darwin

package macx

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestStartStop: a sound's Done closes when the player exits (PlayWait
// waits for it), and Stop ends it at once. A silent stand-in plays (a
// script that waits), so the test needs no output device and makes no
// sound. The bounds hold under the full suite's load (a busy Mac may
// take a second or more to start or reap a process): a player that
// sleeps 0.3 s never ends sooner, and a stopped one that would sleep a
// minute ends long before.
func TestStartStop(t *testing.T) {
	const played = 300 * time.Millisecond // the stand-in's default sleep
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
		if d := time.Since(t0); d < played {
			t.Errorf("ended after %v", d)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("did not end")
	}
	p.Stop() // ended already: nothing

	// PlayWait returns when the player exits.
	t0 = time.Now()
	if err := PlayWait(SoundStart); err != nil || time.Since(t0) < played {
		t.Errorf("PlayWait: %v after %v", err, time.Since(t0))
	}

	t.Setenv("SLEEP", "60")
	p, err = Start("Submarine")
	if err != nil {
		t.Fatal(err)
	}
	t0 = time.Now()
	p.Stop()
	select {
	case <-p.Done():
		t.Logf("stopped after %v", time.Since(t0))
	case <-time.After(30 * time.Second): // half its sleep
		t.Fatal("not stopped")
	}
	p.Stop() // again: nothing

	afplay = filepath.Join(t.TempDir(), "missing")
	if _, err := Start(SoundStart); err == nil {
		t.Error("a missing player started")
	}
}
