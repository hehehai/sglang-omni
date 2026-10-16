package main

// The Model services page's dialog (providers_page.go): a service's key,
// address and model, with a connection test before saving.

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/icons"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/providers"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/uitext"
)

// ---- The dialog ----

func (a *app) openProviderDialog(kind providers.Kind, id string) {
	pr, _ := providers.LookupPreset(kind, id)
	p, exists := providers.Setup(a.prefs, kind, id)
	d := providerDialog{open: true, kind: kind, id: id, exists: exists, enabled: !exists || p.Enabled,
		name: p.Name, endpoint: p.Endpoint, appID: p.AppID, prompt: p.Prompt}
	model := p.Model
	if model == "" {
		model = pr.Model
	}
	d.model = model
	if model != "" && !slices.Contains(pr.Models, model) {
		d.model, d.customModel = i18n.T("Other model…"), model
	}
	if model == "" {
		d.model = i18n.T("Other model…")
	}
	a.provDlg = d
	acc := providers.Account(kind, id)
	if _, read := a.keyMasks[acc]; !read {
		a.loadKeyMasks([]string{acc})
	}
}

// dialogSetup is the setup the dialog's form describes.
func (d *providerDialog) setup() settings.Provider {
	pr, _ := providers.LookupPreset(d.kind, d.id)
	p := settings.Provider{ID: d.id, Enabled: d.enabled, Endpoint: strings.TrimSpace(d.endpoint), AppID: strings.TrimSpace(d.appID), Prompt: strings.TrimSpace(d.prompt)}
	if pr.Custom {
		p.Name = strings.TrimSpace(d.name)
	}
	model := d.model
	if model == i18n.T("Other model…") {
		model = strings.TrimSpace(d.customModel)
	}
	if model != pr.Model {
		p.Model = model
	}
	return p
}

func (a *app) providerDialogView(c *ui.Context) {
	d := &a.provDlg
	if !d.open {
		return
	}
	t := c.Theme()
	pr, _ := providers.LookupPreset(d.kind, d.id)
	acc := providers.Account(d.kind, d.id)
	name := uitext.PresetName(pr)
	sub := i18n.T("Speech recognition · %s", uitext.ModeLabel(pr))
	if d.kind == providers.LLM {
		sub = i18n.T("Language model · %s", uitext.ModeLabel(pr))
	}
	dialogFrame(c, "prov-dialog", &d.open, name, sub, 560, func() {
		ui.Row(c).Gap(px(t, sp2)).AlignItems(ui.Center).Wrap().Children(func() {
			what := i18n.T("Your recordings are sent to %s to be recognised.", name)
			switch {
			case d.kind == providers.ASR && pr.Mode == providers.ModeFile && pr.ID != providers.StepFunASR:
				what = i18n.T("Your recordings are sent to the service at the endpoint below to be recognised.")
			case d.kind == providers.LLM && pr.Custom:
				what = i18n.T("Recognised and selected text is sent to the service at the endpoint below.")
			case d.kind == providers.LLM:
				what = i18n.T("Recognised and selected text is sent to %s.", name)
			}
			caption(c, what).Grow(1).Basis(px(t, 240))
			if pr.KeyURL != "" {
				ui.Link(c.Key("prov-keyurl"), i18n.T("Get a key"), pr.KeyURL).FontSize(px(t, fsCaption))
			}
		})
		settingRow(c, "prov-enabled", i18n.T("Use this service"), i18n.T("Off, the features skip it but keep its setup and key."), func() {
			ui.Switch(c.Key("prov-enabled-switch"), &d.enabled).Label(i18n.T("Use this service"))
		})
		if pr.Custom {
			fieldInfo(c, i18n.T("Name"), "", func() {
				ui.TextInput(c.Key("prov-name"), &d.name).Placeholder(name).Label(i18n.T("Name"))
			})
		}
		if pr.AppID {
			fieldInfo(c, i18n.T("App ID"), i18n.T("From the app in the Volcengine speech console, with its Access Token below. A key of the newer console needs no App ID."), func() {
				ui.TextInput(c.Key("prov-appid"), &d.appID).Placeholder(i18n.T("Optional")).Label(i18n.T("App ID"))
			})
		}
		mask := a.keyMasks[acc]
		fieldInfo(c, uitext.KeyLabel(d.kind, d.id), i18n.T("Saved in this Mac's Keychain, never in VoxtNew's settings or logs."), func() {
			ui.Row(c).Gap(px(t, sp2)).AlignItems(ui.Center).Children(func() {
				ph := i18n.T("Paste the key")
				if mask != "" && !d.removeKey {
					ph = i18n.T("Saved: %s · paste a new one to replace it", mask)
				}
				ui.TextInput(c.Key("prov-key"), &d.key).Password().Placeholder(ph).Label(uitext.KeyLabel(d.kind, d.id)).Grow(1).MinWidth(0)
				if mask != "" && !d.removeKey && ghostButton(c.Key("prov-key-remove"), i18n.T("Remove")).Label(i18n.T("Remove the saved key")).Clicked() {
					d.removeKey, d.key = true, ""
				}
			})
			if d.removeKey {
				caption(c, i18n.T("The saved key is removed when you save."))
			}
		})
		epInfo := i18n.T("Leave empty for the service's own. Only https:// (wss:// for streaming) addresses, or http:// to this Mac.")
		if d.kind == providers.ASR && pr.Mode == providers.ModeFile && pr.ID != providers.StepFunASR {
			epInfo = i18n.T("Any OpenAI-compatible transcription address (Groq, SiliconFlow…), or its API root ending in /v1. Only https://, or http:// to this Mac.")
		}
		fieldInfo(c, i18n.T("Endpoint"), epInfo, func() {
			ph := pr.Endpoint
			if ph == "" {
				ph = "https://…/v1"
			}
			ui.TextInput(c.Key("prov-endpoint"), &d.endpoint).Placeholder(ph).Label(i18n.T("Endpoint"))
		})
		fieldInfo(c, i18n.T("Model"), "", func() {
			opts := append(slices.Clone(pr.Models), i18n.T("Other model…"))
			if !slices.Contains(opts, d.model) {
				opts = append([]string{d.model}, opts...)
			}
			ui.Select(c.Key("prov-model"), &d.model, opts).Label(i18n.T("Model")).Width(px(t, 320))
			if d.model == i18n.T("Other model…") {
				ui.TextInput(c.Key("prov-model-custom"), &d.customModel).Placeholder(i18n.T("Model id")).Label(i18n.T("Model id"))
			}
		})
		if pr.Prompt {
			fieldInfo(c, i18n.T("Recognition prompt"), i18n.T("Words about what you say (topics, names, how to spell them) that help recognition. Your dictionary's terms are added to it."), func() {
				ui.TextArea(c.Key("prov-prompt"), &d.prompt).Placeholder(i18n.T("Optional")).Label(i18n.T("Recognition prompt")).MinHeight(px(t, 64))
			})
		}
		if d.err != "" {
			notice(c, "prov-dlg-err", noticeError, d.err, d.errMore, nil, func() { d.err, d.errMore = "", "" })
		}
	}, func() {
		if ui.Button(c.Key("prov-dlg-test"), i18n.T("Test connection")).Disabled(d.test.running || d.saving).Shrink(0).Clicked() {
			a.testDialog()
		}
		// The test's state, beside its button; a long reason is cut, its
		// ⓘ tells the whole of it.
		ui.Row(c.Key("prov-dlg-status")).Gap(px(t, sp1)).AlignItems(ui.Center).Grow(1).Shrink(1).Basis(0).MinWidth(0).Children(func() {
			testStatus(c, d.test, true)
		})
		if ghostButton(c.Key("prov-dlg-cancel"), i18n.T("Cancel")).Shrink(0).Clicked() {
			d.open = false
		}
		if primaryButton(c.Key("prov-dlg-save"), i18n.T("Save")).Disabled(d.saving).Shrink(0).Clicked() {
			a.saveProviderDialog()
		}
	})
}

// testStatus is a connection test's state: a spinner while it runs, a
// green tick and its time once it works, a red mark and a short reason
// when it failed, with the long one and what the service said in a
// tooltip (and an ⓘ, when long is set: the dialog's).
func testStatus(c *ui.Context, tr providerTest, long bool) {
	t := c.Theme()
	k := tok(t)
	switch {
	case tr.running:
		ui.Spinner(c).Size(px(t, 14), px(t, 14)).Shrink(0)
		if long {
			caption(c, i18n.T("Testing…")).SingleLine().Ellipsis("…").MinWidth(0)
		}
	case tr.res.At.IsZero() && tr.res.Err == nil && tr.res.Latency == 0:
	case tr.res.Err == nil:
		text := i18n.T("%d ms", tr.res.Latency.Milliseconds())
		if long {
			text = i18n.T("Connection OK · %d ms", tr.res.Latency.Milliseconds())
		}
		statusMark(c, icons.CheckCircle, k.Success, text).Shrink(1).Tooltip(text)
	default:
		short := uitext.ProviderErrorShort(tr.res.Err)
		msg, _ := uitext.ProviderErrorText(tr.res.Err)
		tip := msg + "\n\n" + uitext.ProviderErrorDetail(tr.res.Err)
		if !long {
			statusMark(c, icons.CloseCircle, k.Danger, i18n.T("Failed")).Shrink(0).Tooltip(short + "\n" + tip)
			return
		}
		statusMark(c, icons.CloseCircle, k.Danger, short).Shrink(1).Tooltip(tip)
		infoTip(c, tip).Shrink(0)
	}
}

// dialogKey is the key the dialog's test uses: the one typed, else the
// saved one (read in the background), none when it is to be removed.
func (a *app) dialogKey(acc string) func() (string, error) {
	typed, remove, kr := strings.TrimSpace(a.provDlg.key), a.provDlg.removeKey, a.keys
	return func() (string, error) {
		switch {
		case typed != "":
			return typed, nil
		case remove:
			return "", nil
		}
		return kr.Get(acc)
	}
}

// testDialog tests what the dialog's form describes, saved or not.
func (a *app) testDialog() {
	d := &a.provDlg
	kind, p := d.kind, d.setup()
	p.Enabled = true
	if err := providers.CheckEndpoint(kind, p); err != nil {
		d.err, d.test = "", providerTest{res: providers.TestResult{Err: err, At: time.Now()}}
		return
	}
	d.err, d.test = "", providerTest{running: true}
	key, proxy, id, logs := a.dialogKey(providers.Account(kind, p.ID)), a.prefs.Network.Proxy, d.id, a.logs
	a.async(func() {
		k, err := key()
		res := providers.TestResult{Err: err, At: time.Now()}
		if err == nil {
			res = runProviderTest(context.Background(), kind, p, providers.Env{Key: k, Proxy: proxy})
		}
		logTest(logs, kind, p, res, k)
		a.post(func() {
			if a.provDlg.open && a.provDlg.id == id && a.provDlg.kind == kind {
				a.provDlg.test = providerTest{res: res}
			}
			a.provTests[providers.Account(kind, p.ID)] = providerTest{res: res}
		})
	})
}

// saveProviderDialog checks the form, saves the key (when one was typed
// or removed) and then the setup.
func (a *app) saveProviderDialog() {
	d := &a.provDlg
	kind, p := d.kind, d.setup()
	if err := providers.CheckEndpoint(kind, p); err != nil {
		d.err, d.errMore = uitext.ProviderErrorText(err)
		return
	}
	acc := providers.Account(kind, p.ID)
	key, remove := strings.TrimSpace(d.key), d.removeKey
	label := "VoxtNew " + uitext.ProviderName(kind, p)
	d.saving, d.err = true, ""
	kr := a.keys
	a.async(func() {
		var err error
		switch {
		case key != "":
			err = kr.Set(acc, label, key)
		case remove:
			err = kr.Set(acc, label, "")
		}
		a.post(func() {
			a.provDlg.saving = false
			if err != nil {
				a.provDlg.err, a.provDlg.errMore = i18n.T("Could not save the key in the Keychain."), err.Error()
				return
			}
			switch {
			case key != "":
				a.keyMasks[acc] = maskKey(key)
			case remove:
				a.keyMasks[acc] = ""
			}
			delete(a.provTests, acc)
			a.updateSettings(func(s *settings.Settings) { providers.Put(s, kind, p) })
			a.checkServices()
			a.provDlg = providerDialog{}
			a.toast(i18n.T("%s saved", uitext.ProviderName(kind, p)))
		})
	})
}
