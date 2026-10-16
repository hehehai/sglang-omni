package llm

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
)

// JSONMode is how a provider is asked for JSON.
type JSONMode string

const (
	JSONSchemaMode JSONMode = "schema" // response_format: json_schema (OpenAI structured outputs)
	JSONObjectMode JSONMode = "object" // response_format: json_object; the schema goes in the prompt
	JSONPromptMode JSONMode = "prompt" // no API support; the schema goes in the prompt
)

// Auth styles.
const (
	AuthBearer  = "bearer"    // Authorization: Bearer <key>
	AuthXAPIKey = "x-api-key" // x-api-key: <key> (Anthropic)
	AuthAPIKey  = "api-key"   // api-key: <key> (Azure OpenAI)
	AuthNone    = "none"
)

// Preset is a provider's fixed facts. Presets are data (presets.json).
type Preset struct {
	ID          string `json:"id"`
	Name        string `json:"name"`      // brand name, not translated
	Transport   string `json:"transport"` // "openai" | "anthropic"
	BaseURL     string `json:"baseURL"`   // "" for custom: the user supplies it
	Auth        string `json:"auth"`
	KeyName     string `json:"keyName,omitempty"` // Secrets name when shared with another preset; default ID
	KeyOptional bool   `json:"keyOptional,omitempty"`
	ModelsPath  string `json:"modelsPath,omitempty"` // "" → Models returns the suggested list
	// Models are the suggested models, for the model menu (any id may be
	// typed), and what Models returns when there is no ModelsPath.
	Models       []string          `json:"models,omitempty"`
	JSONMode     JSONMode          `json:"jsonMode"`
	Local        bool              `json:"local,omitempty"`
	DefaultModel string            `json:"defaultModel,omitempty"`
	Headers      map[string]string `json:"headers,omitempty"`
	// MaxTokensField is the request field for Request.MaxTokens
	// (OpenAI: "max_completion_tokens"); default "max_tokens".
	MaxTokensField string `json:"maxTokensField,omitempty"`
	// ExtraBody is merged into every request body (top-level keys;
	// request fields win): how a preset turns a provider's default off,
	// such as DeepSeek's thinking, which otherwise spends a short answer's
	// budget before any text (Voxt's lesson). A server that rejects one of
	// its keys is asked again without ExtraBody.
	ExtraBody map[string]any `json:"extraBody,omitempty"`
	// KeyURL is where to get a key; Docs the API's documentation.
	KeyURL string `json:"keyURL,omitempty"`
	Docs   string `json:"docs,omitempty"`
}

// SecretName is the Secrets name of the preset's API key.
func (p Preset) SecretName() string {
	if p.KeyName != "" {
		return SecretPrefix + p.KeyName
	}
	return SecretPrefix + p.ID
}

//go:embed presets.json
var presetsJSON []byte

var presets = sync.OnceValue(func() []Preset {
	var doc struct {
		Version int      `json:"version"`
		Presets []Preset `json:"presets"`
	}
	if err := json.Unmarshal(presetsJSON, &doc); err != nil {
		panic("llm: presets.json: " + err.Error())
	}
	return doc.Presets
})

// Presets returns the built-in provider presets, in display order. The slice is a copy.
func Presets() []Preset { return slices.Clone(presets()) }

// LookupPreset returns the preset with id.
func LookupPreset(id string) (Preset, bool) {
	for _, p := range presets() {
		if p.ID == id {
			return p, true
		}
	}
	return Preset{}, false
}

// ProviderConfig is a user's configuration of one provider (stored in
// settings; never the key itself).
type ProviderConfig struct {
	ID      string            `json:"id"`                // unique; usually the preset id ("openai"), "custom-2"…
	Preset  string            `json:"preset"`            // preset id; "" = ID
	Name    string            `json:"name,omitempty"`    // user label for custom providers
	BaseURL string            `json:"baseURL,omitempty"` // overrides the preset's
	Model   string            `json:"model,omitempty"`   // default model; overrides the preset's
	Headers map[string]string `json:"headers,omitempty"` // extra headers
	// JSONMode overrides the preset's (a custom server that supports json_schema).
	JSONMode JSONMode `json:"jsonMode,omitempty"`
	// ExtraBody is merged over the preset's (a nil value removes a key).
	ExtraBody map[string]any `json:"extraBody,omitempty"`
}

// Resolve merges cfg over its preset.
func (cfg ProviderConfig) Resolve() (Preset, error) {
	pid := cfg.Preset
	if pid == "" {
		pid = cfg.ID
	}
	p, ok := LookupPreset(pid)
	if !ok {
		return Preset{}, newErr(CodeUnknown, "provider", pid)
	}
	if cfg.ID != "" && cfg.ID != p.ID {
		if p.KeyName == "" {
			p.KeyName = cfg.ID // custom-2 keeps its own key
		}
		p.ID = cfg.ID
	}
	if cfg.Name != "" {
		p.Name = cfg.Name
	}
	if cfg.BaseURL != "" {
		p.BaseURL = cfg.BaseURL
	}
	if cfg.Model != "" {
		p.DefaultModel = cfg.Model
	}
	if cfg.JSONMode != "" {
		p.JSONMode = cfg.JSONMode
	}
	if len(cfg.ExtraBody) > 0 {
		x := maps.Clone(p.ExtraBody)
		if x == nil {
			x = map[string]any{}
		}
		for k, v := range cfg.ExtraBody {
			if v == nil {
				delete(x, k)
				continue
			}
			x[k] = v
		}
		p.ExtraBody = x
	}
	if len(cfg.Headers) > 0 {
		h := map[string]string{}
		for k, v := range p.Headers {
			h[k] = v
		}
		for k, v := range cfg.Headers {
			h[k] = v
		}
		p.Headers = h
	}
	p.BaseURL = strings.TrimRight(p.BaseURL, "/")
	if p.BaseURL == "" {
		return Preset{}, newErr(CodeConfig, "provider", p.ID, "field", "baseURL")
	}
	// Keys go over https only; plain http only to this Mac (a relay or a
	// test server), and never with a user or password in the URL.
	u, err := url.Parse(p.BaseURL)
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && !(u.Scheme == "http" && isLoopback(u.Hostname()))) {
		return Preset{}, newErr(CodeConfig, "provider", p.ID, "field", "baseURL")
	}
	if isLoopback(u.Hostname()) {
		p.Local = true
	}
	return p, nil
}

func isLoopback(host string) bool {
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// SecretPrefix starts every API-key name: "llm.openai" (the Keychain
// account of internal/secrets).
const SecretPrefix = "llm."

// ErrNoSecret is returned by Secrets when nothing is stored under the name.
var ErrNoSecret = errors.New("no secret stored")

// Secrets supplies API keys by name. The app backs it with the macOS
// Keychain (it may block: call off the UI thread). Implementations return
// ErrNoSecret (possibly wrapped) when the name has no value.
type Secrets interface {
	Secret(ctx context.Context, name string) (string, error)
}

// SecretsFunc adapts a function to Secrets.
type SecretsFunc func(ctx context.Context, name string) (string, error)

func (f SecretsFunc) Secret(ctx context.Context, name string) (string, error) { return f(ctx, name) }

// StaticSecrets is an in-memory Secrets (tests, a key read for one call).
type StaticSecrets map[string]string

func (s StaticSecrets) Secret(_ context.Context, name string) (string, error) {
	if v, ok := s[name]; ok && v != "" {
		return v, nil
	}
	return "", ErrNoSecret
}

// EnvSecrets reads $AURALINK_<NAME> ("llm.openai" → AURALINK_LLM_OPENAI),
// falling back to Fallback. For development and CI only.
type EnvSecrets struct{ Fallback Secrets }

func (e EnvSecrets) Secret(ctx context.Context, name string) (string, error) {
	env := "AURALINK_" + strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r - 'a' + 'A'
		case r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		}
		return '_'
	}, name)
	if v := os.Getenv(env); v != "" {
		return v, nil
	}
	if e.Fallback != nil {
		return e.Fallback.Secret(ctx, name)
	}
	return "", ErrNoSecret
}

// lookupKey fetches the key for p, mapping "missing" to CodeNoKey unless optional.
func lookupKey(ctx context.Context, s Secrets, p Preset) (string, error) {
	if p.Auth == AuthNone && s == nil {
		return "", nil
	}
	if s == nil {
		if p.KeyOptional {
			return "", nil
		}
		return "", newErr(CodeNoKey, "provider", p.ID)
	}
	key, err := s.Secret(ctx, p.SecretName())
	if err != nil {
		if errors.Is(err, ErrNoSecret) {
			if p.KeyOptional || p.Auth == AuthNone {
				return "", nil
			}
			return "", newErr(CodeNoKey, "provider", p.ID)
		}
		e := newErr(CodeNoKey, "provider", p.ID)
		e.Err = fmt.Errorf("secrets: %w", err)
		return "", e
	}
	return strings.TrimSpace(key), nil
}
