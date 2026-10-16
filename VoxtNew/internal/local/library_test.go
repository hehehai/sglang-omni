package local

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/asr"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models/modelstest"
)

type fakeProvider struct{ asr.FileTranscriber }

func TestLibrary(t *testing.T) {
	root := t.TempDir()
	if err := modelstest.Seed(root, models.ASRFast, models.VADSilero, models.LLMTranslate, models.LLMFast); err != nil {
		t.Fatal(err)
	}
	m := models.Open(root, models.Options{})
	name := func(id string) string { return "name of " + id }
	var s Services = NewLibrary(m, Openers{}, name)

	if l := s.Installed(ASR); len(l) != 1 || l[0].ID != models.ASRFast || l[0].Name != "name of asr.fast" {
		t.Errorf("asr %+v", l)
	}
	llms := s.Installed(LLM)
	if len(llms) != 2 || llms[0].ID != models.LLMFast || llms[1].ID != models.LLMTranslate {
		t.Fatalf("llm %+v", llms)
	}
	if got := ForFeature(llms, "rewrite"); len(got) != 1 || got[0].ID != models.LLMFast {
		t.Errorf("rewrite %+v", got)
	}
	if got := ForFeature(llms, "translate"); len(got) != 2 {
		t.Errorf("translate %+v", got)
	}

	// No runtime: a clear error, not "not installed".
	_, _, err := s.ASR(context.Background(), "")
	if !errors.Is(err, ErrNoRuntime) || errors.Is(err, ErrNotInstalled) {
		t.Errorf("asr without runtime: %v", err)
	}
	if _, _, err := s.LLM(context.Background(), models.LLMBalanced); !errors.Is(err, ErrNoRuntime) {
		t.Errorf("llm without runtime: %v", err)
	}

	// With openers: the installed folder.
	var opened []string
	lib := NewLibrary(m, Openers{
		ASR: func(_ context.Context, id, dir string) (asr.Provider, error) {
			opened = append(opened, id+" "+dir)
			return fakeProvider{}, nil
		},
		LLM: func(_ context.Context, id, dir string) (Chat, error) {
			opened = append(opened, id+" "+dir)
			return nil, errors.New("boom")
		},
	}, nil)
	p, mod, err := lib.ASR(context.Background(), models.ASRAccurate) // not installed: the first
	if err != nil || p == nil || mod.ID != models.ASRFast || mod.Name != models.ASRFast {
		t.Errorf("asr %v %+v %v", p, mod, err)
	}
	if _, _, err := lib.LLM(context.Background(), models.LLMTranslate); err == nil || err.Error() != "boom" {
		t.Errorf("llm %v", err)
	}
	want := []string{models.ASRFast + " " + filepath.Join(root, models.ASRFast), models.LLMTranslate + " " + filepath.Join(root, models.LLMTranslate)}
	if len(opened) != 2 || opened[0] != want[0] || opened[1] != want[1] {
		t.Errorf("opened %q", opened)
	}
	if lib.Dir(models.VADSilero) != filepath.Join(root, models.VADSilero) || lib.Dir(models.ASRAccurate) != "" {
		t.Error("Dir")
	}

	// Nothing installed.
	empty := NewLibrary(models.Open(t.TempDir(), models.Options{}), Openers{}, nil)
	if _, _, err := empty.ASR(context.Background(), ""); !errors.Is(err, ErrNotInstalled) {
		t.Errorf("empty: %v", err)
	}
}

// TestLibraryDelete: the runtime unloads a model before its files go.
func TestLibraryDelete(t *testing.T) {
	root := t.TempDir()
	if err := modelstest.Seed(root, models.ASRFast); err != nil {
		t.Fatal(err)
	}
	m := models.Open(root, models.Options{})
	var unloaded []string
	lib := NewLibrary(m, Openers{Unload: func(id string) {
		if !m.Installed(id) {
			t.Error("unloaded after the delete")
		}
		unloaded = append(unloaded, id)
	}}, nil)
	if err := lib.Delete(models.ASRFast); err != nil {
		t.Fatal(err)
	}
	if len(unloaded) != 1 || unloaded[0] != models.ASRFast || m.Installed(models.ASRFast) {
		t.Errorf("unloaded %q, installed %v", unloaded, m.Installed(models.ASRFast))
	}
	if err := NewLibrary(m, Openers{}, nil).Delete(models.ASRFast); err != nil {
		t.Errorf("no Unload: %v", err)
	}
}
