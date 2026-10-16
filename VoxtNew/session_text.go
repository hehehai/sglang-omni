package main

// What a session's problem says, and the action its notice offers
// (session_link.go): the words for the notice in the overlay and the Try
// area.

import (
	"context"
	"errors"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/i18n"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/session"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/uitext"
)

// sessionProblemText says what went wrong in a session, its detail (the
// service's own message) and where the notice's button goes. "" for a
// problem that needs no notice.
func sessionProblemText(p *session.Problem) (text, more, action string) {
	switch p.Code {
	case session.ProblemNoASR:
		return i18n.T("No speech service is set up."), "", actionProviders
	case session.ProblemMicrophone:
		return i18n.T("VoxtNew may not use the microphone."), errText(p.Err), actionPermissions
	case session.ProblemDevice:
		return i18n.T("No microphone gave any sound."), errText(p.Err), actionNone
	case session.ProblemHelper:
		return i18n.T("The helper stopped: try again in a moment."), errText(p.Err), actionHelper
	case session.ProblemASR:
		msg, more := uitext.ProviderErrorText(p.Err)
		return i18n.T("Speech recognition failed: %s", msg), more, actionProviders
	case session.ProblemNoLLM:
		return i18n.T("No language model is set up."), "", actionProviders
	case session.ProblemEmpty:
		return i18n.T("The language model answered nothing."), "", actionNone
	case session.ProblemLLM:
		if !p.Degraded {
			msg, more := uitext.ProviderErrorText(p.Err)
			return i18n.T("The language model failed: %s", msg), more, actionProviders
		}
		_, more := uitext.ProviderErrorText(p.Err)
		var le *llm.Error
		if errors.Is(p.Err, context.DeadlineExceeded) || errors.As(p.Err, &le) && le.Code == llm.CodeTimeout {
			return i18n.T("Inserted as recognised: the language model did not answer in time."), more, actionNone
		}
		return i18n.T("Inserted as recognised: the language model failed."), more, actionNone
	case session.ProblemNoSpeech:
		return i18n.T("Nothing was heard."), "", actionNone
	case session.ProblemUnsupported:
		return i18n.T("This feature is not available."), "", actionNone
	case session.ProblemTooShort:
		return "", "", actionNone
	}
	return i18n.T("Something went wrong: %s", errText(p.Err)), "", actionNone
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// noticeActionLabel is a notice's button.
func noticeActionLabel(action string) string {
	switch action {
	case actionProviders:
		return i18n.T("Open Model services")
	case actionPermissions:
		return i18n.T("Open Permissions")
	case actionHelper:
		return i18n.T("Restart the helper")
	}
	return ""
}
