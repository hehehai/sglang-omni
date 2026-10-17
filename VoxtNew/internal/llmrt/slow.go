package llmrt

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llmrt/wire"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
)

// A chat is slow, and its log line says how the Mac's memory stood, when
// its first token took longer than slowFirstToken (its model's load
// aside) or it wrote slower than slowTokensPerSecond (behavior.md 5.5).
// A model whose weights were swapped out writes 2–2.5 times slower.
const (
	slowFirstToken      = 3 * time.Second
	slowTokensPerSecond = 15
	slowMinTokens       = 20 // fewer tokens give no steady rate
)

// The Mac's memory and a process's, read for the log; tests replace them.
var (
	readSystemMemory = macx.ReadSystemMemory
	processMemory    = macx.Memory
)

func slow(r wire.ChatResult) bool {
	first := time.Duration((r.Timings.FirstTokenMs - r.Timings.LoadMs) * float64(time.Millisecond))
	return first > slowFirstToken || r.Usage.CompletionTokens >= slowMinTokens && r.Timings.TokensPerSecond < slowTokensPerSecond
}

// stopped: ctx ended a chat by a deadline (the attempt's, or a progress
// deadline of llm.Client), not by a cancel.
func stopped(ctx context.Context) bool {
	return ctx.Err() != nil && !errors.Is(context.Cause(ctx), context.Canceled)
}

// stoppedLine is the log's line of a chat a deadline stopped: how far it
// got, and the memory of the Mac and of the process.
func (b *Backend) stoppedLine(skill llm.Skill, s streamStats, before macx.SystemMemory) string {
	var line strings.Builder
	fmt.Fprintf(&line, "%s %s stopped after %.1f s without an answer: ", b.profile.ID, skill, s.elapsed.Seconds())
	if s.deltas == 0 {
		line.WriteString("nothing streamed")
	} else {
		fmt.Fprintf(&line, "%d pieces streamed, the first after %.1f s, the last %.1f s before the stop", s.deltas, s.first.Seconds(), (s.elapsed - s.last).Seconds())
	}
	line.WriteString("; " + systemLine(before, s.longestGap))
	if pid := b.rt.Status().PID; pid > 0 {
		if m, err := processMemory(pid); err == nil {
			fmt.Fprintf(&line, "; voxtnew-llm footprint %d MB, resident %d MB", m.Footprint>>20, m.Resident>>20)
		}
	}
	return line.String()
}

// systemLine is the Mac's memory now, and the pages swapped in since
// before (the chat's start).
func systemLine(before macx.SystemMemory, longestGap time.Duration) string {
	now, err := readSystemMemory()
	if err != nil {
		return fmt.Sprintf("the longest wait between two pieces %.1f s; the Mac's memory unknown (%v)", longestGap.Seconds(), err)
	}
	line := fmt.Sprintf("the longest wait between two pieces %.1f s; %s", longestGap.Seconds(), now)
	if before.Swapins > 0 && now.Swapins >= before.Swapins {
		line += fmt.Sprintf(", %d pages swapped in during the chat", now.Swapins-before.Swapins)
	}
	return line
}

// streamStats are a chat's deltas: how many, when the first and the last
// came (from its start) and the longest wait between two.
type streamStats struct {
	deltas               int
	first, last, elapsed time.Duration
	longestGap           time.Duration
}

// deltaPump hands chat.delta texts from the reader goroutine to the
// caller's, without blocking the reader, and times them.
type deltaPump struct {
	mu     sync.Mutex
	texts  []string
	signal chan struct{}
	start  time.Time
	timing streamStats
}

func (d *deltaPump) push(m wire.Message) {
	var p wire.DeltaParams
	if m.Method != wire.MethodChatDelta || m.DecodeParams(&p) != nil || p.Text == "" {
		return
	}
	at := time.Since(d.start)
	d.mu.Lock()
	d.texts = append(d.texts, p.Text)
	t := &d.timing
	if t.deltas == 0 {
		t.first = at
	} else {
		t.longestGap = max(t.longestGap, at-t.last)
	}
	t.deltas++
	t.last = at
	d.mu.Unlock()
	select {
	case d.signal <- struct{}{}:
	default:
	}
}

// deliver passes the texts so far to fn (nil: drops them).
func (d *deltaPump) deliver(fn func(string)) {
	d.mu.Lock()
	texts := d.texts
	d.texts = nil
	d.mu.Unlock()
	if fn == nil {
		return
	}
	for _, t := range texts {
		fn(t)
	}
}

// stats are the deltas' timing so far.
func (d *deltaPump) stats() streamStats {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.timing
	s.elapsed = time.Since(d.start)
	return s
}
