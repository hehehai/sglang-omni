// Package providers joins the user's setup of the speech and language
// services (settings.Providers) to the code that talks to them
// (internal/asr's providers, internal/llm): the presets the Model
// services page offers, which service a feature uses, building a client
// from a setup and its key, and the connection test.
//
// It never reads the Keychain itself: callers pass keys in (read off the
// main thread with internal/secrets) and a hasKey function for the
// decisions that only need to know whether one is saved.
//
// Imports: asr (+ openai, doubao, aliyun), llm, settings, netx.
package providers

import (
	"slices"
	"strings"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/aliyun"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/doubao"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/openai"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

// Kind is a list of services: speech recognition or language models.
type Kind string

const (
	ASR Kind = "asr"
	LLM Kind = "llm"
)

// Modes of an ASR preset.
const (
	ModeStream = "stream" // recognises while the user speaks
	ModeFile   = "file"   // uploads the recording when it stops
)

// Preset is a service the Model services page offers, with its defaults.
type Preset struct {
	Kind Kind
	ID   string
	Name string // brand name, not translated
	// Mode: ASR ModeStream or ModeFile; LLM the transport ("openai",
	// "anthropic").
	Mode     string
	Endpoint string   // the default endpoint ("" for custom: the user's)
	Model    string   // the default model
	Models   []string // suggested models (any id may be typed)
	// AppID: the service has an App ID besides its key (Doubao's older
	// console: App ID + Access Token; its newer one gives one API key, so
	// the App ID may stay empty).
	AppID bool
	// Prompt: the service takes an ASR prompt. Hints: it takes the
	// dictionary's terms as hot words (else they go into the prompt, or
	// nowhere).
	Prompt, Hints bool
	// KeyOptional: it works without a key (a custom server).
	KeyOptional bool
	// Custom: the user names it and must give an endpoint.
	Custom bool
	// KeyURL is where to get a key, Docs the API's documentation.
	KeyURL, Docs string
}

// asrPresets are the speech services of plan §4.4 (P0), in the page's
// order: the two streaming ones first, as they show text while you speak.
var asrPresets = []Preset{
	{Kind: ASR, ID: doubao.ID, Name: "Doubao (Volcengine)", Mode: ModeStream, Endpoint: doubao.DefaultEndpoint,
		Model: doubao.DefaultModel, Models: doubao.Models, AppID: true, Hints: true,
		KeyURL: "https://console.volcengine.com/speech/app", Docs: "https://www.volcengine.com/docs/6561/1354869"},
	{Kind: ASR, ID: aliyun.ID, Name: "Alibaba Cloud Model Studio", Mode: ModeStream, Endpoint: aliyun.InferenceEndpoint,
		Model: aliyun.DefaultModel, Models: aliyun.Models, Hints: true,
		KeyURL: "https://bailian.console.aliyun.com/?tab=model#/api-key", Docs: "https://help.aliyun.com/zh/model-studio/real-time-speech-recognition"},
	// StepFun's transcriptions are OpenAI-compatible (multipart, Bearer):
	// the openai client with StepFun's endpoint and model. Checked by hand
	// on 2026-10-15 with step-asr; no prompt (not documented there).
	{Kind: ASR, ID: StepFunASR, Name: "StepFun", Mode: ModeFile, Endpoint: stepFunEndpoint,
		Model: "step-asr", Models: []string{"step-asr", "step-asr-1.1"},
		KeyURL: "https://platform.stepfun.com/interface-key", Docs: "https://platform.stepfun.com/docs/"},
	{Kind: ASR, ID: openai.ID, Name: "OpenAI-compatible", Mode: ModeFile, Endpoint: openai.DefaultEndpoint,
		Model: openai.DefaultModel, Models: openai.Models, Prompt: true,
		KeyURL: "https://platform.openai.com/api-keys", Docs: "https://platform.openai.com/docs/api-reference/audio/createTranscription"},
}

// StepFunASR is StepFun's speech service: OpenAI-compatible uploads.
const (
	StepFunASR      = "stepfun"
	stepFunEndpoint = "https://api.stepfun.com/v1/audio/transcriptions"
)

// Presets returns kind's presets in the page's order (a copy).
func Presets(kind Kind) []Preset {
	if kind == ASR {
		return slices.Clone(asrPresets)
	}
	var out []Preset
	for _, p := range llm.Presets() {
		out = append(out, Preset{Kind: LLM, ID: p.ID, Name: p.Name, Mode: p.Transport, Endpoint: p.BaseURL,
			Model: p.DefaultModel, Models: p.Models, KeyOptional: p.KeyOptional, Custom: p.BaseURL == "",
			KeyURL: p.Docs, Docs: p.Docs})
	}
	return out
}

// LookupPreset finds kind's preset id.
func LookupPreset(kind Kind, id string) (Preset, bool) {
	for _, p := range Presets(kind) {
		if p.ID == id {
			return p, true
		}
	}
	return Preset{}, false
}

// Account is the Keychain account of a provider's key: "asr.<id>",
// "llm.<id>" (internal/secrets).
func Account(kind Kind, id string) string { return string(kind) + "." + id }

// list is s's setups of kind.
func list(s settings.Settings, kind Kind) []settings.Provider {
	if kind == ASR {
		return s.Providers.ASR
	}
	return s.Providers.LLM
}

// Setup is the user's setup of provider id, and whether there is one.
func Setup(s settings.Settings, kind Kind, id string) (settings.Provider, bool) {
	for _, p := range list(s, kind) {
		if p.ID == id {
			return p, true
		}
	}
	return settings.Provider{ID: id}, false
}

// PresetOf is the preset of a setup (its Preset, else its ID).
func PresetOf(kind Kind, p settings.Provider) (Preset, bool) {
	id := p.Preset
	if id == "" {
		id = p.ID
	}
	return LookupPreset(kind, id)
}

// Put sets p in s's kind list, replacing the setup with its ID or
// appending it.
func Put(s *settings.Settings, kind Kind, p settings.Provider) {
	l := &s.Providers.LLM
	if kind == ASR {
		l = &s.Providers.ASR
	}
	if i := slices.IndexFunc(*l, func(x settings.Provider) bool { return x.ID == p.ID }); i >= 0 {
		(*l)[i] = p
		return
	}
	*l = append(*l, p)
}

// Name is how the page names a setup: the user's label, else its preset's.
func Name(kind Kind, p settings.Provider) string {
	if p.Name != "" {
		return p.Name
	}
	if pr, ok := PresetOf(kind, p); ok {
		return pr.Name
	}
	return p.ID
}

// Model is the model a setup uses: its own, else its preset's default.
func Model(kind Kind, p settings.Provider) string {
	if p.Model != "" {
		return p.Model
	}
	if pr, ok := PresetOf(kind, p); ok {
		return pr.Model
	}
	return ""
}

// Missing says what a setup lacks before it can be used: "" when it is
// ready; else MissingSetup (never set up), MissingOff, MissingKey or
// MissingEndpoint.
func Missing(kind Kind, p settings.Provider, configured, hasKey bool) string {
	pr, ok := PresetOf(kind, p)
	switch {
	case !configured || !ok:
		return MissingSetup
	case !p.Enabled:
		return MissingOff
	case pr.Custom && p.Endpoint == "":
		return MissingEndpoint
	case !hasKey && !pr.KeyOptional:
		return MissingKey
	}
	return ""
}

// What a setup can lack (Missing).
const (
	MissingSetup    = "setup"
	MissingOff      = "off"
	MissingKey      = "key"
	MissingEndpoint = "endpoint"
)

// Ready lists kind's setups that can be used now, in the page's order:
// the presets' order, then custom setups in the order they were added.
func Ready(s settings.Settings, kind Kind, hasKey func(account string) bool) []settings.Provider {
	var out []settings.Provider
	setups := slices.Clone(list(s, kind))
	order := func(p settings.Provider) int {
		pr, _ := PresetOf(kind, p)
		for i, x := range Presets(kind) {
			if x.ID == pr.ID {
				return i
			}
		}
		return 1 << 20
	}
	slices.SortStableFunc(setups, func(a, b settings.Provider) int { return order(a) - order(b) })
	for _, p := range setups {
		if Missing(kind, p, true, hasKey(Account(kind, p.ID))) == "" {
			out = append(out, p)
		}
	}
	return out
}

// Choose is the setup a feature uses: want (settings.Feature.ASR or LLM)
// when it is ready, else the first ready one; false when none is.
func Choose(s settings.Settings, kind Kind, want string, hasKey func(account string) bool) (settings.Provider, bool) {
	ready := Ready(s, kind, hasKey)
	want = strings.TrimSpace(want)
	for _, p := range ready {
		if p.ID == want {
			return p, true
		}
	}
	if len(ready) > 0 {
		return ready[0], true
	}
	return settings.Provider{}, false
}

// Feature names, for FeatureOf.
const (
	Transcribe = "transcribe"
	Translate  = "translate"
	Rewrite    = "rewrite"
)

// FeatureOf is the feature's part of the settings.
func FeatureOf(s settings.Settings, feature string) settings.Feature {
	switch feature {
	case Translate:
		return s.Features.Translate.Feature
	case Rewrite:
		return s.Features.Rewrite.Feature
	}
	return s.Features.Transcribe.Feature
}

// SkillOf is the LLM skill of a feature.
func SkillOf(feature string) llm.Skill {
	switch feature {
	case Translate:
		return llm.SkillTranslateText
	case Rewrite:
		return llm.SkillRewrite
	}
	return llm.SkillTranscribeEnhance
}

// Routing is the LLM routing of the features: each skill to the setup
// its feature uses (Choose), with the setup's model.
func Routing(s settings.Settings, hasKey func(account string) bool) llm.Routing {
	r := llm.Routing{Skills: map[llm.Skill][]llm.Route{}}
	for _, f := range []string{Transcribe, Translate, Rewrite} {
		if p, ok := Choose(s, LLM, FeatureOf(s, f).LLM, hasKey); ok {
			r.Skills[SkillOf(f)] = []llm.Route{{Provider: p.ID, Model: Model(LLM, p)}}
		}
	}
	return r
}
