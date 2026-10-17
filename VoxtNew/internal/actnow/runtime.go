package actnow

// VoxtNew's runtime file (runtime/<bundle id>.json, spec §11.1): the
// models its runtimes hold (the omni servers', voxtnew-llm's), each with
// its repo, commit, worker, bytes and since when it is idle; its memory
// budget against the other apps'; its paste in progress. The runtimes
// report through Loaded, Busy, Idle and Unloaded; the file is rewritten
// on each change and removed when VoxtNew quits.

import (
	"context"
	"maps"
	"slices"
	"sync"
	"time"

	famruntime "github.com/hehehai/actnowkit/runtime"
)

// Runtime is VoxtNew's runtime file. Goroutine-safe; each change writes
// the file (I/O: off the main thread).
type Runtime struct {
	f *Family

	mu      sync.Mutex
	loaded  map[string]famruntime.Loaded // by model id
	pasting bool
	// unload lets a runtime go of an idle model on a memory request
	// (OnUnload), by model id.
	unload func(id string)
	now    func() time.Time
}

func newRuntime(f *Family) *Runtime {
	return &Runtime{f: f, loaded: map[string]famruntime.Loaded{}, now: time.Now}
}

// OnUnload sets what lets go of model id when another app asks for
// memory (spec §11.1: idle models only).
func (r *Runtime) OnUnload(fn func(id string)) {
	r.mu.Lock()
	r.unload = fn
	r.mu.Unlock()
}

// Loaded says a runtime (worker "omni", "llm") holds model id, from
// repo@revision, taking about bytes; it is busy until Idle.
func (r *Runtime) Loaded(id, worker, repo, revision string, bytes int64) {
	r.change(func() {
		r.loaded[id] = famruntime.Loaded{Repo: repo, Revision: revision, Worker: worker, Bytes: bytes}
	})
}

// Busy says model id works (a session uses it).
func (r *Runtime) Busy(id string) { r.setIdle(id, false) }

// Idle says model id finished its work.
func (r *Runtime) Idle(id string) { r.setIdle(id, true) }

func (r *Runtime) setIdle(id string, idle bool) {
	r.change(func() {
		l, ok := r.loaded[id]
		if !ok || (l.IdleSince != nil) == idle {
			return
		}
		l.IdleSince = nil
		if idle {
			t := r.now().UTC().Truncate(time.Second)
			l.IdleSince = &t
		}
		r.loaded[id] = l
	})
}

// Unloaded says model id left memory.
func (r *Runtime) Unloaded(id string) {
	r.change(func() { delete(r.loaded, id) })
}

// change applies fn and writes the file when it changed something.
func (r *Runtime) change(fn func()) {
	r.mu.Lock()
	before := maps.Clone(r.loaded)
	fn()
	same := maps.EqualFunc(before, r.loaded, sameLoaded)
	r.mu.Unlock()
	if !same {
		r.write()
	}
}

func sameLoaded(a, b famruntime.Loaded) bool {
	return a.Repo == b.Repo && a.Revision == b.Revision && a.Worker == b.Worker && a.Bytes == b.Bytes &&
		(a.IdleSince == nil) == (b.IdleSince == nil) && (a.IdleSince == nil || a.IdleSince.Equal(*b.IdleSince))
}

// LoadedBytes is the memory VoxtNew's models take.
func (r *Runtime) LoadedBytes() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	var n int64
	for _, l := range r.loaded {
		n += l.Bytes
	}
	return n
}

// Budget is VoxtNew's memory budget for models (spec §11.1): the family's
// share of the physical memory less what the other running apps hold
// (VoxtNew sets no limit of its own).
func (r *Runtime) Budget() int64 {
	return famruntime.Budget(0, famruntime.FamilyCap(famruntime.PhysicalMemory()), famruntime.OthersLoadedBytes(r.f.dir, r.f.bundleID))
}

// Reserve makes room before a runtime loads a model of bytes (spec
// §11.1): when it does not fit the budget, VoxtNew's own idle models go
// first, then the other apps are asked to unload theirs and are given a
// moment; the model loads anyway afterwards (it never blocks the user).
func (r *Runtime) Reserve(ctx context.Context, id string, bytes int64) {
	if r.Budget()-r.othersOf(id) >= bytes {
		return
	}
	r.unloadIdle(0, id)
	if r.Budget()-r.othersOf(id) >= bytes || r.f.readOnly {
		return
	}
	if err := famruntime.RequestMemory(r.f.dir); err != nil {
		r.f.logf("family: memory request: %v", err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
	}
}

// othersOf is what VoxtNew's models but id take.
func (r *Runtime) othersOf(id string) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	var n int64
	for k, l := range r.loaded {
		if k != id {
			n += l.Bytes
		}
	}
	return n
}

// OnMemory answers another app's memory request (family.TopicMemory):
// the models idle for famruntime.UnloadIdleAfter go.
func (r *Runtime) OnMemory() { r.unloadIdle(famruntime.UnloadIdleAfter, "") }

// unloadIdle lets go of the models idle for at least after (0: any idle
// one), but keep.
func (r *Runtime) unloadIdle(after time.Duration, keep string) {
	r.mu.Lock()
	unload := r.unload
	now := r.now()
	var ids []string
	for id, l := range r.loaded {
		if id != keep && l.IdleSince != nil && now.Sub(*l.IdleSince) >= after && (after == 0 || famruntime.Idle(l, now)) {
			ids = append(ids, id)
		}
	}
	r.mu.Unlock()
	if unload == nil {
		return
	}
	slices.Sort(ids)
	for _, id := range ids {
		r.f.logf("family: unloading %s (idle) for memory", id)
		unload(id)
	}
}

// Paste runs fn, a paste through the clipboard (write it, ⌘V, restore
// it), after another app's paste ends (at most famruntime.PasteWait), and
// says so in the file while it runs, so that the other voice-input apps
// wait for it (spec §11.1).
func (r *Runtime) Paste(ctx context.Context, fn func() error) error {
	famruntime.WaitPasting(ctx, r.f.dir, r.f.bundleID)
	r.mu.Lock()
	r.pasting = true
	r.mu.Unlock()
	r.write()
	defer func() {
		r.mu.Lock()
		r.pasting = false
		r.mu.Unlock()
		r.write()
	}()
	return fn()
}

// write writes the runtime file.
func (r *Runtime) write() {
	if r.f.readOnly {
		return
	}
	r.mu.Lock()
	ids := slices.Sorted(maps.Keys(r.loaded))
	loaded := make([]famruntime.Loaded, 0, len(ids))
	for _, id := range ids {
		loaded = append(loaded, r.loaded[id])
	}
	file := famruntime.File{BundleID: r.f.bundleID, Loaded: loaded, Pasting: r.pasting}
	r.mu.Unlock()
	file.BudgetBytes = r.Budget()
	if err := famruntime.Write(r.f.dir, file); err != nil {
		r.f.logf("family: runtime: %v", err)
	}
}

// remove deletes the runtime file (VoxtNew quits).
func (r *Runtime) remove() {
	if r.f.readOnly {
		return
	}
	if err := famruntime.Remove(r.f.dir, r.f.bundleID); err != nil {
		r.f.logf("family: runtime: %v", err)
	}
}
