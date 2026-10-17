package llmrt

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llmrt/llmrttest"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
)

// TestProgressDeadlines: llm.Client's progress deadlines over the real
// process: a late first token and a stall end the chat (cancelled in the
// process, which answers the next chat at once), with a log line that
// says how far it got and how the Mac's memory stood; a slow but steady
// chat passes, its line marked slow.
func TestProgressDeadlines(t *testing.T) {
	readSystemMemory = func() (macx.SystemMemory, error) {
		return macx.SystemMemory{Pressure: "warning", AvailablePercent: 21, SwapUsedBytes: 17 << 30, SwapTotalBytes: 18 << 30}, nil
	}
	t.Cleanup(func() { readSystemMemory = macx.ReadSystemMemory })
	words := strings.Repeat("word ", 20) // 25 pieces
	reply := llmrttest.Opt("reply", words)
	limits := llm.Request{FirstTokenTimeout: 400 * time.Millisecond, StallTimeout: 300 * time.Millisecond, Timeout: 10 * time.Second}
	for _, c := range []struct {
		name, opts string
		wait, log  string // the timeout's wait and a line of the log; wait "" for an answer
	}{
		{"first token late", "first-ms=5000," + reply, llm.WaitFirstToken, "stopped after 0.4 s without an answer: nothing streamed; the longest wait between two pieces 0.0 s; memory pressure warning, 21% available, swap 17.0 of 18.0 GB used"},
		{"stall", "stall-at=3,stall-ms=5000," + reply, llm.WaitStall, "3 pieces streamed, the first after"},
		{"slow but steady", "piece-ms=80," + reply, "", "; slow: the longest wait between two pieces 0."},
	} {
		t.Run(c.name, func(t *testing.T) {
			rt, logs := newRuntime(t, c.opts, nil)
			chat, err := Open(context.Background(), rt, Balanced, mlxDir(t))
			if err != nil {
				t.Fatal(err)
			}
			var streamed strings.Builder
			req := limits
			req.Messages = []llm.Message{{Role: llm.User, Content: "hi"}}
			req.OnDelta = func(d string) { streamed.WriteString(d) }
			t0 := time.Now()
			resp, err := chat.Chat(context.Background(), req)
			took := time.Since(t0)
			var e *llm.Error
			switch {
			case c.wait == "":
				if err != nil || resp.Text != words || took < 1500*time.Millisecond {
					t.Fatalf("%q, %v after %v", resp.Text, err, took)
				}
			case !errors.As(err, &e) || e.Code != llm.CodeTimeout || e.Params["wait"] != c.wait || resp.Attempts != 1:
				t.Fatalf("%+v, %v", resp, err)
			case took > 2*time.Second:
				t.Errorf("took %v", took)
			}
			waitFor(t, "the line "+c.log, func() bool { return logs.has(c.log) })
			if c.wait == "" {
				return
			}
			// The process stopped the chat: the next one is not behind it.
			t0 = time.Now()
			if _, err := chat.Chat(context.Background(), llm.Request{Messages: req.Messages, MaxTokens: 1}); err != nil || time.Since(t0) > 2*time.Second {
				t.Errorf("next chat: %v after %v", err, time.Since(t0))
			}
		})
	}
}
