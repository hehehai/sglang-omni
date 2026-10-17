package session

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/compose"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/deliver"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

// draftEvery is how often a streaming answer is published at most.
const draftEvery = 40 * time.Millisecond

// answerSchema is Rewrite's JSON answer.
var answerSchema = func() *llm.Schema {
	s := llm.Object(map[string]*llm.Schema{"title": llm.String(), "content": llm.String()}, "title", "content")
	s.Name = "answer"
	return s
}()

// writeInput is Translate's or Rewrite's request to compose: raw and
// selection as write's.
func (r *run) writeInput(raw, selection string) compose.Input {
	in := compose.Input{
		MainLanguage: MainLanguage(r.settings, r.m.cfg.Locale()), OtherLanguages: r.settings.General.OtherLanguages,
		Glossary: r.glossary(), Scene: r.composeScene(), // the group decides whether it applies to the feature (appctx)
	}
	switch r.req.Kind {
	case store.KindTranslate:
		f := r.settings.Features.Translate
		in.Task, in.TaskPrompt, in.TargetLanguage = compose.Translate, f.Prompt, r.m.Current().TargetLanguage
		if selection != "" {
			in.Text, in.Selected = selection, true
		} else {
			in.Text, in.Cleanup = raw, f.Cleanup
		}
	case store.KindRewrite:
		f := r.settings.Features.Rewrite
		in.Task, in.TaskPrompt, in.Cleanup, in.Instruction, in.Text = compose.Rewrite, f.Prompt, f.Cleanup, raw, selection
		in.Previous = r.req.Previous
		// Written from an instruction: an answer with a title; a follow-up
		// answers in plain text, as a conversation does (Voxt's).
		in.Answer = selection == "" && len(in.Previous) == 0
	}
	return in
}

// write is Translate's and Rewrite's language-model step: raw is what
// was said (Translate's speech, Rewrite's instruction; "" when Translate
// translates a selection), selection the selected text. The answer
// streams into the snapshot's Draft (and into the answer card when it
// will end there); a failure ends the session failed, in the card, to
// try again.
func (r *run) write(raw, selection string) {
	cfg := r.m.cfg
	kind := r.req.Kind
	if r.svc.LLM == nil {
		r.endWriteFailed(&Problem{Code: ProblemNoLLM, Err: errors.New("no language model is ready")}, false)
		return
	}
	in := r.writeInput(raw, selection)
	var o finishOpts
	switch kind {
	case store.KindTranslate:
		o.needEditable = selection != ""
		if r.settings.Features.Translate.ShowCard {
			o.card = deliver.ReasonCard
		}
	case store.KindRewrite:
		// Every answer goes to the answer card, which inserts it (or
		// replaces the selection) when asked, and takes follow-ups (Voxt's:
		// a Rewrite result always shows in the card).
		o.card = deliver.ReasonCard
	}
	if r.req.Card {
		o.card = deliver.ReasonCard
	}
	r.m.update(r, func(s *Snapshot) { s.State, s.Selection, s.Card = Composing, selection, o.card != "" && !r.req.Try })

	// Will it insert? If not, the answer streams into the card at once.
	if o.card == "" && !r.req.Try {
		ctx, cancel := context.WithTimeout(r.ctx, cfg.DeliverTime)
		res := deliver.Check(ctx, cfg.Text, deliver.Request{Text: "-", Target: r.req.Target, Self: cfg.Self, NeedEditable: o.needEditable})
		cancel()
		if res.Reason != deliver.ReasonNone && r.ctx.Err() == nil {
			r.logf("info", "the answer goes to the card: %s", res.Reason)
			o.card = res.Reason
			r.m.update(r, func(s *Snapshot) { s.Card, s.Delivery = true, res.Reason })
		}
	}

	llmStart := r.now()
	res, profile, err := r.answer(in)
	llmTime := r.now().Sub(llmStart)
	if r.cancelled.Load() {
		r.endCancelled(nil)
		return
	}
	r.m.update(r, func(s *Snapshot) { s.Profile, s.Timings.LLM = profile, llmTime })
	if err != nil {
		r.logf("warning", "language model %s (%s) failed after %v: %v", r.svc.LLMInfo.ID, r.svc.LLMInfo.Model, llmTime.Round(time.Millisecond), err)
		r.endWriteFailed(&Problem{Code: ProblemLLM, Err: err}, true)
		return
	}
	r.logf("info", "wrote %s in %v", r.logText(res.Content), llmTime.Round(time.Millisecond))
	if res.Content == "" {
		if kind == store.KindTranslate && selection == "" {
			r.finish(Done, &Problem{Code: ProblemNoSpeech}, "", finishOpts{})
			return
		}
		r.endWriteFailed(&Problem{Code: ProblemEmpty, Err: errors.New("the language model answered nothing")}, true)
		return
	}
	r.m.update(r, func(s *Snapshot) { s.Title, s.Draft = res.Title, res.Content })
	r.finish(Done, nil, res.Content, o)
}

// answer asks the model for in's answer, part by part (compose.BuildParts:
// long speech in pieces), each streaming into the snapshot's Draft after
// the parts before it. A Translate part that came back untranslated
// (compose.Untranslated) is asked again with the Strict layer. It
// returns the answer (Content only, but for a JSON answer), the
// composition's profile and the first failure, which fails the whole.
func (r *run) answer(in compose.Input) (compose.Answer, string, error) {
	parts, err := compose.BuildParts(in)
	if err != nil {
		return compose.Answer{}, "", err
	}
	if len(parts) > 1 {
		r.logf("info", "%s of %d characters in %d pieces", in.Task, len([]rune(in.Text)), len(parts))
	}
	profile := parts[0].Profile()
	var strict []compose.Part
	var answers []string
	var title string
	for i, p := range parts {
		a, err := r.ask(in, parts[:i+1], answers)
		if err != nil {
			return compose.Answer{}, profile, err
		}
		if in.Task == compose.Translate && compose.Untranslated(p.Text, a.Content, in.TargetLanguage) && r.ctx.Err() == nil {
			r.logf("warning", "the translation looks untranslated: asking again, strictly")
			draft := compose.JoinParts(parts, answers)
			r.m.update(r, func(s *Snapshot) { s.Retried, s.Draft = true, draft })
			if strict == nil {
				in.Strict = true
				strict, err = compose.BuildParts(in)
				in.Strict = false
			}
			var again compose.Answer
			if err == nil {
				again, err = r.ask(in, strict[:i+1], answers)
			}
			if err == nil {
				a, profile = again, strict[i].Profile()
			} else if r.ctx.Err() == nil {
				r.logf("warning", "the strict retry failed, keeping the first answer: %v", err)
			}
		}
		answers = append(answers, a.Content)
		title = a.Title
	}
	return compose.Answer{Title: title, Content: compose.JoinParts(parts, answers)}, profile, nil
}

// ask sends the last of parts and streams its answer into the snapshot,
// after the answers of the parts before it.
func (r *run) ask(in compose.Input, parts []compose.Part, answers []string) (compose.Answer, error) {
	cfg := r.m.cfg
	p := parts[len(parts)-1]
	skill := llm.SkillTranslateText
	if in.Task == compose.Rewrite {
		skill = llm.SkillRewrite
	}
	draft := newDrafter(r, parts, answers)
	draft.json = in.Answer
	req := llm.Request{Messages: llmMessages(p.Output), Skill: skill, Timeout: cfg.WriteTimeout, OnDelta: draft.add}
	if in.Answer {
		req.Format, req.Schema = llm.FormatJSON, answerSchema
	}
	if in.Task == compose.Translate {
		// For a model that builds its own prompt and takes no clean-up
		// rules (Hy-MT2): speech without its fillers (docs/eval.md).
		text := p.Text
		if !in.Selected {
			text = compose.StripFillers(text)
		}
		req.Translate = &llm.TranslateHint{Text: text, Target: in.TargetLanguage}
	}
	ctx, cancel := context.WithTimeout(r.ctx, cfg.WriteTimeout)
	defer cancel()
	resp, err := r.svc.LLM.Chat(ctx, req)
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded && r.ctx.Err() == nil {
			err = fmt.Errorf("no answer within %v: %w", cfg.WriteTimeout, err)
		}
		return compose.Answer{}, err
	}
	if draft.buf.Len() > 0 {
		draft.publish()
	}
	if in.Answer {
		if a, ok := compose.ParseAnswer(resp.Text); ok {
			return a, nil
		}
		r.logf("warning", "the answer is not the JSON asked for: taking it as text")
		return compose.Answer{Content: compose.Clean(strings.TrimSpace(strings.Trim(strings.TrimSpace(resp.Text), "`")), in.Instruction)}, nil
	}
	return compose.Answer{Content: compose.Clean(resp.Text, p.Text)}, nil
}

// endWriteFailed ends a Translate or Rewrite session failed. With card,
// the answer card shows the error and offers to try again (not for a
// try); the entry is kept whatever the recording's length: it holds the
// text.
func (r *run) endWriteFailed(p *Problem, card bool) {
	r.cancel()
	r.logf("warning", "failed: %s: %v", p.Code, p.Err)
	total := r.now().Sub(r.m.Current().StartedAt)
	r.m.end(r, Failed, func(s *Snapshot) {
		s.Problem, s.Timings.Total = p, total
		s.Card = card && !r.req.Try
		s.Draft = ""
	}, func(s Snapshot) { r.keep(s, store.StatusFailed) })
}
