package main

// TestLLMMeasure runs VoxtNew's own prompts (compose) through the real
// voxtnew-llm on a Mac, each twice, and logs what each chat took and
// answered: the first token, the rate, the memory, the text. It is the
// measurement behind docs/llm-models.md (VOXTNEW_LLM_REAL=1 and
// VOXTNEW_DEV_LLM as llm_e2e_test.go's).

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/compose"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llmrt"
)

// measureCase is one request in VoxtNew's shapes.
type measureCase struct {
	name  string
	skill llm.Skill
	in    compose.Input
	json  bool
}

var measureCases = []measureCase{
	{"transcribe zh-en", llm.SkillTranscribeEnhance, compose.Input{Task: compose.Transcribe, Cleanup: true, MainLanguage: "zh",
		Glossary: []compose.Term{{Term: "VoxtNew"}, {Term: "MLX"}},
		Text:     "嗯那个我们下周二呃下周三下午三点开个会讨论一下 voxt new 的发布计划然后 m l x 那边的模型也要一起看一下"}, false},
	{"transcribe en", llm.SkillTranscribeEnhance, compose.Input{Task: compose.Transcribe, Cleanup: true, Structure: true, MainLanguage: "en",
		Text: "so um the first thing is we need to update the docs second we should uh fix the login bug and third let's ship it on friday no wait thursday"}, false},
	{"translate en→zh", llm.SkillTranslateText, compose.Input{Task: compose.Translate, Selected: true, MainLanguage: "zh", TargetLanguage: "zh-Hans",
		Text: "Good morning, team. The release moves to Thursday; please review the checklist in docs/release.md before then."}, false},
	{"translate zh→en (speech)", llm.SkillTranslateText, compose.Input{Task: compose.Translate, Cleanup: true, MainLanguage: "zh", TargetLanguage: "en",
		Text: "呃今天天气真好我们下午三点在会议室见面吧记得带上电脑"}, false},
	{"rewrite selection", llm.SkillRewrite, compose.Input{Task: compose.Rewrite, Cleanup: true, MainLanguage: "en",
		Instruction: "make it more polite and a bit shorter", Text: "send me the report by friday, i told you twice already and it's still not here"}, false},
	{"rewrite answer (JSON)", llm.SkillRewrite, compose.Input{Task: compose.Rewrite, Cleanup: true, MainLanguage: "zh", Answer: true,
		Instruction: "帮我写一条消息告诉团队周五的会议改到下周一上午十点"}, true},
}

func TestLLMMeasure(t *testing.T) {
	if os.Getenv("VOXTNEW_LLM_REAL") != "1" {
		t.Skip("VOXTNEW_LLM_REAL=1 on a Mac, with VOXTNEW_DEV_LLM")
	}
	ms, err := llmrt.ParseDev(os.Getenv(llmrt.DevEnv))
	if err != nil || len(ms) == 0 {
		t.Fatalf("%s: %v", llmrt.DevEnv, err)
	}
	for _, m := range ms {
		t.Run(m.ID, func(t *testing.T) {
			_, l := llmServices(t, &fakeTranscriptions{}, "", m.ID)
			p, _ := llmrt.Lookup(m.ID)
			b, err := llmrt.NewModel(l.rt, m.ID, m.Dir)
			if err != nil {
				t.Fatal(err)
			}
			t0 := time.Now()
			if err := b.Warm(context.Background()); err != nil {
				t.Fatal(err)
			}
			t.Logf("start and load %v; %s", time.Since(t0).Round(time.Millisecond), strings.Join(l.lines("loaded"), " "))
			client := &llm.Client{Backend: b}
			for _, c := range measureCases {
				if p.TranslateOnly() && c.skill != llm.SkillTranslateText {
					continue
				}
				out, err := compose.Build(c.in)
				if err != nil {
					t.Fatal(err)
				}
				req := llm.Request{Skill: c.skill, Timeout: 60 * time.Second}
				for _, msg := range out.Messages() {
					req.Messages = append(req.Messages, llm.Message{Role: llm.Role(msg.Role), Content: msg.Content})
				}
				if c.in.Task == compose.Translate {
					req.Translate = &llm.TranslateHint{Text: c.in.Text, Target: c.in.TargetLanguage}
				}
				for run := 1; run <= 2; run++ {
					before := len(l.lines(m.ID + " "))
					var resp llm.Response
					if c.json {
						resp, err = client.JSON(context.Background(), req, nil, 0)
					} else {
						resp, err = client.Chat(context.Background(), req)
					}
					line := ""
					if ls := l.lines(m.ID + " "); len(ls) > before {
						line = ls[len(ls)-1]
					}
					text := resp.Text
					if c.json && err == nil {
						text = string(resp.JSON)
					}
					if err != nil {
						t.Errorf("%s #%d: %v", c.name, run, err)
						continue
					}
					t.Logf("%s #%d: %s\n    → %s", c.name, run, line, oneLine(compose.Clean(text, c.in.Text)))
				}
			}
			if res, err := l.rt.Memory(context.Background()); err == nil {
				t.Logf("memory: footprint %d MB, peak %d MB, MLX active %d MB, peak %d MB", res.Memory.FootprintBytes>>20,
					res.Memory.PeakFootprintBytes>>20, res.Memory.MLXActiveBytes>>20, res.Memory.MLXPeakBytes>>20)
			}
		})
	}
}

func oneLine(s string) string { return fmt.Sprintf("%q", s) }
