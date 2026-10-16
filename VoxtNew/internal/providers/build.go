package providers

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/aliyun"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/doubao"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/openai"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/netx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

// Env is what building a client needs besides the setup: its key and
// how to reach the network.
type Env struct {
	Key   string // the key from the Keychain ("" for none)
	Proxy string // settings.Network.Proxy
	// HTTP replaces the clients built on Proxy (tests).
	HTTP *http.Client
}

// NewASR builds the speech client of a setup.
func NewASR(p settings.Provider, env Env) (asr.Provider, error) {
	pr, ok := PresetOf(ASR, p)
	if !ok {
		return nil, asr.Errorf(p.ID, asr.KindConfig, "unknown speech service %q", p.Preset)
	}
	cfg := asr.Config{Endpoint: p.Endpoint, Model: p.Model, Key: env.Key, AppID: p.AppID, Prompt: p.Prompt, Proxy: env.Proxy, HTTPClient: env.HTTP}
	switch pr.ID {
	case openai.ID:
		return openai.New(cfg)
	case StepFunASR:
		if cfg.Endpoint == "" {
			cfg.Endpoint = pr.Endpoint
		}
		if cfg.Model == "" {
			cfg.Model = pr.Model
		}
		return openai.New(cfg)
	case doubao.ID:
		return doubao.New(cfg)
	case aliyun.ID:
		return aliyun.New(cfg)
	}
	return nil, asr.Errorf(p.ID, asr.KindConfig, "unknown speech service %q", pr.ID)
}

// CheckEndpoint checks the endpoint of a setup before it is saved: the
// scheme its service needs (wss for streams, https otherwise; plain only
// on loopback). "" (the default) is fine, except for a custom LLM.
func CheckEndpoint(kind Kind, p settings.Provider) error {
	pr, ok := PresetOf(kind, p)
	if !ok {
		return asr.Errorf(p.ID, asr.KindConfig, "unknown service %q", p.Preset)
	}
	if kind == LLM {
		if p.Endpoint == "" && !pr.Custom {
			return nil
		}
		_, err := LLMConfig(p).Resolve()
		return err
	}
	if p.Endpoint == "" {
		return nil
	}
	switch pr.Mode {
	case ModeStream:
		_, err := asr.CheckEndpoint(pr.ID, p.Endpoint, "wss")
		return err
	default:
		_, err := asr.CheckEndpoint(pr.ID, openai.Endpoint(p.Endpoint), "https")
		return err
	}
}

// LLMConfig is the llm package's configuration of a setup.
func LLMConfig(p settings.Provider) llm.ProviderConfig {
	preset := p.Preset
	if preset == "" {
		preset = p.ID
	}
	return llm.ProviderConfig{ID: p.ID, Preset: preset, Name: p.Name, BaseURL: p.Endpoint, Model: p.Model}
}

// NewLLM builds the language model backend of a setup, with its key.
func NewLLM(p settings.Provider, env Env) (llm.Backend, error) {
	client := env.HTTP
	if client == nil {
		client = netx.NewHTTPClient(env.Proxy, 0)
	}
	cfg := LLMConfig(p)
	pr, err := cfg.Resolve()
	if err != nil {
		return nil, err
	}
	return llm.NewBackend(cfg, client, llm.StaticSecrets{pr.SecretName(): env.Key})
}

// TestResult is the outcome of a connection test.
type TestResult struct {
	Latency time.Duration
	Text    string // what the service answered (an ASR test's text of silence is usually "")
	Err     error  // nil: it works
	At      time.Time
}

// TestTimeout bounds a connection test.
const TestTimeout = 30 * time.Second

// Test checks that a setup works: for speech, a second of silence
// recognised (streamed or uploaded), which proves the key, the endpoint
// and the protocol; for a language model, one tiny request (llm.Probe).
func Test(ctx context.Context, kind Kind, p settings.Provider, env Env) TestResult {
	ctx, cancel := context.WithTimeout(ctx, TestTimeout)
	defer cancel()
	start := time.Now()
	res := TestResult{At: start}
	switch kind {
	case ASR:
		c, err := NewASR(p, env)
		if err != nil {
			res.Err = err
			return res
		}
		r, err := asr.Recognize(ctx, c, asr.Silence(time.Second), "", nil, "", asr.Feed{})
		res.Text, res.Err = r.Text, err
	case LLM:
		b, err := NewLLM(p, env)
		if err != nil {
			res.Err = err
			return res
		}
		_, err = llm.Probe(ctx, b, Model(LLM, p))
		res.Err = err
	default:
		res.Err = errors.New("unknown kind")
	}
	res.Latency = time.Since(start)
	return res
}

// TestLog is the log line of a connection test: the service, its model,
// the outcome, how long it took and, for a failure, the error (its kind
// or code, HTTP status and the service's message, clipped). Never the key
// (removed should an error quote it) nor the text recognised.
func TestLog(kind Kind, p settings.Provider, res TestResult, key string) (level, msg string) {
	what := "speech"
	if kind == LLM {
		what = "language model"
	}
	head := fmt.Sprintf("connection test of %s %s (%s, model %s)", what, p.ID, p.Preset, Model(kind, p))
	if p.Preset == "" || p.Preset == p.ID {
		head = fmt.Sprintf("connection test of %s %s (model %s)", what, p.ID, Model(kind, p))
	}
	took := res.Latency.Round(time.Millisecond)
	if res.Err == nil {
		return "info", fmt.Sprintf("%s: ok in %v", head, took)
	}
	return "warning", fmt.Sprintf("%s: failed in %v: %s", head, took, ErrorLog(res.Err, key))
}

// ErrorLog is err for the log: clipped to about 300 bytes, with key (when
// not empty) blanked out.
func ErrorLog(err error, key string) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if key = strings.TrimSpace(key); len(key) >= 4 {
		s = strings.ReplaceAll(s, key, "[key]")
	}
	return asr.Clip(s, 400)
}
