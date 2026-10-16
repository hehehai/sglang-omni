package main

// TestRealSystemProxy downloads the VAD from huggingface.co alone (no
// mirror, no proxy in the environment, the app's own models.Options) on a
// Mac whose network reaches the Hub only through the system's proxy
// (mac-air: 127.0.0.1:7897), and checks every request went through it.
//
//	env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY -u all_proxy \
//	  VOXTNEW_MODELS_REAL=1 go test -count=1 -v -run TestRealSystemProxy .

import (
	"net/http"
	"net/url"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
)

func TestRealSystemProxy(t *testing.T) {
	if os.Getenv("VOXTNEW_MODELS_REAL") != "1" {
		t.Skip("set VOXTNEW_MODELS_REAL=1")
	}
	for _, name := range []string{"https_proxy", "http_proxy", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "all_proxy"} {
		if os.Getenv(name) != "" {
			t.Fatalf("%s is set: run with env -u %s", name, name)
		}
	}
	system := systemProxies()
	t.Logf("system proxies: %+v", system)
	if system.HTTPS == "" {
		t.Skip("no system HTTPS proxy")
	}
	opt := managerOptions(nil)
	opt.Endpoint, opt.HFCache = "https://huggingface.co", ""
	var mu sync.Mutex
	used := map[string]int{} // requests by the proxy they went through
	appProxy := opt.Proxy
	opt.Proxy = func(request *http.Request) (*url.URL, error) {
		proxyURL, err := appProxy(request)
		mu.Lock()
		defer mu.Unlock()
		if proxyURL != nil {
			used[proxyURL.Host]++
		} else {
			used["direct"]++
		}
		return proxyURL, err
	}
	m := models.Open(t.TempDir(), opt)
	defer m.Close()
	start := time.Now()
	if err := m.Download(models.VADSilero); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Minute)
	for m.Status(models.VADSilero).Downloading && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	s := m.Status(models.VADSilero)
	t.Logf("silero-vad: %+v in %v, requests by proxy: %v", s, time.Since(start).Round(time.Millisecond), used)
	if !s.Installed || s.Err != nil {
		t.Fatalf("not installed: %+v", s)
	}
	if used[system.HTTPS] == 0 || len(used) != 1 {
		t.Errorf("requests by proxy %v, want all through %s", used, system.HTTPS)
	}
}
