// Package modelstest installs models of the catalogue for tests, without
// their bytes: each file is a sparse file of its size, which is all
// models.Open checks when it scans (the hashes are checked as files
// download).
package modelstest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
)

// Seed installs the models ids under root, a models.Manager's root.
func Seed(root string, ids ...string) error {
	for _, id := range ids {
		m, ok := models.Lookup(id)
		if !ok {
			return fmt.Errorf("modelstest: unknown model %q", id)
		}
		dir := filepath.Join(root, id)
		for _, f := range m.Files {
			p := filepath.Join(dir, filepath.FromSlash(f.Path))
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return err
			}
			file, err := os.Create(p)
			if err != nil {
				return err
			}
			err = file.Truncate(f.Size)
			file.Close()
			if err != nil {
				return err
			}
		}
		b, err := json.Marshal(map[string]any{"id": m.ID, "repo": m.Repo, "revision": m.Revision, "files": m.Files})
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, models.ManifestFile), b, 0o644); err != nil {
			return err
		}
	}
	return nil
}
