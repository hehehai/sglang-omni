package main

// A feature page's Services section and Transcribe's clean-up layers
// (feature_page.go).

import (
	"slices"
	"strings"

	"github.com/egoist/mygo/ui"
	"github.com/hehehai/Auralink/internal/hotkey"
	"github.com/hehehai/Auralink/internal/i18n"
	"github.com/hehehai/Auralink/internal/providers"
	"github.com/hehehai/Auralink/internal/settings"
	"github.com/hehehai/Auralink/internal/uitext"
)

// ---- Services ----

func (a *app) featureServices(c *ui.Context, feature string) {
	t := c.Theme()
	p := uitext.FeaturePrefix(feature)
	u := a.fui(feature)
	f := providers.FeatureOf(a.prefs, feature)
	enhance := feature != hotkey.Transcribe || a.prefs.Features.Transcribe.Enhance
	readyA := providers.Ready(a.prefs, providers.ASR, a.hasKey)
	readyL := providers.Ready(a.prefs, providers.LLM, a.hasKey)
	optsA, autoA := serviceOptions(providers.ASR, readyA)
	optsL, autoL := serviceOptions(providers.LLM, readyL)
	seen := strings.Join([]string{f.ASR, f.LLM, strings.Join(optsA, "\x00"), strings.Join(optsL, "\x00")}, "\x01")
	if u.svcSeen != seen {
		u.svcSeen = seen
		u.asr, u.llm = serviceLabel(providers.ASR, readyA, f.ASR, autoA), serviceLabel(providers.LLM, readyL, f.LLM, autoL)
	}
	sectionTitleTip(c, i18n.T("Services"), i18n.T("Automatic uses the first service that is ready, in the order of the Model services page."))
	opened := false // one "Open Model services" per page
	openProviders := func() {
		if opened {
			return
		}
		opened = true
		if ui.Button(c.Key(p+"-open-providers"), i18n.T("Open Model services")).Clicked() {
			a.navigate("/providers")
		}
	}
	if len(readyA) == 0 {
		switch feature {
		case hotkey.Translate:
			notice(c, p+"-no-asr", noticeInfo, i18n.T("No speech service is ready: only selected text can be translated."), "", openProviders, nil)
		case hotkey.Rewrite:
			notice(c, p+"-no-asr", noticeWarn, i18n.T("No speech service is ready: set one up to rewrite."), "", openProviders, nil)
		default:
			notice(c, p+"-no-asr", noticeWarn, i18n.T("No speech service is ready: set one up to transcribe."), "", openProviders, nil)
		}
	}
	if len(readyL) == 0 {
		switch feature {
		case hotkey.Translate:
			notice(c, p+"-no-llm", noticeWarn, i18n.T("No language model is ready: set one up to translate."), "", openProviders, nil)
		case hotkey.Rewrite:
			notice(c, p+"-no-llm", noticeWarn, i18n.T("No language model is ready: set one up to rewrite."), "", openProviders, nil)
		}
	}
	var asrDesc, asrLabel, llmDesc, llmLabel string
	switch feature {
	case hotkey.Translate:
		asrDesc, asrLabel = i18n.T("Turns what you say into text, when nothing is selected."), i18n.T("Speech service for Translate")
		llmDesc, llmLabel = i18n.T("Translates the text."), i18n.T("Language model for Translate")
	case hotkey.Rewrite:
		asrDesc, asrLabel = i18n.T("Turns your spoken instruction into text."), i18n.T("Speech service for Rewrite")
		llmDesc, llmLabel = i18n.T("Rewrites the selection, or writes what you ask for."), i18n.T("Language model for Rewrite")
	default:
		asrDesc, asrLabel = i18n.T("Turns your recording into text."), i18n.T("Speech service for Transcribe")
		llmDesc, llmLabel = i18n.T("Cleans up the recognised text when \"Clean up with a language model\" is on."), i18n.T("Language model for Transcribe")
	}
	settingRow(c, p+"-asr", i18n.T("Speech recognition"), asrDesc, func() {
		sel := ui.Select(c.Key(p+"-asr-sel"), &u.asr, optsA).Label(asrLabel).Width(px(t, 260)).Shrink(1).MinWidth(px(t, 160)).Disabled(len(readyA) == 0)
		if sel.Changed() {
			id := serviceID(optsA, readyA, u.asr)
			a.updateSettings(func(s *settings.Settings) { setFeatureProvider(s, providers.ASR, feature, id) })
		}
	})
	settingRow(c, p+"-llm", i18n.T("Language model"), llmDesc, func() {
		sel := ui.Select(c.Key(p+"-llm-sel"), &u.llm, optsL).Label(llmLabel).Width(px(t, 260)).Shrink(1).MinWidth(px(t, 160)).
			Disabled(len(readyL) == 0 || !enhance)
		if sel.Changed() {
			id := serviceID(optsL, readyL, u.llm)
			a.updateSettings(func(s *settings.Settings) { setFeatureProvider(s, providers.LLM, feature, id) })
		}
	})
	if feature == hotkey.Transcribe && len(readyL) == 0 && enhance {
		notice(c, "tr-no-llm", noticeInfo, i18n.T("No language model is ready: the text is typed as recognised, without clean-up."), "", openProviders, nil)
	}
}

// serviceOptions are a service select's labels: "Automatic: X", then
// the ready services.
func serviceOptions(kind providers.Kind, ready []settings.Provider) (opts []string, auto string) {
	auto = i18n.T("Automatic")
	if len(ready) > 0 {
		auto = i18n.T("Automatic: %s", uitext.ProviderName(kind, ready[0]))
	}
	opts = []string{auto}
	for _, p := range ready {
		opts = append(opts, uitext.ProviderName(kind, p))
	}
	return opts, auto
}

// serviceLabel is the select's label of the service id ("" automatic).
func serviceLabel(kind providers.Kind, ready []settings.Provider, id, auto string) string {
	for _, p := range ready {
		if p.ID == id {
			return uitext.ProviderName(kind, p)
		}
	}
	return auto
}

// serviceID is the id a select's label stands for, "" for automatic.
func serviceID(opts []string, ready []settings.Provider, label string) string {
	if j := slices.Index(opts, label); j > 0 {
		return ready[j-1].ID
	}
	return ""
}

// ---- Clean-up ----

func (a *app) trEnhance(c *ui.Context) {
	sectionTitle(c, i18n.T("Clean-up"))
	f := &a.prefs.Features.Transcribe
	settingRow(c, "tr-enhance", i18n.T("Clean up with a language model"),
		i18n.T("Sends the recognised text to the language model with the rules below, and types its answer. Off, the text is typed as recognised. If the model fails or is slow, the recognised text is typed."), func() {
			if ui.Switch(c.Key("tr-enhance-switch"), &f.Enhance).Label(i18n.T("Clean up with a language model")).Changed() {
				on := f.Enhance
				a.updateSettings(func(s *settings.Settings) { s.Features.Transcribe.Enhance = on })
			}
		})
	settingRow(c, "tr-cleanup", i18n.T("Basic clean-up"),
		i18n.T("Removes fillers (um, uh, you know) and false starts, keeps what you said after correcting yourself, fixes punctuation, spacing and capitals, turns spoken punctuation (\"comma\", \"new line\") into marks, writes numbers and dates the usual way, and keeps names, terms and code as said."), func() {
			if ui.Switch(c.Key("tr-cleanup-switch"), &f.Cleanup).Label(i18n.T("Basic clean-up")).Disabled(!f.Enhance).Changed() {
				on := f.Cleanup
				a.updateSettings(func(s *settings.Settings) { s.Features.Transcribe.Cleanup = on })
			}
		})
	settingRow(c, "tr-structure", i18n.T("Structure"),
		i18n.T("Makes a list when you clearly say steps or several items, and splits a long text into paragraphs. Off, the text keeps the form you said it in."), func() {
			if ui.Switch(c.Key("tr-structure-switch"), &f.Structure).Label(i18n.T("Structure")).Disabled(!f.Enhance).Changed() {
				on := f.Structure
				a.updateSettings(func(s *settings.Settings) { s.Features.Transcribe.Structure = on })
			}
		})
}
