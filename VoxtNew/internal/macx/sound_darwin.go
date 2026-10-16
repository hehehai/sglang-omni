//go:build darwin

package macx

import (
	"os/exec"
	"path/filepath"
)

func play(s Sound) error {
	path := filepath.Join("/System/Library/Sounds", filepath.Base(string(s))+".aiff")
	cmd := exec.Command("/usr/bin/afplay", "-v", soundVolume, path)
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait() // reap it
	return nil
}
