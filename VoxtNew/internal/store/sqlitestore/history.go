package sqlitestore

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/egoist/mygo/plugins/sqlite"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/core"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

// historyRepo stores finished sessions (the history table: migration 001,
// rule_source 002, sent_ms 003, dsp and gain_db 004).
type historyRepo struct {
	db  *sqlite.DB
	dir string
}

func (r *historyRepo) AudioDir() string { return r.dir }

// historyColumns are the columns an Entry has, in scanEntry's order.
const historyColumns = `id, kind, created_at, status, error, app_bundle, app_name, url_host, rule_id, rule_name,
raw_text, source_text, prompt_text, result, target_lang, delivery, asr_provider, asr_model, llm_provider, llm_model,
audio_ms, asr_ms, llm_ms, total_ms, audio, rule_source, sent_ms, dsp, gain_db`

var historyUpsert = func() string {
	cols := strings.Split(strings.ReplaceAll(historyColumns, "\n", " "), ",")
	var set []string
	for i := range cols {
		cols[i] = strings.TrimSpace(cols[i])
		if cols[i] != "id" {
			set = append(set, cols[i]+" = excluded."+cols[i])
		}
	}
	return `INSERT INTO history (` + strings.Join(cols, ", ") + `) VALUES (` + strings.TrimSuffix(strings.Repeat("?, ", len(cols)), ", ") + `)
ON CONFLICT(id) DO UPDATE SET ` + strings.Join(set, ", ")
}()

func (r *historyRepo) Put(ctx context.Context, e store.Entry) error {
	if err := validID(e.ID); err != nil {
		return err
	}
	if !slices.Contains(store.Kinds, e.Kind) {
		return fmt.Errorf("history %s: kind %q: %w", e.ID, e.Kind, core.ErrInvalid)
	}
	if e.Status == "" {
		e.Status = store.StatusDone
	}
	if e.Audio != "" && filepath.Base(e.Audio) != e.Audio {
		return fmt.Errorf("history %s: audio %q: %w", e.ID, e.Audio, core.ErrInvalid)
	}
	_, err := r.db.Execute(ctx, historyUpsert,
		e.ID, string(e.Kind), e.CreatedAt.UnixMilli(), string(e.Status), e.Error, e.AppBundle, e.AppName, e.URLHost, e.RuleID, e.RuleName,
		e.RawText, e.SourceText, e.PromptText, e.Result, e.TargetLang, e.Delivery, e.ASRProvider, e.ASRModel, e.LLMProvider, e.LLMModel,
		e.AudioMS, e.ASRMS, e.LLMMS, e.TotalMS, e.Audio, e.RuleSource, e.SentMS, e.DSP, e.GainDB)
	return wrap("history "+e.ID, err)
}

func scanEntry(row []any) store.Entry {
	str := func(i int) string { return asString(row[i]) }
	return store.Entry{
		ID: str(0), Kind: store.Kind(str(1)), CreatedAt: fromMS(row[2]), Status: store.Status(str(3)), Error: str(4),
		AppBundle: str(5), AppName: str(6), URLHost: str(7), RuleID: str(8), RuleName: str(9),
		RawText: str(10), SourceText: str(11), PromptText: str(12), Result: str(13), TargetLang: str(14), Delivery: str(15),
		ASRProvider: str(16), ASRModel: str(17), LLMProvider: str(18), LLMModel: str(19),
		AudioMS: asInt(row[20]), ASRMS: asInt(row[21]), LLMMS: asInt(row[22]), TotalMS: asInt(row[23]), Audio: str(24),
		RuleSource: str(25), SentMS: asInt(row[26]), DSP: str(27), GainDB: asFloat(row[28]),
	}
}

func (r *historyRepo) Get(ctx context.Context, id string) (store.Entry, error) {
	rows, err := r.db.Query(ctx, `SELECT `+historyColumns+` FROM history WHERE id = ?`, id)
	if err != nil {
		return store.Entry{}, wrap("history "+id, err)
	}
	if len(rows.Values) == 0 {
		return store.Entry{}, fmt.Errorf("history %s: %w", id, core.ErrNotFound)
	}
	return scanEntry(rows.Values[0]), nil
}

func (r *historyRepo) List(ctx context.Context, q store.HistoryQuery) ([]store.Entry, error) {
	var where []string
	var args []any
	if s := strings.TrimSpace(q.Search); s != "" {
		if useFTS(s) {
			where = append(where, `seq IN (SELECT rowid FROM history_fts WHERE history_fts MATCH ?)`)
			args = append(args, ftsPhrase(s))
		} else {
			p := likePattern(s)
			where = append(where, `(raw_text LIKE ? ESCAPE '\' OR source_text LIKE ? ESCAPE '\' OR prompt_text LIKE ? ESCAPE '\' OR result LIKE ? ESCAPE '\')`)
			args = append(args, p, p, p, p)
		}
	}
	if q.Kind != "" {
		where, args = append(where, `kind = ?`), append(args, string(q.Kind))
	}
	sql := `SELECT ` + historyColumns + ` FROM history`
	if len(where) > 0 {
		sql += ` WHERE ` + strings.Join(where, ` AND `)
	}
	sql += ` ORDER BY created_at DESC, id DESC`
	sql, args = page(sql, args, q.Limit, q.Offset)
	rows, err := r.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, wrap("history", err)
	}
	out := make([]store.Entry, 0, len(rows.Values))
	for _, row := range rows.Values {
		out = append(out, scanEntry(row))
	}
	return out, nil
}

// Delete removes the row, then the audio file (a missing file is fine).
func (r *historyRepo) Delete(ctx context.Context, id string) error {
	rows, err := r.db.Query(ctx, `DELETE FROM history WHERE id = ? RETURNING audio`, id)
	if err != nil {
		return wrap("history "+id, err)
	}
	if len(rows.Values) == 0 {
		return fmt.Errorf("history %s: %w", id, core.ErrNotFound)
	}
	return r.removeAudio(asString(rows.Values[0][0]))
}

func (r *historyRepo) DeleteAll(ctx context.Context, kind store.Kind) (int, error) {
	sql, args := `DELETE FROM history RETURNING audio`, []any(nil)
	if kind != "" {
		sql, args = `DELETE FROM history WHERE kind = ? RETURNING audio`, []any{string(kind)}
	}
	rows, err := r.db.Query(ctx, sql, args...)
	if err != nil {
		return 0, wrap("history", err)
	}
	var first error
	for _, row := range rows.Values {
		if err := r.removeAudio(asString(row[0])); err != nil && first == nil {
			first = err
		}
	}
	return len(rows.Values), first
}

func (r *historyRepo) removeAudio(file string) error {
	if file == "" || filepath.Base(file) != file {
		return nil
	}
	if err := os.Remove(filepath.Join(r.dir, file)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("removing %s: %w", file, err)
	}
	return nil
}
