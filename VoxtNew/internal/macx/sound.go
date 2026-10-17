package macx

import (
	"slices"
	"time"
)

// Sound is a macOS system sound: /System/Library/Sounds/<name>.aiff.
type Sound string

// The cues of Voxt's default ("Soft") preset, the one a new install and a
// setting without a preset play.
const (
	SoundStart Sound = "Pop"  // recording starts
	SoundStop  Sound = "Tink" // recording stops, the text is on its way
)

// Preset is a pair of cues the user picks in Settings → Audio → Play
// sounds (settings.Audio.SoundPreset holds its ID): Voxt's presets, with
// its IDs. Soft has two sounds; the others play one sound for both.
type Preset struct {
	ID          string
	Start, Stop Sound
}

// DefaultPreset is the preset of an empty or unknown ID.
const DefaultPreset = "soft"

// presets, in the order the menu lists them (Voxt's).
var presets = []Preset{
	{"soft", SoundStart, SoundStop},
	{"glass", "Ping", "Ping"},
	{"funk", "Morse", "Morse"},
	{"submarine", "Submarine", "Submarine"},
	{"basso", "Basso", "Basso"},
	{"bottle", "Bottle", "Bottle"},
	{"frog", "Frog", "Frog"},
	{"hero", "Hero", "Hero"},
	{"purr", "Purr", "Purr"},
	{"sosumi", "Sosumi", "Sosumi"},
}

// Presets lists the presets, Soft first.
func Presets() []Preset { return slices.Clone(presets) }

// PresetFor is the preset of id: Soft for "" and for an ID it does not
// know (a setting from a later version, a typo).
func PresetFor(id string) Preset {
	if i := slices.IndexFunc(presets, func(p Preset) bool { return p.ID == id }); i >= 0 {
		return presets[i]
	}
	return presets[0]
}

// audible is how long each preset's sound is heard: from its start to
// its last sample at or above -60 dBFS (Voxt's threshold, 0.001), as
// measured on the files of macOS 26.7 (Auralink's port). The files go on
// in silence for longer (Pop is 1.63 s long, of which 0.22 s are heard),
// which afplay plays to the end. Settings → Audio's Try button shows the
// accent for this long; Voxt also waits for it before muting the output,
// which VoxtNew does not do yet (Audio.MuteOutput, P1).
var audible = map[Sound]time.Duration{
	"Pop":       215 * time.Millisecond,
	"Tink":      45 * time.Millisecond,
	"Ping":      492 * time.Millisecond,
	"Morse":     180 * time.Millisecond,
	"Submarine": 872 * time.Millisecond,
	"Basso":     169 * time.Millisecond,
	"Bottle":    564 * time.Millisecond,
	"Frog":      331 * time.Millisecond,
	"Hero":      861 * time.Millisecond,
	"Purr":      431 * time.Millisecond,
	"Sosumi":    593 * time.Millisecond,
}

// Audible is how long s is heard once it starts (see audible); 0 for a
// sound it does not know.
func (s Sound) Audible() time.Duration { return audible[s] }

// soundVolume is afplay's volume (0–1): cues should not compete with
// the user's own audio.
const soundVolume = "0.5"

// Playing is a sound that plays (Start).
type Playing struct {
	done chan struct{}
	stop func()
}

// Done is closed when the sound ended, or was stopped.
func (p *Playing) Done() <-chan struct{} { return p.done }

// Stop ends the sound now; a sound that ended already is left alone.
func (p *Playing) Stop() {
	if p.stop != nil {
		p.stop()
	}
}

// Start plays s in a process of its own (afplay) and returns once that
// started. Off macOS it plays nothing: Done is closed at once. Callers
// keep it off the main thread: starting a process may take a few
// milliseconds.
func Start(s Sound) (*Playing, error) { return start(s) }

// Play plays s, without waiting for the sound to end.
func Play(s Sound) error {
	_, err := start(s)
	return err
}
