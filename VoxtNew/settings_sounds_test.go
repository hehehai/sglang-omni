package main

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/session"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

// soundsRig is Settings → Audio with the previews recorded ("Pop" when
// one starts, "-Pop" when it is stopped) and the clock of a.later in the
// test's hands.
type soundsRig struct {
	*app
	tt    *ui.Tester
	ft    *fakeTimers
	plays []string
}

func newSoundsRig(t *testing.T) *soundsRig {
	a, _, tt := newTestApp(t)
	r := &soundsRig{app: a, tt: tt}
	r.ft = new(fakeTimers).install(a)
	a.startSound = func(s macx.Sound) func() {
		r.plays = append(r.plays, string(s))
		return func() { r.plays = append(r.plays, "-"+string(s)) }
	}
	tt.SetSize(windowWidth, 1400) // the whole section, without scrolling
	a.navigate("/settings/audio")
	frames(tt)
	return r
}

func (r *soundsRig) takePlays() []string {
	p := r.plays
	r.plays = nil
	return p
}

// center is the middle of the text s on screen.
func (r *soundsRig) center(t *testing.T, s string) (float32, float32) {
	t.Helper()
	rc, ok := r.tt.Find(s)
	if !ok {
		t.Fatalf("no %q on screen: %q", s, firstTexts(r.tt))
	}
	return rc.X + rc.W/2, rc.Y + rc.H/2
}

// TestSoundsRow: the menu and Try show while Play sounds is on, as in
// Voxt's row; the menu lists Voxt's ten presets, Soft's name translated
// and the others macOS's.
func TestSoundsRow(t *testing.T) {
	r := newSoundsRig(t)
	if !has(r.tt, "Soft (Pop/Tink)") || !has(r.tt, "Try sound") {
		t.Fatalf("no menu or Try: %q", firstTexts(r.tt))
	}
	// The switch is right of Try (the title's text, first, has its name).
	try, _ := r.tt.Find("Try sound")
	_, y := r.center(t, "Play sounds")
	sw := try.X + try.W + 20
	r.tt.ClickAt(sw, y)
	if r.prefs.Audio.Sounds || has(r.tt, "Soft (Pop/Tink)") || has(r.tt, "Try sound") {
		t.Fatal("the menu shows while the sounds are off")
	}
	r.tt.ClickAt(sw, y)
	if !r.prefs.Audio.Sounds || !has(r.tt, "Soft (Pop/Tink)") {
		t.Fatal("the menu did not come back")
	}
	click(t, r.tt, "Sound preset") // opens the menu: plays nothing
	for _, name := range []string{"Ping", "Morse", "Submarine", "Basso", "Bottle", "Frog", "Hero", "Purr", "Sosumi"} {
		if !hasExact(r.tt, name) {
			t.Errorf("no %s in the menu", name)
		}
	}
	r.ft.advance(soundRest * 3)
	if p := r.takePlays(); len(p) != 0 {
		t.Errorf("opening the menu played %q", p)
	}
	// An unknown preset in the settings shows as Soft.
	r.tt.Key(0, ui.KeyEscape)
	r.updateSettings(func(s *settings.Settings) { s.Audio.SoundPreset = "bell" })
	r.loadSettingsForm()
	if !has(r.tt, "Soft (Pop/Tink)") || r.settingsForm.soundPreset != "soft" {
		t.Errorf("unknown preset: %q", r.settingsForm.soundPreset)
	}
}

// TestSoundsChoose: choosing a preset keeps it and plays its start sound
// at once.
func TestSoundsChoose(t *testing.T) {
	r := newSoundsRig(t)
	click(t, r.tt, "Sound preset")
	click(t, r.tt, "Hero")
	if got := r.settings.Get().Audio.SoundPreset; got != "hero" {
		t.Fatalf("preset %q", got)
	}
	if p := r.takePlays(); !slices.Equal(p, []string{"Hero"}) {
		t.Fatalf("plays %q", p)
	}
	if !has(r.tt, "Hero") || has(r.tt, "Soft (Pop/Tink)") {
		t.Errorf("the menu does not show Hero: %q", firstTexts(r.tt))
	}
	// Try plays the chosen one, cutting the one before short.
	click(t, r.tt, "Try sound")
	if p := r.takePlays(); !slices.Equal(p, []string{"-Hero", "Hero"}) {
		t.Fatalf("Try: %q", p)
	}
	// Back to Soft: Pop.
	click(t, r.tt, "Sound preset")
	click(t, r.tt, "Soft (Pop/Tink)")
	if got := r.settings.Get().Audio.SoundPreset; got != "soft" {
		t.Fatalf("preset %q", got)
	}
	if p := r.takePlays(); !slices.Equal(p, []string{"-Hero", "Pop"}) {
		t.Fatalf("Soft: %q", p)
	}
}

// TestSoundsTryAccent: Try shows the accent while the sound is heard (at
// least previewMin), and a second Try keeps it on until its own end.
func TestSoundsTryAccent(t *testing.T) {
	r := newSoundsRig(t)
	click(t, r.tt, "Try sound")
	if !r.sounds.previewing || !slices.Equal(r.takePlays(), []string{"Pop"}) {
		t.Fatal("Try did not play Pop")
	}
	r.ft.advance(previewMin - 1)
	if !r.sounds.previewing {
		t.Fatal("the accent went before previewMin")
	}
	click(t, r.tt, "Try sound")
	r.ft.advance(1)
	if !r.sounds.previewing {
		t.Fatal("the first preview's timer ended the second's accent")
	}
	r.ft.advance(previewMin)
	frames(r.tt)
	if r.sounds.previewing {
		t.Fatal("the accent stayed")
	}
	// A long sound keeps it longer: Submarine's 0.87 s and the margin.
	r.updateSettings(func(s *settings.Settings) { s.Audio.SoundPreset = "submarine" })
	click(t, r.tt, "Try sound")
	r.ft.advance(previewMin)
	if !r.sounds.previewing {
		t.Fatal("Submarine's accent ended at previewMin")
	}
	r.ft.advance(macx.Sound("Submarine").Audible() + cueMargin - previewMin)
	if r.sounds.previewing {
		t.Fatal("Submarine's accent stayed")
	}
}

// TestSoundsRest: in the open menu, an option the pointer or the arrows
// rest on plays after soundRest; options passed over play nothing, and
// nothing is chosen.
func TestSoundsRest(t *testing.T) {
	r := newSoundsRig(t)
	click(t, r.tt, "Sound preset")
	r.tt.Move(r.center(t, "Bottle"))
	frames(r.tt)
	r.tt.Move(r.center(t, "Frog"))
	frames(r.tt)
	r.ft.advance(soundRest - 1)
	if p := r.takePlays(); len(p) != 0 {
		t.Fatalf("played before the rest: %q", p)
	}
	r.ft.advance(soundRest)
	if p := r.takePlays(); !slices.Equal(p, []string{"Frog"}) {
		t.Fatalf("rest: %q", p)
	}
	if r.settings.Get().Audio.SoundPreset != "" {
		t.Fatal("the highlight chose a preset")
	}
	r.tt.Key(0, ui.KeyDown) // to Hero
	frames(r.tt)
	r.ft.advance(soundRest)
	if p := r.takePlays(); !slices.Equal(p, []string{"-Frog", "Hero"}) {
		t.Fatalf("arrow: %q", p)
	}
	// A rest cut short by closing the menu plays nothing.
	r.tt.Key(0, ui.KeyDown) // to Purr
	frames(r.tt)
	r.tt.Key(0, ui.KeyEscape)
	frames(r.tt)
	r.ft.advance(soundRest)
	if p := r.takePlays(); len(p) != 0 {
		t.Fatalf("after closing: %q", p)
	}
	if r.settings.Get().Audio.SoundPreset != "" {
		t.Fatal("Escape chose a preset")
	}
}

// TestPreviewPlayerOrder: a preview that reaches the player after a newer
// one plays nothing, and each one stops the one before.
func TestPreviewPlayerOrder(t *testing.T) {
	var plays []string
	start := func(s macx.Sound) func() {
		plays = append(plays, string(s))
		return func() { plays = append(plays, "-"+string(s)) }
	}
	var p previewPlayer
	p.play(2, "Ping", start)
	p.play(1, "Pop", start) // late
	p.play(3, "Frog", start)
	p.play(4, "Hero", nil) // could not start: the one before stops anyway
	p.play(5, "Basso", start)
	if want := []string{"Ping", "-Ping", "Frog", "-Frog", "Basso"}; !slices.Equal(plays, want) {
		t.Fatalf("plays %q, want %q", plays, want)
	}
}

// TestSoundsWhileRecording: a preview during a recording leaves its
// session alone, and the recording's cues stay its preset's.
func TestSoundsWhileRecording(t *testing.T) {
	r := newSoundsRig(t)
	var cues []macx.Sound
	r.playSound = func(s macx.Sound) { cues = append(cues, s) }
	rev := r.sess.Rev
	feed := func(st session.State) {
		rev++
		r.sessionChanged(session.Snapshot{Rev: rev, ID: "s1", Kind: store.KindTranscribe, State: st, Try: true})
	}
	feed(session.Recording)
	r.trySound("glass")
	if r.sess.State != session.Recording || !slices.Equal(r.takePlays(), []string{"Ping"}) {
		t.Fatalf("state %s", r.sess.State)
	}
	feed(session.Recognizing)
	if want := []macx.Sound{macx.SoundStart, macx.SoundStop}; !slices.Equal(cues, want) {
		t.Fatalf("cues %q, want %q", cues, want)
	}
}
