package main

// Settings → Audio → Play sounds (settings_audio.go): whether a recording
// plays its cues, which pair (settings.Audio.SoundPreset: Voxt's presets,
// macx.Presets) and trying them. While the switch is on, a menu of the
// presets and a Try button stand left of it, as in Voxt's row. Choosing a
// preset plays its start sound, and so does an option the pointer or the
// arrows rest on for a moment while the menu is open (Voxt's menu plays
// nothing). A preview cuts the one before it short; the Try button shows
// the accent while it is heard. The cues of a recording are playCue's
// (settings_audio.go). Ported from Auralink (10-17).

import (
	"sync"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/icons"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

// soundsState is the previews of Settings → Audio → Play sounds.
type soundsState struct {
	sounds struct {
		previewing bool // the Try button's accent
		seq        int  // numbers the previews: a preview's timer ends only its own
		// hl is the option highlighted in the open menu ("" while it is
		// closed); hlSeq numbers its changes, so that a rest's timer plays
		// only the option still highlighted.
		hl    string
		hlSeq int
	}
	// startSound starts a sound and returns what stops it (macx.Start,
	// on a goroutine); tests record the sounds instead.
	startSound func(macx.Sound) (stop func())
	sndPlayer  previewPlayer
}

// Times of the previews.
const (
	// cueMargin follows a sound's audible part: afplay's start and
	// Voxt's 80 ms after it.
	cueMargin = 150 * time.Millisecond
	// previewMin is the least the Try button shows the accent (Voxt's).
	previewMin = 650 * time.Millisecond
	// soundRest is how long an option of the open menu is highlighted
	// before it plays: the pointer passing over options plays none.
	soundRest = 300 * time.Millisecond
)

// startPreview is macx.Start for previews: what stops the sound (nothing
// when it could not start).
func startPreview(s macx.Sound) func() {
	p, err := macx.Start(s)
	if err != nil {
		return nil
	}
	return p.Stop
}

// previewPlayer plays one preview at a time, off the main thread: a new
// one stops the one before; one that comes after a newer one (goroutines
// run in any order) is dropped.
type previewPlayer struct {
	mu   sync.Mutex
	seq  int
	stop func()
}

func (p *previewPlayer) play(seq int, s macx.Sound, start func(macx.Sound) func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if seq <= p.seq {
		return
	}
	p.seq = seq
	if p.stop != nil {
		p.stop()
		p.stop = nil
	}
	if start != nil {
		p.stop = start(s)
	}
}

// trySound plays preset's start sound, as Voxt's Try button does (the
// stop sound is the same one but for Soft, whose name says both), and
// shows the accent on the button meanwhile. It has nothing to do with a
// session: one that records goes on.
func (a *app) trySound(preset string) {
	s := macx.PresetFor(preset).Start
	a.sounds.seq++
	seq := a.sounds.seq
	a.sounds.previewing = true
	start, player := a.startSound, &a.sndPlayer
	a.async(func() { player.play(seq, s, start) })
	a.later(max(s.Audible()+cueMargin, previewMin), func() {
		if a.sounds.seq == seq {
			a.sounds.previewing = false
		}
	})
}

// soundHighlighted follows the open menu's highlight (h, "" while it is
// closed): the option it rests on plays after soundRest. The selected
// option, highlighted as the menu opens, does not.
func (a *app) soundHighlighted(h string) {
	was := a.sounds.hl
	if h == was {
		return
	}
	a.sounds.hl = h
	a.sounds.hlSeq++
	if was == "" || h == "" {
		return
	}
	seq := a.sounds.hlSeq
	a.later(soundRest, func() {
		if a.sounds.hlSeq == seq && a.sounds.hl == h && a.settingsOpen && a.setRouter.Path() == "/audio" {
			a.trySound(h)
		}
	})
}

// presetLabel is a preset's name in the menu: macOS's names of its
// sounds, untranslated as in System Settings, but for Soft.
func presetLabel(p macx.Preset) string {
	if p.ID == macx.DefaultPreset {
		return i18n.T("Soft (Pop/Tink)")
	}
	return string(p.Start)
}

// soundsRow is the Play sounds row: the menu and Try while it is on.
func (a *app) soundsRow(c *ui.Context) {
	t := c.Theme()
	settingRow(c, "audio-sounds", i18n.T("Play sounds"), i18n.T("A short sound when recording starts, and another when it stops. Choosing a sound plays it, as does resting on one in the menu."), func() {
		if a.settingsForm.sounds {
			ui.Row(c.Key("audio-sounds-pick")).Gap(px(t, sp1)).AlignItems(ui.Center).Children(func() {
				if a.soundSelect(c) {
					id := a.settingsForm.soundPreset
					a.updateSettings(func(s *settings.Settings) { s.Audio.SoundPreset = id })
					a.trySound(id)
				}
				if a.tryButton(c.Key("audio-sounds-try")).Clicked() {
					a.trySound(a.prefs.Audio.SoundPreset)
				}
			})
		} else {
			a.soundHighlighted("")
		}
		if ui.Switch(c.Key("audio-sounds-switch"), &a.settingsForm.sounds).Label(i18n.T("Play sounds")).Changed() {
			on := a.settingsForm.sounds
			a.updateSettings(func(s *settings.Settings) { s.Audio.Sounds = on })
		}
	})
}

// soundSelect is the menu of presets: ui.Select's look over SelectBase,
// whose options say when they are highlighted (soundHighlighted). It
// reports a new choice, in settingsForm.soundPreset.
func (a *app) soundSelect(c *ui.Context) bool {
	t := c.Theme()
	sel := ui.SelectBase(c.Key("audio-sounds-select"), &a.settingsForm.soundPreset)
	b := sel.Trigger
	b.Label(i18n.T("Sound preset")).Width(px(t, 176)).Padding(t.Space(1.5), t.Space(3.5)).Gap(t.Space(1.5)).Radius(t.Radius).
		Justify(ui.SpaceBetween).Border(1, t.Border).TextColor(t.Text)
	switch {
	case b.Pressed():
		b.Background(t.SurfacePressed)
	case b.Hovered():
		b.Background(t.SurfaceHover)
	default:
		b.Background(t.Surface)
	}
	presets := macx.Presets()
	b.Children(func() {
		ui.Text(c, presetLabel(macx.PresetFor(a.settingsForm.soundPreset))).SingleLine().Ellipsis("…").MinWidth(0)
		selectChevron(c)
	})
	h := ""
	sel.Popup(func(panel ui.Element) {
		panel.Margin(t.Space(1), 0, 0, 0).Padding(t.Space(1)).Radius(t.Radius+2).Background(t.Background).Border(1, t.Border).
			Shadow(0, 6, 20, 0, ui.RGBA(0, 0, 0, 0.18))
		ui.Scroll(c).MaxHeight(t.Space(80)).Children(func() {
			ui.Column(c).Children(func() {
				for _, p := range presets {
					item := sel.Item(p.ID).Padding(t.Space(1.5), t.Space(2.5)).Radius(t.Radius)
					switch {
					case item.Highlighted():
						item.Background(t.Accent).TextColor(t.AccentText)
						h = p.ID
					case p.ID == a.settingsForm.soundPreset:
						item.Background(t.Surface)
					}
					item.Children(func() { ui.Text(c, presetLabel(p)).SingleLine() })
				}
			})
		})
	})
	a.soundHighlighted(h)
	return b.Changed()
}

// selectChevron is the arrow of ui.Select's trigger.
func selectChevron(c *ui.Context) {
	t := c.Theme()
	ui.Box(c).Size(t.Space(2.5), t.Space(2.5)).Shrink(0).Draw(func(p *ui.Painter, r ui.Rect) {
		var path ui.Path
		path.MoveTo(r.X+r.W*0.1, r.Y+r.H*0.3).LineTo(r.X+r.W*0.5, r.Y+r.H*0.7).LineTo(r.X+r.W*0.9, r.Y+r.H*0.3)
		p.StrokePath(&path, 1.5, t.TextMuted)
	})
}

// tryButton is Try sound: iconButton's face, its note in the accent while
// a preview plays.
func (a *app) tryButton(c *ui.Context) ui.Element {
	t := c.Theme()
	k := tok(t)
	tip := i18n.T("Try sound")
	b := ghostBase(c).Size(px(t, 28), px(t, 28)).Center().Label(tip).Tooltip(tip).Shrink(0)
	b.Children(func() {
		col := k.Text2
		switch {
		case a.sounds.previewing:
			col = k.Accent
		case b.Hovered():
			col = k.Text
		}
		ui.Icon(c, icons.MusicNote.Linear).Size(px(t, 16), px(t, 16)).TextColor(col)
	})
	return b
}
