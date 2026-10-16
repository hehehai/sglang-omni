package providers_test

import (
	"context"
	"encoding/binary"
	"math"
	"math/rand/v2"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/providers"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/vad"
)

// TestE2ETrimmedStepFun sends StepFun (step-asr) the speech sample with 3 s
// of a noisy room before and after it and 2 s inside it, once whole and
// once as internal/vad trims it, and checks the trimmed one is recognised
// no worse: two real requests. It runs with VOXTNEW_E2E=1 and
// STEPFUN_API_KEY set.
func TestE2ETrimmedStepFun(t *testing.T) {
	key := os.Getenv("STEPFUN_API_KEY")
	if os.Getenv("VOXTNEW_E2E") != "1" || key == "" {
		t.Skip("set VOXTNEW_E2E=1 and STEPFUN_API_KEY")
	}
	data, err := os.ReadFile("../../testdata/speech/sample-zh-en.wav")
	if err != nil {
		t.Skip(err)
	}
	pcm, rate, ch, err := asr.ReadWAV(data)
	if err != nil || rate != asr.SampleRate || ch != 1 {
		t.Fatalf("sample: %v %d %d", err, rate, ch)
	}
	noisy := noisyVariant(pcm)
	p := vad.Defaults()
	an := vad.Analyze(noisy, asr.SampleRate, p)
	c := vad.Compact(noisy, asr.SampleRate, an, p)
	if !an.Speech || !c.Changed {
		t.Fatalf("not trimmed: %+v", an)
	}
	prov, err := providers.NewASR(settings.Provider{ID: providers.StepFunASR, Enabled: true}, providers.Env{Key: key})
	if err != nil {
		t.Fatal(err)
	}
	ft := prov.(asr.FileTranscriber)
	golden := "今天下午三点开会讨论voxtnew的发布计划pleasesendthemeetingnotestotheteam"
	run := func(name string, audio []byte) float64 {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		start := time.Now()
		res, err := ft.Transcribe(ctx, asr.FileRequest{Audio: audio, Format: "pcm", SampleRate: asr.SampleRate})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		score := overlap(norm(res.Text), golden)
		t.Logf("%s: %v of audio, %v: %q (%.0f%% of the golden text)", name, asr.Duration(audio, asr.SampleRate), time.Since(start).Round(time.Millisecond), res.Text, 100*score)
		return score
	}
	whole := run("whole", noisy)
	trimmed := run("trimmed", c.PCM)
	if trimmed < whole-0.05 {
		t.Errorf("trimmed recognised worse: %.2f < %.2f", trimmed, whole)
	}
}

// noisyVariant is pcm with 3 s before and after it and 2 s at 6.06 s
// (between two words), over white noise at -50 dBFS RMS.
func noisyVariant(pcm []byte) []byte {
	in := make([]float64, len(pcm)/2)
	for i := range in {
		in[i] = float64(int16(binary.LittleEndian.Uint16(pcm[2*i:]))) / 32768
	}
	sec := func(s float64) int { return int(s * asr.SampleRate) }
	var out []float64
	out = append(out, make([]float64, sec(3))...)
	out = append(out, in[:sec(6.06)]...)
	out = append(out, make([]float64, sec(2))...)
	out = append(out, in[sec(6.06):]...)
	out = append(out, make([]float64, sec(3))...)
	r := rand.New(rand.NewPCG(7, 14))
	amp := math.Pow(10, -50.0/20) * math.Sqrt(3) // uniform noise of that RMS
	b := make([]byte, 2*len(out))
	for i, v := range out {
		v += amp * (2*r.Float64() - 1)
		binary.LittleEndian.PutUint16(b[2*i:], uint16(int16(max(-1, min(v, 32767.0/32768))*32768)))
	}
	return b
}

// norm keeps the letters and digits of s, lower case.
func norm(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r > 0x2E80 && !strings.ContainsRune("，。！？：；、“”‘’（）", r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// overlap is the share of want's characters found in order in got (the
// longest common subsequence over len(want)).
func overlap(got, want string) float64 {
	a, b := []rune(got), []rune(want)
	prev := make([]int, len(b)+1)
	for i := range a {
		cur := make([]int, len(b)+1)
		for j := range b {
			if a[i] == b[j] {
				cur[j+1] = prev[j] + 1
			} else {
				cur[j+1] = max(cur[j], prev[j+1])
			}
		}
		prev = cur
	}
	return float64(prev[len(b)]) / float64(len(b))
}
