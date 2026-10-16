package models

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCatalog(t *testing.T) {
	seen := map[string]bool{}
	defaults := map[Kind]int{}
	hexRE := regexp.MustCompile(`^[0-9a-f]{64}$`)
	for _, m := range Catalog() {
		if seen[m.ID] {
			t.Errorf("%s twice", m.ID)
		}
		seen[m.ID] = true
		if m.Default {
			defaults[m.Kind]++
		}
		if len(m.Revision) != 40 || m.Repo == "" || len(m.Files) == 0 || m.Size() <= 0 {
			t.Errorf("%s: pin %q %q, %d files", m.ID, m.Repo, m.Revision, len(m.Files))
		}
		for _, f := range m.Files {
			if !hexRE.MatchString(f.SHA256) || f.Size <= 0 || f.Path == "" {
				t.Errorf("%s: file %+v", m.ID, f)
			}
		}
		for _, n := range m.Needs {
			if _, ok := Lookup(n); !ok {
				t.Errorf("%s needs %s, not in the catalogue", m.ID, n)
			}
		}
	}
	for _, k := range []Kind{ASR, LLM, VAD} {
		if defaults[k] != 1 {
			t.Errorf("%d defaults of %s", defaults[k], k)
		}
	}
	for _, id := range []string{ASRAccurate, ASRFast, VADSilero, LLMBalanced, LLMFast, LLMTranslate} {
		if !seen[id] {
			t.Errorf("%s missing", id)
		}
	}
	if m, _ := Lookup(ASRAccurate); !m.Default || m.Repo != "mlx-community/Qwen3-ASR-1.7B-8bit" {
		t.Errorf("accurate: %+v", m)
	}
	if _, ok := Lookup("nope"); ok {
		t.Error("Lookup(nope)")
	}
}

// TestOmniPins: the omni models are pinned as the native runtime's CI
// pins them.
func TestOmniPins(t *testing.T) {
	b, err := os.ReadFile("../../../sglang_omni_mlx/native/ci/models.json")
	if err != nil {
		t.Skip("sglang_omni_mlx/native/ci/models.json not there:", err)
	}
	var pins map[string]struct {
		Revision string            `json:"revision"`
		Files    map[string]string `json:"files"`
	}
	if err := json.Unmarshal(b, &pins); err != nil {
		t.Fatal(err)
	}
	for _, m := range Catalog() {
		if m.Runtime != Omni {
			continue
		}
		p, ok := pins[m.Repo]
		if !ok || p.Revision != m.Revision || len(p.Files) != len(m.Files) {
			t.Errorf("%s: pinned %+v", m.ID, p)
			continue
		}
		for _, f := range m.Files {
			if p.Files[f.Path] != f.SHA256 {
				t.Errorf("%s: %s is %s in models.json", m.ID, f.Path, p.Files[f.Path])
			}
		}
	}
}

// hub is a fake Hub: files by "<repo>/resolve/<rev>/<path>", with
// ranges, and a log of the requests.
type hub struct {
	mu       sync.Mutex
	files    map[string][]byte
	requests []string // "path range"
	// cut, when set, ends a response after so many bytes, once per path.
	cut     int
	cutDone map[string]bool
	// hold, when set, makes responses wait for it after half a file.
	hold     chan struct{}
	held     chan string
	inFlight atomic.Int32
	maxIn    atomic.Int32
}

func (h *hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	n := h.inFlight.Add(1)
	defer h.inFlight.Add(-1)
	for {
		m := h.maxIn.Load()
		if n <= m || h.maxIn.CompareAndSwap(m, n) {
			break
		}
	}
	path := strings.TrimPrefix(r.URL.Path, "/")
	h.mu.Lock()
	h.requests = append(h.requests, path+" "+r.Header.Get("Range"))
	b, ok := h.files[path]
	hold := h.hold
	cut := h.cut > 0 && !h.cutDone[path]
	if cut {
		h.cutDone[path] = true
	}
	h.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	// A first request (no range) of a cut or held file stops half-way;
	// a resumed one is served by ServeContent.
	if (cut || hold != nil) && r.Header.Get("Range") == "" {
		{
			w.Header().Set("Content-Length", strconv.Itoa(len(b)))
			w.WriteHeader(http.StatusOK)
			half := len(b) / 2
			if cut {
				half = min(h.cut, len(b))
			}
			w.Write(b[:half])
			w.(http.Flusher).Flush()
			if !cut {
				h.held <- path
				<-hold
			}
			panic(http.ErrAbortHandler)
		}
	}
	http.ServeContent(w, r, path, time.Time{}, bytes.NewReader(b))
}

func (h *hub) log() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.requests...)
}

// testModel is a model of the given files' contents.
func testModel(id string, contents map[string]string, needs ...string) Model {
	m := Model{ID: id, Kind: ASR, Runtime: Omni, Repo: "org/" + id, Revision: strings.Repeat("a", 40), Needs: needs}
	for _, p := range slices.Sorted(maps.Keys(contents)) {
		sum := sha256.Sum256([]byte(contents[p]))
		m.Files = append(m.Files, File{Path: p, Size: int64(len(contents[p])), SHA256: hex.EncodeToString(sum[:])})
	}
	return m
}

// testSetup replaces the catalogue with a speech model needing a VAD,
// served by a fake Hub.
func testSetup(t *testing.T) (*hub, *httptest.Server, map[string]map[string]string) {
	t.Helper()
	contents := map[string]map[string]string{
		"vad": {"config.json": `{"vad":1}`, "model.safetensors": strings.Repeat("v", 3000)},
		"asr": {"config.json": `{"asr":1}`, "model.safetensors": strings.Repeat("abcdefgh", 40000), "sub/vocab.json": `{"a":1}`},
	}
	vad := testModel("vad", contents["vad"])
	vad.Kind = VAD
	asr := testModel("asr", contents["asr"], "vad")
	saved, savedDelay := catalog, retryDelay
	catalog = []Model{asr, vad}
	retryDelay = func(int) time.Duration { return time.Millisecond }
	t.Cleanup(func() { catalog, retryDelay = saved, savedDelay })
	h := &hub{files: map[string][]byte{}, cutDone: map[string]bool{}}
	for _, m := range catalog {
		for p := range contents[m.ID] {
			h.files[m.Repo+"/resolve/"+m.Revision+"/"+p] = []byte(contents[m.ID][p])
		}
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return h, srv, contents
}

// wait waits until model id's download ended.
func wait(t *testing.T, m *Manager, id string) Status {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if s := m.Status(id); !s.Downloading {
			return s
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s still downloading", id)
	return Status{}
}

func checkInstalled(t *testing.T, root, id string, contents map[string]string) {
	t.Helper()
	for p, want := range contents {
		b, err := os.ReadFile(filepath.Join(root, id, p))
		if err != nil || string(b) != want {
			t.Errorf("%s/%s: %v (%d bytes)", id, p, err, len(b))
		}
	}
	if _, err := os.Stat(filepath.Join(root, id, ManifestFile)); err != nil {
		t.Error(err)
	}
}

func TestDownload(t *testing.T) {
	h, srv, contents := testSetup(t)
	root := t.TempDir()
	var notes atomic.Int32
	m := Open(root, Options{Endpoint: srv.URL, OnChange: func() { notes.Add(1) }})
	if s := m.Status("asr"); s.Installed || s.Downloading || s.Total != catalog[0].Size() {
		t.Fatalf("before: %+v", s)
	}
	if err := m.Download("asr"); err != nil {
		t.Fatal(err)
	}
	s := wait(t, m, "asr")
	if !s.Installed || s.Err != nil {
		t.Fatalf("after: %+v", s)
	}
	if !m.Installed("vad") || m.Dir("asr") != filepath.Join(root, "asr") || m.Dir("nope") != "" {
		t.Errorf("vad %v, dir %q", m.Installed("vad"), m.Dir("asr"))
	}
	checkInstalled(t, root, "asr", contents["asr"])
	checkInstalled(t, root, "vad", contents["vad"])
	if _, err := os.Stat(filepath.Join(root, ".partial", "asr")); !os.IsNotExist(err) {
		t.Errorf("staging left: %v", err)
	}
	if notes.Load() == 0 {
		t.Error("no OnChange")
	}
	if n := len(h.log()); n != 5 {
		t.Errorf("%d requests: %v", n, h.log())
	}
	// A new Manager finds them.
	if m2 := Open(root, Options{Endpoint: srv.URL}); !m2.Installed("asr") || !m2.Installed("vad") {
		t.Error("not found again")
	}
	// Downloading what is installed does nothing.
	m.Download("asr")
	if n := len(h.log()); n != 5 {
		t.Errorf("downloaded again: %d", n)
	}
	// A file gone: no longer installed.
	os.Remove(filepath.Join(root, "asr", "sub", "vocab.json"))
	if Open(root, Options{}).Installed("asr") {
		t.Error("installed without a file")
	}
	if err := m.Download("nope"); !errors.Is(err, ErrUnknown) {
		t.Errorf("unknown: %v", err)
	}
}

func TestDownloadResumes(t *testing.T) {
	h, srv, contents := testSetup(t)
	h.cut = 1000 // each file's first response ends after 1000 bytes
	root := t.TempDir()
	m := Open(root, Options{Endpoint: srv.URL})
	m.Download("asr")
	if s := wait(t, m, "asr"); !s.Installed || s.Err != nil {
		t.Fatalf("%+v", s)
	}
	checkInstalled(t, root, "asr", contents["asr"])
	var resumed bool
	for _, r := range h.log() {
		if strings.HasSuffix(r, "model.safetensors bytes=1000-") {
			resumed = true
		}
	}
	if !resumed {
		t.Errorf("not resumed: %v", h.log())
	}
}

func TestCancelThenResume(t *testing.T) {
	h, srv, contents := testSetup(t)
	h.hold, h.held = make(chan struct{}), make(chan string, 10)
	root := t.TempDir()
	m := Open(root, Options{Endpoint: srv.URL, Parallel: 1})
	m.Download("asr")
	<-h.held // the VAD's first file is half there
	for deadline := time.Now().Add(5 * time.Second); m.Status("asr").Done == 0 && time.Now().Before(deadline); {
		time.Sleep(time.Millisecond)
	}
	if s := m.Status("asr"); !s.Downloading || s.Done == 0 || s.Done >= s.Total {
		t.Errorf("while: %+v", s)
	}
	m.Cancel("asr")
	h.mu.Lock()
	close(h.hold)
	h.hold = nil
	h.mu.Unlock()
	s := m.Status("asr")
	if s.Downloading || s.Installed || s.Err != nil {
		t.Fatalf("cancelled: %+v", s)
	}
	if m.Status("vad").Done == 0 {
		t.Errorf("nothing kept: %+v", m.Status("vad"))
	}
	if Open(root, Options{}).Status("vad").Done == 0 {
		t.Error("a new Manager does not see what was kept")
	}
	m.Download("asr")
	if s := wait(t, m, "asr"); !s.Installed {
		t.Fatalf("%+v", s)
	}
	checkInstalled(t, root, "vad", contents["vad"])
	var ranged bool
	for _, r := range h.log() {
		ranged = ranged || strings.Contains(r, "bytes=")
	}
	if !ranged {
		t.Errorf("no range request: %v", h.log())
	}
}

func TestChecksumMismatch(t *testing.T) {
	h, srv, _ := testSetup(t)
	for p := range h.files {
		if strings.HasSuffix(p, "vad/resolve/"+strings.Repeat("a", 40)+"/model.safetensors") {
			h.files[p] = []byte(strings.Repeat("w", 3000))
		}
	}
	root := t.TempDir()
	m := Open(root, Options{Endpoint: srv.URL})
	m.Download("asr")
	s := wait(t, m, "asr")
	if s.Installed || !errors.Is(s.Err, ErrChecksum) {
		t.Fatalf("%+v", s)
	}
	if m.Installed("vad") {
		t.Error("vad installed")
	}
	part := filepath.Join(partialDir(root, catalog[1]), "model.safetensors.part")
	if _, err := os.Stat(part); !os.IsNotExist(err) {
		t.Errorf("bad part kept: %v", err)
	}
}

func TestHTTPErrorNotRetried(t *testing.T) {
	h, srv, _ := testSetup(t)
	for p := range h.files {
		if strings.Contains(p, "config.json") {
			delete(h.files, p)
		}
	}
	m := Open(t.TempDir(), Options{Endpoint: srv.URL, Parallel: 1})
	m.Download("asr")
	s := wait(t, m, "asr")
	var he *HTTPError
	if !errors.As(s.Err, &he) || he.Status != 404 {
		t.Fatalf("%+v", s)
	}
	n := 0
	for _, r := range h.log() {
		if strings.Contains(r, "config.json") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("config.json asked %d times", n)
	}
	// The next download clears the error.
	m.Download("asr")
	if s := m.Status("asr"); s.Err != nil && s.Downloading {
		t.Errorf("error kept while downloading: %+v", s)
	}
	wait(t, m, "asr")
}

func TestNoSpace(t *testing.T) {
	_, srv, _ := testSetup(t)
	m := Open(t.TempDir(), Options{Endpoint: srv.URL, DiskFree: func(string) int64 { return 100 << 20 }})
	err := m.Download("asr")
	var ns *NoSpaceError
	if !errors.As(err, &ns) || ns.Free != 100<<20 || ns.Need <= catalog[0].Size() {
		t.Fatalf("%v", err)
	}
	if s := m.Status("asr"); s.Downloading || !errors.As(s.Err, &ns) {
		t.Errorf("%+v", s)
	}
}

func TestParallelBound(t *testing.T) {
	h, srv, _ := testSetup(t)
	m := Open(t.TempDir(), Options{Endpoint: srv.URL, Parallel: 2})
	m.Download("asr")
	wait(t, m, "asr")
	if n := h.maxIn.Load(); n > 2 || n < 1 {
		t.Errorf("%d at once", n)
	}
}

func TestDelete(t *testing.T) {
	_, srv, _ := testSetup(t)
	root := t.TempDir()
	m := Open(root, Options{Endpoint: srv.URL})
	m.Download("asr")
	wait(t, m, "asr")
	if err := m.Delete("asr"); err != nil {
		t.Fatal(err)
	}
	if m.Installed("asr") || !m.Installed("vad") {
		t.Error("states")
	}
	if _, err := os.Stat(filepath.Join(root, "asr")); !os.IsNotExist(err) {
		t.Errorf("folder: %v", err)
	}
	if ents, _ := os.ReadDir(root); len(ents) != 1 { // vad
		t.Errorf("left: %v", ents)
	}
	if err := m.Delete("nope"); !errors.Is(err, ErrUnknown) {
		t.Error(err)
	}
}

// TestAdoptHFCache: the files of a Hugging Face cache are linked, not
// downloaded; a file whose hash differs is downloaded; removing the model
// leaves the cache alone.
func TestAdoptHFCache(t *testing.T) {
	h, srv, contents := testSetup(t)
	cache := t.TempDir()
	asr := catalog[0]
	repo := filepath.Join(cache, "models--org--asr")
	snap := filepath.Join(repo, "snapshots", "0123456789")
	os.MkdirAll(filepath.Join(snap, "sub"), 0o755)
	os.MkdirAll(filepath.Join(repo, "blobs"), 0o755)
	for p, c := range contents["asr"] {
		if p == "config.json" {
			c = `{"asr":2}` // another revision's
		}
		blob := filepath.Join(repo, "blobs", strings.ReplaceAll(p, "/", "_"))
		os.WriteFile(blob, []byte(c), 0o644)
		rel, _ := filepath.Rel(filepath.Dir(filepath.Join(snap, p)), blob)
		if err := os.Symlink(rel, filepath.Join(snap, p)); err != nil {
			t.Fatal(err)
		}
	}
	root := t.TempDir()
	m := Open(root, Options{Endpoint: srv.URL, HFCache: cache})
	m.Download("asr")
	if s := wait(t, m, "asr"); !s.Installed {
		t.Fatalf("%+v", s)
	}
	checkInstalled(t, root, "asr", contents["asr"])
	for _, r := range h.log() {
		if strings.Contains(r, asr.Repo) && !strings.Contains(r, "config.json") {
			t.Errorf("downloaded %s", r)
		}
	}
	b, _ := os.ReadFile(filepath.Join(root, "asr", ManifestFile))
	var man manifest
	json.Unmarshal(b, &man)
	if man.Linked != 2 {
		t.Errorf("linked %d", man.Linked)
	}
	if err := m.Delete("asr"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(snap, "model.safetensors")); err != nil || string(b) != contents["asr"]["model.safetensors"] {
		t.Errorf("the cache lost its file: %v", err)
	}
}
