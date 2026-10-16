package models

// Manager: which models are installed (in memory, read once when it
// opens), and their downloads, each on a goroutine of its own.

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// ErrUnknown: no model of the catalogue has that id.
var ErrUnknown = errors.New("models: unknown model")

// NoSpaceError: the disk has not the room a download needs.
type NoSpaceError struct{ Need, Free int64 }

func (e *NoSpaceError) Error() string {
	return fmt.Sprintf("models: not enough disk space: %d bytes needed, %d free", e.Need, e.Free)
}

// DefaultEndpoints are the Hub, then its mirror, for networks that do not
// reach the Hub.
var DefaultEndpoints = []string{"https://huggingface.co", "https://hf-mirror.com"}

// spareBytes is the room a download leaves free on the disk.
const spareBytes = 512 << 20

// Options configure a Manager; the zero value downloads from the Hub.
type Options struct {
	// Endpoint is the Hub's address (default: DefaultEndpoints, in turn).
	Endpoint string
	// HFCache is a Hugging Face hub cache to adopt verified files from,
	// before downloading ("": none).
	HFCache string
	// Parallel is how many files download at once, across models
	// (default 3).
	Parallel int
	Client   *http.Client
	// Proxy is the default Client's proxy (default: the environment's;
	// the app's: SystemProxy).
	Proxy func(*http.Request) (*url.URL, error)
	// DiskFree is the space free on path's disk (default: statfs).
	DiskFree func(path string) int64
	// OnChange is called after a status changed, on any goroutine; at
	// most every 200 ms while bytes arrive.
	OnChange func()
}

// Status is a model's state.
type Status struct {
	Installed   bool
	Downloading bool
	// Done and Total are a download's bytes (of the model and the models
	// it needs); Done is also what a stopped download kept.
	Done, Total int64
	// Err is the last download's failure, until the next starts.
	Err error
}

// Manager keeps the models under its root. Goroutine-safe.
type Manager struct {
	root  string
	opt   Options
	fetch *fetcher

	mu        sync.Mutex
	installed map[string]bool
	partial   map[string]int64
	errs      map[string]error
	jobs      map[string]*job
	claimed   map[string]bool // models a job is installing (a speech model's VAD: one job)
	lastNote  time.Time
	closed    bool
	diskMu    sync.Mutex // installs and removals, one at a time
}

// job is one download: a model and the models it needs.
type job struct {
	cancel context.CancelFunc
	done   chan struct{}
	total  int64
	files  map[string]int64 // bytes there of each "<id>/<path>"
}

// Open reads which models are installed under root (a little I/O: call
// it while the app starts, not while a view builds).
func Open(root string, opt Options) *Manager {
	endpoints := DefaultEndpoints
	if opt.Endpoint != "" {
		endpoints = []string{opt.Endpoint}
	}
	if opt.Parallel <= 0 {
		opt.Parallel = 3
	}
	if opt.Proxy == nil {
		opt.Proxy = http.ProxyFromEnvironment
	}
	if opt.Client == nil {
		opt.Client = &http.Client{Transport: &http.Transport{
			Proxy:                 opt.Proxy,
			DialContext:           (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: 30 * time.Second,
		}}
	}
	if opt.DiskFree == nil {
		opt.DiskFree = diskFree
	}
	m := &Manager{root: root, opt: opt, installed: map[string]bool{}, partial: map[string]int64{},
		errs: map[string]error{}, jobs: map[string]*job{}, claimed: map[string]bool{},
		fetch: &fetcher{client: opt.Client, endpoints: endpoints, slots: make(chan struct{}, opt.Parallel)}}
	for _, mod := range catalog {
		m.installed[mod.ID] = isInstalled(root, mod)
		if !m.installed[mod.ID] {
			m.partial[mod.ID] = partialBytes(root, mod)
		}
	}
	return m
}

// Root is the folder of the models.
func (m *Manager) Root() string { return m.root }

// Installed says whether model id is installed (memory only).
func (m *Manager) Installed(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.installed[id]
}

// Dir is the folder of model id, "" when it is not installed.
func (m *Manager) Dir(id string) string {
	if !m.Installed(id) {
		return ""
	}
	return modelDir(m.root, id)
}

// Status is model id's state (memory only).
func (m *Manager) Status(id string) Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := Status{Installed: m.installed[id], Err: m.errs[id], Done: m.partial[id]}
	if mod, ok := Lookup(id); ok {
		s.Total = mod.Size()
	}
	if j := m.jobs[id]; j != nil {
		s.Downloading, s.Done, s.Total = true, 0, j.total
		for _, n := range j.files {
			s.Done += n
		}
	}
	return s
}

// Download starts installing model id and the models it needs, unless
// it is installed or downloading. It fails at once when there is not the
// disk space; later failures are the Status's Err.
func (m *Manager) Download(id string) error {
	mod, ok := Lookup(id)
	if !ok {
		return fmt.Errorf("%w: %q", ErrUnknown, id)
	}
	m.mu.Lock()
	if m.closed || m.installed[id] || m.jobs[id] != nil {
		m.mu.Unlock()
		return nil
	}
	var list []Model
	for _, need := range mod.Needs {
		if n, ok := Lookup(need); ok && !m.installed[need] && !m.claimed[need] {
			list = append(list, n)
		}
	}
	list = append(list, mod)
	var total, need int64
	for _, l := range list {
		total += l.Size()
		need += l.Size() - m.partial[l.ID]
	}
	if free := m.opt.DiskFree(m.root); free > 0 && free < need+spareBytes {
		err := &NoSpaceError{Need: need + spareBytes, Free: free}
		m.errs[id] = err
		m.mu.Unlock()
		m.note(true)
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	j := &job{cancel: cancel, done: make(chan struct{}), total: total, files: map[string]int64{}}
	for _, l := range list {
		m.claimed[l.ID] = true
	}
	m.jobs[id] = j
	delete(m.errs, id)
	m.mu.Unlock()
	m.note(true)
	go m.run(ctx, id, j, list)
	return nil
}

// Cancel stops model id's download; what came is kept for the next.
func (m *Manager) Cancel(id string) {
	m.mu.Lock()
	j := m.jobs[id]
	m.mu.Unlock()
	if j != nil {
		j.cancel()
		<-j.done
	}
}

// Delete stops model id's download and removes the model and what came
// of it. It blocks on the disk: call it off the main thread.
func (m *Manager) Delete(id string) error {
	if _, ok := Lookup(id); !ok {
		return fmt.Errorf("%w: %q", ErrUnknown, id)
	}
	m.Cancel(id)
	m.diskMu.Lock()
	err := remove(m.root, id)
	m.diskMu.Unlock()
	m.mu.Lock()
	m.installed[id] = false
	m.partial[id] = 0
	delete(m.errs, id)
	m.mu.Unlock()
	m.note(true)
	return err
}

// Close stops every download (what came is kept).
func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	var ids []string
	for id := range m.jobs {
		ids = append(ids, id)
	}
	m.mu.Unlock()
	for _, id := range ids {
		m.Cancel(id)
	}
}

func (m *Manager) run(ctx context.Context, id string, j *job, list []Model) {
	var err error
	for _, mod := range list {
		if err = m.installOne(ctx, j, mod); err != nil {
			break
		}
	}
	m.mu.Lock()
	for _, mod := range list {
		delete(m.claimed, mod.ID)
		if !m.installed[mod.ID] {
			m.partial[mod.ID] = partialBytes(m.root, mod)
		}
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		m.errs[id] = err
	}
	delete(m.jobs, id)
	m.mu.Unlock()
	close(j.done)
	m.note(true)
}

// installOne fetches mod's files (adopting those of the cache), then
// moves them into place.
func (m *Manager) installOne(ctx context.Context, j *job, mod Model) error {
	staging := partialDir(m.root, mod)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		wg     sync.WaitGroup
		mu     sync.Mutex
		first  error
		linked int
	)
	for _, f := range mod.Files {
		dst := filepath.Join(staging, filepath.FromSlash(f.Path))
		key := mod.ID + "/" + f.Path
		progress := func(n int64) {
			m.mu.Lock()
			j.files[key] = n
			m.mu.Unlock()
			m.note(false)
		}
		if fi, err := os.Stat(dst); err == nil && fi.Size() == f.Size {
			progress(f.Size) // verified by an earlier download
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			if m.opt.HFCache != "" {
				if src := cachedFile(m.opt.HFCache, mod, f); src != "" && linkFile(src, dst) == nil {
					mu.Lock()
					linked++
					mu.Unlock()
					progress(f.Size)
					return
				}
			}
			if err := m.fetch.fetch(ctx, mod, f, dst, progress); err != nil {
				mu.Lock()
				if first == nil {
					first = err
				}
				mu.Unlock()
				cancel()
			}
		}()
	}
	wg.Wait()
	if first != nil {
		return first
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	m.diskMu.Lock()
	err := install(m.root, mod, staging, linked)
	m.diskMu.Unlock()
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.installed[mod.ID], m.partial[mod.ID] = true, 0
	m.mu.Unlock()
	m.note(true)
	return nil
}

// note tells OnChange; a note that is not forced waits 200 ms after the
// last.
func (m *Manager) note(force bool) {
	if m.opt.OnChange == nil {
		return
	}
	m.mu.Lock()
	now := time.Now()
	if !force && now.Sub(m.lastNote) < 200*time.Millisecond {
		m.mu.Unlock()
		return
	}
	m.lastNote = now
	m.mu.Unlock()
	m.opt.OnChange()
}

// diskFree is the space free for the user on path's disk (path, or the
// nearest folder above it that exists).
func diskFree(path string) int64 {
	var st syscall.Statfs_t
	for p := path; ; p = filepath.Dir(p) {
		if syscall.Statfs(p, &st) == nil {
			return int64(st.Bavail) * int64(st.Bsize)
		}
		if p == filepath.Dir(p) {
			return 0
		}
	}
}
