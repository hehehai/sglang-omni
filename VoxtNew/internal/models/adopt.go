package models

// Adopting files from a Hugging Face cache (a developer's option, so that
// a Mac that has the models does not download them again): a file of the
// repo in any snapshot (the pinned revision's first), of the right size
// and SHA-256, is hard-linked into the download (a symbolic link when the
// cache is on another disk). The cache is only read: removing the model
// removes the links.

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// DefaultHFCache is the Hugging Face hub cache of this user:
// $HF_HUB_CACHE, $HF_HOME/hub, else ~/.cache/huggingface/hub.
func DefaultHFCache() string {
	if d := os.Getenv("HF_HUB_CACHE"); d != "" {
		return d
	}
	if d := os.Getenv("HF_HOME"); d != "" {
		return filepath.Join(d, "hub")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".cache", "huggingface", "hub")
}

// cachedFile is f of m in the cache hub, verified: the real file (the
// snapshot's link resolved), or "".
func cachedFile(hub string, m Model, f File) string {
	repo := filepath.Join(hub, "models--"+strings.ReplaceAll(m.Repo, "/", "--"), "snapshots")
	snaps, err := os.ReadDir(repo)
	if err != nil {
		return ""
	}
	order := []string{m.Revision}
	for _, s := range snaps {
		if s.Name() != m.Revision {
			order = append(order, s.Name())
		}
	}
	for _, rev := range order {
		p, err := filepath.EvalSymlinks(filepath.Join(repo, rev, filepath.FromSlash(f.Path)))
		if err != nil {
			continue
		}
		if fi, err := os.Stat(p); err != nil || fi.Size() != f.Size {
			continue
		}
		if sum, err := fileSHA256(p); err == nil && sum == f.SHA256 {
			return p
		}
	}
	return ""
}

// linkFile makes dst a hard link to src, or a symbolic one.
func linkFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	os.Remove(dst + ".part")
	os.Remove(dst)
	if os.Link(src, dst) == nil {
		return nil
	}
	return os.Symlink(src, dst)
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
