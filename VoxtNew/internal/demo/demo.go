// Package demo is the machinery of the demo build (package main's demo.go,
// -tags demo), which makes the README's screenshots and recordings: the
// services' traffic recorded on a recording's first take and replayed on
// the next ones (Replay), so that every take shows the same text; the
// demo's keys in memory (Keyring), read from its keys.env (ReadEnvFile);
// the running bundle's identifier (BundleID); the microphone as granted
// while the helper records a file (PermSys). Only the demo build imports
// it.
package demo

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/permission"
)

// Replay is the services' transport: outside a take it calls; in a take
// it plays the take's n-th request back when it was recorded, else calls
// and records it.
type Replay struct {
	Dir, Calls string
	Base       http.RoundTripper
	mu         sync.Mutex
	take       string
	n          int
}

type recChunk struct {
	MS   int64  `json:"ms"`
	Data []byte `json:"data"`
}

type recording struct {
	URL      string     `json:"url"`
	Status   int        `json:"status"`
	Type     string     `json:"type"`
	HeaderMS int64      `json:"headerMs"`
	Chunks   []recChunk `json:"chunks"`
}

// SetTake starts a take: its requests are played back when recorded,
// else made and recorded ("": none, every request is made).
func (r *Replay) SetTake(name string) {
	r.mu.Lock()
	r.take, r.n = name, 0
	r.mu.Unlock()
}

// RoundTrip is http.RoundTripper's.
func (r *Replay) RoundTrip(req *http.Request) (*http.Response, error) {
	r.mu.Lock()
	take, n := r.take, r.n
	r.n++
	r.mu.Unlock()
	url := req.URL.Host + req.URL.Path
	path := ""
	if take != "" {
		path = filepath.Join(r.Dir, take, fmt.Sprintf("%02d.json", n))
		var rec recording
		if b, err := os.ReadFile(path); err == nil && json.Unmarshal(b, &rec) == nil && rec.URL == url {
			if req.Body != nil {
				io.Copy(io.Discard, req.Body)
				req.Body.Close()
			}
			return r.play(req, rec)
		}
	}
	start := time.Now()
	resp, err := r.Base.RoundTrip(req)
	status := 0
	if resp != nil {
		status = resp.StatusCode
	}
	r.logCall(fmt.Sprintf("%s\t%s\t%s\t%d\t%v", start.Format(time.RFC3339), req.URL.Host, take, status, err))
	if err != nil || path == "" || resp.StatusCode != http.StatusOK {
		return resp, err
	}
	rec := recording{URL: url, Status: resp.StatusCode, Type: resp.Header.Get("Content-Type"), HeaderMS: time.Since(start).Milliseconds()}
	resp.Body = &recBody{rc: resp.Body, rec: rec, t0: time.Now(), path: path}
	return resp, nil
}

func (r *Replay) logCall(line string) {
	f, err := os.OpenFile(r.Calls, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	fmt.Fprintln(f, line)
	f.Close()
}

// play answers req with rec, at its pace.
func (r *Replay) play(req *http.Request, rec recording) (*http.Response, error) {
	ctx := req.Context()
	select {
	case <-time.After(time.Duration(rec.HeaderMS) * time.Millisecond):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	pr, pw := io.Pipe()
	go func() {
		t0 := time.Now()
		for _, c := range rec.Chunks {
			if d := time.Duration(c.MS)*time.Millisecond - time.Since(t0); d > 0 {
				select {
				case <-time.After(d):
				case <-ctx.Done():
					pw.CloseWithError(ctx.Err())
					return
				}
			}
			if _, err := pw.Write(c.Data); err != nil {
				return
			}
		}
		pw.Close()
	}()
	h := http.Header{}
	h.Set("Content-Type", rec.Type)
	return &http.Response{StatusCode: rec.Status, Status: http.StatusText(rec.Status), Header: h, Body: pr,
		Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1, Request: req, ContentLength: -1}, nil
}

// recBody records a response's body as it is read, and saves it at its
// end.
type recBody struct {
	rc   io.ReadCloser
	rec  recording
	t0   time.Time
	path string
	done bool
}

func (b *recBody) Read(p []byte) (int, error) {
	n, err := b.rc.Read(p)
	if n > 0 {
		b.rec.Chunks = append(b.rec.Chunks, recChunk{MS: time.Since(b.t0).Milliseconds(), Data: append([]byte(nil), p[:n]...)})
	}
	if err == io.EOF {
		b.save()
	}
	return n, err
}

// Close saves what was read: a stream's reader stops at its last event,
// before the end of the body.
func (b *recBody) Close() error {
	b.save()
	return b.rc.Close()
}

func (b *recBody) save() {
	if b.done || len(b.rec.Chunks) == 0 {
		return
	}
	b.done = true
	if data, e := json.Marshal(b.rec); e == nil {
		os.MkdirAll(filepath.Dir(b.path), 0o755)
		os.WriteFile(b.path, data, 0o644)
	}
}

// BundleID reads the running bundle's identifier ("" outside a bundle).
func BundleID() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(filepath.Dir(filepath.Dir(exe)), "Info.plist"))
	if err != nil {
		return ""
	}
	m := regexp.MustCompile(`<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>`).FindSubmatch(b)
	if m == nil {
		return ""
	}
	return string(m[1])
}

// ReadEnvFile reads NAME=value lines (keys.env).
func ReadEnvFile(path string) map[string]string {
	out := map[string]string{}
	b, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(strings.TrimPrefix(line, "export "), "=")
		if ok {
			out[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return out
}

// Keyring holds the demo's keys in memory (M: account → key).
type Keyring struct {
	mu sync.Mutex
	M  map[string]string
}

// Get is the key of account acc.
func (k *Keyring) Get(acc string) (string, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.M[acc], nil
}

// Set keeps (or, empty, removes) the key of account acc.
func (k *Keyring) Set(acc, _, v string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if v == "" {
		delete(k.M, acc)
	} else {
		k.M[acc] = v
	}
	return nil
}

// ---- commands ----

// PermSys reports the microphone granted while the helper records a
// file.
type PermSys struct{ permission.System }

// Microphone is granted.
func (d PermSys) Microphone() permission.State { return permission.Granted }
