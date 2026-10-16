package models

// Fetching one file from the Hub: resumed from its .part with a Range
// request, hashed on the way (the part already there first), renamed into
// place once its SHA-256 matches; network failures retried, resuming.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// ErrChecksum: a file's SHA-256 is not the catalogue's (the part is
// thrown away: the next try starts it again).
var ErrChecksum = errors.New("models: checksum mismatch")

// HTTPError is a status the Hub answered with.
type HTTPError struct {
	Status int
	URL    string
}

func (e *HTTPError) Error() string { return fmt.Sprintf("models: HTTP %d from %s", e.Status, e.URL) }

// fetchAttempts is how many times a file is tried when the network fails.
const fetchAttempts = 4

// retryDelay is the wait before the next attempt (a variable: tests).
var retryDelay = func(attempt int) time.Duration { return time.Duration(attempt) * time.Second }

// fetcher downloads files from a Hub, a bounded number at once. When the
// network fails it moves on to its next endpoint (a mirror: every file's
// SHA-256 is pinned, so where it comes from does not matter), and stays
// there.
type fetcher struct {
	client    *http.Client
	endpoints []string
	current   atomic.Int32
	slots     chan struct{}
}

// fileURL is where f of m is, at m's revision, on endpoint.
func fileURL(endpoint string, m Model, f File) string {
	parts := strings.Split(f.Path, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.TrimRight(endpoint, "/") + "/" + m.Repo + "/resolve/" + m.Revision + "/" + strings.Join(parts, "/")
}

// fetch puts f of m at dst, verified; progress gets the bytes of f there
// so far (it may go back, when a part is thrown away).
func (d *fetcher) fetch(ctx context.Context, m Model, f File, dst string, progress func(int64)) error {
	select {
	case d.slots <- struct{}{}:
		defer func() { <-d.slots }()
	case <-ctx.Done():
		return ctx.Err()
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	var err error
	for attempt := 1; attempt <= fetchAttempts; attempt++ {
		at := d.current.Load()
		err = d.fetchOnce(ctx, d.endpoints[at], m, f, dst, progress)
		if err == nil || !retryable(err) || ctx.Err() != nil {
			break
		}
		var he *HTTPError
		if !errors.As(err, &he) && int(at)+1 < len(d.endpoints) {
			d.current.CompareAndSwap(at, at+1) // unreachable: the next endpoint
			continue
		}
		select {
		case <-time.After(retryDelay(attempt)):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

// retryable: the network or the server failed, not the file.
func retryable(err error) bool {
	if errors.Is(err, ErrChecksum) || errors.Is(err, context.Canceled) {
		return false
	}
	var he *HTTPError
	if errors.As(err, &he) {
		return he.Status >= 500 || he.Status == http.StatusTooManyRequests || he.Status == http.StatusRequestTimeout ||
			he.Status == http.StatusRequestedRangeNotSatisfiable // the part was dropped: the next try starts again
	}
	var pe *os.PathError
	return !errors.As(err, &pe) // a file of ours failing is not the network's
}

func (d *fetcher) fetchOnce(ctx context.Context, endpoint string, m Model, f File, dst string, progress func(int64)) error {
	part := dst + ".part"
	file, err := os.OpenFile(part, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	have, err := file.Seek(0, io.SeekEnd)
	if err != nil {
		return err
	}
	digest := sha256.New()
	if have > f.Size {
		have = 0
	} else if have > 0 {
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return err
		}
		if _, err := io.CopyN(digest, file, have); err != nil {
			return err
		}
	}
	progress(have)
	if have < f.Size {
		have, err = d.download(ctx, fileURL(endpoint, m, f), f, file, have, digest, progress)
		if err != nil {
			return err
		}
	}
	if have != f.Size {
		return fmt.Errorf("models: %s: %d of %d bytes: %w", f.Path, have, f.Size, io.ErrUnexpectedEOF)
	}
	if hex.EncodeToString(digest.Sum(nil)) != f.SHA256 {
		file.Close()
		os.Remove(part)
		progress(0)
		return fmt.Errorf("%w: %s of %s", ErrChecksum, f.Path, m.Repo)
	}
	if err := file.Sync(); err != nil {
		return err
	}
	file.Close()
	return os.Rename(part, dst)
}

// download appends the rest of f, from u, to file (at have bytes, hashed
// in digest), and says how many bytes file then has.
func (d *fetcher) download(ctx context.Context, u string, f File, file *os.File, have int64, digest hash.Hash, progress func(int64)) (int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return have, err
	}
	req.Header.Set("User-Agent", "VoxtNew")
	if have > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(have, 10)+"-")
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return have, err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusPartialContent && have > 0 && strings.HasPrefix(resp.Header.Get("Content-Range"), "bytes "+strconv.FormatInt(have, 10)+"-"):
	case resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusRequestedRangeNotSatisfiable:
		// The whole file (no ranges here), or a part that cannot go on:
		// start again.
		if err := file.Truncate(0); err != nil {
			return have, err
		}
		digest.Reset()
		have = 0
		progress(0)
		if resp.StatusCode != http.StatusOK {
			return have, &HTTPError{Status: resp.StatusCode, URL: u}
		}
	default:
		return have, &HTTPError{Status: resp.StatusCode, URL: u}
	}
	if _, err := file.Seek(have, io.SeekStart); err != nil {
		return have, err
	}
	buf := make([]byte, 256<<10)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if have+int64(n) > f.Size {
				return have, fmt.Errorf("models: %s is longer than %d bytes: %w", f.Path, f.Size, ErrChecksum)
			}
			if _, err := file.Write(buf[:n]); err != nil {
				return have, err
			}
			digest.Write(buf[:n])
			have += int64(n)
			progress(have)
		}
		if rerr == io.EOF {
			return have, nil
		}
		if rerr != nil {
			return have, rerr
		}
	}
}
