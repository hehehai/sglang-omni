package uitext

// The words of the Model services page and of the services' card:
// providers' and presets' names, what a key is called, a preset's mode,
// and what a provider's error means.

import (
	"errors"
	"fmt"
	"strings"

	"github.com/hehehai/Auralink/internal/asr"
	"github.com/hehehai/Auralink/internal/i18n"
	"github.com/hehehai/Auralink/internal/llm"
	"github.com/hehehai/Auralink/internal/providers"
	"github.com/hehehai/Auralink/internal/settings"
)

// ProviderName is a service's name in the UI language: the user's label,
// else the preset's (translated where it has a Chinese name).
func ProviderName(kind providers.Kind, p settings.Provider) string {
	if p.Name != "" {
		return p.Name
	}
	pr, _ := providers.PresetOf(kind, p)
	return PresetName(pr)
}

func PresetName(pr providers.Preset) string {
	if pr.Kind == providers.ASR {
		switch pr.ID {
		case "doubao":
			return i18n.T("Doubao (Volcengine)")
		case "aliyun":
			return i18n.T("Alibaba Cloud Model Studio")
		case "openai":
			return i18n.T("OpenAI-compatible")
		}
	}
	switch pr.ID {
	case "dashscope":
		return i18n.T("Qwen (Alibaba Cloud Model Studio)")
	case "dashscope-intl":
		return i18n.T("Qwen (Model Studio international)")
	case "volcengine":
		return i18n.T("Volcengine Ark (Doubao)")
	case "moonshot":
		return i18n.T("Moonshot (Kimi)")
	case "moonshot-intl":
		return i18n.T("Moonshot (Kimi, international)")
	case "zhipu":
		return i18n.T("Zhipu GLM")
	case "stepfun":
		return i18n.T("StepFun")
	case "mimo":
		return i18n.T("Xiaomi MiMo")
	case "siliconflow":
		return i18n.T("SiliconFlow")
	case "siliconflow-intl":
		return i18n.T("SiliconFlow (international)")
	case "custom":
		return i18n.T("Custom (OpenAI-compatible)")
	}
	if pr.Name != "" {
		return pr.Name
	}
	return pr.ID
}

// KeyLabel is what a service calls its key.
func KeyLabel(kind providers.Kind, id string) string {
	if kind == providers.ASR && id == "doubao" {
		return i18n.T("Access Token or API key")
	}
	return i18n.T("API key")
}

// ModeLabel is the chip of a service: how it works.
func ModeLabel(pr providers.Preset) string {
	switch pr.Mode {
	case providers.ModeStream:
		return i18n.T("Streaming")
	case providers.ModeFile:
		return i18n.T("Upload")
	case "anthropic":
		return "Anthropic"
	}
	return i18n.T("OpenAI API")
}

// ProviderErrorText says what went wrong with a service, and its detail
// (the service's own message, for the ⓘ).
func ProviderErrorText(err error) (msg, more string) {
	if err == nil {
		return "", ""
	}
	more = err.Error()
	var ae *asr.Error
	if errors.As(err, &ae) {
		switch ae.Kind {
		case asr.KindAuth:
			if ae.Provider == "doubao" {
				return i18n.T("The service refused the key. Check it (and the App ID) and try again."), more
			}
			return i18n.T("The service refused the key. Check it and try again."), more
		case asr.KindQuota:
			return i18n.T("The service refused for now: out of quota, rate limited, or the model is not enabled for your account."), more
		case asr.KindNetwork:
			return i18n.T("Could not reach the service. Check the network, the proxy and the endpoint."), more
		case asr.KindServer:
			return i18n.T("The service had a problem on its side. Try again in a moment."), more
		case asr.KindAudio:
			return i18n.T("The service did not accept the audio."), more
		case asr.KindCancelled:
			return i18n.T("Cancelled."), more
		case asr.KindConfig:
			return i18n.T("The setup is incomplete or wrong: check the key, the endpoint and the model."), more
		}
		return i18n.T("The service answered something Auralink does not understand. Check the endpoint and the model."), more
	}
	var le *llm.Error
	if errors.As(err, &le) {
		switch le.Code {
		case llm.CodeNoKey:
			return i18n.T("No key is saved for this service."), more
		case llm.CodeAuth:
			return i18n.T("The service refused the key. Check it and try again."), more
		case llm.CodeRateLimited, llm.CodeOverloaded:
			return i18n.T("The service refused for now: out of quota, rate limited, or busy."), more
		case llm.CodeModelNotFound:
			return i18n.T("The service does not know the model %s.", le.Params["model"]), more
		case llm.CodeTimeout:
			return i18n.T("The service did not answer in time."), more
		case llm.CodeNetwork:
			return i18n.T("Could not reach the service. Check the network, the proxy and the endpoint."), more
		case llm.CodeServer:
			return i18n.T("The service had a problem on its side. Try again in a moment."), more
		case llm.CodeConfig:
			return i18n.T("The setup is incomplete or wrong: check the endpoint (https:// only) and the model."), more
		case llm.CodeBadRequest, llm.CodeContextLength, llm.CodeFiltered:
			return i18n.T("The service refused the request."), more
		case llm.CodeCancelled:
			return i18n.T("Cancelled."), more
		}
		return i18n.T("The service answered something Auralink does not understand. Check the endpoint and the model."), more
	}
	return i18n.T("Could not reach the service. Check the network, the proxy and the endpoint."), more
}

// ProviderErrorShort is a failed test's reason beside its button: a few
// words, and what to change.
func ProviderErrorShort(err error) string {
	var ae *asr.Error
	if errors.As(err, &ae) {
		switch ae.Kind {
		case asr.KindAuth:
			if ae.Provider == "doubao" {
				return i18n.T("Key refused: check the key and App ID")
			}
			return i18n.T("Key refused: check the key")
		case asr.KindQuota:
			return i18n.T("Refused: quota, rate limit or model not enabled")
		case asr.KindNetwork:
			return i18n.T("Unreachable: check the network, proxy and endpoint")
		case asr.KindServer:
			return i18n.T("The service failed: try again later")
		case asr.KindAudio:
			return i18n.T("The service refused the audio")
		case asr.KindCancelled:
			return i18n.T("Cancelled.")
		case asr.KindConfig:
			return i18n.T("Check the key, endpoint and model")
		}
		return i18n.T("Unexpected answer: check the endpoint and model")
	}
	var le *llm.Error
	if errors.As(err, &le) {
		switch le.Code {
		case llm.CodeNoKey:
			return i18n.T("No key: paste the key")
		case llm.CodeAuth:
			return i18n.T("Key refused: check the key")
		case llm.CodeRateLimited, llm.CodeOverloaded:
			return i18n.T("Refused: quota, rate limit or busy")
		case llm.CodeModelNotFound:
			return i18n.T("Unknown model: check the model")
		case llm.CodeTimeout:
			return i18n.T("No answer in time: check the network and proxy")
		case llm.CodeNetwork:
			return i18n.T("Unreachable: check the network, proxy and endpoint")
		case llm.CodeServer:
			return i18n.T("The service failed: try again later")
		case llm.CodeConfig:
			return i18n.T("Check the endpoint (https://) and model")
		case llm.CodeBadRequest, llm.CodeContextLength, llm.CodeFiltered:
			return i18n.T("Request refused: check the model")
		case llm.CodeCancelled:
			return i18n.T("Cancelled.")
		}
		return i18n.T("Unexpected answer: check the endpoint and model")
	}
	return i18n.T("Unreachable: check the network, proxy and endpoint")
}

// ProviderErrorDetail is what the service said, for a failure's ⓘ: its
// HTTP status, code and message (never a key: errors carry none).
func ProviderErrorDetail(err error) string {
	var ae *asr.Error
	if errors.As(err, &ae) {
		var parts []string
		if ae.Status != 0 {
			parts = append(parts, fmt.Sprintf("HTTP %d", ae.Status))
		}
		if ae.Code != "" {
			parts = append(parts, ae.Code)
		}
		if ae.Detail != "" {
			parts = append(parts, ae.Detail)
		} else if ae.Err != nil {
			parts = append(parts, asr.Clip(ae.Err.Error(), 300))
		}
		if len(parts) > 0 {
			return strings.Join(parts, " · ")
		}
	}
	var le *llm.Error
	if errors.As(err, &le) {
		var parts []string
		if st := le.Params["status"]; st != "" {
			parts = append(parts, "HTTP "+st)
		} else if le.Status != 0 {
			parts = append(parts, fmt.Sprintf("HTTP %d", le.Status))
		}
		parts = append(parts, le.Code)
		if d := le.Params["detail"]; d != "" {
			parts = append(parts, d)
		} else if le.Err != nil {
			parts = append(parts, asr.Clip(le.Err.Error(), 300))
		}
		return strings.Join(parts, " · ")
	}
	return asr.Clip(err.Error(), 300)
}
