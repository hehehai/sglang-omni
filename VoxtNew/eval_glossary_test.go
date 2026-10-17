package main

// TestEvalGlossary: does the clean-up write the dictionary's terms when
// the speech model got them wrong? Each dictionary clip's transcript as a
// speech model wrote it without the dictionary (eval.Clip.Heard) goes
// through Transcribe's clean-up with the whole eval dictionary as the
// glossary (and the alias the user noted for Auralink), as it was heard
// and with the dictionary's aliases replaced first (dict.Replace, as the
// session does); clips without terms check that no term is put in where
// none was said (eval_test.go; glossary.md).

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/compose"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/dict"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/eval"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llmrt"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

func TestEvalGlossary(t *testing.T) {
	e := evalSetup(t)
	rt := evalLLMRuntime(t, nil)
	ctx := context.Background()
	var terms []compose.Term
	var dictionary []store.Term
	for _, d := range e.set.Dictionary {
		terms = append(terms, compose.Term{Term: d, Aliases: e.set.Aliases[d]})
		dictionary = append(dictionary, store.Term{Term: d, Aliases: e.set.Aliases[d], Enabled: true})
	}
	var cases []eval.Clip
	for _, c := range e.set.Clips {
		if c.Heard != "" || c.Set == "zh-plain" || c.ID == "en-3" {
			cases = append(cases, c)
		}
	}
	tb := table{head: []string{"model", "input", "terms written", "terms put in unsaid", "median total"}}
	answers := table{head: []string{"model", "input", "clip", "heard", "answer"}}
	for _, id := range e.llms(t, true) {
		b, err := llmrt.NewModel(rt, id, e.dir(t, id))
		if err != nil {
			t.Fatal(err)
		}
		client := &llm.Client{Backend: b}
		for _, aliases := range []bool{false, true} {
			variant := map[bool]string{false: "as heard", true: "aliases replaced"}[aliases]
			written, want, unsaid := 0, 0, 0
			var totals []time.Duration
			for _, c := range cases {
				heard := c.Heard
				if heard == "" {
					heard = c.Text
				}
				if aliases {
					heard = dict.Replace(heard, dictionary)
				}
				in := compose.Input{Task: compose.Transcribe, Cleanup: true, MainLanguage: c.Lang, Glossary: terms, Text: heard}
				req := chatRequest(t, in, true, llm.SkillTranscribeEnhance)
				req.Timeout = 2 * time.Minute
				t0 := time.Now()
				resp, err := client.Chat(ctx, req)
				if err != nil {
					t.Fatalf("%s %s: %v", id, c.ID, err)
				}
				totals = append(totals, time.Since(t0))
				out := compose.Clean(resp.Text, heard)
				found := eval.TermsFound(c.Terms, out)
				written, want = written+len(found), want+len(c.Terms)
				for _, d := range e.set.Dictionary {
					if strings.Contains(out, d) && !strings.Contains(c.Text, d) {
						unsaid++
					}
				}
				answers.add(id, variant, c.ID, mdText(heard), mdText(out))
			}
			tb.add(id, variant, fmt.Sprintf("%d of %d", written, want), unsaid, ms(median(totals)))
			if e.quick && id == llmrt.Balanced && written*2 < want {
				t.Errorf("%s (%s) wrote %d of %d terms, under the quick floor of half", id, variant, written, want)
			}
		}
		rt.Unload()
	}
	e.report(t, "glossary.md", "# The glossary on misheard terms\n\n"+tb.String()+"\n"+answers.String())
}
