# Auralink architecture

*State: M6, polish for 0.1: Home, the setup guide, the settings' remaining sections, the menu bar (2026-10-15). Product plan: the project's `plan/auralink-plan.md` (§4 architecture, §5 data, §8 engineering). Behaviour compared with Voxt: [behavior.md](behavior.md). Helper wire format: [helper-protocol.md](helper-protocol.md).*

Auralink is a Go app on MyGo (native UI, no cgo) with one small Swift helper process. It reuses AudioSmith's engineering (AudioSmith @f171c86, Apache-2.0): its window shell, UI kit and tokens, settings, store, i18n, logs and notification code, and its engine supervisor reduced to one helper. What it took and how it changed is in §5.

## 1. Package map

```
github.com/hehehai/Auralink
├── *.go                  package main: the UI (views + view state) and the wiring
├── internal/
│   ├── core/             event bus, ULIDs, error sentinels, notifications and log lines        (leaf)
│   ├── settings/         the typed, versioned settings document (v1) + Service                 (leaf)
│   ├── store/            persistence contract: Documents, History, Dictionary
│   │   └── sqlitestore/  SQLite (MyGo plugin): migrations, backup, FTS5 trigram, maintenance
│   ├── helper/           supervisor of auralink-helper: handshake, restarts, stderr to the log, call traces
│   │   ├── proto/        the helper protocol's wire types (leaf); fixtures in helper/Fixtures/
│   │   └── helpertest/   a fake helper for tests (the test binary re-runs itself); cmd/fakehelper
│   ├── i18n/             T / N / X keyed by English source; locales/*.json; dates              (leaf)
│   ├── icons/            Solar icons (names.txt → solar_gen.go)
│   ├── logs/             log ring + rotated files
│   ├── notify/           the notification centre (kept in the store's documents)
│   ├── lang/             the language table, 652 languages                                     (leaf)
│   ├── secrets/          API keys in the Keychain, service "Auralink"                          (leaf)
│   ├── netx/             the proxy (settings.Network) and the HTTP client every provider uses  (leaf)
│   ├── permission/       Microphone and Accessibility (purego on darwin; Fake for tests)       (leaf)
│   ├── macx/             activating an app again before a paste (purego on darwin); the       (leaf)
│   │                     recording's sounds (afplay)
│   ├── asr/              remote speech recognition: FileTranscriber, Streamer/Stream, error kinds,
│   │   │                 endpoint policy, WebSocket dial through the proxy, WAV/PCM helpers
│   │   ├── openai/       OpenAI-compatible /audio/transcriptions (multipart upload)
│   │   ├── doubao/       Volcengine big-model streaming ASR (binary frames, gzip)
│   │   ├── aliyun/       Model Studio: inference (fun-asr, paraformer) and realtime (qwen3-asr) WebSockets
│   │   └── asrtest/      loopback WebSocket server, golden files, E2E switches (tests only)
│   ├── llm/              chat models (from AudioSmith): presets, OpenAI/Anthropic transports, retries,
│   │                     JSON repair, usage, skills and routing, Probe
│   ├── providers/        settings.Providers ↔ asr/llm: presets of the Models page, readiness, the
│   │                     service a feature uses, building clients, connection tests
│   ├── session/          the one owner of a voice session: the state machine (reading →
│   │                     recording → recognizing → composing → delivering → done/cancelled/
│   │                     failed), the selection, Translate's and Rewrite's streaming answer, its
│   │                     snapshots, the history entry; adapters over the helper (helperio.go)
│   ├── vad/              local voice activity detection (energy over an adaptive noise floor, no
│   │                     model): Analyze, Compact (file services), Gate (streams), Merge   (leaf)
│   ├── dsp/              the sound of what a speech service gets: a high-pass filter (4th-order
│   │                     Butterworth, 80 Hz), one gain from the speech (files) or a slow one
│   │                     (streams, Leveler), a peak limiter; pure Go
│   ├── compose/          the layered prompt composer: Transcribe, Translate, Rewrite;
│   │                     templates/{en,zh-Hans}; 112 golden prompts; Untranslated, ParseAnswer
│   ├── deliver/          the insert transaction: textio.focus, then textio.paste or the answer card
│   ├── hotkey/           the shortcuts' grammar, bindings for hotkey.configure and the Carbon
│   │                     fallback, conflict checks, routing an event to an action
│   ├── appctx/           app enhancement: groups (document appctx:rules), URL rules and their
│   │                     matching, the order URL → the browser's group → the app's group → none,
│   │                     the built-in browsers, auto keys
│   ├── appicons/         apps' icons for the lists that name apps: which are wanted, asked for,
│   │                     there or missing; the PNGs on disk (a week fresh); fetching a batch
│   ├── appbundle/        the version of the app bundle on disk (Info.plist), to tell an update      (leaf)
│   │                     installed while the app runs (updates.go, helper.Config.Stale)
│   ├── overlay/
│   │   ├── layout/       the overlay's geometry as numbers: the pill's, the live text's, a notice's and
│   │   │                 the answer card's sizes (Voxt's), the shadow's margin, the frame anchored to an
│   │   │                 edge of the display, the waveform's bars, the loader's dots (mygo.Rectangle only)
│   │   └── ink/          the overlay's ink check: the face and its strokes measured from a picture, against
│   │                     the layout (Tester renders on Linux, the window's captures on the Mac)
│   ├── demo/             the demo build's machinery (-tags demo imports it): the services' traffic recorded
│   │                     and replayed per take, the keys in memory, keys.env, the bundle's identifier
│   ├── uitext/           the words the UI shows from the domain's values (shortcuts, providers' errors,
│   │                     a session's state, history entries, sizes and times, the menu bar's labels):
│   │                     i18n, no MyGo; the one internal package that imports i18n
│   ├── datadir/          where the data folder is: location.json, a move or an erase finished at the
│   │                     start (Resolve, before the library opens), copying and checking a tree
│   ├── dict/             the dictionary's rules: cleaning a term, hints for speech services,
│   │                     CSV and text import and export, merging an import
│   ├── archtest/         tests of the code's structure only: file sizes, import layering ("Code structure rules")
│   └── tools/            developer commands (standard library only): snapcmp (snapshot comparison),
│                         declhash (pure-move check)
├── helper/               the Swift helper (helper/README.md): Sources/, Tests/, Fixtures/, Support/
└── third_party/mygo/     MyGo 0.4.8 with three patches (scripts/vendor-mygo.sh)
```

The plan's `textio` is the helper's `textio.*` (session.HelperText adapts it).

### Import rules

Arrows point to what a package may import. No cycles. Leaves import nothing internal.

```
main ──▶ every internal package
store ──▶ core                 store/sqlitestore ──▶ core, store      datadir ──▶ store/sqlitestore    overlay/layout ──▶ session (Bars), settings (Overlay)    overlay/ink ──▶ overlay/layout
uitext ──▶ i18n and the domain's types (appctx, asr, compose, core, deliver, dict, helper, helper/proto, hotkey, lang, llm, permission, providers, session, settings, store)
helper ──▶ core, helper/proto  helper/helpertest ──▶ helper/proto
notify, logs ──▶ core
asr ──▶ core, netx            asr/openai, doubao, aliyun ──▶ asr, netx     asr/asrtest ──▶ (nothing internal)
llm ──▶ core                  providers ──▶ asr (+ its providers), llm, settings, netx
session ──▶ appctx, asr, compose, core, deliver, dict, dsp, helper/proto, lang, llm, settings, store, vad
dsp ──▶ vad
compose ──▶ lang              deliver ──▶ helper/proto      hotkey ──▶ helper/proto, settings
appctx ──▶ helper/proto, hotkey, settings                    dict ──▶ store
appicons ──▶ helper/proto
core, settings, helper/proto, i18n, lang, secrets, netx, permission, macx, vad, appbundle ──▶ (nothing internal)
icons ──▶ mygo/ui
```

The domain packages (session, compose, deliver, hotkey, appctx, dict, asr, llm) are pure Go behind narrow interfaces, with the macOS parts behind them: recording, the event tap, the app in front, AX reads (text, browser addresses) and pasting in the helper; the permission reads before the helper runs and `macx.Activate` in purego code. That keeps their logic testable on Linux with fakes (plan §1.4): the fake helper plays recordings, scripted hotkey events and text I/O.

Event types live next to their publisher, and their topic starts with the publisher's name. They satisfy `core.Event` (a `Topic() string` method) without importing `core`:

| Event | Topic | Publisher |
|---|---|---|
| `core.NotificationPosted`, `core.LogAppended` | `notification.posted`, `log.appended` | notify, logs |
| `settings.Changed` | `settings.changed` | the settings store, after saving |
| `helper.StatusChanged` | `helper.status` | the supervisor |

### Why the UI stays in package main

MyGo builds the root `main` package (`mygo dev`, `mygo build`, `ui.View`); views need the window and its main thread. The domain, which must be goroutine-safe and testable, is in `internal/`. Each area of the UI keeps its fields in a struct of its own, embedded in `app` (app.go).

### Code structure rules

`internal/archtest` checks these with every `go test ./...`; each failure says how to fix it (the rules from AudioSmith's refactor, the plan of refactor R0–R8).

- **File size.** A Go file has at most 600 lines, a test file 800; code should keep to about 400 (files over it are reported by `go test -v -run TestFileSizes ./internal/archtest`, not failed). Generated files, `third_party/`, `testdata/`, `build/` and the Swift helper are not counted. The files over the limit today are listed in `internal/archtest/allowlist.txt` with their size as a ceiling, why they are long and the batch that splits them: they may shrink, not grow, and leave the list once split. Functions over 150 lines are reported (`-run TestLongFuncs`).
- **Layering.** Leaves (above) import nothing internal; only `icons` uses `mygo/ui`, and only `store/sqlitestore` (`plugins/sqlite`) and `overlay/layout` (`mygo`, for `mygo.Rectangle`) another MyGo package; only `uitext` may import `i18n` (the domain returns codes and errors, package main and `uitext` say them); fakes (packages whose name ends in `test`) are for tests; `internal/tools` is standard library only. The rules and their reasons are in `internal/archtest/imports_test.go`.
- **Every internal → internal import is listed** in `internal/archtest/imports.txt` (`from to`, paths under `internal/`). A new dependency adds a line there, so that review sees it; a line no import needs fails until removed.
- **Refactors that only move code** prove it: `go run ./internal/tools/declhash . ./internal/...` on the base and on the branch print the same lines (a hash per top-level declaration, comments and build constraints included; `-nocomments` tells a move that also updated the file names comments mention), and `scripts/snapshots.sh check` renders every set of UI snapshots of both and compares them pixel for pixel (§6). Snapshots are reproducible: `snapshot_env_test.go` pins the clock (a `testing/synctest` bubble), the data directories, the free disk space and the sizes Settings → Storage measures.

## 2. Processes and data flow

```
          MyGo main thread                          goroutines
┌──────────────────────────────┐  calls (go …)  ┌──────────────────────────────────────────┐
│ views (build pass: no I/O)   │──────────────▶ │ library: store (SQLite) · bus · settings │
│ app view state + snapshots   │                │ helper.Supervisor ──stdio JSON lines──▶ auralink-helper (Swift)
│        ▲ Window.Update       │                │    capture.* · hotkey.* · textio.* · app.* · browser.url · permissions.*
└────────┼─────────────────────┘                └──────────────────────────────────────────┘
   core.Bus subscribers ◀── Publish ─────────────┘
   (wiring code, once)
```

main.go wires, in order: the single-instance lock → the updater plugin (`mygo.Use(native.New(…))`, updates.go; release builds only can update, docs/release.md) → `datadir.Resolve` (finishes a pending move or erase of the data folder) → `openLibrary` (store migrated, bus, settings) → `newHelperHost` (finds the helper) → `newApp` → `connectShell` (log files, deep links) → `connectHelper` (the supervisor, its status and notifications) → `connectUpdates`. When MyGo is ready: the window, `applyBeta` (Beta updates, before the first check), `startHelper`, the menu bar icon, `watchBundle` (an update installed while it runs). On quit: the tray, the helper (`helper.shutdown`), the notifications and logs, then the database.

There is no job queue (plan §5): a session lives in memory, owned by one state machine (`internal/session`), and writes one history entry when it ends.

### A session

```
hotkey.event (helper) ─▶ helperNotified ─▶ hotkeyFired ─▶ hotkey.Route ─▶ startSession (session_control.go)
   sessionBlocker: helper ready? the services the feature needs? (memory only)  ─ no ─▶ a notice in the overlay
   (Rewrite's shortcut on a Rewrite answer card: followUpAnswer, the card's turns as Previous)
   session.Manager.Start ─▶ goroutine:
      capture.start (job, the session's id) ─▶ capture.pcm ─▶ memory ─▶ Stream.Send (streaming services)
      Resolver (keys from the Keychain, providers.NewASR/NewLLM) and the dictionary, meanwhile
      app enhancement, meanwhile: a browser's address (browser.url by the front's pid, 800 ms),
         appctx.Resolve(rules, front, address, feature) ─▶ the snapshot's Scene (the overlay's label)
   Stop (a shortcut, the menu bar) ─▶ capture.stop ─▶ Finish / upload ─▶ the text
         (internal/dsp: high-pass 80 Hz, then the level: one gain for an upload, a slow one after a stream's gate; a limiter)
         (internal/vad: a stream gets nothing before the speech, an upload no silence around it; no speech: nothing is sent)
         (the recording kept in the history is the original)
   compose.Build (+ the Scene layer, the glossary) ─▶ one chat (8 s) ─▶ compose.Clean      (fails: the text as recognised, a warning)
   deliver.Insert: textio.focus ─▶ textio.paste {targetPid, press: the group's auto key}   (or the answer card)
Translate: textio.selection {allowCopy: session.AllowCopy(app)} first ─ text ─▶ compose (no recording)
           ─ none ─▶ record and recognise as above ─▶ compose
Rewrite:   textio.selection while recording; the instruction (+ the selection) ─▶ compose
   deliver.Check ─ would not insert ─▶ the answer streams into the card
   one streaming chat (60 s; Rewrite without a selection: JSON {title, content}) ─▶ Draft
   Translate: compose.Untranslated? ─▶ once more with the Strict layer
   fails ─▶ failed, in the card with Try again (retryAnswer: StartRequest.Text)
   history entry (+ audio/<id>.wav) ─▶ the end snapshot
snapshots ─▶ a.post ─▶ sessionChanged ─▶ (events.go, in order) the setup guide, the start and stop sounds;
                                         hotkey.configure {active}; the menu bar (its menu and recording icon), the overlay;
                                         at the end: Home, the card or a notice, then onHistory (Home, the menu bar, History)
```

While a session is live (or the answer card shows) the bindings go to the helper with `active`: a tap fires at once and Escape is reported. Without Accessibility the event tap is not installed; the bindings Carbon can express are registered with `mygo.GlobalShortcut` until it is.

## 3. Threading and state rules

1. **The build pass does no I/O.** A view reads only `app` fields, snapshots and memory-only getters (`settings.Service.Get`, `i18n.T`). Store, Keychain, network and helper calls happen in handlers that start a goroutine (`a.async`, `helperCall`).
2. **`app` is main-thread only.** Goroutines reach it through `a.post(fn)` (`Window.Update`). In tests `post` runs fn at once, or queues it (`postQueue`) in tests that run real goroutines (the supervisor against the fake helper process).
3. **Bus subscriptions are set up once, in wiring code** (`openShell`, `connectHelper`), never in a build pass. Handlers must not block. Publishers publish after their change is durable, never while holding a lock.
4. **Domain packages are goroutine-safe**, take a `context.Context` when they may block, return copies, and wrap `core.Err*` sentinels.
5. **MyGo lifetime rules hold** (`.agents/skills/mygo-maintenance`): keys before stateful widgets; never store elements; dialogs on goroutines; persistent callbacks capture `c.Services()`, not the `Context`.
6. **The helper is stateless.** Truth (history, dictionary, settings, rules, keys) lives in Go. A helper crash fails its calls (`core.ErrHelper`) and the supervisor restarts it; nothing is lost. Late notifications of a finished job are dropped.

### Seams inside package main

| Seam | Defined in | Used by |
|---|---|---|
| `a.lib` (`*library`: store, bus, settings) | library.go | every area |
| `a.navigate(path)`, `a.showPage(name)`, `a.currentPage()`, `a.shownPath()`; `movedPaths` (old paths, e.g. `/permissions` → `/settings/permissions`) | shell.go, shell_pages.go, shell_settings.go | palette, deep links, notifications, tests |
| `navGroups`, `shortcutPages` (⌘1–⌘6), `pageTitle`, `a.navBadge` | shell_pages.go | sidebar, rail, palette, Go menu |
| `a.page(c, p)`, `a.pageShown(path)` | pages.go | the router: each page's view, and what it reads when it shows |
| `a.updateSettings(fn)`, `a.prefs`, `settingsSections()`, `a.settingsShown(sub)`, `a.setMainLanguage(code)`, `a.syncOpenAtLogin()` | shell_settings.go (the dialog, `settingsState`), settings_general.go, settings_locale.go | every area that changes a setting; sections that read something when they open; the window's opening (shell.go) |
| `a.railMode()` (the only place that decides: the user's choice, else a window narrower than 740), `a.setRail(on)` | shell_nav.go | the sidebar, `pageWidth`, Settings → Appearance |
| `a.audio` (the inputs `capture.devices` listed), `a.loadDevices()`, `a.audioShown()`, `deviceInUse(list, devs)`, `a.playSound` (`macx.Play`; tests record), `recordingCue(was, s)`, `a.playCue(was, s)` | settings_audio.go | Settings → Audio, helperlink.go (a helper that became ready), session_link.go (`sessionChanged`) |
| `faceStyle(e, o, mode, h)`, `overlayPill(c, s, mode, look)`, `a.overlayRestyle()` | overlay_face.go, overlay.go | the overlay, the preview of Settings → Overlay style (settings_overlay.go), `settingsChanged` |
| `uitext.TriggerText(trigger)` (its name; the setup guide's `uitext.TriggerHowText` says how to use it), `featurePath(feature)` | internal/uitext (keys.go), settings_shortcuts.go | Settings → Shortcuts |
| `a.trayItems()`, `a.loadTrayRecent()` (the last three results), `trayicon.Icon(recording)` (Voxt's microphone, `internal/trayicon`), `a.copyText` (tests) | tray.go | `historyChanged`, the menu bar |
| `a.helperStatus()`, `helperCall[T](a, method, params, timeout, then)`, `a.helperNotified(m)`, `a.restartHelper()`, `a.hotkeys` (hotkey.state), `a.front` (app.activated) | helperlink.go | the helper's card (shell_notices.go), Home, permissions, Diagnostics, sessions |
| `a.mgr` (`*session.Manager`), `a.sess` (the newest snapshot), `a.startSession(req)`, `a.startTranscribe(target, hold, try)`, `a.sessionBlocker(kind)`, `a.stopSession()`, `a.cancelSession()`, `a.toggleTranscribe()`, `a.pasteLast(target)`, `a.answer` + `openAnswer` / `insertAnswer` / `copyAnswer` / `closeAnswer` / `retryAnswer(lang)` / `followUpAnswer(hold)`, `a.showNotice`, `sessionProblemText(p)`, `a.syncHotkeys()` | session_link.go (the snapshots, notices), session_control.go (start, stop, paste the last), session_answer.go (the card's actions), session_hotkeys.go | the overlay, the feature pages' Try areas, the menu bar, helperlink.go |
| `a.overlaySync()`, `a.ov` (mode, size, visible), `a.later(d, fn)` (timers; `laterHook` in tests), `overlayView`, `waveform` / `layout.WaveBars`, `overlayLoader`, `uitext.WorkingText(s)`, `kindIcon`, `uitext.KindTitle`, `cardNow`, `uitext.TargetLanguageLabel`, `noticeActionLabel` | overlay.go (state, sync), overlay_size.go, overlay_face.go, overlay_wave.go, overlay_card.go; the texts in internal/uitext (session.go) and session_text.go | session_link.go; the feature pages and History reuse the texts |
| `a.featurePage(c, feature)`, `a.fui(feature)` (each page's controls), `featureKind`, `uitext.HotkeyText`, `uitext.FeatureTitle` | feature_page.go; feature_keys.go, feature_services.go, feature_prompts.go; internal/uitext (keys.go: shortcuts' words) | pages.go (Transcribe, Translate, Rewrite) |
| `a.historyChanged()` | history_page.go (history_detail.go: an entry's details; internal/uitext history.go: its words) | session_link.go, after an entry is kept or changed |
| `a.aeBook` (`ruleBook`: the groups for sessions, goroutine-safe), `a.aeRules` + `a.setRules(r)`, `a.sceneConfig()`, `a.urlReads`, `a.frontChanged(app)`, `a.lastOther`, `a.previewApp()`, `a.refreshPreview(force)`, `a.previewMatch()` | appenhance.go | session_link.go (the manager's Scene), helperlink.go (app.activated), the App enhancement page |
| `uitext.SourceText(source, pattern)` | internal/uitext (history.go) | History's details, App enhancement's preview |
| `a.loadDict()`, `a.openTerm(term)`, `chooseImportFile`, `chooseExportFile` (test seams) | dictionary_page.go | the Dictionary page |
| `a.permSys` (`permission.System`), `a.recheckPermissions()`, `a.askPermission(which)` | permissions.go | Settings → Permissions, Diagnostics, Home, the setup guide |
| `a.tryCard(c, tryOpts)` (a Try area), `a.tryIntro(feature)`, `a.startTry(kind)`, `a.startSessionID(req)` (the id, to tell a try from another session) | try_card.go, session_control.go | the feature pages, Home, the setup guide |
| `a.tryPlace(kind, target)` (where a shortcut pressed while Auralink is in front runs as a try), `a.tryStarted`, `a.homeChanged()`, `readHome` (today's numbers and the recent results, off the main thread), `a.readinessList()`, `a.openHistoryEntry(e)` | home_page.go, home_ready.go (readiness), home_try.go (try places) | session_hotkeys.go (`hotkeyFired`), history_page.go (`historyChanged`) |
| `a.openOnboarding()`, `a.maybeOnboard()` (first start), `a.obSessionChanged(s)` (a step passes on its own session's result), `a.obOwns(id)`, `a.onboardingRow(c)` | onboarding.go (onboarding_view.go: the dialog; onboarding_steps.go: the steps) | shell.go (`openWindow`), session_link.go, Settings → General, Home, ⌘K |
| `floatingWindowOptions(…)`, `showFloating(w, x, y)` (non-activating windows, mygo patch 0003), `hudContent(view)` (their text unsmoothed, patch 0005), `activateTarget(pid)` (`macx.Activate`) | floating.go | the recording pill and the answer card (M3, M4) |
| `a.upd` (`updateService`: MyGo's updater plugin; `fakeUpdates` in tests), `a.checkForUpdates()`, `a.updateMenuItems(act)`, `a.bundleStale` (`appbundle.Updated`), `a.appUpdated()` (the restart card), `a.relaunch()` (`appRelaunch`) | updates.go | the app menu, the menu bar, ⌘K, Settings → About, the helper's card (FailUpdated), Home |
| `a.toast(msg)`, `a.notify(…)`, `a.post(fn)`, `a.async(fn)` | app.go, shell_notices.go | everyone |
| `a.onSession`, `a.afterSession`, `a.onSessionEnd`, `a.onHistory` (observers, in order; `connectEvents` lists them all), published by `sessionChanged` / `sessionEnded` (session_link.go) and `historyChanged` (history_page.go) | events.go | the setup guide, the sounds, the menu bar, the overlay, Home, History: an area that cares about sessions or the history adds itself there, instead of the publisher calling it |
| `a.notices` (the centre's, newest first), `a.noticeStack(c)` (the cards at the foot of the sidebar; the rail's popover), `a.setProblem(id, code, n)` (a problem's card: shown once, withdrawn when solved, kept away this run once dismissed), `a.checkServices()`, `a.checkHelper()` | shell_notices.go | the sidebar, the rail; key reads and saves (providers_page.go), `settingsChanged`, `helperChanged` |
| `a.keys` (`keyring`: the Keychain; memory in tests), `a.keyMasks`, `a.hasKey(account)`, `a.keysKnown`, `uitext.ProviderName(kind, p)`, `uitext.ProviderErrorText(err)` | providers_page.go, providers_dialog.go; internal/uitext (provider.go) | Model services page, the services' card; sessions read keys through `a.keys` off the main thread (`resolver`, session_link.go) |
| `uitext.HotkeyGlyphs(keys)` | internal/uitext (keys.go) | ? sheet, menu bar, feature pages |
| Design tokens: `tok(t)`, `px`, `fs*`, `sp*`, `radius*`; `accentName` (teal) | ui_tokens.go | every view |
| UI kit (AudioSmith 0.3): buttons by rank, `pageHeader`, `card`, `formRow`, `settingRow`, `emptyState`, `notice`, `sidePanel`, `dialogFrame`… | ui_kit.go (its overview), ui_buttons.go, ui_marks.go, ui_layout.go, ui_panels.go, ui_forms.go (AudioSmith's split), ui_rows.go (`settingRow`, `sectionTitle`) | every view |

## 4. Data on disk (macOS)

| What | Where |
|---|---|
| Database: history (+ `history_fts`; `rule_source` since migration 2), dictionary terms, documents (`settings:app`, `appctx:rules`, `notifications`) | `~/Library/Application Support/Auralink/auralink.db` (WAL; `auralink.db.bak-<v>` before each migration) |
| Recordings kept with history entries | `…/Auralink/audio/<id>.wav` (only with Settings → Privacy → Keep the recordings) |
| Data folder location | `…/Auralink/location.json` when the user moved it (Settings → Storage); `move.json`, `reset.json` while a move or an erase waits for the next start |
| Apps' icons (App enhancement's lists) | `~/Library/Caches/Auralink/icons/<bundle id>-64.png`, drawn by the helper (`app.icons`), redrawn after a week (`internal/appicons`) |
| Logs | `~/Library/Logs/Auralink/auralink.log` (app, rotated at 5 MB) and `helper.log` (the helper's stderr) |
| Secrets | the login Keychain, service "Auralink": `asr.<provider>`, `llm.<provider>` |
| Helper | `Auralink.app/Contents/Resources/helper/auralink-helper` (or `$AURALINK_HELPER`) |

## 5. What came from AudioSmith, and how it changed

| Auralink | From AudioSmith @f171c86 | Change |
|---|---|---|
| `ui_kit.go` (split as AudioSmith's: `ui_buttons.go`, `ui_marks.go`, `ui_layout.go`, `ui_panels.go`, `ui_forms.go`), `ui_tokens.go` | same files | comments; `setAccent` (accent review shots) dropped |
| `shell*.go` | same files | Auralink's sidebar groups and pages (a first group without a title); a smaller window (800×520, at least 680×440; AudioSmith 1100×720 and 820×520); no status bar: the version beside Settings, notifications as stacked cards over it (the rail: a dot, then a popover), the services and the helper as cards while something is wrong, instead of the bell, engine, jobs and downloads; no ⌘E quick switch; ? sheet lists the global shortcuts from the settings |
| `shell_settings.go`, `settings_*.go`, `internal/datadir` (`storage_move.go`), `sysinfo.go` | same files | ten sections: General (app, main and other languages, menu bar, open at login), Permissions (permissions.go), Audio (the microphones' order, sounds), Overlay style (with a preview), Shortcuts (the table of every shortcut), Appearance (the sidebar: automatic, names and icons, icons only), Network (proxy only, provider hosts), Privacy (history, recordings, text in logs), Storage (Auralink's folders; erase removes provider keys), About, 诊断与关于 in Chinese (helper instead of engine) |
| `permissions.go` | same file | a section of the settings dialog (after General): the Microphone and Accessibility only, through the helper; no browser Automation (addresses are read with AX) |
| `tray.go` | `dictation_tray.go` | Auralink's menu (the last three results, a click copies one); a sound-wave icon, with a dot while recording |
| `internal/core` | `core` | bus, ids, errors, notifications, log lines only; `Stream` dropped |
| `internal/settings` | `settings` | the Store kept; the document is new (v1, plan §3–§5) |
| `internal/store`, `sqlitestore` | same | Open, migrations, backup, `CheckFile`, `RewritePaths` kept; new schema and repositories; `Stats` instead of `Usage` |
| `internal/helper` (+ `proto`, `helpertest`) | `engine` (+ `proto`, `enginetest`) | one process instead of roles; no scheduler, memory budget or stats polling; notifications without a job go to `OnNotify`; protocol 1 with the helper's methods |
| `internal/secrets` | `hub/token.go` (`Keychain`, `Secret`) | service "Auralink"; no HF token |
| `internal/netx` | `hub/proxy.go` | unchanged rules |
| `internal/permission` | `dictation/system_darwin.go` | Microphone and Accessibility only; the page asks the helper first |
| `helper/` (Swift) | `engine/Sources` (`Server.swift`, `Capture.swift`, the protocol target's `Wire.swift`) and the M0 spikes | no MLX; the M0 spike's capture, event tap, text I/O and browser code, made protocol 1 (docs/helper-protocol.md §6) |
| `internal/i18n`, `icons`, `logs`, `notify`, `lang` | same | zh-Hans rebuilt from what Auralink uses (304 strings at M1); the icons of `names.txt` (53 at M6); log file `auralink.log` |
| `third_party/mygo`, `scripts/vendor-mygo.sh`, `scripts/mac.sh`, CI | same | renamed; patch 0003 (non-activating windows) is Auralink's |

| `internal/llm` | `llm` | no engine backend, no dubbing skills, no Ollama/LM Studio presets; skills `transcribe_enhance`, `translate_text`, `rewrite`; Volcengine Ark, MiniMax, StepFun, MiMo presets; `extraBody` (thinking off); https-only base URLs; `Probe` (its README) |

Not taken: jobs, hub (downloads), catalog, licence, engine's MLX side, services, dsp (Auralink's `internal/dsp` is its own), translate, text, doc, dub, api, mcp, workflow, telephony, watermark, gallery, voicedesign, audio, and the dictation's paste and clipboard code (pasting is the helper's `textio.paste`).

## 6. Testing

| What | Command | Notes |
|---|---|---|
| All Go tests | `CGO_ENABLED=0 go test ./...` | Views in `ui.Tester` with a fake supervisor in process; the real supervisor against the fake helper process; protocol fixtures; the store over real SQLite (the plugin's library is downloaded and checked once, or `MYGO_SQLITE_LIBRARY`); i18n key parity |
| MyGo vet | `go tool mygo vet .` | `go vet ./...` and the UI-lifetime checks |
| Race | `CGO_ENABLED=1 go test -race ./...` | needs cgo |
| Snapshots, compared | `scripts/snapshots.sh check [BASE]` (`twice`: is it reproducible?; `render DIR`) | every set below (main, min, home, overlay, ink) of BASE (default: the merge base with origin/main) and of the working tree, compared pixel for pixel by `internal/tools/snapcmp`; about a minute; the pictures of what differs in `$SNAP_TMP/diff`. New snapshot tests call `runSnapshots` and make their directories with `testDir` (snapshot_env_test.go). The overlay's flows (`AURALINK_FLOW_SHOTS`) are left out: they run real goroutines, and their tests check the steps |
| Snapshots | `AURALINK_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .` | every page, the settings sections and the overlays, light/dark, en/zh-Hans, 2×; the window's default size (800×520); `AURALINK_SNAPSHOTS_SIZE=680x440` (or `min`) for the smallest; the foot of the sidebar with none, one and three notifications and the rail's dot and popover (`sidebar-notices-*`, `rail-notices*`) |
| Swift helper | `scripts/mac.sh 'cd helper && swift test'` | the wire types against helper/Fixtures (the same lines the Go tests decode), the hotkey recognizer, the PCM framer; CI runs it on macOS (the `helper` job, with the release build and `go test ./internal/helper/...`) |
| Mac checks | `scripts/mac.sh 'AURALINK_MAC=1 go test -run "TestMacKeychain|TestNative|TestActivate|TestPlay" -v ./internal/secrets ./internal/permission ./internal/macx'` | the Keychain, the permission calls, activation, the recording's sounds |
| Packaged app | `scripts/mac.sh 'scripts/build-helper.sh && go tool mygo build'` | the helper, then the app; signing during development: README |
| Provider protocols | `go test ./internal/asr/... ./internal/llm ./internal/providers` | golden files of what each client sends (`testdata/*.golden`; `AURALINK_UPDATE_GOLDEN=1` rewrites them) against loopback servers replaying recorded answers |
| Settings (M6) | `go test -run 'TestAudioSettings|TestDeviceInUse|TestRecordingCues|TestSessionSounds|TestOverlayStyle|TestShortcutsSettings|TestOtherLanguages|TestAutoRail|TestStartHidden|TestTray' .`; `go test -run 'TestPlay' ./internal/macx` | the microphones' list over the fake helper's `capture.devices`, the cues of each change of a session, the overlay's settings, the shortcut table's problems and links, the automatic rail at 680 and 800 wide, the menu bar's items and icons |
| App enhancement, dictionary | `go test ./internal/appctx ./internal/dict`; `go test -run 'TestScene' ./internal/session`; `go test -run 'TestAppEnhancement|TestDictionary|TestSessionAppEnhancement|TestSceneConfig' .`; `go test -run Dictionary ./internal/asr/...` | URL rules and the matching order (table tests); sessions in a URL group, a browser's group, an app's group, none, an address that times out, the auto key; the dictionary's hints in each service's request (golden files) |
| Sound | `go test -v -run 'TestCompareVariants' ./internal/dsp` (the table of levels before and after; `AURALINK_DSP_OUT=dir` writes the WAVs); `AURALINK_DSP_E2E=1 go test -run TestE2EStepFun ./internal/dsp` (two real StepFun requests) | the filter's response at 50, 60, 80, 100, 200 Hz and 1 kHz, a DC offset at the start and a jump of it, chunks against the whole byte for byte; the gain rule (table), quiet speech raised as a file and as a stream, noise alone never raised, a stream's gain holding through silence and moving smoothly, the limiter on full-scale squares and on speech raised by 30 dB, nothing, a byte, zeros; the speech sample quiet, under hum, white and fan noise, and clipped (no speech frame cut, never over -1 dBFS, the stream's gain near the file's) |
| Sessions | `go test ./internal/session ./internal/vad ./internal/compose ./internal/deliver ./internal/hotkey`; `go test -run 'TestSession|TestOverlay|TestAnswer|TestTranslate|TestRewrite' .` | the state machine with in-process fakes (both kinds of speech service × the language model on, off, failing, timing out × cancel at each stage × a target that takes no text × late callbacks; Translate and Rewrite: a selection read, missing, failing, by ⌘C, the strict retry, the card by choice, by a target that takes no text and by length, the JSON answer, the text given at Start, follow-ups; the voice activity detection on the speech sample with silence and noise added, a stream held until the speech, a recording without speech sent nowhere; the overlay leaving the screen after each way a session ends, on a fake clock); the app over the fake helper process (`selection=`, `copy-selection=`, `readonly`, `paste-log=`) with loopback transcription, streaming and chat (streaming too) servers |
| Real services | `AURALINK_E2E=1 go test -run 'TestE2E' -v . ./internal/asr/... ./internal/providers` | keys from the environment or `~/.config/auralink-dev/keys.env` (`DOUBAO_APP_ID`, `DOUBAO_ACCESS_TOKEN`, `DASHSCOPE_API_KEY`, `OPENAI_API_KEY`, `STEPFUN_API_KEY`, `DEEPSEEK_API_KEY`); speech sample `testdata/speech/sample-zh-en.wav`; each test skips without its key |
| Headless on a Mac | `MAC_DIR=code/Auralink-mt scripts/mac.sh scripts/mac-e2e.sh [--offline]` | the real supervisor and Swift helper (`mac_e2e_test.go`, `AURALINK_MAC_E2E=1`): the helper's read-only methods, its test-only file input (`AURALINK_HELPER_CAPTURE_FILE`) against the speech sample, a Transcribe session with StepFun and DeepSeek, Translate and Rewrite with DeepSeek, the history in a temporary SQLite; text fit with Core Text. No window, key, tap, clipboard or microphone: it runs beside other work (manual-test.md, "自动真机测试（无界面）") |
| README media | [scripts/readme-media](../scripts/readme-media/README.md) | the demo build (`-tags demo`, demo.go: its own bundle ID, data and keys, driven by command files; demo_data.go: the sample data; internal/demo: the services' answers recorded and replayed, the keys in memory) on a Mac: window shots, takes in TextEdit over a backdrop, then `post.sh` on Linux into docs/images and docs/media |
| By hand on a Mac | [manual-test.md](manual-test.md) | what needs permissions, a GUI and real services: about 35 minutes, in order |
| Text fit | `AURALINK_TEXTFIT_PROBE=1` / `AURALINK_TEXTFIT_AUDIT=1 go test -run 'TestTextFits|TestTranslationsFit' .` | meaningful on macOS (Core Text) |
