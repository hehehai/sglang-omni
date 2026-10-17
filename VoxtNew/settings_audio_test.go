package main

import (
	"encoding/json"
	"slices"
	"testing"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/session"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

func TestAudioSettingsDevices(t *testing.T) {
	a, fs, tt := newTestApp(t)
	a.navigate("/settings/audio")
	if !slices.Contains(fs.methods(), proto.MethodCaptureDevices) {
		t.Fatalf("the section did not list the inputs: %v", fs.methods())
	}
	if !has(tt, "No microphone chosen: VoxtNew records from the system's default input.") || !has(tt, "MacBook Air Microphone") {
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
		name   string
		was, s session.Snapshot
		want   cue
	}{
		{"start", snap("", session.Idle), snap("a", session.Recording), startCue},
		{"after reading", snap("a", session.Reading), snap("a", session.Recording), startCue},
		{"a new session", snap("a", session.Recording), snap("b", session.Recording), startCue},
		{"still recording", snap("a", session.Recording), snap("a", session.Recording), noCue},
		{"stop", snap("a", session.Recording), snap("a", session.Recognizing), stopCue},
		{"stop to compose", snap("a", session.Recording), snap("a", session.Composing), stopCue},
		{"cancelled", snap("a", session.Recording), snap("a", session.Cancelled), noCue},
		{"failed", snap("a", session.Recording), snap("a", session.Failed), noCue},
		{"reading a selection", snap("a", session.Reading), snap("a", session.Composing), noCue},
		{"recognized", snap("a", session.Recognizing), snap("a", session.Composing), noCue},
	} {
		if got := recordingCue(tc.was, tc.s); got != tc.want {
			t.Errorf("%s: %v", tc.name, got)
		}
	}
	for _, tc := range []struct {
		preset      string
		start, stop macx.Sound
	}{
		{"", "Pop", "Tink"}, {"soft", "Pop", "Tink"}, {"nope", "Pop", "Tink"},
		{"glass", "Ping", "Ping"}, {"submarine", "Submarine", "Submarine"}, {"sosumi", "Sosumi", "Sosumi"},
	} {
		if s, e := cueSound(startCue, tc.preset), cueSound(stopCue, tc.preset); s != tc.start || e != tc.stop {
			t.Errorf("%q: %s, %s", tc.preset, s, e)
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
	// Another preset: its sounds, Hero's the same for both.
	for _, tc := range []struct {
		preset string
		want   []macx.Sound
	}{{"frog", []macx.Sound{"Frog", "Frog"}}, {"hero", []macx.Sound{"Hero", "Hero"}}} {
		a.updateSettings(func(s *settings.Settings) { s.Audio.SoundPreset = tc.preset })
		cues = nil
		feed("s-"+tc.preset, session.Recording)
		feed("s-"+tc.preset, session.Done)
		if !slices.Equal(cues, tc.want) {
			t.Fatalf("%s: cues %q", tc.preset, cues)
		}
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
