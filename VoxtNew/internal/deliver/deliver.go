// Package deliver puts a result where the user was typing (plan §4.1):
// one insert transaction through the helper's text I/O. When the app the
// session started in is still in front and its focused element takes
// text, the result is pasted there (textio.paste: the clipboard is
// snapshotted, written, ⌘V posted, keys pressed after it, the clipboard
// restored unless someone wrote to it meanwhile). Otherwise nothing is
// typed and the caller shows the answer card, which offers Insert and
// Copy. When Auralink itself came to the front (a click on its window),
// the target is activated again first (macx.Activate).
//
// Policy is here, the mechanics in the helper: the restore delay, the
// keys after the paste and whether the clipboard keeps the text are
// params of textio.paste.
//
// Imports: helper/proto.
package deliver

import (
	"context"
	"errors"
	"time"

	"github.com/hehehai/Auralink/internal/helper/proto"
)

// TextIO is the helper's text I/O (textio.focus, textio.paste).
type TextIO interface {
	Focus(ctx context.Context) (proto.FocusResult, error)
	Paste(ctx context.Context, p proto.PasteParams) (proto.PasteResult, error)
}

// Reason says why a result was not inserted.
type Reason string

const (
	ReasonNone Reason = ""
	// ReasonEmpty: there was no text.
	ReasonEmpty Reason = "empty"
	// ReasonNoTarget: the app the session started in is not known.
	ReasonNoTarget Reason = "noTarget"
	// ReasonNotFront: another app is in front now.
	ReasonNotFront Reason = "notFront"
	// ReasonNotEditable: the focused element takes no text (or nothing
	// has the focus).
	ReasonNotEditable Reason = "notEditable"
	// ReasonNoAccess: Auralink may not post keys (Accessibility).
	ReasonNoAccess Reason = "noAccess"
	// ReasonFailed: the helper failed (Result.Err).
	ReasonFailed Reason = "failed"
	// ReasonCard: the result goes to the answer card by choice (Translate's
	// "Show the result in a card"), or always (Rewrite, Voxt's); ReasonLong
	// was 0.1.0's: an answer longer than the card's limit. The session sets
	// these, not Insert.
	ReasonCard Reason = "card"
	ReasonLong Reason = "long" // 0.1.0's (the history may hold it)
)

// Request is one insert.
type Request struct {
	Text string
	// Target is the app the session started in (hotkey.event's front).
	Target proto.App
	// Press are keys posted after the paste (app enhancement's auto key,
	// M5), PressDelayMS after it (0: the helper's 120).
	Press        []proto.KeyPress
	PressDelayMS int
	// KeepClipboard leaves the text on the clipboard; RestoreDelayMS
	// waits before restoring it (0: the helper's 500).
	KeepClipboard  bool
	RestoreDelayMS int
	// Self is Auralink's pid. When Auralink is in front, Activate (nil:
	// none) gives the front back to Target before pasting.
	Self     int
	Activate func(pid int) bool
	// AnyEditable skips the check of the focused element (the answer
	// card's Insert: the user looked and chose). NeedEditable asks for an
	// element Accessibility calls editable, not one that may be (text
	// selected on a web page must not be "replaced" by a paste that
	// goes nowhere).
	AnyEditable  bool
	NeedEditable bool
}

// Result is what happened.
type Result struct {
	Inserted bool
	Reason   Reason
	// Front is the app in front when the result was not inserted.
	Front     proto.App
	Focus     proto.FocusResult
	Paste     proto.PasteResult
	Activated bool // the target was activated again first
	Err       error
	Elapsed   time.Duration
}

// nonText are focused roles that never take text.
var nonText = map[string]bool{
	"AXButton": true, "AXCheckBox": true, "AXRadioButton": true, "AXPopUpButton": true, "AXMenuButton": true,
	"AXMenuItem": true, "AXMenuBarItem": true, "AXImage": true, "AXList": true, "AXOutline": true, "AXTable": true,
	"AXRow": true, "AXCell": true, "AXSlider": true, "AXTabGroup": true, "AXToolbar": true, "AXDisclosureTriangle": true,
	"AXIncrementor": true, "AXColorWell": true, "AXSplitter": true, "AXStaticText": true, "AXLink": true, "AXHeading": true,
}

// Writable says whether a focused element takes text: an editable one,
// or one Auralink cannot tell (no Accessibility answer, a web area, a
// group: contenteditable editors look so), but not nothing at all, nor a
// button, a list or another control that never does.
func Writable(f proto.FocusResult) bool {
	if f.Editable || f.Error != "" {
		return true
	}
	if f.Role == "" {
		return false
	}
	return !nonText[f.Role]
}

// Insert pastes r.Text into r.Target when it can (see the package
// comment). Call it off the main thread: it waits for the helper.
func Insert(ctx context.Context, io TextIO, r Request) Result {
	start := time.Now()
	res := insert(ctx, io, r)
	res.Elapsed = time.Since(start)
	return res
}

// Check tells, without pasting or activating anything, whether Insert
// would paste now (Result.Reason is "" when it would). Sessions ask it
// before a long answer, to stream it into the answer card at once when
// it cannot be inserted.
func Check(ctx context.Context, io TextIO, r Request) Result {
	start := time.Now()
	r.Activate = nil
	res := check(ctx, io, r)
	res.Elapsed = time.Since(start)
	return res
}

func insert(ctx context.Context, io TextIO, r Request) Result {
	res := check(ctx, io, r)
	if res.Reason != ReasonNone {
		return res
	}
	p, err := io.Paste(ctx, proto.PasteParams{
		Text: r.Text, KeepClipboard: r.KeepClipboard, RestoreDelayMS: r.RestoreDelayMS,
		TargetPID: r.Target.PID, Press: r.Press, PressDelayMS: r.PressDelayMS,
	})
	if err != nil {
		return failed(res, err)
	}
	res.Paste = p
	if !p.Posted {
		res.Reason = ReasonNotFront
		if p.Front != nil {
			res.Front = *p.Front
		}
		return res
	}
	res.Inserted = true
	return res
}

// check is Insert up to the paste.
func check(ctx context.Context, io TextIO, r Request) Result {
	var res Result
	if r.Text == "" {
		res.Reason = ReasonEmpty
		return res
	}
	if r.Target.PID == 0 {
		res.Reason = ReasonNoTarget
		return res
	}
	focus, err := io.Focus(ctx)
	if err != nil {
		return failed(res, err)
	}
	if focus.PID != r.Target.PID && r.Self != 0 && focus.PID == r.Self && r.Target.PID != r.Self && r.Activate != nil {
		if r.Activate(r.Target.PID) {
			res.Activated = true
			if focus, err = io.Focus(ctx); err != nil {
				return failed(res, err)
			}
		}
	}
	res.Focus = focus
	if focus.PID != r.Target.PID {
		res.Reason, res.Front = ReasonNotFront, proto.App{PID: focus.PID}
		return res
	}
	switch {
	case r.AnyEditable:
	case r.NeedEditable && !focus.Editable, !Writable(focus):
		res.Reason = ReasonNotEditable
	}
	return res
}

// failed records a helper error: Accessibility refused, or another one.
func failed(res Result, err error) Result {
	res.Err = err
	res.Reason = ReasonFailed
	var pe *proto.Error
	if errors.As(err, &pe) && pe.Code == proto.CodePermissionDenied {
		res.Reason = ReasonNoAccess
	}
	return res
}
