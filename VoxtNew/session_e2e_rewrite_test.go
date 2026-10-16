package main

// Whole sessions of Rewrite on Linux, and Translate and Rewrite on DeepSeek
// (the fakes are in session_e2e_test.go).

import (
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/asrtest"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/helpertest"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/session"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

// TestRewriteAnswerFollowUp: nothing selected and nothing takes text: the
// JSON answer streams into the card with its title; the Rewrite shortcut
// on the card records a follow-up, sent with the conversation so far,
// answered in plain text into the card's conversation.
func TestRewriteAnswerFollowUp(t *testing.T) {
	chat := &fakeChat{texts: []string{`{"title":"Late","content":"Sorry, I am running late."}`, "Running late."}}
	set, keys, tr := fileSetup(t, "write that I am late", chat)
	ev := script(t, hotkeyLine(0, "rewrite/0", proto.PhaseTrigger), hotkeyLine(500, "rewrite/0", proto.PhaseTrigger))
	a := newSessionApp(t, "readonly,"+ev, set, keys)
	a.pump("the end", func() bool { return a.sess.State.Ended() })
	if a.sess.Result != "Sorry, I am running late." || a.sess.Title != "Late" || !a.answer.open || a.answer.title != "Late" || len(a.answer.turns) != 1 {
		t.Fatalf("end %+v card %+v", a.sess, a.answer)
	}
	if reqs := chat.requests(); reqs[0]["response_format"] == nil {
		t.Errorf("no JSON asked: %v", reqs[0])
	}
	// The follow-up: the shortcut, a moment of speech, the shortcut.
	tr.text = "shorter"
	front := helpertest.Apps["com.tinyspeck.slackmacgap"]
	a.hotkeyFired(proto.HotkeyEventParams{Binding: "rewrite/0", Phase: proto.PhaseTrigger, Behavior: proto.BehaviorTap, Front: &front})
	a.pump("the follow-up's recording", func() bool { return a.sess.State == session.Recording && a.sess.HeardAt.After(a.sess.StartedAt) })
	// It records in the card, now a conversation (Voxt's).
	if v := a.cardNow(); !a.answer.open || a.ov.mode != ovAnswer || !v.conversation || !v.recording {
		t.Errorf("card %v overlay %s while recording: %+v", a.answer.open, a.ov.mode, v)
	}
	time.Sleep(400 * time.Millisecond)
	a.hotkeyFired(proto.HotkeyEventParams{Binding: "rewrite/0", Phase: proto.PhaseTrigger, Behavior: proto.BehaviorTap, Front: &front})
	a.pump("the follow-up's end", func() bool { return a.sess.State.Ended() && a.answer.text == "Running late." })
	if a.answer.text != "Running late." || len(a.answer.turns) != 2 || !a.answer.open || !a.answer.conversation || len(a.pasted()) != 0 {
		t.Errorf("card %+v", a.answer)
	}
	// A follow-up answers in plain text, without a title (Voxt's).
	if v := a.cardNow(); len(v.bubbles) != 4 || !v.bubbles[2].user || v.bubbles[2].text != "shorter" || v.bubbles[3].title != "" || v.bubbles[3].text != "Running late." || !v.canFollowUp {
		t.Errorf("the conversation %+v", v.bubbles)
	}
	msgs := chatMessages(chat.requests()[1])
	if len(msgs) != 4 || msgs[2][0] != "assistant" || !strings.Contains(msgs[2][1], "Sorry, I am running late.") || msgs[3][1] != "<instruction>\nshorter\n</instruction>" {
		t.Errorf("follow-up messages %q", msgs)
	}
	a.hotkeyFired(proto.HotkeyEventParams{Binding: proto.HotkeyEscape, Phase: proto.PhaseTrigger})
	if a.answer.open {
		t.Error("Escape did not close the card")
	}
}

// TestE2EWriteReal runs Translate and Rewrite on DeepSeek with the app's
// resolver, from text (no recording): a selection into Chinese, a
// selection rewritten, a note written from scratch as a JSON answer
// (VOXTNEW_E2E=1; DEEPSEEK_API_KEY from the environment or
// ~/.config/voxtnew-dev/keys.env).
func TestE2EWriteReal(t *testing.T) {
	asrtest.E2E(t)
	llmKey := asrtest.Key(t, "DEEPSEEK_API_KEY")
	for _, tc := range []struct {
		name string
		kind store.Kind
		in   session.TextInput
		lang string
	}{
		{"translate a selection", store.KindTranslate, session.TextInput{Selection: "The release moves to Friday: the tests are still running."}, "zh-Hans"},
		{"translate speech", store.KindTranslate, session.TextInput{Raw: "嗯 那个 发布改到周五 不对 改到下周一"}, "en"},
		{"rewrite a selection", store.KindRewrite, session.TextInput{Raw: "make it more formal", Selection: "hey all, release slips to friday, tests still running, sorry!"}, ""},
		{"write from scratch", store.KindRewrite, session.TextInput{Raw: "写一句话告诉同事我会晚到十分钟"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := settings.Defaults()
			s.Providers.LLM = []settings.Provider{{ID: "deepseek", Enabled: true}}
			s.General.MainLanguage = "zh"
			kr := &memKeyring{m: map[string]string{"llm.deepseek": llmKey}}
			text := &pasteText{}
			ended := make(chan session.Snapshot, 4)
			m := session.New(session.Config{
				Audio: wavAudio{}, Text: text, Resolve: resolver(kr),
				Settings: func() settings.Settings { return s },
				OnChange: func(sn session.Snapshot) {
					if sn.State.Ended() {
						ended <- sn
					}
				},
				Log: func(level, msg string) { t.Log(level, msg) },
			})
			in := tc.in
			if _, err := m.Start(session.StartRequest{Kind: tc.kind, Target: slackApp, Text: &in, TargetLanguage: tc.lang}); err != nil {
				t.Fatal(err)
			}
			var end session.Snapshot
			select {
			case end = <-ended:
			case <-time.After(90 * time.Second):
				t.Fatal("no end")
			}
			if end.State != session.Done || end.Result == "" || !end.Inserted && !end.Card {
				t.Fatalf("end %s %+v", end.State, end.Problem)
			}
			t.Logf("%s (%s, retried %v, %v): title %q → %q", end.Profile, end.LLM.Model, end.Retried, end.Timings.LLM.Round(time.Millisecond), end.Title, end.Result)
		})
	}
}
