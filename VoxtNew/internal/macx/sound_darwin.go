//go:build darwin

package macx

import (
	"os/exec"
	"path/filepath"
)

func soundCmd(s Sound) *exec.Cmd {
	path := filepath.Join("/System/Library/Sounds", filepath.Base(string(s))+".aiff")
	return exec.Command("/usr/bin/afplay", "-v", soundVolume, path)
}

// start: afplay exits when the sound ended; killing it stops the sound.
func start(s Sound) (*Playing, error) {
	cmd := soundCmd(s)
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &Playing{done: make(chan struct{})}
	p.stop = func() {
		select {
		case <-p.done:
		default:
			cmd.Process.Kill()
		}
	}
	go func() {
		cmd.Wait() // reap it
		close(p.done)
	}()
	return p, nil
}
