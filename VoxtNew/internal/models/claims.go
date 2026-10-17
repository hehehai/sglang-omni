package models

// What VoxtNew tells the family about its models: claims (it uses a
// model: keep it), and deletions that follow the family's rules (family
// spec §7.3, §7.6).

import (
	"context"
	"errors"
	"fmt"

	fammodels "github.com/hehehai/actnowkit/models"
)

// Decide is what deleting model id would do: who else uses it (Users,
// LoadedBy: the dialog's "Remove from VoxtNew" or "Delete for all
// apps…"), what it frees. It reads the family's files: off the main
// thread.
func (m *Manager) Decide(id string) (fammodels.Decision, error) {
	mod, ok := m.Lookup(id)
	if !ok {
		return fammodels.Decision{}, fmt.Errorf("%w: %q", ErrUnknown, id)
	}
	return m.store.Decide(mod.Ref(m.Status(id).Revision))
}

// Delete stops model id's download and removes it from VoxtNew (scope
// fammodels.ThisApp: its claim, and the files only when no other app
// claims or loads them; fammodels.AllApps: the files whoever uses them,
// with a tombstone for the others). A partial download goes the same way.
// A repo lock held elsewhere (another app downloads it) fails at once
// with a *fammodels.BusyError. It blocks on the disk: off the main
// thread.
func (m *Manager) Delete(ctx context.Context, id string, scope fammodels.Scope) ([]fammodels.Result, error) {
	mod, ok := m.Lookup(id)
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrUnknown, id)
	}
	m.Cancel(id)
	m.mu.Lock()
	client, rev := m.client, m.status[id].Revision
	s := m.status[id]
	s.Err = nil
	m.status[id] = s
	m.mu.Unlock()
	res, err := client.Delete(ctx, mod.Entry(rev), scope)
	m.Refresh()
	return res, err
}

// Use claims the installed models ids for VoxtNew (origin "reused"):
// "Use them" on the setup guide's reuse card, "Use it" for an
// alternative, and a session opening a model nobody claimed for VoxtNew
// yet. A model not on disk is skipped. Disk and family files: off the
// main thread.
func (m *Manager) Use(ctx context.Context, ids ...string) error {
	return m.claim(ctx, fammodels.OriginReused, ids)
}

// Migrate claims, with origin "migrated", the catalogue's models that are
// on disk and no other app claims (not the borrowed ones): the first
// start with the family's protocol (spec §15.2 step 3). Another app's
// models are VoxtNew's when the user uses them (the setup guide's reuse
// card). Disk only, no network; idempotent.
func (m *Manager) Migrate(ctx context.Context) error {
	var ids []string
	for _, mod := range m.catalog {
		if s := m.Status(mod.ID); !mod.Borrowed && len(s.Users) == 0 {
			ids = append(ids, mod.ID)
		}
	}
	return m.claim(ctx, fammodels.OriginMigrated, ids)
}

func (m *Manager) claim(ctx context.Context, origin string, ids []string) error {
	var claims []fammodels.Claim
	for _, id := range ids {
		mod, ok := m.Lookup(id)
		if !ok {
			continue
		}
		if rev, _ := find(m.store.Hub, mod); rev != "" {
			claims = append(claims, mod.Claim(rev, origin))
		}
	}
	var err error
	if len(claims) > 0 {
		err = m.store.Claim(ctx, claims...)
	}
	m.Refresh()
	return err
}

// EnsureClaimed claims model id when it is installed and VoxtNew does
// not claim it yet (a session is about to open it): cheap when it does.
func (m *Manager) EnsureClaimed(ctx context.Context, id string) error {
	s := m.Status(id)
	if !s.OnDisk || s.Mine {
		return nil
	}
	return m.Use(ctx, id)
}

// Found is a model of the catalogue already on this Mac, for the setup
// guide's reuse card: who installed it (other apps' names, "" none).
type Found struct {
	ID    string
	Bytes int64
	By    []string
}

// Survey lists which of ids are on disk, and which other apps claim them
// (family spec §7.10.1). Off the main thread.
func (m *Manager) Survey(ids ...string) []Found {
	var want []fammodels.Claim
	byRef := map[fammodels.Ref]string{}
	for _, id := range ids {
		mod, ok := m.Lookup(id)
		if !ok {
			continue
		}
		if rev, _ := find(m.store.Hub, mod); rev != "" {
			c := mod.Claim(rev, "")
			want = append(want, c)
			byRef[c.Ref()] = id
		}
	}
	var out []Found
	for _, f := range m.store.Survey(want...) {
		x := Found{ID: byRef[f.Want.Ref()], Bytes: f.Status.Bytes}
		for _, u := range f.By {
			x.By = append(x.By, u.Name)
		}
		out = append(out, x)
	}
	return out
}

// Usage is the disk space of VoxtNew's claimed models: only VoxtNew's,
// and shared with other ActNow apps (blobs counted once).
func (m *Manager) Usage() (fammodels.Usage, error) { return m.store.Usage() }

// Busy reports a delete's or a claim's failure because another app holds
// the model's lock (it downloads the model): its bundle id.
func Busy(err error) (bundleID string, ok bool) {
	var b *fammodels.BusyError
	if !errors.As(err, &b) {
		return "", false
	}
	if b.Owner == nil {
		return "", true
	}
	return b.Owner.BundleID, true
}
