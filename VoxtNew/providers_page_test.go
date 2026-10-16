package main

import (
	"context"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/providers"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/uitext"
)

// memKeyring is a keyring in memory: the view tests never reach the
// Keychain.
type memKeyring struct {
	mu   sync.Mutex
	m    map[string]string
	fail error
}

func (k *memKeyring) Get(account string) (string, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.m[account], nil
}

func (k *memKeyring) Set(account, label, value string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.fail != nil {
		return k.fail
	}
	if k.m == nil {
		k.m = map[string]string{}
	}
	if value == "" {
		delete(k.m, account)
	} else {
		k.m[account] = value
	}
	return nil
}

func init() { newKeyring = func() keyring { return &memKeyring{} } }

// fakeTests answers connection tests: errs by account, else success.
func fakeTests(t *testing.T, errs map[string]error) *[]string {
	var seen []string
	old := runProviderTest
	runProviderTest = func(ctx context.Context, kind providers.Kind, p settings.Provider, env providers.Env) providers.TestResult {
		acc := providers.Account(kind, p.ID)
		seen = append(seen, acc+"="+env.Key)
		return providers.TestResult{Err: errs[acc], Latency: 321 * time.Millisecond, At: time.Now()}
	}
	t.Cleanup(func() { runProviderTest = old })
	return &seen
}

func TestProvidersPageSetUp(t *testing.T) {
	a, _, tt := newTestApp(t)
	seen := fakeTests(t, nil)
	a.navigate("/providers")
	if !has(tt, "Model services") || !has(tt, "Doubao (Volcengine)") || !has(tt, "No speech service is ready: set one up below to transcribe, translate and rewrite by voice.") {
		t.Fatalf("page: %q", firstTexts(tt))
	}
	if !hasExact(tt, "No services set up") {
		t.Errorf("no card in the sidebar: %q", firstTexts(tt))
	}
	click(t, tt, "Doubao (Volcengine)")
	if !a.provDlg.open || a.provDlg.id != "doubao" || !has(tt, "Your recordings are sent to Doubao (Volcengine) to be recognised.") {
		t.Fatalf("dialog: %+v", a.provDlg)
	}
	// A bad endpoint is refused before anything is saved.
	a.provDlg.endpoint = "https://openspeech.bytedance.com/api/v3/sauc/bigmodel"
	click(t, tt, "Save")
	if !a.provDlg.open || a.provDlg.err == "" || len(a.prefs.Providers.ASR) != 0 {
		t.Fatalf("saved a bad endpoint: %+v", a.provDlg)
	}
	a.provDlg.endpoint, a.provDlg.err = "", ""
	a.provDlg.appID = "4242"
	a.provDlg.key = "tok-1234567890abcd"
	// Test what the form says, before saving.
	click(t, tt, "Test connection")
	if len(*seen) != 1 || (*seen)[0] != "asr.doubao=tok-1234567890abcd" || !has(tt, "Connection OK · 321 ms") {
		t.Fatalf("test: %v %+v", *seen, a.provDlg.test)
	}
	click(t, tt, "Save")
	if a.provDlg.open {
		t.Fatalf("dialog still open: %+v", a.provDlg)
	}
	kr := a.keys.(*memKeyring)
	if kr.m["asr.doubao"] != "tok-1234567890abcd" {
		t.Errorf("keyring %v", kr.m)
	}
	got := a.lib.settings.Get().Providers.ASR
	if len(got) != 1 || got[0].ID != "doubao" || !got[0].Enabled || got[0].AppID != "4242" || got[0].Model != "" {
		t.Errorf("settings %+v", got)
	}
	if strings.Contains(a.lib.settings.Get().Providers.ASR[0].AppID+a.lib.settings.Get().Providers.ASR[0].Prompt, "tok-") {
		t.Error("the key went into the settings")
	}
	if !has(tt, "tok…abcd") || !has(tt, "Set up") {
		t.Errorf("card: %q", firstTexts(tt))
	}
	if !hasExact(tt, "No language model") || hasExact(tt, "No services set up") {
		t.Errorf("card in the sidebar: %q", tt.Texts())
	}
	// The card's test, then a failure.
	fakeTests(t, map[string]error{"asr.doubao": &asr.Error{Kind: asr.KindAuth, Provider: "doubao", Status: 401}})
	click(t, tt, "Test Doubao (Volcengine)")
	if tr := a.provTests["asr.doubao"]; asr.KindOf(tr.res.Err) != asr.KindAuth || !has(tt, "Failed") {
		t.Errorf("card test %+v", tr)
	}
	// Both tests are in the log, without the key.
	var lines []string
	for _, e := range a.logs.Tail(50, "app") {
		lines = append(lines, e.Message)
	}
	all := strings.Join(lines, "\n")
	if !strings.Contains(all, "connection test of speech doubao (model ") || !strings.Contains(all, "failed in 321ms: asr doubao: auth (status 401)") || strings.Contains(all, "tok-1234567890abcd") {
		t.Errorf("log: %s", all)
	}
	// A failure in the dialog shows beside its button.
	click(t, tt, "Doubao (Volcengine)")
	click(t, tt, "Test connection")
	if !has(tt, "Key refused: check the key and App ID") {
		t.Errorf("dialog failure: %q", firstTexts(tt))
	}
}

func TestProvidersPageLLMAndFeatures(t *testing.T) {
	a, _, tt := newTestApp(t)
	fakeTests(t, nil)
	kr := a.keys.(*memKeyring)
	kr.Set("llm.deepseek", "", "sk-deepseek-0001")
	kr.Set("llm.dashscope", "", "sk-dashscope-0002")
	a.updateSettings(func(s *settings.Settings) {
		s.Providers.LLM = []settings.Provider{{ID: "dashscope", Enabled: true}, {ID: "deepseek", Enabled: true}}
	})
	a.openProviders() // reads the masks again
	a.navigate("/providers")
	a.provTab = 1
	if !has(tt, "DeepSeek") || !has(tt, "Qwen (Alibaba Cloud Model Studio)") || !has(tt, "sk-…0001") {
		t.Fatalf("llm tab: %q", firstTexts(tt))
	}
	// Automatic picks the first ready in the cards' order: DeepSeek.
	if !has(tt, "Automatic: DeepSeek") {
		t.Errorf("automatic: %q", tt.Texts())
	}
	a.featSel[1][2] = "Qwen (Alibaba Cloud Model Studio)" // as the select would
	a.updateSettings(func(s *settings.Settings) { setFeatureProvider(s, providers.LLM, providers.Rewrite, "dashscope") })
	frames(tt)
	if a.prefs.Features.Rewrite.LLM != "dashscope" {
		t.Errorf("rewrite LLM %q", a.prefs.Features.Rewrite.LLM)
	}
	r := providers.Routing(a.prefs, a.hasKey)
	if r.Skills["rewrite"][0].Provider != "dashscope" || r.Skills["transcribe_enhance"][0].Provider != "deepseek" {
		t.Errorf("routing %+v", r)
	}
	// Remove a key.
	click(t, tt, "DeepSeek")
	click(t, tt, "Remove the saved key")
	click(t, tt, "Save")
	if _, ok := kr.m["llm.deepseek"]; ok || a.keyMasks["llm.deepseek"] != "" {
		t.Errorf("key kept: %v", kr.m)
	}
	if !has(tt, "No key saved") {
		t.Errorf("card: %q", tt.Texts())
	}
	if p, _ := providers.Choose(a.prefs, providers.LLM, a.prefs.Features.Transcribe.Feature.LLM, a.hasKey); uitext.ProviderName(providers.LLM, p) != "Qwen (Alibaba Cloud Model Studio)" {
		t.Errorf("Transcribe's LLM %q", uitext.ProviderName(providers.LLM, p))
	}
}

func TestProvidersKeychainFailure(t *testing.T) {
	a, _, tt := newTestApp(t)
	a.keys.(*memKeyring).fail = os.ErrPermission
	a.navigate("/providers")
	a.provTab = 1
	click(t, tt, "DeepSeek")
	a.provDlg.key = "sk-1"
	click(t, tt, "Save")
	if !a.provDlg.open || !has(tt, "Could not save the key in the Keychain.") || len(a.prefs.Providers.LLM) != 0 {
		t.Errorf("%+v", a.provDlg)
	}
}

// TestSnapshotsProviders renders the Model services page in its states
// (VOXTNEW_SNAPSHOTS, as TestSnapshots).
func TestSnapshotsProviders(t *testing.T) { runSnapshots(t, "VOXTNEW_SNAPSHOTS", snapshotsProviders) }

func snapshotsProviders(t *testing.T, out string) {
	w, h := snapshotSize()
	for _, run := range []struct {
		lang string
		dark bool
	}{{"en", false}, {"en", true}, {"zh-Hans", false}, {"zh-Hans", true}} {
		a, _, tt := newTestApp(t)
		tt.SetSize(w, h)
		if run.lang != "en" {
			a.updateSettings(func(s *settings.Settings) { s.General.Language = run.lang })
		}
		tt.SetDark(run.dark)
		tt.SetScale(2)
		a.version = "0.1.0"
		suffix := "light"
		if run.dark {
			suffix = "dark"
		}
		if run.lang != "en" {
			suffix += "-" + run.lang
		}
		save := func(name string) {
			t.Helper()
			a.toasts = nil
			frames(tt)
			f, err := os.Create(filepath.Join(out, name+"-"+suffix+".png"))
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			png.Encode(f, tt.Image())
		}
		kr := a.keys.(*memKeyring)
		kr.Set("asr.doubao", "", "tok-1234567890abcd")
		kr.Set("asr.openai", "", "sk-proj-abcdefgh7788")
		kr.Set("llm.deepseek", "", "sk-deepseek-0001")
		a.navigate("/providers")
		save("providers-empty")
		a.updateSettings(func(s *settings.Settings) {
			s.Providers.ASR = []settings.Provider{{ID: "doubao", Enabled: true, AppID: "4242"}, {ID: "openai", Enabled: true, Model: "whisper-1"}, {ID: "aliyun", Enabled: true}}
			s.Providers.LLM = []settings.Provider{{ID: "deepseek", Enabled: true}, {ID: "volcengine", Enabled: false}}
		})
		a.openProviders()
		a.provTests["asr.doubao"] = providerTest{res: providers.TestResult{Latency: 412 * time.Millisecond, At: time.Now()}}
		a.provTests["asr.openai"] = providerTest{res: providers.TestResult{Err: &asr.Error{Kind: asr.KindQuota, Provider: "openai", Status: 429}, At: time.Now()}}
		save("providers-asr")
		a.provTab = 1
		save("providers-llm")
		tt.Scroll(float32(w)*0.6, float32(h)*0.6, 0, 330) // the cards' long names
		save("providers-llm-cards")
		tt.Scroll(float32(w)*0.6, float32(h)*0.6, 0, -330)
		a.provTab = 0
		a.openProviderDialog(providers.ASR, "doubao")
		save("providers-dialog-doubao")
		a.provDlg = providerDialog{}
		a.openProviderDialog(providers.ASR, "openai")
		a.provDlg.prompt = "VoxtNew, DeepSeek, MyGo"
		a.provDlg.test = providerTest{res: providers.TestResult{Err: &asr.Error{Kind: asr.KindAuth, Provider: "openai", Status: 401, Detail: "Incorrect API key provided"}, At: time.Now()}}
		save("providers-dialog-openai")
		a.provDlg = providerDialog{}
		// The test's three states beside its button.
		a.openProviderDialog(providers.ASR, "stepfun")
		a.provDlg.test = providerTest{running: true}
		save("providers-dialog-test-running")
		a.provDlg.test = providerTest{res: providers.TestResult{Latency: 904 * time.Millisecond, At: time.Now()}}
		save("providers-dialog-test-ok")
		a.provDlg.test = providerTest{res: providers.TestResult{Err: &asr.Error{Kind: asr.KindQuota, Provider: "stepfun", Status: 429, Code: "rate_limit_exceeded", Detail: "Rate limit reached for step-asr in organization org-xxx on requests per min: limit 10, used 10"}, At: time.Now()}}
		save("providers-dialog-test-fail")
		a.provDlg = providerDialog{}
		a.provTab = 1
		a.openProviderDialog(providers.LLM, "custom")
		save("providers-dialog-custom")
	}
}
