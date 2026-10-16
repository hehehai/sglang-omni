package main

// The Local models page (/models): the few models VoxtNew offers, by
// kind (speech recognition, language models), each a card that says in
// plain words what it is good at and which languages it knows, its size,
// and whether it is installed or downloading, with Download, Cancel and
// Delete.
//
// The models on disk and their downloads are internal/models' (a.models);
// what is installed, as the sessions open it, internal/local's (a.local,
// models_runtimes.go). Views read a.modelStatus, the copy of the
// statuses modelsChanged takes on the main thread, and a.installed
// (memory only). A card in the sidebar says when Transcribe lacks a model
// (checkModels, shell_notices.go).

import (
	"fmt"
	"path/filepath"

	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/hotkey"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/icons"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/local"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/uitext"
)

// modelsPath is the Local models page's path.
const modelsPath = "/models"

// modelsState is the local models and the Local models page's state.
type modelsState struct {
	local  local.Services
	models *models.Manager
	// modelStatus is each catalogue model's status, as modelsChanged
	// last read it.
	modelStatus map[string]models.Status
	// modelAsk is the model whose deletion is being confirmed.
	modelAsk string
}

// openModels reads the models on disk and sets up the local models,
// then the sidebar's card.
func (a *app) openModels() {
	if a.models == nil {
		a.models = models.Open(filepath.Join(a.dataDir(), "models"), managerOptions(func() { a.post(a.modelsChanged) }))
	}
	if a.local == nil {
		a.local = a.withDevLLM(newLocalServices(a)) // llm_link.go: VOXTNEW_DEV_LLM
	}
	a.readModelStatus()
	a.checkModels() // shell_notices.go
}

// readModelStatus copies the statuses (memory only), and says which
// models were installed since the last copy.
func (a *app) readModelStatus() (installed []string) {
	next := map[string]models.Status{}
	for _, m := range models.Catalog() {
		s := a.models.Status(m.ID)
		if s.Installed && a.modelStatus != nil && !a.modelStatus[m.ID].Installed {
			installed = append(installed, m.ID)
		}
		next[m.ID] = s
	}
	a.modelStatus = next
	return installed
}

// modelsChanged takes the models' statuses after a change (a download's
// progress, its end, a deletion).
func (a *app) modelsChanged() {
	before := a.modelStatus
	for _, id := range a.readModelStatus() {
		if m, _ := models.Lookup(id); m.Kind != models.VAD {
			a.toast(i18n.T("%s is installed.", uitext.ModelName(id)))
		}
	}
	for id, s := range a.modelStatus {
		if before[id].Installed != s.Installed {
			a.stReport = nil // Settings → Storage measures again
		}
	}
	a.checkModels()
}

// downloadModel starts downloading model id (and the models it needs).
func (a *app) downloadModel(id string) {
	m := a.models
	a.async(func() {
		m.Download(id) // a failure is the status's
		a.post(a.modelsChanged)
	})
}

// cancelModel stops model id's download.
func (a *app) cancelModel(id string) {
	m := a.models
	a.async(func() { m.Cancel(id) })
}

// deleteModel removes model id from the disk, after its runtime let it
// go (local.Library.Delete).
func (a *app) deleteModel(id string) {
	del := a.models.Delete
	if lib, ok := a.local.(*local.Library); ok {
		del = lib.Delete
	}
	a.async(func() {
		err := del(id)
		a.post(func() {
			if err != nil {
				a.toast(i18n.T("Could not delete the model: %v", err))
			}
			a.modelsChanged()
		})
	})
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
// installed that serves it.
func (a *app) featureModel(kind local.Kind, feature string) (local.Model, bool) {
	f := featureOf(a.prefs, feature)
	want := f.ASR
	if kind == local.LLM {
		want = f.LLM
	}
	return local.Choose(local.ForFeature(a.installed(kind), feature), want)
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
	ui.Scroll(c.Key("models-scroll")).Grow(1).MinHeight(0).Children(func() {
		ui.Column(c).Padding(0, px(t, sp6), px(t, sp6)).Gap(px(t, sp3)).MaxWidth(px(t, 880)).Children(func() {
			caption(c, i18n.T("VoxtNew recognises speech and runs its language models on this Mac: your audio and text never leave it."))
			sectionTitleTip(c, i18n.T("Speech recognition"), i18n.T("Turns what you say into text. Every feature needs one to work by voice."))
			a.modelCards(c, models.ASR)
			sectionTitleTip(c, i18n.T("Language models"), i18n.T("Cleans up, translates and rewrites the text. Without one, Transcribe types the text as recognised."))
			a.modelCards(c, models.LLM)
		})
	})
	a.modelDeleteDialog(c)
}

// modelCards are kind's models of the catalogue.
func (a *app) modelCards(c *ui.Context, kind models.Kind) {
	for _, m := range models.Catalog() {
		if m.Kind == kind {
			a.modelCard(c, m)
		}
	}
}

// modelCard is one model: what it is good at, its languages, its size
// and state, and what can be done with it.
func (a *app) modelCard(c *ui.Context, m models.Model) {
	t := c.Theme()
	k := tok(t)
	st := a.modelStatus[m.ID]
	ic := icons.Soundwave
	if m.Kind == models.LLM {
		ic = icons.ChatRoundLine
	}
	card(c.Key("model-" + m.ID)).Children(func() {
		ui.Row(c).Gap(px(t, sp3)).AlignItems(ui.Start).Children(func() {
			ui.Icon(c, ic.Linear).Size(px(t, 20), px(t, 20)).TextColor(k.Text2).Shrink(0).Margin(px(t, 1), 0, 0, 0)
			ui.Column(c).Grow(1).MinWidth(0).Gap(px(t, sp1)).Children(func() {
				ui.Row(c).Gap(px(t, sp2)).AlignItems(ui.Center).Wrap().Children(func() {
					ui.Text(c, uitext.ModelName(m.ID)).FontWeight(600)
					if m.Default {
						tagChip(c, i18n.T("Default"))
					}
					if st.Installed {
						statusMark(c, icons.CheckCircle, k.Success, i18n.T("Installed"))
					}
				})
				ui.Text(c, uitext.ModelAbout(m.ID))
				if l := uitext.ModelLanguages(m.ID); l != "" {
					ui.Row(c).Gap(px(t, 4)).AlignItems(ui.Center).Children(func() {
						ui.Icon(c, icons.Global.Linear).Size(px(t, 14), px(t, 14)).TextColor(k.Text2).Shrink(0)
						caption(c, l).MinWidth(0)
					})
				}
				caption(c, modelSizeText(m, st))
			})
			ui.Row(c.Key("actions")).Gap(px(t, sp2)).Shrink(0).Children(func() { a.modelActions(c, m, st) })
		})
		if st.Downloading {
			frac := 0.0
			if st.Total > 0 {
				frac = float64(st.Done) / float64(st.Total)
			}
			ui.Progress(c, frac).Label(i18n.T("Downloading %s", uitext.ModelName(m.ID)))
		}
		if st.Err != nil && !st.Downloading {
			msg, more := uitext.DownloadErrorText(st.Err)
			notice(c, "model-err", noticeError, msg, more, func() {
				if ui.Button(c.Key("retry"), i18n.T("Try again")).Clicked() {
					a.downloadModel(m.ID)
				}
			}, nil)
		}
	})
}

// modelSizeText is a model's size, or how much of it came.
func modelSizeText(m models.Model, st models.Status) string {
	size := uitext.HumanBytes(m.Size())
	switch {
	case st.Downloading:
		pct := 0
		if st.Total > 0 {
			pct = int(st.Done * 100 / st.Total)
		}
		return i18n.T("Downloading: %s of %s (%s)", uitext.HumanBytes(st.Done), uitext.HumanBytes(st.Total), fmt.Sprintf("%d%%", pct))
	case st.Installed:
		return i18n.T("%s on disk", size)
	case st.Done > 0:
		return i18n.T("Stopped: %s of %s downloaded", uitext.HumanBytes(st.Done), size)
	}
	return i18n.T("%s download", size)
}

// modelActions are a card's buttons for the model's state.
func (a *app) modelActions(c *ui.Context, m models.Model, st models.Status) {
	name := uitext.ModelName(m.ID)
	switch {
	case st.Downloading:
		if ui.Button(c.Key("cancel"), i18n.T("Cancel")).Label(i18n.T("Cancel downloading %s", name)).Clicked() {
			a.cancelModel(m.ID)
		}
	case st.Installed:
		if ghostButton(c.Key("delete"), i18n.T("Delete")).Label(i18n.T("Delete %s…", name)).Clicked() {
			a.modelAsk = m.ID
		}
	default:
		if st.Done > 0 && ghostButton(c.Key("discard"), i18n.T("Delete")).Label(i18n.T("Delete what was downloaded of %s", name)).Clicked() {
			a.deleteModel(m.ID)
		}
		label := i18n.T("Download")
		if st.Done > 0 {
			label = i18n.T("Resume")
		}
		if st.Err == nil && secondaryIconButton(c.Key("download"), icons.DownloadMinimalistic, label).Label(i18n.T("Download %s", name)).Clicked() { // a failure: the notice's Try again
			a.downloadModel(m.ID)
		}
	}
}

// modelDeleteDialog confirms a model's deletion.
func (a *app) modelDeleteDialog(c *ui.Context) {
	t := c.Theme()
	open := a.modelAsk != ""
	id := a.modelAsk
	ui.Modal(c.Key("model-ask-delete"), &open, func() {
		m, _ := models.Lookup(id)
		ui.Text(c, i18n.T("Delete %s?", uitext.ModelName(id))).Bold()
		ui.Text(c, i18n.T("This frees %s. You can download it again later.", uitext.HumanBytes(m.Size()))).Width(px(t, 380))
		ui.Row(c).Gap(px(t, sp2)).Justify(ui.End).Children(func() {
			if ui.Button(c.Key("model-ask-cancel"), i18n.T("Cancel")).AutoFocus().Clicked() {
				a.modelAsk = ""
			}
			if recordButton(c.Key("model-ask-ok"), i18n.T("Delete")).Label(i18n.T("Delete %s", uitext.ModelName(id))).Clicked() {
				a.modelAsk = ""
				a.deleteModel(id)
			}
		})
	})
	if !open && a.modelAsk != "" {
		a.modelAsk = ""
	}
}
