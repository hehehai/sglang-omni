# Changelog

All notable changes to VoxtNew. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each version's section is what the update window shows: English first, then the same in Chinese under matching headings (docs/release.md).

## [Unreleased]

### Added

- VoxtNew: voice input for macOS on local models only, built from Auralink 0.1.0-beta.1 (Transcribe, Translate, Rewrite, App enhancement, the dictionary, history, the overlay, shortcuts, the menu bar, the setup guide, settings and updates). Its own bundle identifier (`dev.hehehai.voxtnew`), data folder and helper (`voxtnew-helper`).
- The Local models page, empty for now: the speech and language models that run on this Mac come in later versions. Until one is installed, a shortcut shows "No speech model is installed." instead of recording.

### Removed

- Remote speech and language services, API keys, the proxy (Settings → Network), the Model services page and the demo build.

### 新增

- VoxtNew：只用本地模型的 macOS 语音输入，基于 Auralink 0.1.0-beta.1（转录、翻译、转写、应用增强、词典、历史、浮窗、快捷键、菜单栏、设置引导、设置和更新）。有自己的 bundle ID（`dev.hehehai.voxtnew`）、数据文件夹和辅助进程（`voxtnew-helper`）。
- 本地模型页，目前为空：在这台 Mac 上运行的语音识别和语言模型会在之后的版本加入。装好模型之前，按快捷键会提示“语音识别模型未安装。”，不会开始录音。

### 移除

- 远程语音识别和语言模型服务、API Key、代理（设置 → 网络）、模型服务页和演示构建。
