package deliver

import (
	"context"
	"errors"
	"testing"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
)

type fakeIO struct {
	focus    []proto.FocusResult // one per call; the last repeats
	focusErr error
	paste    proto.PasteResult
	pasteErr error
	pasted   []proto.PasteParams
	calls    int
}

func (f *fakeIO) Focus(context.Context) (proto.FocusResult, error) {
	if f.focusErr != nil {
		return proto.FocusResult{}, f.focusErr
	}
	r := f.focus[min(f.calls, len(f.focus)-1)]
	f.calls++
	return r, nil
}

func (f *fakeIO) Paste(_ context.Context, p proto.PasteParams) (proto.PasteResult, error) {
	f.pasted = append(f.pasted, p)
	return f.paste, f.pasteErr
}

var slack = proto.App{PID: 812, BundleID: "com.tinyspeck.slackmacgap", Name: "Slack"}

func TestInsert(t *testing.T) {
	textArea := proto.FocusResult{PID: 812, Role: "AXTextArea", Editable: true}
	posted := proto.PasteResult{Posted: true, Restored: true}
	for _, tc := range []struct {
		name     string
		req      Request
		io       fakeIO
		inserted bool
		reason   Reason
		pastes   int
		activate bool
	}{
		{name: "pastes", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{textArea}, paste: posted}, inserted: true, pastes: 1},
		{name: "empty", req: Request{Target: slack}, io: fakeIO{focus: []proto.FocusResult{textArea}}, reason: ReasonEmpty},
		{name: "no target", req: Request{Text: "hi"}, io: fakeIO{focus: []proto.FocusResult{textArea}}, reason: ReasonNoTarget},
		{name: "another app in front", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{{PID: 530, Role: "AXTextArea", Editable: true}}}, reason: ReasonNotFront},
		{name: "nothing focused", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{{PID: 812}}}, reason: ReasonNotEditable},
		{name: "a button", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXButton"}}}, reason: ReasonNotEditable},
		{name: "a button, the user chose", req: Request{Text: "hi", Target: slack, AnyEditable: true}, io: fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXButton"}}, paste: posted}, inserted: true, pastes: 1},
		{name: "a web area may be an editor", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXWebArea"}}, paste: posted}, inserted: true, pastes: 1},
		{name: "a selection needs an editable element", req: Request{Text: "hi", Target: slack, NeedEditable: true}, io: fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXWebArea"}}}, reason: ReasonNotEditable},
		{name: "an editable selection", req: Request{Text: "hi", Target: slack, NeedEditable: true}, io: fakeIO{focus: []proto.FocusResult{textArea}, paste: posted}, inserted: true, pastes: 1},
		{name: "AX could not tell", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{{PID: 812, Error: "-25212"}}, paste: posted}, inserted: true, pastes: 1},
		{name: "front changed before the paste", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{textArea}, paste: proto.PasteResult{Front: &proto.App{PID: 530, Name: "TextEdit"}}}, reason: ReasonNotFront, pastes: 1},
		{name: "no accessibility", req: Request{Text: "hi", Target: slack}, io: fakeIO{focusErr: &proto.Error{Code: proto.CodePermissionDenied, Message: "no"}}, reason: ReasonNoAccess},
		{name: "paste refused", req: Request{Text: "hi", Target: slack}, io: fakeIO{focus: []proto.FocusResult{textArea}, pasteErr: &proto.Error{Code: proto.CodePermissionDenied}}, reason: ReasonNoAccess, pastes: 1},
		{name: "helper gone", req: Request{Text: "hi", Target: slack}, io: fakeIO{focusErr: errors.New("helper exited")}, reason: ReasonFailed},
		{name: "VoxtNew in front: activate the target", req: Request{Text: "hi", Target: slack, Self: 77, Activate: func(int) bool { return true }},
			io: fakeIO{focus: []proto.FocusResult{{PID: 77, Role: "AXWindow"}, textArea}, paste: posted}, inserted: true, pastes: 1, activate: true},
		{name: "VoxtNew in front, activation failed", req: Request{Text: "hi", Target: slack, Self: 77, Activate: func(int) bool { return false }},
			io: fakeIO{focus: []proto.FocusResult{{PID: 77}}}, reason: ReasonNotFront},
	} {
		io := tc.io
		res := Insert(context.Background(), &io, tc.req)
		if res.Inserted != tc.inserted || res.Reason != tc.reason || len(io.pasted) != tc.pastes || res.Activated != tc.activate {
			t.Errorf("%s: %+v (pastes %d)", tc.name, res, len(io.pasted))
		}
		if len(io.pasted) > 0 && (io.pasted[0].TargetPID != 812 || io.pasted[0].Text != "hi") {
			t.Errorf("%s: pasted %+v", tc.name, io.pasted[0])
		}
	}
}

func TestInsertPassesPolicy(t *testing.T) {
	io := &fakeIO{focus: []proto.FocusResult{{PID: 812, Editable: true}}, paste: proto.PasteResult{Posted: true}}
	Insert(context.Background(), io, Request{Text: "x", Target: slack, Press: []proto.KeyPress{{Key: 36}}, PressDelayMS: 200, KeepClipboard: true, RestoreDelayMS: 800})
	p := io.pasted[0]
	if len(p.Press) != 1 || p.Press[0].Key != 36 || p.PressDelayMS != 200 || !p.KeepClipboard || p.RestoreDelayMS != 800 {
		t.Errorf("params %+v", p)
	}
}

func TestCheck(t *testing.T) {
	io := &fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXTextArea", Editable: true}}}
	if res := Check(context.Background(), io, Request{Text: "x", Target: slack}); res.Reason != ReasonNone || res.Inserted || len(io.pasted) != 0 {
		t.Errorf("check %+v, pasted %d", res, len(io.pasted))
	}
	activated := false
	io = &fakeIO{focus: []proto.FocusResult{{PID: 77}}}
	res := Check(context.Background(), io, Request{Text: "x", Target: slack, Self: 77, Activate: func(int) bool { activated = true; return true }})
	if res.Reason != ReasonNotFront || activated || len(io.pasted) != 0 {
		t.Errorf("check with VoxtNew in front %+v (activated %v)", res, activated)
	}
	io = &fakeIO{focus: []proto.FocusResult{{PID: 812, Role: "AXButton"}}}
	if res := Check(context.Background(), io, Request{Text: "x", Target: slack}); res.Reason != ReasonNotEditable {
		t.Errorf("check a button %+v", res)
	}
}
