# Changelog

All notable changes to Auralink. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each version's section is what the update window shows: English first, then the same in Chinese under matching headings (docs/release.md).

## [Unreleased]

### Changed

- Auralink's licence is now the GNU Affero General Public License, version 3 or later (AGPL-3.0-or-later; it was the Apache License 2.0 up to 0.1.0-beta.1). Contributions come in under a Contributor License Agreement (CLA.md). Settings → About shows the copyright and the licence, with links to the licence, the source code and the third-party notices.

### 变更

- Auralink 的许可改为 GNU Affero 通用公共许可证第 3 版或更高版本（AGPL-3.0-or-later；0.1.0-beta.1 及以前是 Apache License 2.0），新增贡献者许可协议（CLA.md）。设置 → 诊断与关于显示版权和许可，并链接到许可全文、源代码和第三方声明。

## [0.1.0-beta.1] - 2026-10-16

The first version, a beta: voice input for macOS on remote models. It updates to the next beta and to the release that follows (Settings → About → Beta updates).

### Added

- **Transcribe**: a shortcut (fn by default; tap, double tap or long press, several per feature) records, a speech service recognises, a language model cleans up (fillers, false starts, punctuation, numbers; an optional structure layer and your own rules), and the text is pasted where the cursor is. Without a language model the text goes in as recognised; when it fails or is slow, too.
- **Translate**: the selection (read through Accessibility, or ⌘C where that is safe) or what you say, into the language you choose; a strict retry when the answer looks untranslated; an answer card to read, copy, insert or translate again into another language.
- **Rewrite**: say how to change the selection, or what to write with nothing selected; every answer is written one line under the pill, then waits in the answer card (as in Voxt), where Insert puts it in place (over the selection) and Continue records a follow-up, answered in plain text in the card's conversation.
- **App enhancement**: groups of rules by app and by website (address rules read through Accessibility, no browser automation), a scene prompt layered on top of the clean-up, the key to press after inserting, the features each group applies to, a live match preview, and the group's label in the overlay and the history.
- **Dictionary**: terms with aliases, sent as hints to the speech services and as a glossary to the language model; CSV and text import and export.
- **Model services**: Doubao and Alibaba Cloud Model Studio streaming recognition and any OpenAI-compatible transcription API; DeepSeek, Qwen, Volcengine Ark, Kimi, GLM, MiniMax, StepFun, MiMo, SiliconFlow, OpenAI, Anthropic, Gemini, OpenRouter and other OpenAI-compatible language models; keys in the Keychain, connection tests, a service per feature.
- **Home**: a slogan with your Transcribe shortcut in a key cap; what is still missing (a service, a permission, the shortcut), each line the way to fix it, and nothing once all is ready; a try of the whole chain on the page until the first result; today's results and characters, the last five results.
- **Setup guide** on the first start (and from Settings → General): privacy, permissions, services, then a real try of Transcribe, Translate and Rewrite, and App enhancement and the dictionary.
- **History**: by feature, searchable, with the texts, where the result went, the services, the rule that matched and each stage's time; recordings kept on request.
- The recording overlay (non-activating, so the app you type into keeps its focus), after Voxt's: the feature's icon and a waveform on a translucent, blurred pill with no buttons and Voxt's proportions (the shortcut stops, Escape cancels; the pointer goes through it), one line of live text under it, the pill as wide as the text up to 300 and the text then scrolled to its newest words, a loader while it works, errors in place of the waveform, nothing after an insert; and the answer card, with start and stop sounds. Every session starts as the pill, and it grows about its edge of the screen without moving; every flow shows the same pill until its result (what the model works on, then its draft, on one line), and the card comes only with the result.
- The answer card, after Voxt's: 440 wide (Voxt's is 560) and as high as its text (up to 220 of it, then it scrolls), its actions in the header (the target language as a capsule opening our own menu in a window of its own, Continue, Insert, Copy, Close), the header as far from the top as from the rule, Voxt's own icons in the pill and the card, why the result is in the card in Insert's tip instead of a line of orange, Copy marking itself for two seconds, Insert hiding the card while it pastes, another language translated in place (the old text with a spinner until the new one comes), and Rewrite follow-ups recorded in the card as a conversation (a small waveform, bubbles); Escape closes it, or cancels a follow-up only.
- Silence left out before recognition (a light energy detector, no model): a file service gets the recording without the silence around the speech and with long pauses shortened, a streaming service nothing before the speech starts, and a recording without speech is not sent at all (Settings → Audio → Skip silence).
- Sound optimization before recognition (pure DSP, no model): a high-pass filter at 80 Hz takes out hum and rumble, and one gain measured on the speech alone raises a quiet voice (up to +12 dB, never lifting the room's noise over -50 dBFS) or lowers a very loud one a little, with a limiter at -1 dBFS; a stream's gain follows slowly and holds through pauses. The recording kept in the history is the original; the history says what was done and the gain (Settings → Audio → Optimize sound, on by default).
- A small window (800×520 by default, 680×440 at the least) with no status bar: notifications stack as cards at the foot of the sidebar (a dot on Settings when it shows only icons), and a missing service or a stopped helper becomes a card with the action that fixes it.
- The menu bar icon: start or stop transcribing, paste the last result, the last three results to copy (one short line each, the whole in the tooltip); it changes while recording. Closing the window keeps Auralink there, and it can open at login.
- Settings: General (languages, the menu bar, login, the setup guide), Permissions, Audio (the microphones in your order of preference, skipping silence, optimizing the sound, sounds), Overlay style (place, opacity, corners, the recording time, with a live preview over a desktop picture), Shortcuts (every feature's keys and their conflicts), Appearance (the sidebar shrinks to icons in a narrow window), Network (proxy), Privacy, Storage, About (versions, updates, the self-check, reporting a problem); English and Simplified Chinese.
- Signed with a Developer ID and notarised. Updates from GitHub Releases: a daily check, the new version's notes in a window of its own, a download of only what changed, installed when you say so; Check for Updates… in the app menu, the menu bar icon's menu and Settings → About. An update installed while Auralink runs asks for a restart instead of starting the new helper.
- Beta updates (Settings → About): betas too, or releases only; on by default in a beta. Turning it off never goes back to an older version: a beta stays until a release newer than it.

### Known limitations

- Apple silicon and macOS 15 or later only (no Intel build yet).
- The app icon is a placeholder.

### 中文

第一个版本，是 beta 版：只用远程模型的 macOS 语音输入。它会更新到下一个 beta 和之后的正式版（设置 → 诊断与关于 → Beta 更新）。

- **转录**：按住快捷键说话，语音识别服务转成文字，语言模型整理（去口头禅、改标点和数字，可加结构和你自己的规则），粘贴到光标处。
- **翻译**：选中的文字或你说的话，翻译成你选的语言；答案卡片里可以阅读、复制、插入或换一种语言。
- **转写**：说出怎么改选中的文字，或在没有选中时说出要写什么；回答进卡片，可以插入，也可以继续追问。
- **应用增强**：按 App 和网站分组的场景规则；**词典**：术语和别名，发给语音识别和语言模型。
- 首页、设置引导、历史、浮窗和答案卡片、菜单栏图标、静音裁剪和声音优化，以及完整的设置；界面有英文和简体中文。
- 使用 Developer ID 签名并经过公证。通过 GitHub Releases 更新：每天检查一次，在单独的窗口里显示更新说明，只下载有变化的部分，你同意后才安装。
- Beta 更新（设置 → 诊断与关于）：同时接收 beta 版，或只接收正式版；正在用 beta 时默认打开。关闭后不会降级：已装的 beta 会保留到比它新的正式版发布。
- 已知限制：只支持 Apple 芯片和 macOS 15 及以上；app 图标还是占位的。
