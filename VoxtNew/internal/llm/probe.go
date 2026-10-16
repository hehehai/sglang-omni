package llm

import (
	"context"
	"time"
)

// ProbeTimeout bounds a Probe.
const ProbeTimeout = 20 * time.Second

// Probe checks that b answers with model ("" its default): one tiny,
// non-streamed request, no retries, at most a few tokens out, so that it
// costs next to nothing and returns fast. An answer cut short by the
// token limit, even an empty one, counts as working; a refused request
// (400, 422: a bad model or parameter) does not and carries the server's
// detail. It returns the request's latency. (Voxt's connection test does
// the same with thinking off and a one-token budget: the preset's
// ExtraBody turns thinking off here.)
func Probe(ctx context.Context, b Backend, model string) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, ProbeTimeout)
	defer cancel()
	req := Request{
		Model:     model,
		Messages:  []Message{{Role: User, Content: "Reply with: ok"}},
		MaxTokens: 8,
		Timeout:   ProbeTimeout,
	}
	start := time.Now()
	_, err := b.Chat(ctx, req)
	if err != nil {
		return 0, ctxErr(ctx, b.Info().ID, err, ProbeTimeout)
	}
	return time.Since(start), nil
}
