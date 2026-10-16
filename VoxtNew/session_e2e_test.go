package main

// Whole sessions on Linux: the app over a real supervisor and the fake
// helper process (helpertest: a tone as the microphone, scripted
// shortcuts, text I/O that logs what it pastes), a loopback
// OpenAI-compatible transcription server or a loopback streaming
// WebSocket in Model Studio's protocol, and a loopback chat-completions
// server as the language model. A shortcut starts the session, another
// stops it (or Escape cancels it), and the text lands in the paste log
// and the history.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/hehehai/Auralink/internal/asr"
	"github.com/hehehai/Auralink/internal/asr/asrtest"
	"github.com/hehehai/Auralink/internal/helper"
	"github.com/hehehai/Auralink/internal/helper/helpertest"
	"github.com/hehehai/Auralink/internal/helper/proto"
	"github.com/hehehai/Auralink/internal/session"
	"github.com/hehehai/Auralink/internal/settings"
	"github.com/hehehai/Auralink/internal/store"
)

// fakeChat is a chat-completions server: it answers each request with
// text (or texts in turn, the last repeating; or status), streamed as
// server-sent events when the request streams, and keeps the requests.
type fakeChat struct {
	mu     sync.Mutex
	text   string
	texts  []string
	status int
	delay  time.Duration
	bodies []map[string]any
}

func (f *fakeChat) set(text string, status int) {
	f.mu.Lock()
	f.text, f.texts, f.status = text, nil, status
	f.mu.Unlock()
}

func (f *fakeChat) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var v map[string]any
	json.Unmarshal(body, &v)
	f.mu.Lock()
	f.bodies = append(f.bodies, v)
	text, status, delay := f.text, f.status, f.delay
	if len(f.texts) > 0 {
		text = f.texts[min(len(f.bodies), len(f.texts))-1]
	}
	f.mu.Unlock()
	if delay > 0 {
		select {
		case <-time.After(delay):
		case <-r.Context().Done():
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	if status != 0 {
		w.WriteHeader(status)
		w.Write([]byte(`{"error":{"message":"overloaded","type":"server_error"}}`))
		return
	}
	if v["stream"] == true {
		w.Header().Set("Content-Type", "text/event-stream")
		rs := []rune(text)
		for i := 0; i < len(rs); i += 6 {
			chunk, _ := json.Marshal(map[string]any{"model": "deepseek-chat",
				"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"content": string(rs[i:min(i+6, len(rs))])}}}})
			fmt.Fprintf(w, "data: %s\n\n", chunk)
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
			time.Sleep(5 * time.Millisecond)
		}
		fmt.Fprint(w, `data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":6,"total_tokens":126}}`+"\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
		return
	}
	out, _ := json.Marshal(map[string]any{
		"id": "c1", "object": "chat.completion", "model": "deepseek-chat",
		"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": text}, "finish_reason": "stop"}},
		"usage":   map[string]any{"prompt_tokens": 120, "completion_tokens": 6, "total_tokens": 126},
	})
	w.Write(out)
}

func (f *fakeChat) requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.bodies...)
}

// fakeTranscriptions is an OpenAI-compatible /audio/transcriptions server.
type fakeTranscriptions struct {
	mu    sync.Mutex
	text  string
	calls int
	size  int64
}

func (f *fakeTranscriptions) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.calls++
	f.size = r.ContentLength
	text := f.text
	f.mu.Unlock()
	io.Copy(io.Discard, r.Body)
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"text":%q}`, text)
}

// aliyunServer is a Model Studio inference WebSocket: task-started, a
// partial after a few frames of audio, the final sentence and
// task-finished on finish-task.
func aliyunServer(t *testing.T, final string) string {
	return asrtest.WSServer(t, "/api-ws/v1/inference", func(c *asrtest.Conn) {
		send := func(taskID, event string, payload any) {
			b, _ := json.Marshal(map[string]any{"header": map[string]any{"task_id": taskID, "event": event, "attributes": map[string]any{}}, "payload": payload})
			c.WriteText(string(b))
		}
		sentence := func(text string, end bool) any {
			return map[string]any{"output": map[string]any{"sentence": map[string]any{
				"begin_time": 0, "end_time": nil, "text": text, "heartbeat": false, "sentence_begin": true, "sentence_end": end, "sentence_id": 1, "words": []any{}}}}
		}
		taskID, frames := "", 0
		for {
			typ, data, ok := c.TryRead()
			if !ok {
				return
			}
			if typ == websocket.MessageBinary {
				frames++
				if frames == 3 {
					send(taskID, "result-generated", sentence("hello", false))
				}
				continue
			}
			var m struct {
				Header struct {
					Action string `json:"action"`
					TaskID string `json:"task_id"`
				} `json:"header"`
			}
			json.Unmarshal(data, &m)
			switch m.Header.Action {
			case "run-task":
				taskID = m.Header.TaskID
				send(taskID, "task-started", map[string]any{})
			case "finish-task":
				send(taskID, "result-generated", sentence(final, true))
				send(taskID, "task-finished", map[string]any{"output": map[string]any{}})
				return
			}
		}
	})
}

// sessionApp is the app over the fake helper process, its post queue
// pumped by the test.
type sessionApp struct {
	*app
	t        *testing.T
	queue    chan func()
	pasteLog string
}

// newSessionApp starts the app with helper options opts (helpertest) and
// the settings set changes.
func newSessionApp(t *testing.T, opts string, set func(*settings.Settings), keys map[string]string) *sessionApp {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	lib, err := openLibrary(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lib.close)
	if err := lib.settings.Update(context.Background(), func(s *settings.Settings) {
		s.Network.Proxy = settings.ProxyDirect
		set(s)
	}); err != nil {
		t.Fatal(err)
	}
	old := newKeyring
	newKeyring = func() keyring { return &memKeyring{m: keys} }
	t.Cleanup(func() { newKeyring = old })
	pasteLog := filepath.Join(t.TempDir(), "paste.jsonl")
	a := newApp(lib, &helperHost{bin: self, env: helpertest.Env("frame-ms=20," + helpertest.Opt("paste-log", pasteLog) + "," + opts)})
	a.measureHook = guessText
	s := &sessionApp{app: a, t: t, queue: make(chan func(), 4096), pasteLog: pasteLog}
	a.postQueue = func(fn func()) { s.queue <- fn }
	a.connectHelper()
	a.startHelper()
	t.Cleanup(func() {
		a.quit()
		// Let the session's goroutines finish posting into the queue.
		for {
			select {
			case fn := <-s.queue:
				fn()
			case <-time.After(50 * time.Millisecond):
				return
			}
		}
	})
	s.pump("the helper", func() bool { return a.helperStatus().State == helper.Ready })
	return s
}

// pump runs posted functions until cond holds.
func (s *sessionApp) pump(what string, cond func() bool) {
	s.t.Helper()
	deadline := time.After(10 * time.Second)
	for !cond() {
		select {
		case fn := <-s.queue:
			fn()
		case <-deadline:
			s.t.Fatalf("timed out waiting for %s (session %s %+v)", what, s.sess.State, s.sess.Problem)
		}
	}
}

// pasted is what the fake helper pasted.
func (s *sessionApp) pasted() []proto.PasteParams {
	data, _ := os.ReadFile(s.pasteLog)
	var out []proto.PasteParams
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var p proto.PasteParams
		json.Unmarshal([]byte(line), &p)
		out = append(out, p)
	}
	return out
}

func (s *sessionApp) history() []store.Entry {
	es, err := s.lib.store.History().List(context.Background(), store.HistoryQuery{})
	if err != nil {
		s.t.Fatal(err)
	}
	return es
}

// script writes an events= script: hotkey events after delays.
func script(t *testing.T, lines ...string) string {
	p := filepath.Join(t.TempDir(), "events.jsonl")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return helpertest.Opt("events", p)
}

func hotkeyLine(afterMS int, binding, phase string) string {
	front := helpertest.Apps["com.tinyspeck.slackmacgap"]
	b, _ := json.Marshal(helpertest.Script{AfterMS: afterMS, Method: proto.MethodHotkeyEvent,
		Params: mustJSON(proto.HotkeyEventParams{Binding: binding, Phase: phase, Behavior: proto.BehaviorTap, T: 1, Front: &front})})
	return string(b)
}

func mustJSON(v any) json.RawMessage { b, _ := json.Marshal(v); return b }

// fileSetup is OpenAI-compatible transcription and DeepSeek on loopback.
func fileSetup(t *testing.T, asrText string, chat *fakeChat) (func(*settings.Settings), map[string]string, *fakeTranscriptions) {
	tr := &fakeTranscriptions{text: asrText}
	asrSrv := httptest.NewServer(tr)
	t.Cleanup(asrSrv.Close)
	llmSrv := httptest.NewServer(chat)
	t.Cleanup(llmSrv.Close)
	return func(s *settings.Settings) {
			s.Providers.ASR = []settings.Provider{{ID: "openai", Enabled: true, Endpoint: asrSrv.URL + "/v1"}}
			s.Providers.LLM = []settings.Provider{{ID: "deepseek", Enabled: true, Endpoint: llmSrv.URL + "/v1"}}
		}, map[string]string{"asr.openai": "sk-asr", "llm.deepseek": "sk-llm"},
		tr
}

// TestSessionEndToEnd: fn, speak, fn: the cleaned-up text is pasted into
// the app that was in front, kept in the history, and ⌃⌘V pastes it again.
func TestSessionEndToEnd(t *testing.T) {
	chat := &fakeChat{text: "Hello, Auralink."}
	set, keys, tr := fileSetup(t, "hello aura link", chat)
	ev := script(t,
		hotkeyLine(0, "transcribe/0", proto.PhaseTrigger),
		hotkeyLine(400, "transcribe/0", proto.PhaseTrigger),
		hotkeyLine(1500, "paste-last", proto.PhaseTrigger),
	)
	a := newSessionApp(t, ev, func(s *settings.Settings) {
		set(s)
		s.Features.Transcribe.Prompt = "Keep it short."
	}, keys)
	var modes []overlayMode
	seen := func() {
		if (len(modes) == 0 && a.ov.mode != ovHidden) || len(modes) > 0 && modes[len(modes)-1] != a.ov.mode {
			modes = append(modes, a.ov.mode)
		}
	}
	a.pump("the recording", func() bool { seen(); return a.sess.State == session.Recording })
	if !strings.Contains(a.hotkeysSent, "Active:true") {
		t.Errorf("not active while recording: %s", a.hotkeysSent)
	}
	a.pump("the end", func() bool { seen(); return a.sess.State.Ended() })
	end := a.sess
	if end.State != session.Done || end.Result != "Hello, Auralink." || end.Raw != "hello aura link" || !end.Inserted || end.Target.Name != "Slack" {
		t.Fatalf("end %+v", end)
	}
	if got := fmt.Sprint(modes); got != "[recording working hidden]" { // nothing after the insert
		t.Errorf("overlay modes %s", got)
	}
	a.pump("the second paste", func() bool { return len(a.pasted()) == 2 })
	p := a.pasted()
	if p[0].Text != "Hello, Auralink." || p[0].TargetPID != 812 || p[1].Text != "Hello, Auralink." {
		t.Errorf("pasted %+v", p)
	}
	if strings.Contains(a.hotkeysSent, "Active:true") {
		t.Errorf("still active: %s", a.hotkeysSent)
	}
	es := a.history()
	if len(es) != 1 || es[0].Result != "Hello, Auralink." || es[0].RawText != "hello aura link" || es[0].ASRProvider != "openai" ||
		es[0].LLMProvider != "deepseek" || es[0].LLMModel != "deepseek-flash" || es[0].Delivery != "insert" || es[0].AppName != "Slack" || es[0].AudioMS < 300 {
		t.Errorf("history %+v", es)
	}
	if tr.calls != 1 || tr.size < 10000 {
		t.Errorf("uploads %d, %d bytes", tr.calls, tr.size)
	}
	reqs := chat.requests()
	if len(reqs) != 1 {
		t.Fatalf("%d chats", len(reqs))
	}
	msgs, _ := reqs[0]["messages"].([]any)
	sys, _ := msgs[0].(map[string]any)["content"].(string)
	user, _ := msgs[1].(map[string]any)["content"].(string)
	if !strings.Contains(sys, "Keep it short.") || strings.Contains(sys, "hello aura link") || user != "<input>\nhello aura link\n</input>" ||
		reqs[0]["model"] != "deepseek-flash" || reqs[0]["thinking"] == nil {
		t.Errorf("chat %v", reqs[0])
	}
}

// TestSessionStreamingCard: a streaming service shows its partial while
// recording; the app in front takes no text, so the result waits in the
// answer card, whose Insert pastes it anyway.
func TestSessionStreamingCard(t *testing.T) {
	url := aliyunServer(t, "你好，Auralink")
	ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger), hotkeyLine(600, "transcribe/0", proto.PhaseTrigger))
	a := newSessionApp(t, "readonly,"+ev, func(s *settings.Settings) {
		s.Providers.ASR = []settings.Provider{{ID: "aliyun", Enabled: true, Endpoint: url}}
		s.Features.Transcribe.Enhance = false
	}, map[string]string{"asr.aliyun": "sk-ali"})
	partial := false
	a.pump("the end", func() bool {
		partial = partial || a.sess.State == session.Recording && a.sess.Partial == "hello" && a.ov.mode == ovRecording
		return a.sess.State.Ended()
	})
	if !partial {
		t.Error("no partial while recording")
	}
	end := a.sess
	if end.State != session.Done || end.Result != "你好，Auralink" || end.Inserted || !end.Card || a.ov.mode != ovAnswer || !a.answer.open {
		t.Fatalf("end %+v, overlay %s", end, a.ov.mode)
	}
	if len(a.pasted()) != 0 {
		t.Fatalf("pasted %+v", a.pasted())
	}
	if !strings.Contains(a.hotkeysSent, "Active:true") {
		t.Error("Escape should close the card")
	}
	a.insertAnswer()
	a.pump("the insert", func() bool { return !a.answer.open })
	if p := a.pasted(); len(p) != 1 || p[0].Text != "你好，Auralink" {
		t.Errorf("pasted %+v", p)
	}
	a.pump("the history", func() bool {
		es := a.history()
		return len(es) == 1 && es[0].Delivery == "insert"
	})
	if a.ov.mode != ovHidden {
		t.Errorf("overlay %s", a.ov.mode)
	}
}

// TestSessionEscapeAndFailures: Escape cancels (nothing pasted or kept);
// a failing language model inserts the text as recognised with a warning.
func TestSessionEscapeAndFailures(t *testing.T) {
	t.Run("escape", func(t *testing.T) {
		chat := &fakeChat{text: "x"}
		set, keys, tr := fileSetup(t, "never", chat)
		ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger), hotkeyLine(300, proto.HotkeyEscape, proto.PhaseTrigger))
		a := newSessionApp(t, ev, set, keys)
		a.pump("the end", func() bool { return a.sess.State.Ended() })
		if a.sess.State != session.Cancelled || a.ov.mode != ovHidden || len(a.pasted()) != 0 || len(a.history()) != 0 || tr.calls != 0 {
			t.Errorf("end %+v", a.sess)
		}
	})
	t.Run("llm fails", func(t *testing.T) {
		chat := &fakeChat{status: 500}
		set, keys, _ := fileSetup(t, "hello there", chat)
		ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger), hotkeyLine(400, "transcribe/0", proto.PhaseTrigger))
		a := newSessionApp(t, ev, set, keys)
		a.pump("the end", func() bool { return a.sess.State.Ended() })
		if a.sess.State != session.Done || a.sess.Result != "hello there" || a.sess.Problem == nil || a.sess.Problem.Code != session.ProblemLLM {
			t.Fatalf("end %+v", a.sess)
		}
		if p := a.pasted(); len(p) != 1 || p[0].Text != "hello there" {
			t.Errorf("pasted %+v", p)
		}
		if a.notice == nil || !a.notice.warn || a.ov.mode != ovNotice || a.notice.text != "Inserted as recognised: the language model failed." {
			t.Errorf("notice %+v, overlay %s", a.notice, a.ov.mode)
		}
		if es := a.history(); len(es) != 1 || es[0].Error == "" || es[0].Status != store.StatusDone {
			t.Errorf("history %+v", es)
		}
	})
	t.Run("no speech service", func(t *testing.T) {
		ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger))
		a := newSessionApp(t, ev, func(*settings.Settings) {}, nil)
		a.pump("the notice", func() bool { return a.notice != nil })
		if a.sess.State != session.Idle || a.notice.action != actionProviders || a.ov.mode != ovNotice {
			t.Errorf("session %s, notice %+v", a.sess.State, a.notice)
		}
		a.noticeAction(a.notice.action)
		if a.router.Path() != "/providers" || a.ov.mode != ovHidden {
			t.Errorf("went to %s, overlay %s", a.router.Path(), a.ov.mode)
		}
	})
	t.Run("microphone denied", func(t *testing.T) {
		chat := &fakeChat{text: "x"}
		set, keys, _ := fileSetup(t, "x", chat)
		ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseTrigger))
		a := newSessionApp(t, "deny-mic,"+ev, set, keys)
		a.pump("the end", func() bool { return a.sess.State.Ended() })
		if a.sess.State != session.Failed || a.sess.Problem.Code != session.ProblemMicrophone || a.notice == nil || a.notice.action != actionPermissions {
			t.Errorf("end %+v notice %+v", a.sess, a.notice)
		}
	})
}

// TestSessionLongPress: a long-press binding records while held.
func TestSessionLongPress(t *testing.T) {
	chat := &fakeChat{text: "held"}
	set, keys, _ := fileSetup(t, "held", chat)
	ev := script(t, hotkeyLine(0, "transcribe/0", proto.PhaseDown), hotkeyLine(500, "transcribe/0", proto.PhaseUp))
	a := newSessionApp(t, ev, func(s *settings.Settings) {
		set(s)
		s.Features.Transcribe.Hotkeys = []settings.Hotkey{{Keys: "RightCommand", Trigger: settings.TriggerLong}}
	}, keys)
	a.pump("the recording", func() bool { return a.sess.State == session.Recording })
	if a.sess.HoldBinding != "transcribe/0" {
		t.Errorf("hold %q", a.sess.HoldBinding)
	}
	a.pump("the end", func() bool { return a.sess.State.Ended() })
	if a.sess.State != session.Done || a.sess.Result != "held" || a.sess.Timings.Audio < 300*time.Millisecond {
		t.Errorf("end %+v", a.sess)
	}
}

// wavAudio plays a WAV file as the microphone, in real time, then stops
// by itself.
type wavAudio struct{ pcm []byte }

func (w wavAudio) Record(ctx context.Context, id string, p proto.CaptureParams, fn func(session.AudioEvent)) (proto.CaptureResult, error) {
	fn(session.AudioEvent{Started: &proto.CaptureStartedParams{Job: id, DeviceName: "sample"}})
	frames := asr.Frames(w.pcm, 100*time.Millisecond, asr.SampleRate)
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for i, f := range frames {
		select {
		case <-ctx.Done():
			return proto.CaptureResult{}, &proto.Error{Code: proto.CodeCancelled}
		case <-t.C:
		}
		fn(session.AudioEvent{PCM: &proto.PCMParams{Job: id, Seq: i, Data: f}})
	}
	return proto.CaptureResult{Reason: proto.CaptureMaxSeconds, Frames: len(frames)}, nil
}

func (wavAudio) Stop(context.Context, string) error { return nil }

// pasteText takes every paste.
type pasteText struct {
	mu   sync.Mutex
	text []string
}

func (p *pasteText) Focus(context.Context) (proto.FocusResult, error) {
	return proto.FocusResult{PID: 812, Role: "AXTextArea", Editable: true}, nil
}

func (p *pasteText) Paste(_ context.Context, pp proto.PasteParams) (proto.PasteResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.text = append(p.text, pp.Text)
	return proto.PasteResult{Posted: true}, nil
}

// TestE2ESessionReal runs the speech sample through each real speech
// service the developer has a key for, and DeepSeek, with the app's
// resolver (AURALINK_E2E=1; keys from ~/.config/auralink-dev/keys.env).
func TestE2ESessionReal(t *testing.T) {
	asrtest.E2E(t)
	data, err := os.ReadFile(asrtest.SamplePath())
	if err != nil {
		t.Skipf("no speech sample: %v", err)
	}
	pcm, rate, ch, err := asr.ReadWAV(data)
	if err != nil || rate != asr.SampleRate || ch != 1 {
		t.Fatalf("sample: %d Hz %d ch %v", rate, ch, err)
	}
	llmKey := asrtest.Key(t, "DEEPSEEK_API_KEY")
	for _, tc := range []struct {
		id, keyName, appIDName string
	}{
		{"doubao", "DOUBAO_ACCESS_TOKEN", "DOUBAO_APP_ID"},
		{"aliyun", "DASHSCOPE_API_KEY", ""},
		{"openai", "OPENAI_API_KEY", ""},
		{"stepfun", "STEPFUN_API_KEY", ""},
	} {
		t.Run(tc.id, func(t *testing.T) {
			key := asrtest.Key(t, tc.keyName)
			s := settings.Defaults()
			prov := settings.Provider{ID: tc.id, Enabled: true}
			if tc.appIDName != "" {
				prov.AppID = asrtest.Key(t, tc.appIDName)
			}
			s.Providers.ASR = []settings.Provider{prov}
			s.Providers.LLM = []settings.Provider{{ID: "deepseek", Enabled: true}}
			s.General.MainLanguage = "zh"
			kr := &memKeyring{m: map[string]string{"asr." + tc.id: key, "llm.deepseek": llmKey}}
			text := &pasteText{}
			ended := make(chan session.Snapshot, 4)
			m := session.New(session.Config{
				Audio: wavAudio{pcm: pcm}, Text: text, Resolve: resolver(kr),
				Settings: func() settings.Settings { return s },
				OnChange: func(sn session.Snapshot) {
					if sn.State.Ended() {
						ended <- sn
					}
				},
				Log:        func(level, msg string) { t.Log(level, msg) },
				LLMTimeout: 20 * time.Second,
			})
			if _, err := m.Start(session.StartRequest{Kind: store.KindTranscribe, Target: slackApp}); err != nil {
				t.Fatal(err)
			}
			var end session.Snapshot
			select {
			case end = <-ended:
			case <-time.After(90 * time.Second):
				t.Fatal("no end")
			}
			if end.State != session.Done || end.Result == "" || !end.Inserted {
				t.Fatalf("end %s %+v", end.State, end.Problem)
			}
			t.Logf("%s → %q; %s → %q (asr %v, llm %v)", end.ASR.Model, end.Raw, end.LLM.Model, end.Result,
				end.Timings.ASR.Round(time.Millisecond), end.Timings.LLM.Round(time.Millisecond))
		})
	}
}

// chatMessages are a chat request's messages: role and content.
func chatMessages(req map[string]any) [][2]string {
	var out [][2]string
	msgs, _ := req["messages"].([]any)
	for _, m := range msgs {
		mm, _ := m.(map[string]any)
		role, _ := mm["role"].(string)
		content, _ := mm["content"].(string)
		out = append(out, [2]string{role, content})
	}
	return out
}
