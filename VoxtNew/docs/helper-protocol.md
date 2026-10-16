# Helper protocol 1

How Auralink (Go) talks to `auralink-helper` (Swift, [helper/](../helper/README.md)). Go types: `internal/helper/proto`. Swift types: `helper/Sources/AuralinkHelperKit/Wire*.swift`. Golden transcripts: `helper/Fixtures/*.jsonl`, decoded by both sides' tests. Supervisor: `internal/helper`.

It is a subset of AudioSmith's engine protocol 2 (`docs/protocol-v2.md` there): the same envelope, handshake and error shape, with one helper process instead of an engine per role, and methods of its own. Their shapes come from the M0 spikes on a Mac (the project's `research/spikes.md`); the differences from the spikes' draft are in §6.

**Change it in all places at once**: the Go types, the Swift types, the fixtures, the fake helper (`internal/helper/helpertest`) and this page. `go test ./internal/helper/proto` and `cd helper && swift test` fail when they disagree.

## 1. Transport

- The app starts the helper with no arguments; its working directory is the executable's. It is `Auralink.app/Contents/Resources/helper/auralink-helper`, or `$AURALINK_HELPER` (development: README, "Signing during development").
- One JSON message per line (UTF-8, `\n`), at most 4 MiB (`proto.MaxLine`); app → helper on stdin, helper → app on stdout. stderr is free-form text: the supervisor writes it to `~/Library/Logs/Auralink/helper.log` and to the logs panel (source `helper`).
- The helper exits when stdin closes or on `helper.shutdown`.
- macOS checks the helper's permissions (Microphone, Accessibility) against Auralink.app, its responsible process: the prompts and System Settings name Auralink, and a grant reaches the running helper (the event tap installs within 2 s, no restart).

## 2. Messages

| Shape | Members | Direction |
|---|---|---|
| request | `id`, `method`, `params`? | app → helper |
| notification | `method`, `params`? (no `id`) | helper → app |
| response | `id` + `result` or `id` + `error` | helper → app |

No `jsonrpc` member; ids are strings (`c1`… for control requests, the session's ULID for a capture). Unknown members are ignored. A member Go marks `omitempty` is absent when zero (Swift: an optional left nil); the others are always present.

Errors are `{"code": "…", "message": "…", "data"?: {…}}` with a string code:

| Code | When | data |
|---|---|---|
| `bad_request` | malformed params, an unknown permission, a capture.stop without job | |
| `method_not_found` | unknown method | |
| `not_initialized` | a request before `helper.hello` | |
| `protocol_mismatch` | hello with another protocol | `{"supported":[1]}` |
| `busy` | a recording runs already | |
| `cancelled` | the job was cancelled | |
| `permission_denied` | macOS refused | `{"permission":"microphone"\|"accessibility"}` |
| `device_unavailable` | no input started, or none gave audio | `{"device":"…"}` |
| `unsupported` | the helper cannot do it on this Mac | `{"capability":"…"}` |
| `timeout` | the helper gave up waiting on macOS | |
| `internal` | anything else | |

## 3. Sequencing

- `helper.hello` comes first; until it is answered every other request fails with `not_initialized`. The app refuses a helper whose `protocol` is not 1 (it is not restarted: rebuild it).
- Requests are answered in any order; each control request runs on its own, so an app slow to answer Accessibility does not hold up `capture.stop`.
- **Jobs** (`capture.start`) send notifications naming them in `job` (`capture.started`, `capture.level`, `capture.pcm`, `capture.restarted`, `log`) before their response; `job.cancel` makes them answer `cancelled`. `capture.stop` and `job.cancel` are answered after the job they end, so every frame has arrived when `capture.stop` answers.
- Notifications without `job` belong to no request: `hotkey.event`, `hotkey.state`, `app.activated` (and `log`). The supervisor hands them to `Config.OnNotify`; a notification naming a job that already answered is dropped.
- If the helper exits, its calls fail (`core.ErrHelper`) and the supervisor restarts it after 1 s, 2 s, 4 s… (at most 3 times in 10 minutes).
- **Timing.** The supervisor times each call's phases (`helper.Trace`: waiting for a ready helper, writing, the helper's answer, waking the caller) and logs a control request slower than 500 ms with them; the helper logs its own side of a request slower than 250 ms on stderr (queued, ran, and the time it waited for its main thread, where the clipboard and NSWorkspace run). The spikes saw 1–2 s round trips while the helper worked for tens of milliseconds; the two lines tell where such a call waited.

## 4. Methods

### Control

| Method | Params → result |
|---|---|
| `helper.hello` | `{protocol, app, logLevel?}` → `{protocol, version, pid, methods, device{name, os}}` |
| `helper.shutdown` | → `{}`, then exit 0 (a recording is cancelled) |
| `job.cancel` | `{job}` → `{cancelled}` |
| `permissions.status` | → `{microphone: "granted"\|"denied"\|"notDetermined"\|"restricted", accessibility}` |
| `permissions.request` | `{permission: "microphone"\|"accessibility"}` → as `permissions.status` |
| `capture.devices` | → `{devices: [{id, name, channels, sampleRate, default, transport?}]}` |
| `capture.start` **job** | `{devices?, sampleRate?, frameMs?, levelHz?, maxSeconds?}` → `{device, reason, frames, samples, seconds, restarts, peak, firstFrameMs?, cpuSeconds}` |
| `capture.stop` | `{job}` → `{stopped}` |
| `hotkey.configure` | `{bindings: [{id, modifiers, key?, behavior, swallow?}], doubleTapMs?, longPressMs?, tapMaxMs?, swallowFn?, active?}` → hotkey status |
| `hotkey.status` | → `{installed, accessibility, bindings, events, disabledByTimeout, missedEvents, maxCallbackMicros, error?}` |
| `app.frontmost` | → `{pid, bundleId?, name?}` |
| `app.list` | `{installed?}` → `{apps: [{bundleId, name, running, pid?, path?}]}` |
| `app.configure` | `{manualAccessibility?: [bundleId]}` → `{}` |
| `app.icons` | `{apps: [{bundleId, path?}], size?}` → `{icons: [{bundleId, png?}]}` |
| `textio.focus` | → `{pid, role?, subrole?, editable, selection?{location, length}, valueLength, error?}` |
| `textio.selection` | `{allowCopy?, copyTimeoutMs?}` → `{text?, via: "ax"\|"ax-range"\|"ax-marker"\|"copy"\|"none", ms, steps?}` |
| `textio.paste` | `{text, keepClipboard?, restoreDelayMs?, targetPid?, press?: [{key, modifiers?}], pressDelayMs?}` → `{posted, restored, clipboardTaken, ms, front?}` |
| `browser.url` | `{bundleId?, pid?}` → `{bundleId, url?, via: "ax-focus"\|"ax-document"\|"ax-weburl"\|"none", ms, error?, retried?}` |

### Notifications

| Notification | Params |
|---|---|
| `capture.started` | `{job, device, deviceName, fellBack, fallbackReason?, deviceSampleRate, deviceChannels, sampleRate, startMs}` |
| `capture.level` | `{job, seconds, rms, peak}` (dBFS, -120 is silence; ~20 Hz) |
| `capture.pcm` | `{job, seq, offset, data}` (`data`: base64 of mono PCM16 LE at the started rate; `seq` from 0 and `offset` in samples, without gaps; ~100 ms each, the last one shorter) |
| `capture.restarted` | `{job, reason: "noCallback"\|"configurationChange"\|"deviceLost", attempt, device}` |
| `hotkey.event` | `{binding, phase: "trigger"\|"down"\|"up", behavior: "tap"\|"doubleTap"\|"longPress", heldMs?, t, front?{pid, bundleId?, name?}}` |
| `hotkey.state` | the hotkey status, when the tap was installed (Accessibility granted) or removed (taken away) |
| `app.activated` | `{pid, bundleId?, name?}` |
| `log` | `{level, message, job?}` |

### Notes

**capture.start.** It tries `devices` (Core Audio UIDs, the user's order) in turn, then the default input (`fellBack`, `fallbackReason`); none starting is `device_unavailable`, the microphone not allowed `permission_denied` (not asked yet: macOS asks, and the job waits for the answer). The audio is resampled to `sampleRate` (16000) mono and cut into `frameMs` (100) frames. `capture.started` comes with the first audio from the input, 200–400 ms after the request (`startMs`): before it, the user's words are not heard. A watchdog rebuilds an engine that gives no audio within 1.2 s, the second time on the default input; a third silence ends the job (`device_unavailable` when no audio came at all, else the recording so far with reason `noCallback`). A configuration change rebuilds the engine (`capture.restarted`); the chosen device going away ends the recording with reason `deviceLost`, the default input follows the new default. `maxSeconds` ends it on its own (reason `maxSeconds`), a guard against a lost `capture.stop`. The app writes the WAV it keeps, from the frames.

**capture.start from a file (tests only).** With `AURALINK_HELPER_CAPTURE_FILE=<audio file>` in its environment the helper records that file instead of the microphone: any rate and channels AVAudioFile reads, through the same downmix, resampling, `PCMFramer`, `capture.started` (`device` is `file:<name>`, `deviceName` the file's name, `deviceSampleRate` and `deviceChannels` the file's), `capture.level`, `capture.pcm` and endings (`capture.stop`, `job.cancel`, `maxSeconds`) as a microphone, at a microphone's pace (`AURALINK_HELPER_CAPTURE_SPEED`, default 1, plays it faster), then silence until it is stopped. It never asks for the microphone, and has no watchdog or device watcher. **Only for tests** (`scripts/mac-e2e.sh`, `mac_e2e_test.go`): the app never sets it, and the helper says so on stderr when it is set.

**hotkey.configure.** It replaces every binding; an empty list removes the tap. A binding is a modifier-only chord (`key` absent: `{"fn":"any"}`, `{"fn":"any","shift":"any"}`, `{"command":"right"}`) or a key (`key`: a kVK code, 0 is A) with modifiers (`{"control":"any","command":"any"}` and 9 is ⌃⌘V); families are `fn`, `shift`, `control`, `option`, `command`, sides `any`, `left`, `right` (fn: `any`). Families not listed must be up. The recognizer judges a chord from the first modifier pressed to the last released: everything held in between is the chord (fn then ⇧ is fn+⇧), another key spoils it, a hold longer than `tapMaxMs` (1500) is no tap. A chord bound to both a tap and a double tap fires the tap after `doubleTapMs` (the system's double-click interval, at most 800, else 500) unless a second press starts within it. `longPress` sends `down` after `longPressMs` (300) and `up` on release. Key bindings fire on key down and swallow their key down and up (unless `swallow` is false); modifier-only chords are never swallowed, but fn and the 🌐 key's events with `swallowFn`. With `active` (a session records) a tap fires at once and Escape fires `{"binding":"escape"}` and is swallowed. A modifier whose event comes without its state changing means macOS dropped one (seen: fn's release after fn+⌃): the chord in progress is dropped (`missedEvents`). The app flips `active` by sending the same bindings: a chord in progress survives a change of timings or `active`. Without Accessibility `installed` is false and the helper retries every 2 s, sending `hotkey.state` when it gets in; meanwhile the app falls back to MyGo's Carbon shortcuts for plain key combinations. `front` is the app in front as the key went down, the start of the session's context snapshot (plan §4.2); `t` is the helper's monotonic clock in ms.

**app.\*.** The helper keeps the app in front from NSWorkspace's activations and tells each change (`app.activated`), so the app need not poll. On activation it gives `AXManualAccessibility` to Electron apps (it finds them by their framework) and to the bundle ids of `app.configure`, once per process (Chromium builds a page's accessibility tree only when a client asks, a moment later), so the selection and the tab's address can be read when a shortcut comes; the outcome is a `debug` log line. `app.configure` replaces the list (case does not matter) and gives the app in front the attribute at once when it is listed (it came to the front before the list); a new helper has an empty list, so the app sends it after each start: its Chromium browsers (`appctx.TreeOnDemand`: the built-in Chromium ones and the user's) while app enhancement is on, none while it is off. The list comes from the app because the user adds browsers; the helper keeps it only for the activations. `app.list` lists the regular running apps and, with `installed`, the bundles in /Applications, /System/Applications and ~/Applications (one folder down too), each bundle id once, by name: the apps App enhancement offers as members.

**app.icons.** The icons the Finder shows (`NSWorkspace.icon(forFile:)`) of at most 48 apps (`proto.MaxIcons`; more is `bad_request`), each by its bundle's `path` when that is still there (app.list's), else the bundle the system finds for `bundleId` (`urlForApplication(withBundleIdentifier:)`): App enhancement's members carry only their bundle ids. Each is drawn off the main thread into a `size` × `size` pixel PNG (default 64, at most 256: 32 points at 2×), base64 in `png`; `png` is absent when no bundle was found (a removed app), and the app shows a generic icon. The answer has one icon per app asked for, in order. The app asks for the rows a list shows, 24 at a time, and keeps the PNGs (`internal/appicons`: `~/Library/Caches/Auralink/icons/<bundle id>-64.png`, redrawn after a week); a helper without the method (it is not in hello's `methods`) only means generic icons, so adding it kept protocol 1.

**textio.\*.** `textio.selection` reads the focused element's selected text, the text of its selected range, then WebKit's and Chromium's text markers; a caret without a selection is `none` (no ⌘C: it would copy nothing, or a whole line). Otherwise, with `allowCopy`, it posts ⌘C, waits up to `copyTimeoutMs` (300) for the clipboard to change, reads it and puts the old clipboard back. The app decides `allowCopy` (not in apps that copy a line on an empty selection). `textio.paste` snapshots the clipboard (every item and type), writes the text (marked `org.nspasteboard.TransientType` and `AutoGeneratedType`, which clipboard managers skip), posts ⌘V, then the keys of `press` after `pressDelayMs` (120; app enhancement's auto key: Return is `{"key":36}`), and after `restoreDelayMs` (500) writes the snapshot back unless the clipboard changed meanwhile (`clipboardTaken`). With `targetPid` it pastes only when that app is in front, else answers `posted: false` with the app in `front`; the app reactivates the target itself when it must (`macx.Activate`: only the active app can hand activation over). Posted keys carry the helper's marker, so its own tap lets them through. Without Accessibility, `permission_denied`.

**browser.url.** Accessibility only (no AppleScript, so no Automation consent per browser; the user's decision, 2026-10-15), the same way for every app: the `AXURL` of the outermost `AXWebArea` around the focused element (`ax-focus`: the tab being typed in, also in a split view, not an iframe inside it), else the focused window's `AXDocument` (`ax-document`: Chromium browsers and Safari), else the `AXURL` of the window's first web area, breadth first over at most 400 nodes (`ax-weburl`: Arc). `pid` (the shortcut's `front`) picks the process, else `bundleId`'s first running one, else the app in front. No URL is `via: "none"` with `error` saying why (not running, no focused window, no web area: Safari in the background has none). When no web area has an address in an Electron app or one `app.configure` listed, the helper sets `AXManualAccessibility` on the process (once per process, besides the activation's), waits 150 ms and reads once more (the same 400 nodes): the result is the second read's, with `retried: true`. Arc in front before the helper started had no page tree at all (2026-10-15: `none` after 400 nodes in 0.7 s; retried, `ax-focus`; then 2 ms). `AXEnhancedUserInterface` is not set: Chromium needs only the manual attribute, and the enhanced one slows window animations. Each element answers within 0.3 s; the app adds its own timeout. Which apps are browsers is the app's business (`internal/appctx`); a URL is used only to match app enhancement rules, never sent to a model.

## 5. Testing

- `go test ./internal/helper/proto`: every fixture line decodes strictly with the Go types and encodes back to the same JSON; the sequencing rules hold (one response per request, a job's notifications before its response and after `capture.started`, frames without gaps, the result counting them); every method has a fixture; the handshake lists every request.
- `cd helper && swift test` (on a Mac): every fixture line decodes with the Swift types and encodes back to the same JSON; the hotkey recognizer and the PCM framer.
- `AURALINK_MAC_E2E=1 go test -run TestMac -v .` (on a Mac; `scripts/mac-e2e.sh`): the real supervisor and the real helper — its read-only methods, the file input above against the speech sample, and whole sessions with real services — without a window, a key, a tap or the clipboard (manual-test.md, "自动真机测试（无界面）").
- `go test ./internal/helper`: the supervisor against `helpertest`, the fake helper the test binary becomes (`AURALINK_FAKE_HELPER`): handshake, capture with PCM frames (a tone, or a WAV played back), cancel, a stuck cancel, crash and restart, protocol mismatch, an app updated on disk (no helper started), missing executable, permissions, hotkey events and scripted notifications, text I/O, call traces, fixture replay.

## 6. Differences from the spikes' draft

| Draft (research/spikes.md) | Protocol 1 | Why |
|---|---|---|
| `capture.start` answers at once; `capture.stop` returns the statistics; `capture.ended` reports a failure | `capture.start` is a job: `capture.started` at the first audio, its response when it ends (stopped, maxSeconds, deviceLost, noCallback), `job.cancel` | The supervisor's job model (routing by `job`, cancel, a crash failing the call); one place says how a recording ended |
| `{session, device?}` | `{devices?}`, the user's preference list (settings `Audio.Devices`) | The settings keep a list; the helper falls back along it |
| `capture.pcm {session, seq, offset, samples, pcm}` | `{job, seq, offset, data}` | `samples` is `len(data)/2`; `data` like AudioSmith's chunks |
| `capture.started` was the start's answer, timed to `engine.start()` | sent with the first audio | That is when the user's words are heard |
| `watchdogSeconds`, `simulateSilentStarts` | fixed 1.2 s; no test hooks | The fake helper covers the cases on Linux |
| `hotkey.event {…, lagMs}` | no `lagMs` | `CGEvent.timestamp` is not on `CLOCK_UPTIME_RAW`'s base: the value was always out of range |
| `hotkey.event` without context | `front`, as the draft recommended | The session's context snapshot |
| defaults `doubleTapMs` 400, `tapMaxMs` 1000 | 500 (or the system's, at most 800), 1500 | The real-key retest (spike e01bb05): double taps judged by the second press; ⇧+fn held 983 ms |
| `helper.ping`, `helper.usage`, `helper.quit`, `debug.*`, `hotkey.raw` | `helper.shutdown`; no ping, usage or debug methods | Spike instrumentation; AudioSmith's handshake and shutdown |
| `permissions.status {…, listenEvent, postEvent}` | `{microphone, accessibility}` | Input Monitoring is not needed; `CGPreflightPostEventAccess` stays false while posting works |
| `textio.frontmost` | `app.frontmost`, and `app.activated` | Grouped with the activation notifications |
| `textio.activate`, `textio.paste {targetPid}` activating the target | no activation in the helper; `targetPid` only checks the app in front | macOS 14 activates cooperatively: the active app (Auralink) must yield, so `macx.Activate` runs in the app |
| `textio.paste {restore, pressReturn, returnDelayMs, source, tap}` | `{keepClipboard, press: [{key, modifiers}], pressDelayMs}`; HID source and tap fixed | Auto keys other than Return (⌘Return); the spike's variants were measurements |
| `textio.selection {enableChromiumAX, skipAX}` | done at activation (Electron apps); no `skipAX` | The tree needs time to appear: at activation it is ready when the shortcut comes |
| `browser.url {appleScript, ax, noCache, enableChromiumAX}` | `{bundleId?, pid?}`, Accessibility only (M5): the web area around the focus first | No Automation consent to ask per browser (the user's decision); the focused web area is the tab being typed in |
| `automation.probe`, `automation.request` | removed (M5) | Nothing runs AppleScript any more |
| — | `app.list` (M5) | App enhancement picks member apps from the running and installed ones |
| — | `app.icons` (10-15) | The lists that name apps show their icons; the app has no AppKit of its own (no cgo), so the helper draws them |
| — | `app.configure {manualAccessibility}`; `browser.url`'s `retried` | Chromium browsers build a page's tree only when asked (Arc read none); the browser list is the app's (the user adds some) |
