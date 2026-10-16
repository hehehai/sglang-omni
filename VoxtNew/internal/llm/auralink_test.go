package llm

import (
	"context"
	"net/http"
	"testing"
)

func deepseekAt(t *testing.T, base string) Preset {
	t.Helper()
	p, err := ProviderConfig{ID: "deepseek", BaseURL: base}.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// TestExtraBodyThinkingOff: DeepSeek's requests turn thinking off, and a
// server that rejects that is asked again without it.
func TestExtraBodyThinkingOff(t *testing.T) {
	f := newFake(t,
		jsonReply(400, map[string]any{"error": map[string]any{"message": "unknown parameter: thinking"}}),
		jsonReply(200, oaText("好的")),
	)
	sec := StaticSecrets{"llm.deepseek": "sk-ds"}
	c := &Client{Backend: NewOpenAI(deepseekAt(t, f.srv.URL), f.srv.Client(), sec), Sleep: noSleep}
	resp, err := c.Chat(context.Background(), Request{Messages: []Message{{Role: System, Content: "s"}, {Role: User, Content: "u"}}})
	if err != nil || resp.Text != "好的" {
		t.Fatalf("%v %+v", err, resp)
	}
	rs := f.requests()
	if len(rs) != 2 {
		t.Fatalf("%d requests", len(rs))
	}
	th, _ := rs[0].Body["thinking"].(map[string]any)
	if th["type"] != "disabled" || rs[0].Body["model"] != "deepseek-flash" || rs[0].Header.Get("Authorization") != "Bearer sk-ds" {
		t.Errorf("first request %+v", rs[0].Body)
	}
	if _, ok := rs[1].Body["thinking"]; ok {
		t.Errorf("retry kept thinking: %+v", rs[1].Body)
	}
	// Request fields win over ExtraBody keys.
	p := deepseekAt(t, f.srv.URL)
	p.ExtraBody = map[string]any{"model": "evil", "thinking": map[string]any{"type": "disabled"}}
	if b := NewOpenAI(p, nil, nil).body(Request{}, "deepseek-flash", false, false, true); b["model"] != "deepseek-flash" {
		t.Errorf("ExtraBody overrode the model: %v", b["model"])
	}
}

func TestProbe(t *testing.T) {
	sec := StaticSecrets{"llm.deepseek": "sk-ds"}
	// A reply cut short (even empty) proves the key and the model.
	f := newFake(t, jsonReply(200, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": ""}, "finish_reason": "length"}}}))
	if d, err := Probe(context.Background(), NewOpenAI(deepseekAt(t, f.srv.URL), f.srv.Client(), sec), ""); err != nil || d <= 0 {
		t.Fatalf("length: %v %v", d, err)
	}
	r := f.requests()[0]
	if r.Body["max_tokens"] != float64(8) || r.Body["stream"] != nil {
		t.Errorf("probe body %+v", r.Body)
	}
	for _, tc := range []struct {
		status int
		msg    string
		code   string
	}{
		{401, "Authentication Fails, Your api key is invalid", CodeAuth},
		{400, "Model Not Exist", CodeModelNotFound},
		{422, "Invalid max_tokens value", CodeBadRequest},
	} {
		f := newFake(t, jsonReply(tc.status, map[string]any{"error": map[string]any{"message": tc.msg}}))
		_, err := Probe(context.Background(), NewOpenAI(deepseekAt(t, f.srv.URL), f.srv.Client(), sec), "deepseek-flash")
		if Code(err) != tc.code {
			t.Errorf("%d %q: %v", tc.status, tc.msg, err)
		}
		if e, _ := err.(*Error); tc.code == CodeBadRequest && (e == nil || e.Params["detail"] == "") {
			t.Errorf("no detail: %v", err)
		}
	}
	// No key.
	f = newFake(t, func(w http.ResponseWriter, r *http.Request) { t.Error("sent without a key") })
	if _, err := Probe(context.Background(), NewOpenAI(deepseekAt(t, f.srv.URL), f.srv.Client(), StaticSecrets{}), ""); Code(err) != CodeNoKey {
		t.Errorf("no key: %v", err)
	}
}
