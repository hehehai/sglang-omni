# Changelog

All notable changes to VoxtNew. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each version's section is what the update window shows: English first, then the same in Chinese under matching headings (docs/release.md).

## [0.1.0-beta.1] - 2026-10-17

### Added

- The first version of VoxtNew: voice input for macOS on local models only. Press a shortcut in any app, speak, and the text appears where your cursor is. Audio and text never leave your Mac.
- Local speech recognition: two models, accurate (recommended) and fast, with the text shown live as you speak, and a voice detector that sends only speech to them.
- Local language models: a balanced one (recommended), a fast one and a translation model, for clean-up, translation and rewriting.
- Transcribe, with an optional clean-up of fillers, false starts and punctuation; Translate, the selected text or what you say; Rewrite, the selected text or new text from a spoken request, with follow-ups in the answer card.
- App enhancement: groups of apps and websites with their own scene prompt and a key pressed after inserting.
- Dictionary: its terms help the speech model hear your names and jargon, and the language model write them as you spell them.
- The Local models page: download, pause and resume, every file verified, delete; the memory a loaded model uses. Downloads use the system's proxy, or a mirror when Hugging Face cannot be reached.
- A setup guide that installs the two recommended models and tries each feature; history, the overlay, the menu bar, shortcuts and settings.
- Updates from actnow.dev, with a Beta channel (Settings → About). The app is signed and notarised.

### 新增

- VoxtNew 的第一个版本：只用本地模型的 macOS 语音输入。在任意 App 里按下快捷键说话，文字出现在光标处。音频和文字不会离开你的 Mac。
- 本地语音识别：精准（推荐）和快速两个模型，说话时实时显示文字；声音检测只把说话的部分交给它们。
- 本地语言模型：均衡（推荐）、快速和翻译专用三个模型，用于整理、翻译和改写。
- 转录，可以整理掉口头语、说了一半的话并补上标点；翻译，选中的文字或说的话；转写，改写选中的文字或按语音要求写新内容，并可在答案卡片里继续追问。
- 应用增强：把 App 和网站分组，每组有自己的场景提示词和插入后的按键。
- 词典：词条帮助语音识别模型听准你的人名和术语，并让语言模型照你的写法输出。
- 本地模型页：下载、暂停和继续下载，每个文件都经过校验，可删除；显示已加载模型占用的内存。下载走系统代理，连不上 Hugging Face 时改用镜像。
- 设置引导：安装推荐的两个模型，并把每个功能试一遍；还有历史、浮窗、菜单栏、快捷键和设置。
- 从 actnow.dev 更新，有 Beta 通道（设置 → 诊断与关于）。app 已签名并经过公证。
