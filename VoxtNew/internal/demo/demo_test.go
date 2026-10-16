package demo

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadEnvFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "keys.env")
	os.WriteFile(p, []byte("# keys\nexport STEPFUN_API_KEY=\"sk-1\"\nDEEPSEEK_API_KEY = 'sk-2'\n\nBROKEN\n"), 0o600)
	got := ReadEnvFile(p)
	if len(got) != 2 || got["STEPFUN_API_KEY"] != "sk-1" || got["DEEPSEEK_API_KEY"] != "sk-2" {
		t.Fatalf("ReadEnvFile = %v", got)
	}
	if got := ReadEnvFile(filepath.Join(t.TempDir(), "none")); len(got) != 0 {
		t.Errorf("a missing file: %v", got)
	}
}

func TestKeyring(t *testing.T) {
	k := Keyring{M: map[string]string{}}
	k.Set("asr.stepfun", "", "sk")
	if v, err := k.Get("asr.stepfun"); err != nil || v != "sk" {
		t.Fatalf("Get = %q, %v", v, err)
	}
	k.Set("asr.stepfun", "", "")
	if v, _ := k.Get("asr.stepfun"); v != "" || len(k.M) != 0 {
		t.Errorf("an empty key is removed: %q, %v", v, k.M)
	}
}

// TestReplay: a take's requests are made and recorded the first time,
// played back from the recording the next, outside a take always made.
func TestReplay(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: hello\n\n")
	}))
	defer srv.Close()
	dir := t.TempDir()
	r := &Replay{Dir: filepath.Join(dir, "replay"), Calls: filepath.Join(dir, "calls.log"), Base: http.DefaultTransport}
	client := &http.Client{Transport: r}
	get := func() string {
		t.Helper()
		resp, err := client.Get(srv.URL + "/v1/chat")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if resp.Header.Get("Content-Type") != "text/event-stream" {
			t.Errorf("Content-Type %q", resp.Header.Get("Content-Type"))
		}
		return string(b)
	}
	r.SetTake("one")
	if got := get(); got != "data: hello\n\n" || calls != 1 {
		t.Fatalf("first take: %q, %d calls", got, calls)
	}
	if _, err := os.Stat(filepath.Join(dir, "replay", "one", "00.json")); err != nil {
		t.Fatalf("not recorded: %v", err)
	}
	r.SetTake("one")
	if got := get(); got != "data: hello\n\n" || calls != 1 {
		t.Fatalf("replayed take: %q, %d calls (want none more)", got, calls)
	}
	r.SetTake("")
	get()
	if calls != 2 {
		t.Errorf("outside a take: %d calls, want 2", calls)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "calls.log"))
	if n := strings.Count(string(log), "\n"); n != 2 {
		t.Errorf("calls.log has %d lines, want 2 (the requests made):\n%s", n, log)
	}
}
