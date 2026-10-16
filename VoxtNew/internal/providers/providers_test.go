package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/aliyun"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/asrtest"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/doubao"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/openai"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

func keys(accounts ...string) func(string) bool {
	return func(a string) bool {
		for _, x := range accounts {
			if x == a {
				return true
			}
		}
		return false
	}
}

func TestPresets(t *testing.T) {
	var ids []string
	for _, p := range Presets(ASR) {
		ids = append(ids, p.ID)
		if p.Kind != ASR || p.Name == "" || p.Model == "" || len(p.Models) == 0 || p.Endpoint == "" {
			t.Errorf("ASR preset %+v", p)
		}
	}
	if strings.Join(ids, ",") != "doubao,aliyun,stepfun,openai" {
		t.Errorf("ASR order %v", ids)
	}
	llms := Presets(LLM)
	if len(llms) != len(llm.Presets()) || llms[0].ID != "deepseek" {
		t.Errorf("LLM presets: %d, first %s", len(llms), llms[0].ID)
	}
	if p, ok := LookupPreset(LLM, "custom"); !ok || !p.Custom || !p.KeyOptional {
		t.Errorf("custom %+v", p)
	}
	if p, _ := LookupPreset(ASR, "doubao"); !p.AppID || !p.Hints || p.Mode != ModeStream {
		t.Errorf("doubao %+v", p)
	}
	if p, _ := LookupPreset(ASR, "openai"); !p.Prompt || p.Mode != ModeFile {
		t.Errorf("openai %+v", p)
	}
	if p, _ := LookupPreset(ASR, StepFunASR); p.Mode != ModeFile || p.Model != "step-asr" || p.Endpoint != stepFunEndpoint {
		t.Errorf("stepfun %+v", p)
	}
	if c, err := NewASR(settings.Provider{ID: StepFunASR, Enabled: true}, Env{Key: "k"}); err != nil {
		t.Errorf("stepfun client: %v", err)
	} else if _, ok := c.(*openai.Client); !ok {
		t.Errorf("stepfun client %T", c)
	}
	if Account(ASR, "doubao") != "asr.doubao" || Account(LLM, "deepseek") != "llm.deepseek" {
		t.Error("accounts")
	}
}

func setupSettings() settings.Settings {
	s := settings.Defaults()
	s.Providers.ASR = []settings.Provider{
		{ID: "openai", Enabled: true},
		{ID: "doubao", Enabled: true, AppID: "app"},
		{ID: "aliyun", Enabled: false},
	}
	s.Providers.LLM = []settings.Provider{
		{ID: "custom", Enabled: true},
		{ID: "dashscope", Enabled: true, Model: "qwen-max-latest"},
		{ID: "deepseek", Enabled: true},
	}
	return s
}

func TestReadyAndChoose(t *testing.T) {
	s := setupSettings()
	has := keys("asr.openai", "asr.doubao", "asr.aliyun", "llm.deepseek", "llm.dashscope")
	var ids []string
	for _, p := range Ready(s, ASR, has) {
		ids = append(ids, p.ID)
	}
	// The preset order, not the order of setting up; aliyun is off.
	if strings.Join(ids, ",") != "doubao,openai" {
		t.Errorf("ready ASR %v", ids)
	}
	if p, ok := Choose(s, ASR, "", has); !ok || p.ID != "doubao" {
		t.Errorf("auto %v %v", p, ok)
	}
	if p, ok := Choose(s, ASR, "openai", has); !ok || p.ID != "openai" {
		t.Errorf("chosen %v", p)
	}
	if p, ok := Choose(s, ASR, "aliyun", has); !ok || p.ID != "doubao" {
		t.Errorf("an off choice falls back: %v", p)
	}
	if _, ok := Choose(s, ASR, "", keys()); ok {
		t.Error("ready without keys")
	}
	// The custom LLM has no endpoint: not ready even without a key need.
	if m := Missing(LLM, s.Providers.LLM[0], true, false); m != MissingEndpoint {
		t.Errorf("custom missing %q", m)
	}
	if m := Missing(ASR, settings.Provider{ID: "doubao", Enabled: true}, true, true); m != "" {
		t.Errorf("doubao without App ID (an API key of the new console): %q", m)
	}
	if m := Missing(ASR, settings.Provider{ID: "doubao"}, false, true); m != MissingSetup {
		t.Errorf("not set up: %q", m)
	}
	s.Features.Rewrite.LLM = "dashscope"
	r := Routing(s, has)
	if got := r.Skills[llm.SkillTranscribeEnhance]; len(got) != 1 || got[0].Provider != "deepseek" || got[0].Model != "deepseek-flash" {
		t.Errorf("transcribe route %+v", got)
	}
	if got := r.Skills[llm.SkillRewrite]; len(got) != 1 || got[0].Provider != "dashscope" || got[0].Model != "qwen-max-latest" {
		t.Errorf("rewrite route %+v", got)
	}
	if Name(LLM, settings.Provider{ID: "deepseek"}) != "DeepSeek" || Model(ASR, settings.Provider{ID: "openai"}) != openai.DefaultModel {
		t.Error("name, model")
	}
}

func TestPut(t *testing.T) {
	s := settings.Defaults()
	Put(&s, ASR, settings.Provider{ID: "doubao", AppID: "1"})
	Put(&s, ASR, settings.Provider{ID: "openai"})
	Put(&s, ASR, settings.Provider{ID: "doubao", AppID: "2"})
	if len(s.Providers.ASR) != 2 || s.Providers.ASR[0].AppID != "2" {
		t.Errorf("%+v", s.Providers.ASR)
	}
	if p, ok := Setup(s, ASR, "openai"); !ok || p.ID != "openai" {
		t.Error("setup")
	}
}

func TestCheckEndpoint(t *testing.T) {
	for _, tc := range []struct {
		kind Kind
		p    settings.Provider
		ok   bool
	}{
		{ASR, settings.Provider{ID: "doubao"}, true},
		{ASR, settings.Provider{ID: "doubao", Endpoint: "wss://relay.example.com/api/v3/sauc/bigmodel_async"}, true},
		{ASR, settings.Provider{ID: "doubao", Endpoint: "https://openspeech.bytedance.com/api/v3/sauc/bigmodel"}, false},
		{ASR, settings.Provider{ID: "aliyun", Endpoint: "ws://127.0.0.1:9000/api-ws/v1/inference"}, true},
		{ASR, settings.Provider{ID: "openai", Endpoint: "https://api.groq.com/openai/v1"}, true},
		{ASR, settings.Provider{ID: "openai", Endpoint: "http://api.groq.com/openai/v1"}, false},
		{LLM, settings.Provider{ID: "deepseek"}, true},
		{LLM, settings.Provider{ID: "custom"}, false},
		{LLM, settings.Provider{ID: "custom", Endpoint: "http://localhost:8080/v1"}, true},
		{LLM, settings.Provider{ID: "custom", Endpoint: "http://10.0.0.2:8080/v1"}, false},
		{LLM, settings.Provider{ID: "nope"}, false},
	} {
		if err := CheckEndpoint(tc.kind, tc.p); (err == nil) != tc.ok {
			t.Errorf("%s %+v: %v", tc.kind, tc.p, err)
		}
	}
}

func TestNewASR(t *testing.T) {
	for id, want := range map[string]any{"openai": &openai.Client{}, "doubao": &doubao.Client{}, "aliyun": &aliyun.Client{}} {
		c, err := NewASR(settings.Provider{ID: id, Enabled: true, AppID: "a"}, Env{Key: "k"})
		if err != nil {
			t.Errorf("%s: %v", id, err)
			continue
		}
		if got, w := typeName(c), typeName(want); got != w {
			t.Errorf("%s: %s, want %s", id, got, w)
		}
	}
	if _, err := NewASR(settings.Provider{ID: "openai"}, Env{}); asr.KindOf(err) != asr.KindConfig {
		t.Errorf("no key: %v", err)
	}
	if _, err := NewASR(settings.Provider{ID: "x"}, Env{Key: "k"}); asr.KindOf(err) != asr.KindConfig {
		t.Errorf("unknown: %v", err)
	}
}

func typeName(v any) string { return fmt.Sprintf("%T", v) }

// TestTest runs connection tests against loopback servers: an
// OpenAI-compatible transcription endpoint and DeepSeek-like chat.
func TestTest(t *testing.T) {
	asrSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer good" {
			w.WriteHeader(401)
			w.Write([]byte(`{"error":{"message":"Incorrect API key provided"}}`))
			return
		}
		w.Write([]byte(`{"text":""}`))
	}))
	defer asrSrv.Close()
	p := settings.Provider{ID: "openai", Enabled: true, Endpoint: asrSrv.URL + "/v1"}
	if res := Test(context.Background(), ASR, p, Env{Key: "good"}); res.Err != nil || res.Latency <= 0 {
		t.Errorf("asr ok: %+v", res)
	}
	if res := Test(context.Background(), ASR, p, Env{Key: "bad"}); asr.KindOf(res.Err) != asr.KindAuth {
		t.Errorf("asr bad key: %+v", res)
	}

	var body map[string]any
	llmSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"total_tokens":3}}`))
	}))
	defer llmSrv.Close()
	lp := settings.Provider{ID: "deepseek", Enabled: true, Endpoint: llmSrv.URL + "/v1"}
	if res := Test(context.Background(), LLM, lp, Env{Key: "sk"}); res.Err != nil {
		t.Errorf("llm: %+v", res)
	}
	if th, _ := body["thinking"].(map[string]any); th["type"] != "disabled" || body["model"] != "deepseek-flash" {
		t.Errorf("probe body %v", body)
	}
	if res := Test(context.Background(), LLM, lp, Env{}); llm.Code(res.Err) != llm.CodeNoKey {
		t.Errorf("llm no key: %+v", res)
	}
}

// TestE2EDeepSeek has one short conversation with DeepSeek's default
// model, thinking off (VOXTNEW_E2E=1 and DEEPSEEK_API_KEY).
func TestE2EDeepSeek(t *testing.T) {
	asrtest.E2E(t)
	key := asrtest.Key(t, "DEEPSEEK_API_KEY")
	b, err := NewLLM(settings.Provider{ID: "deepseek", Enabled: true}, Env{Key: key})
	if err != nil {
		t.Fatal(err)
	}
	c := &llm.Client{Backend: b, Timeout: 60 * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	var streamed strings.Builder
	resp, err := c.Chat(ctx, llm.Request{
		Messages: []llm.Message{
			{Role: llm.System, Content: "You clean up dictated text. Reply with the cleaned text only."},
			{Role: llm.User, Content: "嗯 那个 我们明天 uh 下午三点 开会 讨论 VoxtNew 的 release plan"},
		},
		Temperature: llm.F64(0.1),
		OnDelta:     func(s string) { streamed.WriteString(s) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(resp.Text) == "" || streamed.String() != resp.Text {
		t.Fatalf("empty or unstreamed answer: %q / %q", resp.Text, streamed.String())
	}
	t.Logf("%s %s (%v, %d tokens): %s", resp.Provider, resp.Model, resp.Latency.Round(time.Millisecond), resp.Usage.TotalTokens, resp.Text)
	if d, err := llm.Probe(ctx, b, ""); err != nil {
		t.Errorf("probe: %v", err)
	} else {
		t.Logf("probe %v", d.Round(time.Millisecond))
	}
}

func TestTestLog(t *testing.T) {
	p := settings.Provider{ID: "stepfun", Enabled: true}
	level, msg := TestLog(ASR, p, TestResult{Latency: 904 * time.Millisecond, Text: "secret words"}, "sk-123456")
	if level != "info" || msg != "connection test of speech stepfun (model step-asr): ok in 904ms" {
		t.Errorf("%s %q", level, msg)
	}
	err := &asr.Error{Kind: asr.KindAuth, Provider: "openai", Status: 401, Detail: "Incorrect API key provided: sk-123456"}
	level, msg = TestLog(ASR, settings.Provider{ID: "openai", Model: "whisper-1"}, TestResult{Latency: 120 * time.Millisecond, Err: err}, "sk-123456")
	if level != "warning" || strings.Contains(msg, "sk-123456") ||
		msg != "connection test of speech openai (model whisper-1): failed in 120ms: asr openai: auth (status 401): Incorrect API key provided: [key]" {
		t.Errorf("%s %q", level, msg)
	}
}
