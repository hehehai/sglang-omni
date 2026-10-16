# Working on VoxtNew

VoxtNew is a macOS voice input app on remote models: Go + MyGo (native UI, no cgo) and a small Swift helper. Read [docs/architecture.md](docs/architecture.md) first; [docs/behavior.md](docs/behavior.md) compares its behaviour with Voxt's.

## Rules

- **Every user-visible string goes through `i18n.T`** (or `N`, `X`) with a literal English message, and whoever adds one adds its zh-Hans translation to `internal/i18n/locales/zh-Hans.json`. `TestKeyParity` fails on a missing translation, an unused one, or format verbs that differ. Product words in Chinese: 转录 (Transcribe), 翻译 (Translate), 转写 (Rewrite), 应用增强 (App enhancement), 词典 (Dictionary), 模型服务 (Model services), 辅助进程 (the helper).
- **The build pass does no I/O.** Views read `app` fields, snapshots and memory-only getters. Store, Keychain, network and helper calls run on goroutines (`a.async`, `helperCall`) and come back through `a.post`. `app` is main-thread only.
- **Voxt is a reference, not a source.** Port behaviour, never code: read what Voxt does, write it our way (one session owner, a layered prompt composer, pure logic apart from platform code), and record the difference in `docs/behavior.md` (Voxt / VoxtNew / why).
- **The UI is AudioSmith's.** Build pages from `ui_kit.go` and the tokens in `ui_tokens.go` (one ink primary button per view, the accent for state only, Solar icons, `settingRow` with ⓘ help). New icons: add the name to `internal/icons/names.txt`, then `go generate ./internal/icons`.
- **Pure logic in `internal/`, platform code behind narrow interfaces** (the helper, `permission`), with fakes for tests: everything must be testable on Linux.
- **The helper protocol** changes in every place at once: `internal/helper/proto`, the Swift types (`helper/Sources/VoxtNewHelperKit/Wire*.swift`), `helper/Fixtures`, the fake helper (`internal/helper/helpertest`) and `docs/helper-protocol.md`. Go and Swift tests decode the same fixtures.
- **The helper does, Go decides**: policy (when ⌘C may run, delays, keys after a paste, which device) goes in the params; the helper keeps no settings.
- **Files stay small**: at most 600 lines of code (aim for 400), 800 of tests; split by topic into `<area>_<part>.go`. `internal/archtest` checks the sizes (a ratchet over `allowlist.txt`) and the import layering (`imports.txt` lists every internal → internal import: add a line for a new one). Refactors that move code prove it with `declhash` and `scripts/snapshots.sh check` (docs/architecture.md, "Code structure rules").
- **Licence**: VoxtNew is AGPL-3.0-or-later, contributions under [CLA.md](CLA.md). Third-party code, data or artwork needs a licence compatible with AGPLv3 (no GPLv2-only, no non-commercial or no-derivatives terms) and an entry in `NOTICE`, with its licence text in `LICENSES/` (a new Go module: its licence file in `LICENSES/go/`). No per-file licence headers.
- Code comments and commit messages in English. Keep the MyGo lifetime rules (`.agents/skills/mygo-maintenance`).

## Commands

```sh
CGO_ENABLED=0 go test ./...                                  # all tests (Linux and Mac)
go tool mygo vet .                                           # vet + MyGo's UI checks
CGO_ENABLED=1 go test -race ./...                            # needs cgo
VOXTNEW_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .   # pages as PNG
go test -run TestKeyParity ./internal/i18n                   # strings and zh-Hans
scripts/mac.sh '<command>'                                   # run on the Mac (MAC_HOST, MAC_DIR=code/VoxtNew)
scripts/mac.sh 'scripts/build-helper.sh && go tool mygo build'   # the Swift helper, then the app
scripts/mac.sh 'cd helper && swift test'                     # the helper's tests (same fixtures as Go)
MAC_DIR=code/VoxtNew-mt scripts/mac.sh scripts/mac-e2e.sh   # headless Mac tests: real helper, no window or key (--offline: no services)
scripts/vendor-mygo.sh --check                               # third_party/mygo is MyGo + our patches
scripts/snapshots.sh check                                   # every snapshot, pixel for pixel, against the merge base
go run ./internal/tools/declhash . ./internal/...            # a hash per declaration: equal before and after a pure move
go vet -tags demo ./... && go vet -tags updatecheck .        # the demo and update-check builds (CI does too)
```
