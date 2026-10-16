package models

// The models on disk, under the data folder's models/:
//
//	<id>/                    an installed model: its files and manifest.json
//	.partial/<id>/<rev>/     a download: the files verified so far, and
//	                         <path>.part for those still coming
//	.trash/                  folders being removed (a rename first, so that
//	                         a model is there whole or not at all)

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// ManifestFile is written into a model's folder once all its files are
// verified: a folder without it is not an installed model.
const ManifestFile = ".voxtnew-model.json"

// manifest is what ManifestFile says.
type manifest struct {
	ID       string `json:"id"`
	Repo     string `json:"repo"`
	Revision string `json:"revision"`
	Files    []File `json:"files"`
	// Linked: how many files are links into a Hugging Face cache.
	Linked int `json:"linked,omitempty"`
}

func modelDir(root, id string) string { return filepath.Join(root, id) }

func partialDir(root string, m Model) string {
	return filepath.Join(root, ".partial", m.ID, m.Revision)
}

// isInstalled: m's folder has its manifest at m's revision and every file
// at its size (a link's target too).
func isInstalled(root string, m Model) bool {
	dir := modelDir(root, m.ID)
	b, err := os.ReadFile(filepath.Join(dir, ManifestFile))
	if err != nil {
		return false
	}
	var man manifest
	if json.Unmarshal(b, &man) != nil || man.ID != m.ID || man.Revision != m.Revision {
		return false
	}
	for _, f := range m.Files {
		fi, err := os.Stat(filepath.Join(dir, filepath.FromSlash(f.Path)))
		if err != nil || fi.Size() != f.Size {
			return false
		}
	}
	return true
}

// partialBytes is the bytes a stopped download of m kept.
func partialBytes(root string, m Model) int64 {
	var n int64
	dir := partialDir(root, m)
	for _, f := range m.Files {
		p := filepath.Join(dir, filepath.FromSlash(f.Path))
		if fi, err := os.Stat(p); err == nil {
			n += fi.Size()
		} else if fi, err := os.Stat(p + ".part"); err == nil {
			n += min(fi.Size(), f.Size)
		}
	}
	return n
}

// install makes the verified files in staging m's folder: the manifest,
// then one rename (a folder there before goes to the trash).
func install(root string, m Model, staging string, linked int) error {
	b, err := json.MarshalIndent(manifest{ID: m.ID, Repo: m.Repo, Revision: m.Revision, Files: m.Files, Linked: linked}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(staging, ManifestFile), b, 0o644); err != nil {
		return err
	}
	dir := modelDir(root, m.ID)
	if err := toTrash(root, dir); err != nil {
		return err
	}
	if err := os.Rename(staging, dir); err != nil {
		return fmt.Errorf("models: install %s: %w", m.ID, err)
	}
	os.Remove(filepath.Dir(staging)) // .partial/<id> and .partial, when empty
	os.Remove(filepath.Join(root, ".partial"))
	emptyTrash(root)
	return nil
}

// remove deletes m's folder and any download of it. Links into a Hugging
// Face cache go, never what they point to.
func remove(root, id string) error {
	if err := toTrash(root, modelDir(root, id)); err != nil {
		return err
	}
	err := os.RemoveAll(filepath.Join(root, ".partial", id))
	os.Remove(filepath.Join(root, ".partial"))
	emptyTrash(root)
	return err
}

// toTrash moves dir out of the way, if it is there.
func toTrash(root, dir string) error {
	if _, err := os.Lstat(dir); errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	trash := filepath.Join(root, ".trash")
	if err := os.MkdirAll(trash, 0o755); err != nil {
		return err
	}
	to := filepath.Join(trash, filepath.Base(dir)+"-"+strconv.FormatInt(time.Now().UnixNano(), 36))
	if err := os.Rename(dir, to); err != nil {
		return fmt.Errorf("models: remove %s: %w", filepath.Base(dir), err)
	}
	return nil
}

func emptyTrash(root string) { os.RemoveAll(filepath.Join(root, ".trash")) }
