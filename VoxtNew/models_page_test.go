package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/hotkey"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/local"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models/modelstest"
)

// seedModels installs the models ids (files of their sizes, no bytes)
// and opens a's models again over them, as a start would.
func seedModels(t *testing.T, a *app, ids ...string) {
	t.Helper()
	if err := modelstest.Seed(a.models.Root(), ids...); err != nil {
		t.Fatal(err)
	}
	reopenModels(a)
}

// reopenModels reads the models on disk again, with the environment's
// options (VOXTNEW_HF_ENDPOINT).
func reopenModels(a *app) {
	a.models.Close()
	a.models, a.local, a.modelStatus = nil, nil, nil
	a.openModels()
}

func TestModelsPage(t *testing.T) {
	a, _, tt := newTestApp(t)
	tt.SetSize(windowWidth, 1600) // every card on screen
	a.navigate(modelsPath)
	for _, s := range []string{"Accurate speech recognition", "Fast speech recognition", "Balanced language model",
		"Fast language model", "Translation model", "Default", "2.5 GB download", "4.0 GB download",
		"30 languages and 22 Chinese dialects, including Chinese, English, Cantonese, Japanese and Korean",
		"Translates between 33 languages, including Chinese, English, Japanese, Korean and Cantonese"} {
		if !has(tt, s) {
			t.Errorf("no %q in %q", s, tt.Texts())
		}
	}
	if has(tt, "Voice detection") || has(tt, "Installed") {
		t.Error("the VAD is listed, or a model is installed")
	}

	// Installed models: the page, the features' choices.
	seedModels(t, a, models.ASRFast, models.VADSilero, models.LLMTranslate)
	if !has(tt, "Installed") || !has(tt, "712.8 MB on disk") {
		t.Errorf("installed: %q", tt.Texts())
	}
	if m, ok := a.featureModel(local.ASR, hotkey.Transcribe); !ok || m.ID != models.ASRFast || m.Name != "Fast speech recognition" {
		t.Errorf("transcribe's speech model %+v", m)
	}
	if m, ok := a.featureModel(local.LLM, hotkey.Translate); !ok || m.ID != models.LLMTranslate {
		t.Errorf("translate's language model %+v", m)
	}
	if m, ok := a.featureModel(local.LLM, hotkey.Rewrite); ok {
		t.Errorf("rewrite uses the translation model: %+v", m)
	}
	a.navigate("/rewrite")
	if !has(tt, "No language model is installed: install one to rewrite.") {
		t.Errorf("rewrite: %q", tt.Texts())
	}
	a.navigate("/translate")
	if !has(tt, "Automatic: Translation model") {
		t.Errorf("translate: %q", tt.Texts())
	}

	// Deleting asks first.
	a.navigate(modelsPath)
	click(t, tt, "Delete Fast speech recognition…")
	if !has(tt, "Delete Fast speech recognition?") || !has(tt, "This frees 712.8 MB. You can download it again later.") {
		t.Fatalf("no confirmation: %q", tt.Texts())
	}
	click(t, tt, "Delete Fast speech recognition")
	if a.models.Installed(models.ASRFast) || a.modelStatus[models.ASRFast].Installed {
		t.Error("still installed")
	}
	if _, err := os.Stat(filepath.Join(a.models.Root(), models.ASRFast)); !os.IsNotExist(err) {
		t.Errorf("folder: %v", err)
	}
	if len(a.installed(local.ASR)) != 0 || a.notes == nil {
		t.Error("installed list")
	}
}

// TestModelDownloadStates: a download in progress (Cancel), stopped
// (Resume), failed (Try again), against a fake Hub.
func TestModelDownloadStates(t *testing.T) {
	release := make(chan struct{})
	var mode atomic.Value // "hold" | "missing"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if mode.Load() == "missing" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Range") != "" {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Length", "1000000000")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(strings.Repeat("x", 100))) // less than any file: the rest never comes
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)
	t.Setenv("VOXTNEW_HF_ENDPOINT", srv.URL)
	free := diskFree
	diskFree = func(string) int64 { return 100 << 30 }
	defer func() { diskFree = free }()
	a, _, tt := newTestApp(t)
	tt.SetSize(windowWidth, 1600)
	drain := queuePosts(a)
	reopenModels(a)
	a.navigate(modelsPath)

	mode.Store("hold")
	click(t, tt, "Download Fast language model")
	deadline := time.Now().Add(5 * time.Second)
	for !has(tt, "Downloading: ") && time.Now().Before(deadline) {
		drain()
	}
	if !has(tt, "Cancel") || !a.modelStatus[models.LLMFast].Downloading {
		t.Fatalf("downloading: %+v %+v %q", a.modelStatus[models.LLMFast], a.models.Status(models.LLMFast), tt.Texts()[25:])
	}
	click(t, tt, "Cancel downloading Fast language model")
	drain()
	st := a.modelStatus[models.LLMFast]
	if st.Downloading || st.Done == 0 || st.Err != nil || !has(tt, "Resume") || !has(tt, "Stopped: ") {
		t.Fatalf("stopped: %+v %q", st, tt.Texts())
	}

	// A failure: what the card says, and Try again.
	mode.Store("missing")
	click(t, tt, "Download Translation model")
	deadline = time.Now().Add(5 * time.Second)
	for !has(tt, "The download server does not have this model.") && time.Now().Before(deadline) {
		drain()
	}
	if !has(tt, "The download server does not have this model.") || !has(tt, "Try again") {
		t.Fatalf("failed: %q", tt.Texts())
	}

	// Deleting what a stopped download kept.
	click(t, tt, "Delete what was downloaded of Fast language model")
	drain()
	if st := a.modelStatus[models.LLMFast]; st.Done != 0 || has(tt, "Resume") {
		t.Errorf("kept: %+v", st)
	}
}
