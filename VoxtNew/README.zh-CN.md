# VoxtNew

[English](README.md) · **简体中文**

**只用本地模型**的 macOS 语音输入：在任意 App 里按下快捷键说话，文字出现在光标处。转录、翻译（说的话或选中的文字）、转写（改写选中的文字，或按语音要求写新内容），加上应用增强（按 App 和网站切换场景规则）和词典。语音识别跑在 sglang-omni 的原生 MLX 服务上（[`sglang_omni_mlx/native`](../sglang_omni_mlx/native)），语言模型跑在独立进程里：音频和文字不会离开这台 Mac。

> **状态：M0，骨架。** App 能构建、能运行，除了模型以外都在：窗口、各功能页、历史、词典、应用增强、浮窗、快捷键、菜单栏、设置引导、设置和更新。本地模型页目前为空，所以按快捷键会提示“语音识别模型未安装。”。本地语音识别在 M1 加入，语言模型在 M2（[docs/plan.md](docs/plan.md)）。

VoxtNew 由 [Auralink](https://github.com/hehehai/Auralink) 复制而来，Auralink 是同一作者基于远程模型的应用，它用 Go 和 [MyGo](https://github.com/egoist/mygo) 以 [AudioSmith](https://github.com/hehehai/AudioSmith) 的界面重写了 [Voxt](https://github.com/hehehai/voxt)（本仓的 [`../Voxt`](../Voxt)）。远程服务、API Key、代理、会议、笔记、文件转录和同步都已去掉。

## 从源码构建

需要 Go 1.27.1（`GOTOOLCHAIN=auto` 会自动下载）；打包需要 macOS 15 及以上、Apple 芯片的 Mac 和 Xcode（编译 Swift 辅助进程）。在 `VoxtNew/` 下执行：

```sh
scripts/build-helper.sh              # Swift 辅助进程，输出到 resources/darwin-arm64/helper/
scripts/build-omni.sh                # Omni 运行时（语音模型），输出到 resources/darwin-arm64/omni/
go tool mygo dev                     # 热重载运行
go tool mygo build                   # 生成 build/darwin-arm64/VoxtNew.app 和 dmg
```

在 Linux 上，`scripts/mac.sh <命令>` 会把项目同步到 Mac（`MAC_HOST` 默认 `mac-air`，`MAC_DIR` 默认 `code/VoxtNew`）并在那里执行，例如 `scripts/mac.sh 'scripts/build-helper.sh && go tool mygo build'`。开发时的签名与权限说明见英文 [README](README.md)。

## 开发

```sh
CGO_ENABLED=0 go test ./...          # 全部测试，Linux 上可跑
go tool mygo vet .                   # go vet 和 MyGo 的 UI 生命周期检查
VOXTNEW_SNAPSHOTS=/tmp/shots go test -run TestSnapshots .   # 每个页面截图
cd helper && swift test              # Swift 辅助进程的测试（在 Mac 上）
```

文档：[docs/plan.md](docs/plan.md)（里程碑与本地运行时）、[docs/architecture.md](docs/architecture.md)（包结构、线程、会话、数据位置）、[docs/behavior.md](docs/behavior.md)（与 Voxt 的行为对照）、[AGENTS.md](AGENTS.md)（改动规则）、[CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

Apache License 2.0（[LICENSE](LICENSE)），与本仓其余部分一致。VoxtNew 源自同一作者的 Auralink；第三方素材及其许可见 [NOTICE](NOTICE)。
