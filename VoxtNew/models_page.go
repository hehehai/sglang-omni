package main

// The Local models page (/models): the speech recognition and language
// models VoxtNew runs on this Mac, and which one each feature uses. M0
// has no local runtime yet: the page says so, with an empty state per
// kind. M1 lists the speech models (internal/local over the Omni native
// servers: download, remove, the one in use), M2 the language models.
//
// What is installed is internal/local's (local.Services); the page and
// every readiness check read it from memory (a.installed). A card in the
// sidebar says when Transcribe lacks a model (checkModels,
// shell_notices.go).

import (
	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/hotkey"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/icons"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/local"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

// modelsPath is the Local models page's path.
const modelsPath = "/models"

// newLocalServices is the local models a new app uses: none before the
// runtimes exist (M1, M2); tests swap in fakes.
var newLocalServices = func() local.Services { return local.NotInstalled{} }

// modelsState is the Local models page's state.
type modelsState struct {
	local local.Services
	// modelTab: 0 speech recognition, 1 language models.
	modelTab int
}

// openModels sets up the local models, then the sidebar's card.
func (a *app) openModels() {
	if a.local == nil {
		a.local = newLocalServices()
	}
	a.checkModels() // shell_notices.go
}

// installed is kind's installed models, the recommended one first
// (memory only).
func (a *app) installed(kind local.Kind) []local.Model {
	if a.local == nil {
		return nil
	}
	return a.local.Installed(kind)
}

// featureModel is the model a feature uses of kind, and whether one is
// installed.
func (a *app) featureModel(kind local.Kind, feature string) (local.Model, bool) {
	f := featureOf(a.prefs, feature)
	want := f.ASR
	if kind == local.LLM {
		want = f.LLM
	}
	return local.Choose(a.installed(kind), want)
}

// featureOf is a feature's part of the settings (hotkey.Transcribe…).
func featureOf(s settings.Settings, feature string) settings.Feature {
	switch feature {
	case hotkey.Translate:
		return s.Features.Translate.Feature
	case hotkey.Rewrite:
		return s.Features.Rewrite.Feature
	}
	return s.Features.Transcribe.Feature
}

// setFeatureModel sets the model of kind a feature uses ("": the first
// installed).
func setFeatureModel(s *settings.Settings, kind local.Kind, feature, id string) {
	f := &s.Features.Transcribe.Feature
	switch feature {
	case hotkey.Translate:
		f = &s.Features.Translate.Feature
	case hotkey.Rewrite:
		f = &s.Features.Rewrite.Feature
	}
	if kind == local.ASR {
		f.ASR = id
	} else {
		f.LLM = id
	}
}

// ---- The page ----

func (a *app) modelsPage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, i18n.T("Local models"), nil)
	kind := local.ASR
	if a.modelTab == 1 {
		kind = local.LLM
	}
	ui.Scroll(c.Key("models-scroll")).Grow(1).MinHeight(0).Children(func() {
		ui.Column(c).Padding(0, px(t, sp6), px(t, sp6)).Gap(px(t, sp4)).MaxWidth(px(t, 880)).Children(func() {
			caption(c, i18n.T("VoxtNew recognises speech and runs its language models on this Mac: your audio and text never leave it."))
			segmentedFit(c.Key("models-tab"), &a.modelTab, i18n.T("Speech recognition"), i18n.T("Language models")).Label(i18n.T("Kind of model"))
			a.modelList(c, kind)
		})
	})
}

// modelList lists kind's installed models, or says there are none yet.
func (a *app) modelList(c *ui.Context, kind local.Kind) {
	t := c.Theme()
	list := a.installed(kind)
	if len(list) == 0 {
		ic, title, body := icons.Soundwave, i18n.T("No speech model installed"),
			i18n.T("Speech models will be downloaded here, to transcribe, translate and rewrite by voice. This version cannot download them yet.")
		if kind == local.LLM {
			ic, title, body = icons.ChatRoundLine, i18n.T("No language model installed"),
				i18n.T("Language models will be downloaded here, to clean up, translate and rewrite text. This version cannot download them yet.")
		}
		card(c.Key("models-empty-" + string(kind))).Children(func() {
			emptyState(c, ic, title, body, nil)
		})
		return
	}
	sectionTitle(c, i18n.T("Installed"))
	card(c.Key("models-list-" + string(kind))).Padding(px(t, sp1)).Gap(0).Children(func() {
		for _, m := range list {
			settingRow(c, "model-"+string(kind)+"-"+m.ID, m.Name, "", func() {})
		}
	})
}
