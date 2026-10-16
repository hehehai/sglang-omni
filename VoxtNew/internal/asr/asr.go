// Package asr is Auralink's speech recognition over remote services
// (plan §4.4): two shapes of provider, a file transcriber that uploads a
// finished recording (OpenAI-compatible /audio/transcriptions) and a
// streamer that recognises while the user speaks (Doubao, Alibaba Cloud
// Model Studio), each in a subpackage of its own.
//
// Audio is what the helper records: 16-bit little-endian PCM, mono, at
// 16 kHz (SampleRate), sent in frames of about 100 ms. File providers get
// it as a WAV file (WAV builds one).
//
// Everything here is goroutine-safe and blocks: call it off the main
// thread. Errors are *Error values with a Kind (auth, quota, network,
// protocol, cancelled…) that the UI maps to a message and a way forward;
// they never carry a key.
//
// Endpoints must be https:// or wss:// unless the host is loopback
// (CheckEndpoint), and WebSockets go through the proxy of
// settings.Network (Dial, netx.ProxyFunc).
//
// Imports: core, netx.
package asr

import (
	"context"
	"net/http"
	"time"
)

// SampleRate is the rate of the PCM Auralink records and sends, in Hz.
const SampleRate = 16000

// Caps is what a provider can do.
type Caps struct {
	// Stream: it implements Streamer (partial text while recording);
	// File: FileTranscriber (one upload after the recording stops).
	Stream bool
	File   bool
	// Prompt: it takes a free-text prompt (context, spelling, style),
	// FileRequest.Prompt / StreamRequest.Prompt. Hints: it takes a list
	// of words to favour (hot words), the dictionary's terms.
	Prompt bool
	Hints  bool
	// MaxBytes bounds an upload (0: no bound known); MaxDuration a
	// recording (0: none known). Longer recordings fail with KindAudio
	// before anything is sent.
	MaxBytes    int64
	MaxDuration time.Duration
}

// Provider is what every provider has.
type Provider interface {
	// Caps says what it can do.
	Caps() Caps
}

// FileRequest is one recording to transcribe.
type FileRequest struct {
	// Audio is the recording: a WAV file (Format "wav") or raw PCM16LE
	// mono at SampleRate Hz (Format "pcm"; the provider wraps it).
	Audio      []byte
	Format     string
	SampleRate int // of "pcm"; 0: SampleRate
	// Lang is a language hint (a lang code, "zh", "en"); "" detects.
	Lang string
	// Hints are words to favour; Prompt is free text about the speech.
	// Providers without Caps.Hints fold the hints into the prompt.
	Hints  []string
	Prompt string
}

// Result is a finished transcription.
type Result struct {
	Text     string
	Lang     string        // as the provider reported it, "" when it did not
	Duration time.Duration // of the audio, when the provider reported it
	Model    string
	Latency  time.Duration // from the end of the audio to the final text
}

// FileTranscriber uploads a recording and returns its text.
type FileTranscriber interface {
	Provider
	Transcribe(ctx context.Context, req FileRequest) (Result, error)
}

// StreamRequest opens a stream.
type StreamRequest struct {
	SampleRate int    // of the PCM Send gets; 0: SampleRate
	Lang       string // a language hint, "" detects
	Hints      []string
	Prompt     string
}

// Streamer opens recognition streams.
type Streamer interface {
	Provider
	// Open connects and starts a session; it returns once the provider
	// accepted it (or failed: auth, quota, network…), so that a failure
	// shows before the user has said much.
	Open(ctx context.Context, req StreamRequest) (Stream, error)
}

// Stream is one recognition session.
//
// Send and Finish are called from one goroutine (the session's); Close
// from any. Events delivers EventPartial while audio comes in, then
// exactly one EventFinal or EventError, then closes. ctx of Open bounds the whole
// stream: cancelling it ends the stream with a KindCancelled Error.
type Stream interface {
	// Send sends PCM16LE mono audio at the request's sample rate, any
	// length (the stream frames it as its provider wants). It may block
	// for as long as the network does.
	Send(pcm []byte) error
	// Finish says there is no more audio; EventFinal follows.
	Finish() error
	// Close abandons the stream (no EventFinal), closes the connection and
	// then Events. Safe to call more than once and after the end.
	Close()
	Events() <-chan Event
}

// EventKind is what an Event says.
type EventKind uint8

const (
	// EventPartial: the text so far (the whole hypothesis, not a delta);
	// it may change until the final one.
	EventPartial EventKind = iota + 1
	// EventFinal: the whole final text. The last event.
	EventFinal
	// EventError: the stream failed (Err is an *Error). The last event.
	EventError
)

func (k EventKind) String() string {
	switch k {
	case EventPartial:
		return "partial"
	case EventFinal:
		return "final"
	case EventError:
		return "error"
	}
	return "unknown"
}

// Event is one event of a Stream.
type Event struct {
	Kind EventKind
	Text string // EventPartial and EventFinal
	// Result is the final event's details (Text repeats there).
	Result Result
	Err    error // EventError
}

// Config is what every provider's New takes: the user's setup of it
// (settings.Provider) with its secrets from the Keychain.
type Config struct {
	// Endpoint overrides the provider's default URL ("": the default).
	Endpoint string
	// Model is the model (Doubao: the resource id); "": the default.
	Model string
	// Key is the API key (Doubao: the Access Token). AppID is Doubao's
	// App ID.
	Key   string
	AppID string
	// Prompt is the user's ASR prompt for this provider, sent when a
	// request has none of its own (Caps.Prompt).
	Prompt string
	// Proxy is settings.Network.Proxy (netx.ProxyFunc). HTTPClient, when
	// set, is used instead of one built on it (tests).
	Proxy      string
	HTTPClient *http.Client
}
