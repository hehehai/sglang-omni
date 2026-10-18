package session

import (
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/appctx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/deliver"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

var textEdit = proto.App{PID: 531, BundleID: "com.apple.TextEdit", Name: "TextEdit"}

// TestDeliverWhereTyping: a session started in Slack (the chat group,
// which presses Return) delivers where the user is when the result is
// ready: Slack, another app's text field (no Return there; the history
// keeps Slack and its rule and names the app it went into apart), or
// the card when nothing
// there takes text, a password field has the focus, or a selection made
// in Slack is to be replaced elsewhere.
func TestDeliverWhereTyping(t *testing.T) {
	inSlack := proto.FocusResult{PID: slack.PID, App: &slack, Role: "AXTextArea", Editable: true}
	inTextEdit := proto.FocusResult{PID: textEdit.PID, App: &textEdit, Role: "AXTextArea", Editable: true}
	for _, tc := range []struct {
		name      string
		kind      Kind
		selection string
		focus     proto.FocusResult
		into      proto.App // inserted into; none: the card
		press     bool
		reason    deliver.Reason
	}{
		{name: "the same app", kind: store.KindTranscribe, focus: inSlack, into: slack, press: true},
		{name: "another app's text field", kind: store.KindTranscribe, focus: inTextEdit, into: textEdit},
		{name: "nothing focused in another app", kind: store.KindTranscribe, focus: proto.FocusResult{PID: 410, Error: "no focused element"}, reason: deliver.ReasonNotEditable},
		{name: "a password field", kind: store.KindTranscribe, focus: proto.FocusResult{PID: textEdit.PID, Role: "AXTextField", Subrole: "AXSecureTextField", Editable: true}, reason: deliver.ReasonSecure},
		{name: "VoxtNew's own window", kind: store.KindTranscribe, focus: proto.FocusResult{PID: 77, Role: "AXTextField", Editable: true}, reason: deliver.ReasonNotFront},
		{name: "translated speech into another app", kind: store.KindTranslate, focus: inTextEdit, into: textEdit},
		{name: "a selection, another app in front", kind: store.KindTranslate, selection: "Good morning", focus: inTextEdit, reason: deliver.ReasonNotFront},
		{name: "a selection in the same app", kind: store.KindTranslate, selection: "Good morning", focus: inSlack, into: slack},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, &fakeFile{text: "hello"}, &fakeLLM{text: "Hello."}, func(c *Config, s *settings.Settings) {
				c.Select = &fakeSelector{text: tc.selection}
				c.Self = 77 // no Activate: VoxtNew in front stays so
				c.Scene = &SceneConfig{
					Rules:     func() (appctx.Rules, bool) { return sceneRules(), true },
					IsBrowser: func(string) bool { return false },
					URL:       (&fakeURL{}).read,
				}
				c.LLMFirstToken, c.LLMTimeout = time.Second, time.Second
			})
			h.text.focus = tc.focus
			id, err := h.m.Start(StartRequest{Kind: tc.kind, Target: slack})
			if err != nil {
				t.Fatal(err)
			}
			if tc.selection == "" {
				h.speak(id, 3)
			}
			end := h.rec.wait(t)
			h.text.mu.Lock()
			pasted, presses := h.text.pasted, h.text.presses
			h.text.mu.Unlock()
			es := h.hist.all()
			if end.State != Done || len(es) != 1 {
				t.Fatalf("end %+v, entries %+v", end, es)
			}
			e := es[0]
			if tc.into.PID == 0 {
				if len(pasted) != 0 || end.Inserted || !end.Card || end.Delivery != tc.reason || e.AppName != "Slack" || e.Delivery != "card" || e.InsertedBundle != "" {
					t.Errorf("card: pasted %q, end %+v, entry %s %s", pasted, end, e.AppName, e.Delivery)
				}
				return
			}
			if len(pasted) != 1 || !end.Inserted || end.Card || end.InsertedInto != tc.into || e.AppName != "Slack" || e.AppBundle != slack.BundleID || e.Delivery != "insert" {
				t.Errorf("inserted: pasted %q, end %+v, entry %s %s %s", pasted, end, e.AppName, e.AppBundle, e.Delivery)
			}
			moved := tc.into.PID != slack.PID
			if moved && (e.InsertedBundle != tc.into.BundleID || e.InsertedName != tc.into.Name) || !moved && (e.InsertedBundle != "" || e.InsertedName != "") {
				t.Errorf("inserted into %q %q, want %+v", e.InsertedBundle, e.InsertedName, tc.into)
			}
			if (presses[0] != nil) != tc.press {
				t.Errorf("auto key %+v, want %v", presses[0], tc.press)
			}
			if tc.kind == store.KindTranscribe && e.RuleID != "g-chat" {
				t.Errorf("rule %q: the start app's group composed it", e.RuleID)
			}
		})
	}
}
