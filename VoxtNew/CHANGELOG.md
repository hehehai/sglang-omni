# Changelog

All notable changes to VoxtNew. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each version's section is what the update window and actnow.dev show: English first, then the same in Chinese under `### 中文`, with `####` headings below it (docs/release.md §2.1).

## [Unreleased]

### Added

- History entries have a context menu: right-click (or Control-click) one to copy its result or its recognised text, show its details, show its recording in Finder, or delete it. Home's recent results have the same menu. In History a selected entry also takes ⌘C (copy) and Delete.
- **Keep models loaded** (Local models → Advanced): how long a model stays in memory unused. Automatic, the default, is as before (speech 10 minutes, language models 5); you can choose 5, 15 or 30 minutes, 1 hour, or until VoxtNew quits, so that every dictation starts at once. Other ActNow apps can still ask VoxtNew to free the memory of models it is not using. A change applies at once.
- **Sounds to choose** (Settings → Audio → Play sounds): Voxt's ten pairs of start and stop sounds (Soft, the default, then Ping, Morse, Submarine, Basso, Bottle, Frog, Hero, Purr and Sosumi), in a menu beside the switch with a Try button; choosing one plays it, and so does resting on one in the open menu.
- **Mute system audio while recording** (Settings → Audio, on by default): the current output device is muted from just after the start sound until the recording stops, so that videos, music or calls are not recorded; a device you muted stays muted, one you unmute during the recording stays on, and a device that cannot be muted leaves the recording as it is (the overlay says so). No permission is needed. If VoxtNew or its helper stops while muting, the sound comes back at once, or at the next start.

### 中文

#### 新增

- 历史记录有了右键菜单：右键（或按住 Control 点）一条记录，可以复制结果或识别原文、查看详情、在访达中显示录音，或者删除它。首页的最近结果也有同样的菜单。在历史页选中一条记录后，也可以按 ⌘C 复制、按 Delete 删除。
- **保持模型载入**（本地模型 → 高级）：模型闲置多久后从内存卸载。默认“自动”与以前相同（语音识别 10 分钟、语言模型 5 分钟）；也可以选 5、15、30 分钟、1 小时或“直到退出 VoxtNew”，让每次口述都立即开始。其他 ActNow app 仍然可以请 VoxtNew 释放闲置模型占用的内存。修改立即生效。
- **可选的提示音**（设置 → 音频 → 播放提示音）：和 Voxt 一样的 10 组开始和结束提示音（默认“柔和”，另有 Ping、Morse、Submarine、Basso、Bottle、Frog、Hero、Purr、Sosumi），开关旁边有下拉菜单和试听按钮；选中一组会试听，在打开的菜单里停在某一项上片刻也会试听。
- **录音时静音系统声音**（设置 → 音频，默认开启）：从开始提示音之后到停止录音为止，当前输出设备静音，免得视频、音乐、通话的声音被录进去；你自己静音的设备保持静音，录音中你取消静音后不会再被静音，不支持软件静音的设备照常录音（浮窗会提示）。不需要任何权限。VoxtNew 或辅助进程在静音期间意外退出时，声音会立即恢复，最迟在下次启动时恢复。

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
- Shortcuts: tap the right Option key to transcribe, right Option with Shift to translate, Control with right Option to rewrite; Control-Option-V pastes the last result. They leave fn to Auralink, so the two apps run side by side.
- Updates from actnow.dev, with a Beta channel (Settings → About). The app is signed and notarised.

### 中文

#### 新增

- VoxtNew 的第一个版本：只用本地模型的 macOS 语音输入。在任意 App 里按下快捷键说话，文字出现在光标处。音频和文字不会离开你的 Mac。
- 本地语音识别：精准（推荐）和快速两个模型，说话时实时显示文字；声音检测只把说话的部分交给它们。
- 本地语言模型：均衡（推荐）、快速和翻译专用三个模型，用于整理、翻译和改写。
- 转录，可以整理掉口头语、说了一半的话并补上标点；翻译，选中的文字或说的话；转写，改写选中的文字或按语音要求写新内容，并可在答案卡片里继续追问。
- 应用增强：把 App 和网站分组，每组有自己的场景提示词和插入后的按键。
- 词典：词条帮助语音识别模型听准你的人名和术语，并让语言模型照你的写法输出。
- 本地模型页：下载、暂停和继续下载，每个文件都经过校验，可删除；显示已加载模型占用的内存。下载走系统代理，连不上 Hugging Face 时改用镜像。
- 设置引导：安装推荐的两个模型，并把每个功能试一遍；还有历史、浮窗、菜单栏、快捷键和设置。
- 快捷键：单按右 Option 转录，右 Option 加 Shift 翻译，Control 加右 Option 转写；Control-Option-V 粘贴上一条结果。fn 留给 Auralink，两个 app 可以同时使用。
- 从 actnow.dev 更新，有 Beta 通道（设置 → 诊断与关于）。app 已签名并经过公证。
