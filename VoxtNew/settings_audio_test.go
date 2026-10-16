package main

import (
	"encoding/json"
	"slices"
	"testing"

	"github.com/hehehai/Auralink/internal/helper"
	"github.com/hehehai/Auralink/internal/helper/proto"
	"github.com/hehehai/Auralink/internal/macx"
	"github.com/hehehai/Auralink/internal/session"
	"github.com/hehehai/Auralink/internal/settings"
	"github.com/hehehai/Auralink/internal/store"
)

func TestAudioSettingsDevices(t *testing.T) {
	a, fs, tt := newTestApp(t)
	a.navigate("/settings/audio")
	if !slices.Contains(fs.methods(), proto.MethodCaptureDevices) {
		t.Fatalf("the section did not list the inputs: %v", fs.methods())
	}
	if !has(tt, "No microphone chosen: Auralink records from the system's default input.") || !has(tt, "MacBook Air Microphone") {
		t.Fatalf("empty list: %q", firstTexts(tt))
	}
	if !has(tt, "Skip silence") || !has(tt, "Optimize sound") {
		t.Errorf("no recognition switches: %q", firstTexts(tt))
	}
	click(t, tt, "Add AirPods Pro")
	click(t, tt, "Add MacBook Air Microphone")
	got := a.settings.Get().Audio
	if !slices.Equal(got.Devices, []string{"AirPodsPro:input", "BuiltInMicrophoneDevice"}) || got.DeviceNames["AirPodsPro:input"] != "AirPods Pro" {
		t.Fatalf("added: %+v", got)
	}
	if !has(tt, "Records now") || !has(tt, "No other microphone is connected.") {
		t.Errorf("after adding: %q", firstTexts(tt))
	}
	click(t, tt, "Move MacBook Air Microphone up")
	if d := a.settings.Get().Audio.Devices; !slices.Equal(d, []string{"BuiltInMicrophoneDevice", "AirPodsPro:input"}) {
		t.Fatalf("moved: %q", d)
	}
	click(t, tt, "Remove MacBook Air Microphone")
	if d := a.settings.Get().Audio.Devices; !slices.Equal(d, []string{"AirPodsPro:input"}) {
		t.Fatalf("removed: %q", d)
	}
	// A device that is gone keeps its name, marked.
	fs.mu.Lock()
	fs.handlers[proto.MethodCaptureDevices] = func(json.RawMessage) (any, error) {
		return proto.DevicesResult{Devices: []proto.CaptureDevice{{ID: "BuiltInMicrophoneDevice", Name: "MacBook Air Microphone", Default: true}}}, nil
	}
	fs.mu.Unlock()
	click(t, tt, "Refresh the microphones")
	if !has(tt, "AirPods Pro") || !has(tt, "Not connected") || !has(tt, "Records now · System default") {
		t.Errorf("unplugged: %q", firstTexts(tt))
	}
	// Without the helper: a notice, no list.
	fs.set(helper.Status{State: helper.Stopped})
	if !has(tt, "The helper is not running: the microphones cannot be listed.") {
		t.Errorf("no helper: %q", firstTexts(tt))
	}
}

func TestDeviceInUse(t *testing.T) {
	devs := []proto.CaptureDevice{{ID: "mic"}, {ID: "usb"}, {ID: "def", Default: true}}
	for _, tc := range []struct {
		list []string
		want string
	}{
		{nil, "def"},
		{[]string{"gone", "usb"}, "usb"},
		{[]string{"gone"}, "def"},
		{[]string{"mic", "usb"}, "mic"},
	} {
		if got := deviceInUse(tc.list, devs); got != tc.want {
			t.Errorf("%q: %q, want %q", tc.list, got, tc.want)
		}
	}
	if got := deviceInUse([]string{"x"}, nil); got != "" {
		t.Errorf("no devices: %q", got)
	}
}

func TestRecordingCues(t *testing.T) {
	snap := func(id string, st session.State) session.Snapshot { return session.Snapshot{ID: id, State: st} }
	for _, tc := range []struct {
		name    string
		was, s  session.Snapshot
		want    macx.Sound
		wantAny bool
	}{
		{"start", snap("", session.Idle), snap("a", session.Recording), macx.SoundStart, true},
		{"after reading", snap("a", session.Reading), snap("a", session.Recording), macx.SoundStart, true},
		{"a new session", snap("a", session.Recording), snap("b", session.Recording), macx.SoundStart, true},
		{"still recording", snap("a", session.Recording), snap("a", session.Recording), "", false},
		{"stop", snap("a", session.Recording), snap("a", session.Recognizing), macx.SoundStop, true},
		{"stop to compose", snap("a", session.Recording), snap("a", session.Composing), macx.SoundStop, true},
		{"cancelled", snap("a", session.Recording), snap("a", session.Cancelled), "", false},
		{"failed", snap("a", session.Recording), snap("a", session.Failed), "", false},
		{"reading a selection", snap("a", session.Reading), snap("a", session.Composing), "", false},
		{"recognized", snap("a", session.Recognizing), snap("a", session.Composing), "", false},
	} {
		got, ok := recordingCue(tc.was, tc.s)
		if got != tc.want || ok != tc.wantAny {
			t.Errorf("%s: %q %v", tc.name, got, ok)
		}
	}
}

func TestSessionSounds(t *testing.T) {
	a, _, _ := newTestApp(t)
	var cues []macx.Sound
	a.playSound = func(s macx.Sound) { cues = append(cues, s) }
	rev := a.sess.Rev
	feed := func(id string, st session.State) {
		rev++
		a.sessionChanged(session.Snapshot{Rev: rev, ID: id, Kind: store.KindTranscribe, State: st, Try: true})
	}
	feed("s1", session.Recording)
	feed("s1", session.Recognizing)
	feed("s1", session.Done)
	feed("s2", session.Recording)
	feed("s2", session.Cancelled)
	if want := []macx.Sound{macx.SoundStart, macx.SoundStop, macx.SoundStart}; !slices.Equal(cues, want) {
		t.Fatalf("cues %q, want %q", cues, want)
	}
	// Off in Settings → Audio: silence.
	a.navigate("/settings/audio")
	a.updateSettings(func(s *settings.Settings) { s.Audio.Sounds = false })
	cues = nil
	feed("s3", session.Recording)
	feed("s3", session.Recognizing)
	if len(cues) != 0 {
		t.Errorf("sounds off: %q", cues)
	}
}
