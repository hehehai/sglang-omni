package models

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// The Hub and the Hugging Face cache for real (VOXTNEW_MODELS_REAL=1, on
// a Mac with a little room): the VAD downloaded, a part of the fast speech
// model downloaded, stopped, resumed and deleted, and the fast speech
// model adopted from the cache when it is there. Nothing is left behind,
// and the cache is never written.
//
//	VOXTNEW_MODELS_REAL=1 go test -v -run TestReal ./internal/models

func realOnly(t *testing.T) {
	if os.Getenv("VOXTNEW_MODELS_REAL") != "1" {
		t.Skip("set VOXTNEW_MODELS_REAL=1")
	}
}

func TestRealDownloadVAD(t *testing.T) {
	realOnly(t)
	root := t.TempDir()
	m := Open(root, Options{})
	start := time.Now()
	if err := m.Download(VADSilero); err != nil {
		t.Fatal(err)
	}
	s := waitReal(t, m, VADSilero, 2*time.Minute)
	if !s.Installed || s.Err != nil {
		t.Fatalf("%+v", s)
	}
	t.Logf("silero-vad: %d bytes in %v, at %s", s.Total, time.Since(start).Round(time.Millisecond), m.Dir(VADSilero))
	if !Open(root, Options{}).Installed(VADSilero) {
		t.Error("not found again")
	}
	if err := m.Delete(VADSilero); err != nil {
		t.Fatal(err)
	}
}

func TestRealCancelResume(t *testing.T) {
	realOnly(t)
	root := t.TempDir()
	m := Open(root, Options{})
	part := func(minimum int64) Status {
		t.Helper()
		m.Download(ASRFast)
		deadline := time.Now().Add(3 * time.Minute)
		for m.Status(ASRFast).Done < minimum && time.Now().Before(deadline) {
			if s := m.Status(ASRFast); !s.Downloading {
				t.Fatalf("ended: %+v", s)
			}
			time.Sleep(100 * time.Millisecond)
		}
		m.Cancel(ASRFast)
		return m.Status(ASRFast)
	}
	first := part(40 << 20)
	t.Logf("stopped at %d of %d bytes", first.Done, first.Total)
	if first.Downloading || first.Installed || first.Err != nil || first.Done < 40<<20 {
		t.Fatalf("first: %+v", first)
	}
	again := Open(root, Options{}) // a new start sees what was kept
	if got := again.Status(ASRFast).Done; got != first.Done {
		t.Errorf("kept %d, a new start sees %d", first.Done, got)
	}
	second := part(first.Done + 40<<20)
	t.Logf("resumed, stopped at %d", second.Done)
	if second.Done <= first.Done || second.Err != nil {
		t.Fatalf("second: %+v", second)
	}
	if err := m.Delete(ASRFast); err != nil {
		t.Fatal(err)
	}
	m.Delete(VADSilero)
	if ents, _ := os.ReadDir(root); len(ents) != 0 {
		t.Errorf("left: %v", ents)
	}
}

func TestRealAdoptHFCache(t *testing.T) {
	realOnly(t)
	cache := DefaultHFCache()
	mod, _ := Lookup(ASRFast)
	repo := filepath.Join(cache, "models--mlx-community--Qwen3-ASR-0.6B-4bit")
	if _, err := os.Stat(repo); err != nil {
		t.Skip("not in the cache:", err)
	}
	vad, _ := Lookup(VADSilero)
	vadCached := true
	for _, f := range vad.Files {
		vadCached = vadCached && cachedFile(cache, vad, f) != ""
	}
	root := t.TempDir()
	// A Hub that answers nothing: every file must come from the cache
	// (the VAD's too, when the cache has it).
	endpoint := "http://127.0.0.1:9"
	if !vadCached {
		endpoint = ""
	}
	m := Open(root, Options{HFCache: cache, Endpoint: endpoint})
	start := time.Now()
	m.Download(ASRFast)
	s := waitReal(t, m, ASRFast, 3*time.Minute)
	if !s.Installed {
		t.Fatalf("%+v", s)
	}
	t.Logf("adopted in %v (VAD from the cache: %v)", time.Since(start).Round(time.Millisecond), vadCached)
	weights := filepath.Join(m.Dir(ASRFast), "model.safetensors")
	blob, _ := filepath.EvalSymlinks(filepath.Join(repo, "snapshots", mod.Revision, "model.safetensors"))
	var a, b syscall.Stat_t
	if fi, err := os.Lstat(weights); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		t.Logf("weights: a symbolic link")
	} else if syscall.Stat(weights, &a) == nil && syscall.Stat(blob, &b) == nil && a.Ino == b.Ino {
		t.Logf("weights: a hard link to %s (%d links)", blob, a.Nlink)
	} else {
		t.Errorf("weights not linked to the cache's %s", blob)
	}
	if err := m.Delete(ASRFast); err != nil {
		t.Fatal(err)
	}
	m.Delete(VADSilero)
	if fi, err := os.Stat(blob); err != nil || fi.Size() != mod.Files[4].Size {
		t.Errorf("the cache lost its blob: %v", err)
	}
}

func waitReal(t *testing.T, m *Manager, id string, limit time.Duration) Status {
	t.Helper()
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if s := m.Status(id); !s.Downloading {
			return s
		}
		time.Sleep(100 * time.Millisecond)
	}
	m.Cancel(id)
	t.Fatalf("%s: not done in %v: %+v", id, limit, m.Status(id))
	return Status{}
}

// TestRealInstall installs every catalogue model under
// $VOXTNEW_MODELS_INSTALL (its <id>/ folders), adopting the Hugging Face
// cache's verified files first: the persistent models of the Mac's
// regression runs (scripts/mac-regress.sh, ~/voxtnew-models). Models
// already installed there are kept; a stopped download resumes.
//
//	VOXTNEW_MODELS_INSTALL=$HOME/voxtnew-models go test -count=1 -timeout 2h -v -run TestRealInstall ./internal/models
func TestRealInstall(t *testing.T) {
	root := os.Getenv("VOXTNEW_MODELS_INSTALL")
	if root == "" {
		t.Skip("set VOXTNEW_MODELS_INSTALL to the folder to install into")
	}
	m := Open(root, Options{HFCache: DefaultHFCache()})
	defer m.Close()
	for _, mod := range Catalog() {
		if m.Installed(mod.ID) {
			t.Logf("%s: installed", mod.ID)
			continue
		}
		start := time.Now()
		if err := m.Download(mod.ID); err != nil {
			t.Fatalf("%s: %v", mod.ID, err)
		}
		s := waitReal(t, m, mod.ID, 90*time.Minute)
		if !s.Installed || s.Err != nil {
			t.Fatalf("%s: %+v", mod.ID, s)
		}
		t.Logf("%s: %d MB in %v at %s", mod.ID, mod.Size()>>20, time.Since(start).Round(time.Second), m.Dir(mod.ID))
	}
}
