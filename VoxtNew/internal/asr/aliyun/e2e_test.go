package aliyun

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/hehehai/Auralink/internal/asr"
	"github.com/hehehai/Auralink/internal/asr/asrtest"
)

// TestE2E recognises the speech sample on the real service, one model of
// each protocol. AURALINK_E2E=1 and DASHSCOPE_API_KEY (environment or
// ~/.config/auralink-dev/keys.env); never logs the key.
func TestE2E(t *testing.T) {
	asrtest.E2E(t)
	key := asrtest.Key(t, "DASHSCOPE_API_KEY")
	data, err := os.ReadFile(asrtest.SamplePath())
	if err != nil {
		t.Skipf("no speech sample: %v", err)
	}
	pcm, rate, channels, err := asr.ReadWAV(data)
	if err != nil {
		t.Fatal(err)
	}
	if channels != 1 {
		t.Fatalf("the sample has %d channels, want mono", channels)
	}
	for _, model := range []string{"fun-asr-realtime", "qwen3-asr-flash-realtime"} {
		t.Run(model, func(t *testing.T) {
			c, err := New(asr.Config{Key: key, Model: model, Endpoint: os.Getenv("AURALINK_ALIYUN_ENDPOINT")})
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			partials := 0
			r, err := asr.StreamAll(ctx, c, asr.StreamRequest{SampleRate: rate, Lang: "zh", Hints: []string{"Auralink"}}, pcm,
				asr.Feed{Pace: 2, OnPartial: func(string) { partials++ }})
			if err != nil {
				t.Fatalf("%v", err) // *asr.Error never carries the key
			}
			if r.Text == "" {
				t.Fatal("empty text")
			}
			t.Logf("%s (%s): %q, %d partials, latency %s, audio %s", r.Model, c.Protocol(), r.Text, partials, r.Latency, r.Duration)
		})
	}
}
