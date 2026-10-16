// Package store is VoxtNew's persistence contract: a repository for each
// kind of record. The app uses internal/store/sqlitestore (SQLite through
// the MyGo plugin github.com/egoist/mygo/plugins/sqlite; schema in its
// migrations/*.sql).
//
// Rules:
//   - Repositories are goroutine-safe and may block on I/O: never call
//     them from a MyGo build pass.
//   - Values in, values out: a repository copies what it is given and
//     returns copies.
//   - Not found is an error wrapping core.ErrNotFound.
//   - Blobs (a history entry's audio) are files under the store's
//     directory, referenced by name; the store deletes them with the record.
//
// There is no job queue: a session lives in memory (internal/session)
// and writes one history entry when it ends.
//
// Imports: core.
package store

import (
	"context"
	"time"
)

// Store is the whole database.
type Store interface {
	// Documents holds small JSON documents by key: "settings:app" (the
	// settings), "appctx:rules" (app enhancement), "notifications".
	Documents() Documents
	History() History
	Dictionary() Dictionary
	Close() error
}

// Documents is a key → JSON store for small documents.
type Documents interface {
	// Get returns the document and whether it exists.
	Get(ctx context.Context, key string) ([]byte, bool, error)
	Put(ctx context.Context, key string, doc []byte) error
	Delete(ctx context.Context, key string) error
}

// Kind is the feature that made a history entry.
type Kind string

const (
	KindTranscribe Kind = "transcribe"
	KindTranslate  Kind = "translate"
	KindRewrite    Kind = "rewrite"
)

// Kinds lists the kinds, in the History page's order.
var Kinds = []Kind{KindTranscribe, KindTranslate, KindRewrite}

// Status is how a session ended.
type Status string

const (
	StatusDone      Status = "done"
	StatusFailed    Status = "failed"
	StatusCancelled Status = "cancelled"
)

// Entry is one finished session: what was heard or selected, what the
// model made of it, where it went and how long each stage took.
type Entry struct {
	ID        string
	Kind      Kind
	CreatedAt time.Time
	Status    Status
	Error     string // why it failed, in English; "" when done

	// Context: the app in front when the shortcut was pressed, the host of
	// its tab (a browser), and the app enhancement group that matched.
	AppBundle string
	AppName   string
	URLHost   string
	RuleID    string
	RuleName  string // as it was named then
	// RuleSource is how the group matched: "url", "browserApp" or "app"
	// (appctx.Source); "" for none.
	RuleSource string

	// RawText is the recognised speech; SourceText the selected text
	// (translate, rewrite); PromptText the spoken instruction (rewrite);
	// Result what was delivered; TargetLang the translation's target.
	RawText    string
	SourceText string
	PromptText string
	Result     string
	TargetLang string
	// Delivery: "insert" (pasted where the cursor was), "copy" or "card"
	// (shown in the answer card).
	Delivery string

	ASRProvider, ASRModel string
	LLMProvider, LLMModel string

	// Stage times, in milliseconds: the recording, recognition after the
	// stop, the language model, and the whole session. SentMS is how much
	// of the recording the speech model got, without the silence left
	// out (0: unknown, or none was sent).
	AudioMS, ASRMS, LLMMS, TotalMS int64
	SentMS                         int64

	// DSP is the sound processing the speech model's copy of the
	// recording went through (internal/dsp): "highpass", "level" or
	// "highpass+level"; "" for none (off, older entries, nothing sent).
	// GainDB is the gain the level stage gave the speech (a stream: at
	// its end). The recording kept (Audio) is the original either way.
	DSP    string
	GainDB float64

	// Audio is the recording kept with the entry, a file name in
	// History.AudioDir(); "" when none was kept.
	Audio string
}

// HistoryQuery selects history entries: the zero value is every entry,
// newest first.
type HistoryQuery struct {
	Kind   Kind   // "" = every kind
	Search string // full text over the texts; under 3 characters a substring match
	Limit  int    // 0 = no limit
	Offset int
}

// History stores finished sessions.
type History interface {
	// Put inserts or replaces an entry (by ID); its audio file, if any,
	// must already be in AudioDir.
	Put(ctx context.Context, e Entry) error
	Get(ctx context.Context, id string) (Entry, error)
	List(ctx context.Context, q HistoryQuery) ([]Entry, error)
	// Delete removes the entry and its audio file.
	Delete(ctx context.Context, id string) error
	// DeleteAll removes every entry of kind ("" = all) and their audio,
	// and reports how many went.
	DeleteAll(ctx context.Context, kind Kind) (int, error)
	// AudioDir is the directory history audio lives in. Pure.
	AudioDir() string
}

// Term is an entry of the user's dictionary: a name or a word of jargon
// the speech model should expect and the language model should keep as
// written.
type Term struct {
	ID   string
	Term string // as it must be written: "VoxtNew", "Kubernetes"
	// Aliases are what speech recognition tends to make of it ("aura
	// link"), for the glossary's "write X for Y".
	Aliases   []string
	Note      string // the user's note; not sent anywhere
	Enabled   bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Dictionary stores the user's terms.
type Dictionary interface {
	// Put inserts or replaces a term (by ID); another term with the same
	// spelling (ignoring case) is core.ErrExists.
	Put(ctx context.Context, t Term) error
	Get(ctx context.Context, id string) (Term, error)
	// List returns the terms matching search ("" = all), A to Z.
	List(ctx context.Context, search string) ([]Term, error)
	Delete(ctx context.Context, id string) error
}
