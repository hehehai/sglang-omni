package session

import (
	"context"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/vad"
)

// The voice activity model (Services.VAD: Silero on the Omni runtime)
// finds the speech where it is there; the energy detector stays the
// fallback when there is no model or it fails. Either way the settings'
// VAD.Off turns detection off.

// Bounds of the model's calls: opening a stream's detector (it may start
// its server), and finding the speech in a whole recording.
const (
	vadOpenTimeout   = 3 * time.Second
	vadSpeechTimeout = 5 * time.Second
)

// gate is the gate a streaming service's audio goes through (the
// leading silence held back), nil when the detection is off; with the
// model's stream detector when there is one (close it at the end).
func (r *run) gate() (*vad.Gate, func()) {
	p, ok := r.vadParams()
	if !ok {
		return nil, func() {}
	}
	g := vad.NewGate(asr.SampleRate, p)
	if r.svc.VAD == nil {
		return g, func() {}
	}
	ctx, cancel := context.WithTimeout(r.ctx, vadOpenTimeout)
	defer cancel()
	ms, err := r.svc.VAD.Open(ctx)
	if err != nil {
		if r.ctx.Err() == nil {
			r.logf("warning", "voice activity model: %v; using the energy detector", err)
		}
		return g, func() {}
	}
	g.UseModel(ms)
	return g, ms.Close
}

// noteGate logs how the stream's detection went.
func (r *run) noteGate(g *vad.Gate) {
	if err := g.ModelErr(); err != nil {
		r.logf("warning", "voice activity model failed during the recording (%v): the energy detector went on", err)
	}
}

// modelAnalysis is the model's speech in the recording pcm (energy is
// the energy detector's analysis of it, kept for the log's levels);
// false without a model or when it fails.
func (r *run) modelAnalysis(pcm []byte, energy vad.Analysis) (vad.Analysis, bool) {
	if r.svc.VAD == nil {
		return vad.Analysis{}, false
	}
	ctx, cancel := context.WithTimeout(r.ctx, vadSpeechTimeout)
	defer cancel()
	segs, err := r.svc.VAD.Speech(ctx, pcm, asr.SampleRate)
	if err != nil {
		if r.ctx.Err() == nil {
			r.logf("warning", "voice activity model: %v; using the energy detector", err)
		}
		return vad.Analysis{}, false
	}
	an := vad.FromSegments(segs, len(pcm)/2, energy)
	r.logf("info", "voice activity model: %d segments", len(an.Segments))
	return an, true
}
