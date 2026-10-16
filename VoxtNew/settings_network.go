package main

// Settings → Network: the proxy every request to a provider goes through
// (internal/netx), and a connection test through it. (AudioSmith's
// Network page, without the model mirrors.)

import (
	"context"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/hehehai/Auralink/internal/i18n"
	"github.com/hehehai/Auralink/internal/icons"
	"github.com/hehehai/Auralink/internal/netx"
	"github.com/hehehai/Auralink/internal/settings"
)

// netCheck is the result of reaching one host.
type netCheck struct {
	host    string
	ok      bool
	latency time.Duration
	err     string
}

// networkState is the Network page's state.
type networkState struct {
	proxyInfo  string // the proxy requests use, as loadProxyInfo found it
	netChecks  []netCheck
	netTesting bool
}

// netHosts are the hosts the connection test reaches: the default
// providers' (plan D1), then those of the endpoints the user set up.
var netHosts = []string{"https://api.openai.com", "https://openspeech.bytedance.com", "https://dashscope.aliyuncs.com", "https://api.deepseek.com"}

// testHosts are netHosts and the hosts of the endpoints set up on the
// Model services page.
func (a *app) testHosts() []string {
	hosts := slices.Clone(netHosts)
	for _, p := range append(slices.Clone(a.prefs.Providers.ASR), a.prefs.Providers.LLM...) {
		u, err := url.Parse(p.Endpoint)
		if err != nil || u.Host == "" {
			continue
		}
		scheme := "https"
		if u.Scheme == "http" || u.Scheme == "ws" {
			scheme = "http"
		}
		if h := scheme + "://" + u.Host; !slices.Contains(hosts, h) {
			hosts = append(hosts, h)
		}
	}
	return hosts
}

// testNetwork reaches each host through the proxy.
func (a *app) testNetwork() {
	a.netTesting = true
	client := netx.NewHTTPClient(a.prefs.Network.Proxy, 10*time.Second)
	hosts := a.testHosts()
	a.async(func() {
		out := make([]netCheck, len(hosts))
		var wg sync.WaitGroup
		for i, h := range hosts {
			wg.Go(func() { out[i] = reach(client, h) })
		}
		wg.Wait()
		a.post(func() { a.netChecks, a.netTesting = out, false })
	})
}

// reach asks host for its headers (a HEAD request, 10 s at most); any
// answer below 500 counts as reachable.
var reach = func(client *http.Client, host string) netCheck {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodHead, host, nil)
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		msg := err.Error()
		if i := strings.LastIndex(msg, ": "); i > 0 {
			msg = msg[i+2:]
		}
		return netCheck{host: host, err: msg}
	}
	resp.Body.Close()
	return netCheck{host: host, ok: resp.StatusCode < 500, latency: time.Since(start), err: resp.Status}
}

// loadProxyInfo finds the proxy requests use, in the background (it may
// run scutil).
func (a *app) loadProxyInfo() {
	mode := a.prefs.Network.Proxy
	a.async(func() {
		p := netx.DescribeProxy(mode)
		info := i18n.T("Requests connect directly.")
		if p != "" {
			info = i18n.T("Requests go through %s.", p)
		}
		a.post(func() { a.proxyInfo = info })
	})
}

// networkSettings is Settings → Network.
func (a *app) networkSettings(c *ui.Context) {
	t := c.Theme()
	if a.proxyInfo == "" {
		a.loadProxyInfo()
	}
	caption(c, i18n.T("Auralink talks only to the speech and language services you set up. These settings apply to all of them."))
	settingRowNote(c, "proxy", i18n.T("Proxy"), a.proxyInfo, func() {
		opts := proxyOptions()
		if ui.Select(c.Key("proxy-select"), &a.proxyMode, opts).Label(i18n.T("Proxy")).Width(px(t, 240)).Changed() {
			mode := ""
			switch slices.Index(opts, a.proxyMode) {
			case 1:
				mode = settings.ProxyDirect
			case 2:
				mode = strings.TrimSpace(a.proxy)
				if mode == "" {
					return // until a URL is typed
				}
			}
			a.updateSettings(func(s *settings.Settings) { s.Network.Proxy = mode })
		}
	})
	if slices.Index(proxyOptions(), a.proxyMode) == 2 {
		settingRow(c, "proxy-url", i18n.T("Proxy URL"), i18n.T("http://, https:// or socks5://host:port"), func() {
			in := ui.TextInput(c.Key("proxy-input"), &a.proxy).Placeholder("http://127.0.0.1:7890").Width(px(t, 280)).Label(i18n.T("Proxy URL"))
			if in.Submitted() {
				mode := strings.TrimSpace(a.proxy)
				a.updateSettings(func(s *settings.Settings) { s.Network.Proxy = mode })
			}
		})
	}

	sectionTitle(c, i18n.T("Connection"))
	settingRow(c, "net-test", i18n.T("Test the connection"), i18n.T("Reaches OpenAI, Volcengine (Doubao), Alibaba Cloud Model Studio, DeepSeek and the endpoints you set up, through the proxy above."), func() {
		if a.netTesting {
			ui.Spinner(c)
		}
		if ui.Button(c.Key("net-test"), i18n.T("Test")).Disabled(a.netTesting).Clicked() {
			a.testNetwork()
		}
	})
	for _, r := range a.netChecks {
		ui.Row(c.Key("net-" + r.host)).Gap(px(t, 8)).AlignItems(ui.Center).Children(func() {
			mark, col := icons.CheckCircle, t.Success
			detail := i18n.T("%d ms", r.latency.Milliseconds())
			if !r.ok {
				mark, col, detail = icons.CloseCircle, t.Danger, r.err
			}
			ui.Icon(c, mark.Linear).Size(px(t, 14), px(t, 14)).TextColor(col).Shrink(0)
			ui.Text(c, strings.TrimPrefix(r.host, "https://")).Width(px(t, 220)).SingleLine().Ellipsis("…")
			ui.Text(c, detail).TextColor(t.TextMuted).FontSize(px(t, fsCaption)).Grow(1).MinWidth(0).SingleLine().Ellipsis("…")
		})
	}
}
