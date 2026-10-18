package main

import (
	"testing"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/deliver"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/session"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
)

// TestSessionSwitchedApp: the shortcut is pressed in Slack, then the user
// goes to another app. A text field focused there gets the result (the
// history names that app); nothing focused (Finder's desktop) or a
// password field leaves it in the answer card, saying why.
func TestSessionSwitchedApp(t *testing.T) {
	for _, tc := range []struct {
		name, opts string
		into       string // the app it went into; "": the card
		why        string
		reason     deliver.Reason
	}{
		{name: "a text field", opts: "switch=com.apple.TextEdit", into: "TextEdit"},
		{name: "nothing focused", opts: "switch=com.apple.finder,focus=none", reason: deliver.ReasonNotEditable,
			why: "No text field is focused: click where it should go, then insert, or copy it."},
		{name: "a password field", opts: "switch=com.apple.TextEdit,focus=secure", reason: deliver.ReasonSecure,
			why: "A password field is focused, and VoxtNew never types into one: copy it, or click another field and insert."},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger), hotkeyLine(400, "transcribe/0", proto.PhaseTrigger))
			a := newSessionApp(t, tc.opts+","+ev, func(s *settings.Settings) {
				s.Features.Transcribe.Enhance = false
			}, &fakeLocal{ASRP: fakeStreamer{final: "你好"}})
			a.pump("the end", func() bool { return a.sess.State.Ended() })
			end := a.sess
			if end.State != session.Done || end.Target.Name != "Slack" {
				t.Fatalf("end %+v", end)
			}
			if tc.into == "" {
				if end.Inserted || !end.Card || end.Delivery != tc.reason || len(a.pasted()) != 0 || !a.answer.open || a.answer.why != tc.why {
					t.Errorf("card: end %+v, pasted %+v, card %+v", end, a.pasted(), a.answer)
				}
				return
			}
			p := a.pasted()
			if !end.Inserted || end.InsertedInto.Name != tc.into || len(p) != 1 || p[0].TargetPID != 530 || p[0].Text != "你好" {
				t.Errorf("end %+v, pasted %+v", end, p)
			}
			a.pump("the history", func() bool { return len(a.history()) == 1 })
			if e := a.history()[0]; e.AppName != tc.into || e.AppBundle != "com.apple.TextEdit" || e.Delivery != "insert" {
				t.Errorf("history %s %s %s", e.AppName, e.AppBundle, e.Delivery)
			}
		})
	}
}
