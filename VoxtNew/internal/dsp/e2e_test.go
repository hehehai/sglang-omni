package dsp

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/asrtest"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr/openai"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/vad"
)

// TestE2EStepFun sends StepFun the speech sample's "quiet + hum" variant
// as a session would without the sound processing (trimmed by the voice
// activity detection alone) and with it: two real requests. It needs
// VOXTNEW_DSP_E2E=1 (VOXTNEW_E2E alone does not run it) and
// STEPFUN_API_KEY.
func TestE2EStepFun(t *testing.T) {
	if os.Getenv("VOXTNEW_DSP_E2E") != "1" {
		t.Skip("set VOXTNEW_DSP_E2E=1 (and STEPFUN_API_KEY) for two real StepFun requests")
	}
	key := asrtest.Key(t, "STEPFUN_API_KEY")
	s := loadSample(t)
	v := variantSpec{"quiet + hum -45 dBFS", -20, func(n int) []float64 { return hum(n, -45) }}
	pcm, _ := v.build(s)

	raw := vad.Analyze(pcm, rate, vad.Params{})
	before := vad.Compact(pcm, rate, raw, vad.Params{})
	f := ProcessFile(pcm, rate, Params{}, vad.Params{})
	after := vad.Compact(f.PCM, rate, f.Analysis, vad.Params{})
	t.Logf("variant %.2f s: without the processing %.2f s sent; with it %.2f s, gain %+.1f dB", float64(len(pcm)/2)/rate, before.Kept.Seconds(), after.Kept.Seconds(), f.Report.GainDB)

	c, err := openai.New(asr.Config{Key: key, Endpoint: "https://api.stepfun.com/v1/audio/transcriptions", Model: "step-asr"})
	if err != nil {
		t.Fatal(err)
	}
	for _, run := range []struct {
		name string
		pcm  []byte
	}{{"without", before.PCM}, {"with", after.PCM}} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		res, err := c.Transcribe(ctx, asr.FileRequest{Audio: run.pcm, Format: "pcm", SampleRate: rate})
		cancel()
		if err != nil {
			t.Fatalf("%s: %v", run.name, err)
		}
		t.Logf("%s the processing (%v): %s", run.name, res.Latency.Round(time.Millisecond), strings.TrimSpace(res.Text))
	}
}
