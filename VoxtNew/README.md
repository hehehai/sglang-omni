# VoxtNew

**English** · [简体中文](README.zh-CN.md)

Voice input for macOS on **local models only**: press a shortcut in any app, speak, and the text appears where your cursor is. 转录 Transcribe, 翻译 Translate (speech or the selection), 转写 Rewrite (the selection, or new text from a spoken request), with 应用增强 App enhancement (scene rules by app and website) and a 词典 Dictionary. Speech recognition runs on sglang-omni's native MLX servers ([`sglang_omni_mlx/native`](../sglang_omni_mlx/native)), the language models in a process of their own: audio and text never leave the Mac.

> **Status: M0, the skeleton.** The app builds and runs, with everything but the models: the window, the feature pages, the history, the dictionary, App enhancement, the overlay, the shortcuts, the menu bar, the setup guide, the settings and updates. The Local models page is still empty, so a shortcut says "No speech model is installed." Local speech recognition comes with M1, the language models with M2 ([docs/plan.md](docs/plan.md)).

VoxtNew started as a copy of [Auralink](https://github.com/hehehai/Auralink), the same author's app on remote models, which itself rewrote [Voxt](https://github.com/hehehai/voxt) (here as [`../Voxt`](../Voxt)) on Go and [MyGo](https://github.com/egoist/mygo) with [AudioSmith](https://github.com/hehehai/AudioSmith)'s interface. Remote services, API keys, the proxy, meetings, notes, file transcription and sync are gone.

## Build from source

Needs Go 1.27.1 (`GOTOOLCHAIN=auto` fetches it) and, to package, a Mac with macOS 15 or later on Apple silicon and Xcode for the Swift helper.

```sh
scripts/build-helper.sh              # the Swift helper, into resources/darwin-arm64/helper/
go tool mygo dev                     # run with hot reload
go tool mygo build                   # build/darwin-arm64/VoxtNew.app and "VoxtNew 0.1.0 arm64.dmg"
```

From Linux, `scripts/mac.sh <command>` mirrors the project to a Mac (`MAC_HOST`, default `mac-air`; `MAC_DIR`, default `code/VoxtNew`) and runs the command there: `scripts/mac.sh 'scripts/build-helper.sh && go tool mygo build'`.

<details>
<summary>Signing during development (keeping the permissions across rebuilds)</summary>

macOS keeps the Microphone and Accessibility grants for a signature. An ad hoc signed build (the default) has a new one each time the app is rebuilt, so after a rebuild macOS forgets them: the microphone turns **denied without asking again**, and Accessibility still shows on in System Settings but does not work. The helper's grants are the app's (macOS checks the helper against VoxtNew.app, its responsible process), so the same happens to it. Ways around it:

- **Change only the helper:** keep one built app and run it with a helper outside the bundle. The helper inherits the app's grants wherever it lives, so rebuilding it costs nothing:
  ```sh
  scripts/build-helper.sh --out ~/voxtnew-dev
  open --env VOXTNEW_HELPER=$HOME/voxtnew-dev/voxtnew-helper build/darwin-arm64/VoxtNew.app
  ```
- **Start over:** `tccutil reset Microphone dev.hehehai.voxtnew` (likewise `Accessibility`), then open the app and grant again. If a stale Accessibility entry stays on but does nothing, remove it with − in System Settings and grant again.
- **Sign with a fixed identity:** an Apple Development certificate keeps the grants across rebuilds: `go tool mygo build -sign "Apple Development: …"` (or `macos.signingIdentity` in a local mygo.json; `VOXTNEW_SIGN_IDENTITY` for `scripts/build-helper.sh`). Over ssh, `codesign` fails with `errSecInternalComponent` until the key may be used without the GUI: once, in Terminal on the Mac, `security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db`.

</details>

## Development

VoxtNew is a Go app on [MyGo](https://github.com/egoist/mygo) (native macOS UI from Go, no cgo) and a small Swift helper for what needs Apple's frameworks: the microphone, global shortcuts, Accessibility, pasting and app icons. Go decides; the helper does what it is told over JSON lines on stdin and stdout. Everything but the helper is plain Go and is tested on Linux. Run from `VoxtNew/`:

```sh
CGO_ENABLED=0 go test ./...          # everything; runs on Linux
go tool mygo vet .                   # go vet and MyGo's UI-lifetime checks
VOXTNEW_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .   # every page as PNG, light/dark, en/zh-Hans
cd helper && swift test              # the Swift helper (on a Mac), against the same protocol fixtures
```

The store's tests use MyGo's SQLite plugin, which downloads its library once (checked against its SHA-256) or uses `MYGO_SQLITE_LIBRARY`. On Linux the overlay's pixel checks of Chinese text need a CJK font (Ubuntu: `fonts-noto-cjk`).

- [docs/plan.md](docs/plan.md): the milestones and the local runtimes.
- [docs/architecture.md](docs/architecture.md): packages, threading, the session, the prompt composer, data on disk.
- [docs/behavior.md](docs/behavior.md): what VoxtNew does differently from Voxt, and why.
- [docs/helper-protocol.md](docs/helper-protocol.md): the helper's protocol.
- [AGENTS.md](AGENTS.md): the rules for changes (strings, threading, the helper protocol).
- [CHANGELOG.md](CHANGELOG.md): changes by version.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to send a change.

## Licence

Apache License 2.0 ([LICENSE](LICENSE)), as the rest of this repository. VoxtNew derives from Auralink by the same author; third-party material and its licences are listed in [NOTICE](NOTICE).
