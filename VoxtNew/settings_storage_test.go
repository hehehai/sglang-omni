package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/datadir"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
)

// TestStorageModels: Settings → Storage shows the shared model folder and
// VoxtNew's part of it; erasing keeps the models other apps use, and
// removes VoxtNew's files from the family directory.
func TestStorageModels(t *testing.T) {
	a, _, tt := newTestApp(t)
	seedModels(t, a, models.ASRFast, models.VADSilero, models.LLMTranslate)
	useModels(t, a, models.ASRFast, models.VADSilero, models.LLMTranslate)
	claimFor(t, a, audioSmithID, models.ASRFast)
	a.navigate("/settings/storage")
	frames(tt)
	r := a.stReport
	fast, _ := models.Lookup(models.ASRFast)
	vad, _ := models.Lookup(models.VADSilero)
	tr, _ := models.Lookup(models.LLMTranslate)
	if r == nil || r.modelsShared != fast.Size() || r.modelsMine != vad.Size()+tr.Size() {
		t.Fatalf("usage: %+v (want shared %d, mine %d)", r, fast.Size(), vad.Size()+tr.Size())
	}
	for _, s := range []string{"Model folder", "Shared by all ActNow apps", "Only VoxtNew", "Shared with other ActNow apps"} {
		if !has(tt, s) {
			t.Errorf("no %q", s)
		}
	}
	for _, c := range r.cats {
		if c.id == "other" && c.bytes > 100<<20 {
			t.Errorf("the data folder counts the model library: %d", c.bytes)
		}
	}

	relaunched := false
	old := appRelaunch
	appRelaunch = func() { relaunched = true }
	defer func() { appRelaunch = old }()
	tt.SetSize(windowWidth, 1400)
	click(t, tt, "Erase…")
	if !has(tt, "These models are also used by other ActNow apps and will be kept: Fast speech recognition (712.8 MB)") {
		t.Fatalf("no kept models: %q", tt.Texts())
	}
	a.resetText = "DELETE"
	click(t, tt, "Erase and restart")
	if !relaunched {
		t.Fatal("no restart")
	}
	if !onDisk(a, models.ASRFast) || onDisk(a, models.LLMTranslate) || onDisk(a, models.VADSilero) {
		t.Errorf("on disk after erase: fast %v, translate %v, vad %v", onDisk(a, models.ASRFast), onDisk(a, models.LLMTranslate), onDisk(a, models.VADSilero))
	}
	if _, err := os.Stat(a.fam.Dir().ClaimsFile(a.fam.BundleID())); !os.IsNotExist(err) {
		t.Errorf("claims file: %v", err)
	}
	if _, err := os.Stat(filepath.Join(a.home(), datadir.ResetFile)); err != nil {
		t.Errorf("no reset: %v", err)
	}
}
