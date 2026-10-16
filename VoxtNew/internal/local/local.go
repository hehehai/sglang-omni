// Package local is the seam between a session and the models on this
// Mac: which speech and language models are installed, and the clients a
// session uses (internal/asr's FileTranscriber and Streamer, and Chat).
//
// M0 has no local runtime: NotInstalled lists nothing and fails every
// open with ErrNotInstalled, so that a session shows "no model is
// installed" instead of recording for nothing. M1 implements the speech
// side (the Omni native MLX servers of sglang_omni_mlx/native, their
// catalogue and downloads), M2 the language side (the voxtnew-llm
// process: mlx-swift-lm and a few GGUF models); package main swaps its
// Services in (newLocalServices, models_page.go).
//
// Installed reads memory only, so that views may call it while they
// build; ASR and LLM may block (they may start a runtime and load a
// model): call them off the main thread.
//
// Imports: asr, llm.
package local

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llm"
)

// Kind is a kind of model: speech recognition or a language model.
type Kind string

const (
	ASR Kind = "asr"
	LLM Kind = "llm"
)

// Model is one installed model, as a feature chooses it.
type Model struct {
	Kind Kind
	// ID is the model's stable id in the catalogue; settings.Feature's
	// ASR and LLM hold it ("" there: the first installed).
	ID string
	// Name is what the UI shows: a plain description of what it is good
	// at, not its family, size or quantisation (the plan's model policy).
	Name string
}

// Chat is a language model as a session uses it (session.LLM).
type Chat interface {
	Chat(ctx context.Context, req llm.Request) (llm.Response, error)
}

// Services are the local models. Implementations are goroutine-safe.
type Services interface {
	// Installed lists kind's installed models, the recommended one
	// first. Memory only.
	Installed(kind Kind) []Model
	// ASR opens speech model id ("": the first installed): an
	// asr.FileTranscriber, an asr.Streamer, or both. It fails with an
	// error wrapping ErrNotInstalled when the model is not installed.
	ASR(ctx context.Context, id string) (asr.Provider, Model, error)
	// LLM opens language model id ("": the first installed), as ASR.
	LLM(ctx context.Context, id string) (Chat, Model, error)
}

// ErrNotInstalled: the model asked for (or any model of its kind) is not
// installed.
var ErrNotInstalled = errors.New("local: model not installed")

// NotInstalledError is the error of an open whose model is not
// installed; it matches ErrNotInstalled.
func NotInstalledError(kind Kind, id string) error {
	if id == "" {
		return fmt.Errorf("%w: no %s model", ErrNotInstalled, kind)
	}
	return fmt.Errorf("%w: %s model %q", ErrNotInstalled, kind, id)
}

// Choose is the model a feature uses among the installed list: want
// when it is there, else the first; false when the list is empty.
func Choose(list []Model, want string) (Model, bool) {
	want = strings.TrimSpace(want)
	for _, m := range list {
		if m.ID == want {
			return m, true
		}
	}
	if len(list) > 0 {
		return list[0], true
	}
	return Model{}, false
}

// NotInstalled is the Services of VoxtNew before its local runtimes
// exist (M0): nothing is installed, and every open fails with
// ErrNotInstalled.
type NotInstalled struct{}

func (NotInstalled) Installed(Kind) []Model { return nil }

func (NotInstalled) ASR(_ context.Context, id string) (asr.Provider, Model, error) {
	return nil, Model{}, NotInstalledError(ASR, id)
}

func (NotInstalled) LLM(_ context.Context, id string) (Chat, Model, error) {
	return nil, Model{}, NotInstalledError(LLM, id)
}
