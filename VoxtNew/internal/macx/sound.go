package macx

// Sound is a macOS system sound: /System/Library/Sounds/<name>.aiff.
type Sound string

// The cues of a recording (Settings → Audio → Sounds): the ones Voxt's
// default ("Soft") preset plays.
const (
	SoundStart Sound = "Pop"  // recording starts
	SoundStop  Sound = "Tink" // recording stops, the text is on its way
)

// soundVolume is afplay's volume (0–1): cues should not compete with
// the user's own audio.
const soundVolume = "0.5"

// Play plays s in a process of its own (afplay) and returns once that
// started, without waiting for the sound to end. Off macOS it does
// nothing. Callers keep it off the main thread: starting a process may
// take a few milliseconds.
func Play(s Sound) error { return play(s) }
