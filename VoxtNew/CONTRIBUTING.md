# Contributing to Auralink

**English** · [简体中文](#参与贡献)

Thank you for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- **Bugs**: Settings → About → Report a problem opens a GitHub issue with the diagnostics filled in. Or open an [issue](https://github.com/hehehai/Auralink/issues) by hand: what happened, what you expected, the steps.
- **Changes**: for anything larger than a fix, open an issue first and say what you want to change. Auralink does three things (Transcribe, Translate, Rewrite) with App enhancement and the dictionary, on remote models only; meetings, file transcription, notes and local models are out of its scope.
- Read [AGENTS.md](AGENTS.md) (the rules for changes) and [docs/architecture.md](docs/architecture.md) before changing code.

## The Contributor License Agreement

Every contributor signs the [Auralink Contributor License Agreement](CLA.md) once, before their first pull request is merged. You keep the copyright in your work; you give actnow, the project's owner, a license to it, which lets actnow distribute your work under the GNU AGPL and under other terms, including commercial ones, while your work stays available under the AGPL as well (CLA §4).

To sign: open your pull request. The CLA Assistant bot comments on it if an author of its commits has not signed; reply with a comment that reads exactly

```
I have read the CLA Document and I hereby sign the CLA
```

The check turns green, and you will not be asked again. Every commit's author must be linked to a GitHub account (the commit e-mail is one of your account's addresses), or the bot cannot tell who signed. If you contribute for a company, say so in the pull request before you sign.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep a pull request to one change, with tests. Commit messages and code comments are in English.
3. Every user-visible string goes through `i18n.T` with an English message, and its Simplified Chinese translation goes into `internal/i18n/locales/zh-Hans.json`.
4. A change in behaviour from Voxt goes into [docs/behavior.md](docs/behavior.md); a change users notice gets a line in the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md), in English and Chinese.
5. Run the checks below; CI runs them too and must pass.
6. Say in the pull request what changed and how you checked it. For a change in the UI, add before and after screenshots.

By opening a pull request you agree that your contribution is licensed under the [GNU AGPL 3.0 or later](LICENSE) and under the CLA.

## Development

Auralink is a Go app on [MyGo](https://github.com/egoist/mygo) (native UI, no cgo) with a small Swift helper. Everything but the helper is plain Go and is tested on Linux; building the app needs a Mac with macOS 15 or later on Apple silicon and Xcode. Go 1.27.1 (`GOTOOLCHAIN=auto` fetches it).

```sh
CGO_ENABLED=0 go test ./...                                  # all tests (Linux and Mac)
go tool mygo vet .                                           # go vet and MyGo's UI checks
git ls-files '*.go' ':!:third_party/**' | xargs gofmt -l    # must print nothing
go test -run TestKeyParity ./internal/i18n                   # strings and zh-Hans
AURALINK_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .   # every page as PNG
scripts/snapshots.sh check                                   # which snapshots your branch changes
cd helper && swift test                                      # the Swift helper (on a Mac)
scripts/build-helper.sh && go tool mygo build                # build the app (on a Mac)
```

The store's tests use MyGo's SQLite plugin, which downloads its library once (checked against its SHA-256) or uses `MYGO_SQLITE_LIBRARY`. On Linux the overlay's pixel checks of Chinese text need a CJK font (Ubuntu: `fonts-noto-cjk`). What needs permissions, a screen or real services is checked by hand: [docs/manual-test.md](docs/manual-test.md).

---

## 参与贡献

感谢你的帮助。欢迎提交问题、建议和 PR。

### 开始之前

- **报告问题**：设置 → 诊断与关于 → 反馈问题，会打开一个已填好诊断信息的 GitHub issue；也可以手动开 [issue](https://github.com/hehehai/Auralink/issues)，写清发生了什么、你期望什么、复现步骤。
- **改动**：比修 bug 大的改动，请先开 issue 说明。Auralink 只做转录、翻译、转写三件事，加上应用增强和词典，只用远程模型；会议、文件转录、笔记和本地模型不在范围内。
- 改代码前请先读 [AGENTS.md](AGENTS.md)（修改规则）和 [docs/architecture.md](docs/architecture.md)。

### 贡献者许可协议（CLA）

每位贡献者在第一个 PR 合并前签署一次 [Auralink 贡献者许可协议](CLA.md)。版权仍然归你；你授予项目所有者 actnow 一项许可，actnow 可以按 GNU AGPL 发布你的贡献，也可以按其他协议（包括商业协议）发布，同时你的贡献始终也能按 AGPL 获得（CLA 第 4 条）。CLA 的中文说明在 [CLA.md](CLA.md#中文说明) 末尾，仅供参考，以英文为准。

签署方法：提交 PR 后，如果有提交作者还没签，CLA Assistant 机器人会在 PR 里留言；回复一条评论，内容必须是

```
I have read the CLA Document and I hereby sign the CLA
```

检查会变绿，以后不会再问。每个提交的作者都要关联到 GitHub 账号（提交用的邮箱是你账号里的邮箱），否则机器人认不出是谁签的。代表公司贡献时，请在签署前在 PR 里说明。

### 提交 PR

1. Fork 仓库，从 `main` 建分支。
2. 一个 PR 只做一件事，并带上测试。提交信息和代码注释用英文。
3. 界面上的每一句文字都要经过 `i18n.T`（英文原文），并在 `internal/i18n/locales/zh-Hans.json` 里加上简体中文翻译。
4. 和 Voxt 行为不同的地方写进 [docs/behavior.md](docs/behavior.md)；用户能感知的改动，在 [CHANGELOG.md](CHANGELOG.md) 的 `Unreleased` 一节加一条，中英文各一。
5. 跑一遍下面的检查；CI 也会跑，必须通过。
6. 在 PR 里说明改了什么、怎么验证的；界面改动请附上改前改后的截图。

提交 PR 即表示你同意你的贡献按 [GNU AGPL 3.0 或更高版本](LICENSE)和 CLA 授权。

### 开发

Auralink 是基于 [MyGo](https://github.com/egoist/mygo) 的 Go app（原生界面，不用 cgo），另有一个小的 Swift 辅助进程。除辅助进程外都是纯 Go 代码，在 Linux 上测试；构建 app 需要 macOS 15 及以上的 Apple 芯片 Mac 和 Xcode。Go 1.27.1（`GOTOOLCHAIN=auto` 会自动获取）。

```sh
CGO_ENABLED=0 go test ./...                                  # 全部测试（Linux 和 Mac）
go tool mygo vet .                                           # go vet 加 MyGo 的 UI 检查
git ls-files '*.go' ':!:third_party/**' | xargs gofmt -l    # 应当没有输出
go test -run TestKeyParity ./internal/i18n                   # 界面文字和中文翻译
AURALINK_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .   # 每个页面的截图
scripts/snapshots.sh check                                   # 你的分支改变了哪些截图
cd helper && swift test                                      # Swift 辅助进程的测试（Mac 上）
scripts/build-helper.sh && go tool mygo build                # 构建 app（Mac 上）
```

存储层的测试用 MyGo 的 SQLite 插件，第一次会下载它的库（校验 SHA-256），也可以用 `MYGO_SQLITE_LIBRARY` 指定。在 Linux 上，浮窗中文文字的像素检查需要 CJK 字体（Ubuntu 装 `fonts-noto-cjk`）。需要权限、屏幕或真实服务的部分按 [docs/manual-test.md](docs/manual-test.md) 手动验证。
