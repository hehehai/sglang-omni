package main

// The Model services page (/providers, plan §3.1): the speech (ASR) and
// language (LLM) services Auralink sends audio and text to. Two tabs;
// each lists which service each feature uses, then a card per service
// (its state, model, saved key and a connection test). A card opens the
// service's dialog: its key, endpoint, model and, for speech, its
// recognition prompt. A card in the sidebar says when a feature lacks one
// (checkServices, shell_notices.go).
//
// Keys live in the Keychain only (keyring, internal/secrets): the page
// keeps their masks ("sk-…wxyz"), read in the background, never a key.
// What to build and test is internal/providers'.

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/hehehai/Auralink/internal/core"
	"github.com/hehehai/Auralink/internal/i18n"
	"github.com/hehehai/Auralink/internal/icons"
	"github.com/hehehai/Auralink/internal/logs"
	"github.com/hehehai/Auralink/internal/providers"
	"github.com/hehehai/Auralink/internal/secrets"
	"github.com/hehehai/Auralink/internal/settings"
	"github.com/hehehai/Auralink/internal/uitext"
)

// keyring keeps the providers' keys, by Keychain account ("asr.doubao").
// Its calls may block: off the main thread only.
type keyring interface {
	Get(account string) (string, error)
	Set(account, label, value string) error // "" deletes
}

// keychain is the macOS Keychain (internal/secrets).
type keychain struct{}

func (keychain) Get(account string) (string, error) { return secrets.Secret(account, "").Get() }
func (keychain) Set(account, label, value string) error {
	return secrets.Secret(account, label).Set(value)
}

// newKeyring is the keyring a new app uses; tests swap in a memory one.
var newKeyring = func() keyring { return keychain{} }

// providersState is the Model services page's state.
type providersState struct {
	keys keyring
	// provTab: 0 speech, 1 language models.
	provTab int
	// keyMasks are the saved keys' masks by account, "" for none; an
	// account not in it was not read yet.
	keyMasks map[string]string
	// keysKnown: the keys were read once (checkServices waits for it).
	keysKnown bool
	// provTests are the last connection tests, by account.
	provTests map[string]providerTest
	// featSel holds the "used by" selects' labels, featSeen what they
	// were last set from.
	featSel  [2][3]string
	featSeen [2]string
	provDlg  providerDialog
}

// providerTest is a connection test running or done.
type providerTest struct {
	running bool
	res     providers.TestResult
}

// providerDialog is the open service dialog's form.
type providerDialog struct {
	open               bool
	kind               providers.Kind
	id                 string
	exists             bool // the service was set up before
	name, key          string
	endpoint, appID    string
	model, customModel string // model: the select's label
	prompt             string
	enabled            bool
	err, errMore       string // a save or check error
	saving, removeKey  bool
	test               providerTest
}

// openProviders reads the masks of the keys of every service set up.
func (a *app) openProviders() {
	if a.keys == nil {
		a.keys = newKeyring()
	}
	a.keyMasks = map[string]string{}
	a.provTests = map[string]providerTest{}
	var accounts []string
	for _, kind := range []providers.Kind{providers.ASR, providers.LLM} {
		for _, p := range providerList(a.prefs, kind) {
			accounts = append(accounts, providers.Account(kind, p.ID))
		}
	}
	if len(accounts) == 0 {
		a.keysKnown = true
		a.checkServices() // shell_notices.go
		return
	}
	a.loadKeyMasks(accounts)
}

func providerList(s settings.Settings, kind providers.Kind) []settings.Provider {
	if kind == providers.ASR {
		return s.Providers.ASR
	}
	return s.Providers.LLM
}

// loadKeyMasks reads the keys of accounts from the keyring, in the
// background, and keeps their masks.
func (a *app) loadKeyMasks(accounts []string) {
	if len(accounts) == 0 {
		return
	}
	kr := a.keys
	a.async(func() {
		masks := map[string]string{}
		for _, acc := range accounts {
			v, err := kr.Get(acc)
			if err != nil {
				v = ""
			}
			masks[acc] = maskKey(v)
		}
		a.post(func() {
			for k, v := range masks {
				a.keyMasks[k] = v
			}
			a.keysKnown = true
			a.checkServices() // shell_notices.go
		})
	})
}

// hasKey reports whether a key is saved for account (as last read).
func (a *app) hasKey(account string) bool { return a.keyMasks[account] != "" }

// ---- The page ----

func (a *app) providersPage(c *ui.Context) {
	t := c.Theme()
	pageHeader(c, i18n.T("Model services"), func() {
		if ghostIconButton(c.Key("prov-network"), icons.WiFiRouterMinimalistic, i18n.T("Network")).Label(i18n.T("Network settings")).Clicked() {
			a.openSettings("/network")
		}
	})
	kind := providers.ASR
	if a.provTab == 1 {
		kind = providers.LLM
	}
	ui.Scroll(c.Key("prov-scroll")).Grow(1).MinHeight(0).Children(func() {
		ui.Column(c).Padding(0, px(t, sp6), px(t, sp6)).Gap(px(t, sp4)).MaxWidth(px(t, 880)).Children(func() {
			caption(c, i18n.T("Auralink sends your audio and text only to the services you set up here, and has no server of its own. Keys stay in this Mac's Keychain."))
			segmentedFit(c.Key("prov-tab"), &a.provTab, i18n.T("Speech recognition"), i18n.T("Language models")).Label(i18n.T("Kind of service"))
			a.providerUse(c, kind)
			a.providerCards(c, kind)
		})
	})
}

// providerUse is the "used by" section: which service each feature uses.
func (a *app) providerUse(c *ui.Context, kind providers.Kind) {
	t := c.Theme()
	ready := providers.Ready(a.prefs, kind, a.hasKey)
	ti := 0
	if kind == providers.LLM {
		ti = 1
	}
	auto := i18n.T("Automatic")
	if len(ready) > 0 {
		auto = i18n.T("Automatic: %s", uitext.ProviderName(kind, ready[0]))
	}
	opts := []string{auto}
	for _, p := range ready {
		opts = append(opts, uitext.ProviderName(kind, p))
	}
	feats := []struct{ id, title, info string }{
		{providers.Transcribe, i18n.T("Transcribe"), ""},
		{providers.Translate, i18n.T("Translate"), ""},
		{providers.Rewrite, i18n.T("Rewrite"), ""},
	}
	// Set the selects from the settings when they (or the choices) change.
	var wants [3]string
	for i, f := range feats {
		ff := providers.FeatureOf(a.prefs, f.id)
		wants[i] = ff.ASR
		if kind == providers.LLM {
			wants[i] = ff.LLM
		}
	}
	seen := strings.Join(wants[:], "\x00") + "\x01" + strings.Join(opts, "\x00")
	if a.featSeen[ti] != seen {
		a.featSeen[ti] = seen
		for i := range feats {
			a.featSel[ti][i] = auto
			for _, p := range ready {
				if p.ID == wants[i] {
					a.featSel[ti][i] = uitext.ProviderName(kind, p)
				}
			}
		}
	}
	tip := i18n.T("Automatic uses the first service that is ready, in the order of the cards below.")
	sectionTitleTip(c, i18n.T("Used by"), tip)
	if len(ready) == 0 {
		notice(c, "prov-none-"+string(kind), noticeWarn, noneReadyText(kind), "", nil, nil)
		return
	}
	for i, f := range feats {
		settingRow(c, "prov-use-"+string(kind)+"-"+f.id, f.title, f.info, func() {
			sel := ui.Select(c.Key("prov-use-select-"+string(kind)+"-"+f.id), &a.featSel[ti][i], opts).Label(i18n.T("Service for %s", f.title)).Width(px(t, 300))
			if sel.Changed() {
				id := ""
				if j := slices.Index(opts, a.featSel[ti][i]); j > 0 {
					id = ready[j-1].ID
				}
				a.updateSettings(func(s *settings.Settings) { setFeatureProvider(s, kind, f.id, id) })
			}
		})
	}
}

func noneReadyText(kind providers.Kind) string {
	if kind == providers.ASR {
		return i18n.T("No speech service is ready: set one up below to transcribe, translate and rewrite by voice.")
	}
	return i18n.T("No language model is ready: set one up below to clean up, translate and rewrite text.")
}

// setFeatureProvider sets a feature's service of kind.
func setFeatureProvider(s *settings.Settings, kind providers.Kind, feature, id string) {
	f := &s.Features.Transcribe.Feature
	switch feature {
	case providers.Translate:
		f = &s.Features.Translate.Feature
	case providers.Rewrite:
		f = &s.Features.Rewrite.Feature
	}
	if kind == providers.ASR {
		f.ASR = id
	} else {
		f.LLM = id
	}
}

// providerCards lists kind's services: those set up first, then the rest.
func (a *app) providerCards(c *ui.Context, kind providers.Kind) {
	t := c.Theme()
	var mine, rest []providers.Preset
	for _, pr := range providers.Presets(kind) {
		if _, ok := providers.Setup(a.prefs, kind, pr.ID); ok {
			mine = append(mine, pr)
		} else {
			rest = append(rest, pr)
		}
	}
	room := min(a.pageWidth(c), px(t, 880)) - px(t, 2*sp6) - 1 // the column's padding
	// Cards at least 260 wide (as the setup guide's): two columns in the
	// default window (800 wide) and the smallest; long names ("Qwen
	// (Model Studio international)") keep to two lines.
	cols := max(1, int((room+px(t, sp3))/(px(t, 260)+px(t, sp3))))
	cardW := (room - px(t, sp3)*float32(cols-1)) / float32(cols)
	grid := func(key string, list []providers.Preset) {
		ui.Row(c.Key(key)).Wrap().Gap(px(t, sp3)).AlignItems(ui.Start).Children(func() {
			for _, pr := range list {
				a.providerCard(c, kind, pr, cardW)
			}
		})
	}
	if len(mine) > 0 {
		sectionTitle(c, i18n.T("Set up"))
		grid("prov-mine-"+string(kind), mine)
	}
	if len(rest) > 0 {
		title := i18n.T("Available")
		if len(mine) == 0 {
			title = i18n.T("Services")
		}
		sectionTitle(c, title)
		grid("prov-rest-"+string(kind), rest)
	}
}

// providerState is a card's state line: its dot's colour and text.
func (a *app) providerState(c *ui.Context, kind providers.Kind, p settings.Provider, configured bool) (ui.Color, string) {
	t := c.Theme()
	k := tok(t)
	acc := providers.Account(kind, p.ID)
	switch providers.Missing(kind, p, configured, a.hasKey(acc)) {
	case providers.MissingSetup:
		return k.G[5], i18n.T("Not set up")
	case providers.MissingOff:
		return k.G[5], i18n.T("Off")
	case providers.MissingKey:
		return k.Warning, i18n.T("No key saved")
	case providers.MissingEndpoint:
		return k.Warning, i18n.T("No endpoint")
	}
	if tr, ok := a.provTests[acc]; ok && !tr.running && tr.res.Err != nil {
		return k.Danger, i18n.T("Test failed")
	}
	return k.Success, i18n.T("Ready")
}

// providerCard is a service's card: its state dot, name and model; once
// set up, its key's mask, its last test and a Test button. A click opens
// its dialog.
func (a *app) providerCard(c *ui.Context, kind providers.Kind, pr providers.Preset, w float32) {
	t := c.Theme()
	k := tok(t)
	p, configured := providers.Setup(a.prefs, kind, pr.ID)
	name := uitext.ProviderName(kind, p)
	acc := providers.Account(kind, p.ID)
	dot, state := a.providerState(c, kind, p, configured)
	missing := providers.Missing(kind, p, configured, a.hasKey(acc))
	b := ui.ButtonBase(c.Key("prov-card-"+acc)).Width(w).Padding(px(t, sp3), px(t, sp4)).Radius(px(t, radiusCard)).Border(1, k.Line).
		Label(name).Tooltip(i18n.T("Set up %s", name)).AlignItems(ui.Stretch).Shrink(0)
	if b.Hovered() {
		b.Background(k.Subtle)
	}
	b.Children(func() {
		ui.Column(c).Gap(px(t, 6)).Grow(1).MinWidth(0).Children(func() {
			// A long name takes two lines; the dot and the chip stay on the first.
			ui.Row(c).Gap(px(t, sp2)).AlignItems(ui.Start).MinHeight(px(t, 22)).Children(func() {
				ui.Row(c).Height(px(t, 22)).AlignItems(ui.Center).Shrink(0).Children(func() { statusDot(c, dot) })
				ui.Text(c, name).FontWeight(600).Grow(1).MinWidth(0).MaxLines(2).Ellipsis("…").Margin(px(t, 2), 0, 0, 0)
				if kind == providers.ASR {
					ui.Row(c).Height(px(t, 22)).AlignItems(ui.Center).Shrink(0).Children(func() { tagChip(c, uitext.ModeLabel(pr)) })
				}
			})
			model := providers.Model(kind, p)
			if model == "" {
				model = i18n.T("Model not chosen")
			}
			truncText(c, model).FontSize(px(t, fsCaption)).TextColor(k.Text2)
			if !configured {
				return // the rest shows once it is set up
			}
			ui.Row(c).Gap(px(t, sp1)).AlignItems(ui.Center).Height(px(t, 30)).Children(func() {
				mask, read := a.keyMasks[acc]
				keyText, keyCol := mask, k.Text2
				switch {
				case mask == "" && !read:
					keyText = "…"
				case mask == "" && missing == providers.MissingKey:
					keyText, keyCol = state, k.Warning
				case mask == "":
					keyText, keyCol = i18n.T("No key"), k.Text3
				}
				ui.Icon(c, icons.KeyMinimalisticSquare.Linear).Size(px(t, 14), px(t, 14)).TextColor(keyCol).Shrink(0)
				ui.Text(c, keyText).FontSize(px(t, fsCaption)).TextColor(keyCol).SingleLine().Ellipsis("…").MinWidth(0).Grow(1)
				switch missing {
				case "":
					a.testMark(c, acc)
					tr := a.provTests[acc]
					if ghostButton(c.Key("prov-test-"+acc), i18n.T("Test")).Label(i18n.T("Test %s", name)).Disabled(tr.running).Clicked() {
						a.testProvider(kind, p)
					}
				case providers.MissingKey:
				default:
					ui.Text(c, state).FontSize(px(t, fsCaption)).TextColor(k.Text3).SingleLine().Shrink(0)
				}
			})
		})
	})
	if b.Clicked() {
		a.openProviderDialog(kind, pr.ID)
	}
}

// testMark is a ready card's test state: a spinner while it runs, its
// result once done (as the dialog's, shorter).
func (a *app) testMark(c *ui.Context, acc string) {
	if tr, ok := a.provTests[acc]; ok {
		testStatus(c, tr, false)
	}
}

// testProvider runs a connection test of a saved setup.
func (a *app) testProvider(kind providers.Kind, p settings.Provider) {
	acc := providers.Account(kind, p.ID)
	a.provTests[acc] = providerTest{running: true}
	kr, proxy, logs := a.keys, a.prefs.Network.Proxy, a.logs
	a.async(func() {
		key, err := kr.Get(acc)
		res := providers.TestResult{Err: err, At: time.Now()}
		if err == nil {
			res = runProviderTest(context.Background(), kind, p, providers.Env{Key: key, Proxy: proxy})
		}
		logTest(logs, kind, p, res, key)
		a.post(func() { a.provTests[acc] = providerTest{res: res} })
	})
}

// logTest writes a connection test's outcome to the app log (any
// goroutine): the service, model, time and error, never the key.
func logTest(r *logs.Ring, kind providers.Kind, p settings.Provider, res providers.TestResult, key string) {
	if r == nil {
		return
	}
	level, msg := providers.TestLog(kind, p, res, key)
	r.Append(core.LogEntry{Time: time.Now(), Level: core.Severity(level), Source: "app", Message: msg})
}

// runProviderTest is providers.Test; tests swap it for a fake.
var runProviderTest = providers.Test

func maskKey(v string) string {
	if v == "" {
		return ""
	}
	if demoMask != nil {
		return demoMask(v)
	}
	return secrets.Mask(v)
}
