package main

// Settings → Privacy: what leaves this Mac (only what the user's
// providers need), and what VoxtNew keeps here: the history, its
// recordings, the text in the logs (plan §6).

import (
	"context"

	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

func (a *app) privacySettings(c *ui.Context) {
	t := c.Theme()
	sectionTitle(c, i18n.T("What leaves this Mac"))
	ui.Column(c.Key("priv-list")).Gap(px(t, sp1)).Children(func() {
		for _, s := range []string{
			i18n.T("Your recordings and the text to clean up, translate or rewrite go to the speech and language services you set up, and nowhere else. VoxtNew has no server of its own."),
			i18n.T("API keys stay in this Mac's Keychain."),
			i18n.T("The address of the browser tab in front is read only to pick your scene rules. It is never sent to a model; only the app's name is."),
			i18n.T("VoxtNew collects no usage data, crash reports or identifiers."),
		} {
			ui.Text(c, "• "+s).FontSize(px(t, fsCaption)).TextColor(t.TextMuted)
		}
	})

	sectionTitle(c, i18n.T("Kept on this Mac"))
	settingRow(c, "priv-history", i18n.T("Keep a history"), i18n.T("Each transcription, translation and rewrite is saved with its source text, so you can find, copy or redo it."), func() {
		if ui.Switch(c.Key("priv-history"), &a.settingsForm.keepHistory).Label(i18n.T("Save each result")).Changed() {
			on := a.settingsForm.keepHistory
			a.updateSettings(func(s *settings.Settings) {
				s.Privacy.KeepHistory = on
				if !on {
					s.Privacy.KeepAudio = false
				}
			})
		}
	})
	settingRow(c, "priv-audio", i18n.T("Keep the recordings"), i18n.T("Saves the audio with each history entry, to listen again or recognise it once more."), func() {
		if ui.Switch(c.Key("priv-audio"), &a.settingsForm.keepAudio).Label(i18n.T("Save each recording")).Disabled(!a.prefs.Privacy.KeepHistory).Changed() {
			on := a.settingsForm.keepAudio
			a.updateSettings(func(s *settings.Settings) { s.Privacy.KeepAudio = on })
		}
	})
	settingRow(c, "priv-clear", i18n.T("Clear the history"), i18n.T("Deletes every entry and its recording. Your dictionary and settings stay."), func() {
		if ui.Button(c.Key("priv-clear"), i18n.T("Clear…")).Clicked() {
			a.clearHistoryAsk = true
		}
	})

	sectionTitle(c, i18n.T("Logs"))
	settingRow(c, "priv-log-text", i18n.T("Write text to the log"), i18n.T("Off, the log records only lengths and timings of what you said and got back, never the text. Turn it on to report a problem, then off again."), func() {
		if ui.Switch(c.Key("priv-log-text"), &a.settingsForm.logText).Label(i18n.T("Log what was said")).Changed() {
			on := a.settingsForm.logText
			a.updateSettings(func(s *settings.Settings) { s.Privacy.LogText = on })
		}
	})
	a.clearHistoryDialog(c)
}

// clearHistoryDialog confirms Clear the history.
func (a *app) clearHistoryDialog(c *ui.Context) {
	t := c.Theme()
	ui.Modal(c.Key("priv-clear-ask"), &a.clearHistoryAsk, func() {
		ui.Text(c, i18n.T("Clear the history?")).Bold()
		ui.Text(c, i18n.T("Every transcription, translation and rewrite, and their recordings, are deleted. This cannot be undone.")).Width(px(t, 380))
		ui.Row(c).Gap(px(t, sp2)).Justify(ui.End).Children(func() {
			if ui.Button(c.Key("priv-clear-cancel"), i18n.T("Cancel")).AutoFocus().Clicked() {
				a.clearHistoryAsk = false
			}
			if recordButton(c.Key("priv-clear-ok"), i18n.T("Delete the history")).Clicked() {
				a.clearHistoryAsk = false
				a.clearHistory()
			}
		})
	})
}

// clearHistory deletes every history entry, in the background.
func (a *app) clearHistory() {
	h := a.lib.store.History()
	a.async(func() {
		n, err := h.DeleteAll(context.Background(), "")
		a.post(func() {
			if err != nil {
				a.toast(i18n.T("Could not clear the history: %v", err))
				return
			}
			a.toast(i18n.N(n, "Deleted %d entry", "Deleted %d entries", n))
			a.historyChanged() // history_page.go
		})
	})
}
