# Voxt Omni XPC 集成方案

## 1. 目标

将 Voxt 当前的 Omni Native backend 从“App 启动本地 HTTP/WebSocket server”逐步演进为：

```text
Voxt.app
  -> Omni XPC Service
      -> Omni Native Core
          -> MLX / Metal
              -> 本地模型权重缓存
```

用户只安装一个 `Voxt.app`。Native runtime 代码随 App 构建、签名和发布；模型权重作为数据按需下载并缓存，不放进 App bundle。

现有 HTTP server 保留为开发、CI、CLI 和模型 golden test 的 transport adapter，不作为正式 Voxt 产品路径。

当前迁移目标是移除 Voxt 对 MLX Audio 的依赖，而不是等待所有模型补齐后才切换。不支持的模型或能力暂时禁用，不回退到 Swift MLX Audio；后续通过 Native 能力验收再启用。本地 LLM/VLM 使用的 mlx-swift / mlx-swift-lm 不属于本次替换范围。第 12 节为当前任务与验收依据；第 10、11 节保留历史验证记录，不代表 XPC 已实现。

## 2. 初始基线

编写初版方案时，Voxt 的 Omni 路径是（内嵌 runtime 的后续进展见第 11 节）：

```text
MLXModelManager
  -> OmniASRRuntime
      -> Process()
          -> qwen3_asr_server / whisper_server / cohere_transcribe_server /
             moss_transcribe_diarize_server
              -> localhost HTTP/WebSocket
                  -> C++ / MLX inference
```

已具备的基础：

- Native C++/MLX ASR、VAD、Sortformer runtime；
- supervised process launch protocol；
- HTTP、SSE、WebSocket API；
- Swift 侧模型加载、lease、drain、retire、restart 逻辑；
- 模型下载、校验、缓存和删除逻辑；
- Native golden、API、生命周期和 Voxt Omni 测试；
- GitHub Apple Silicon CI 现场构建 Native runtime 并运行测试。

当前主要限制：

- Xcode 工程没有 Omni XPC target；
- Release App 没有嵌入 Native runtime；
- `VOXT_OMNI_RUNTIME` 仍然指向外部 binary；
- Native server 的 HTTP transport、进程控制和推理核心尚未分层；
- GitHub CI 会临时构建 runtime，但未产出可发布的 runtime artifact 或 packaged Voxt.app；
- Qwen、Whisper、Cohere、MOSS 仍共用 Voxt 的 MLXAudio 上层兼容类型。

## 3. 目标架构

### 3.1 代码分层

```text
Omni Core
  - 模型加载
  - 音频预处理
  - MLX 推理
  - session 状态
  - final / streaming / VAD / diarization 结果

Omni XPC Service
  - XPC listener
  - Swift/C++ 或 Objective-C++ bridge
  - session 生命周期
  - 音频 chunk 和 event 转发
  - 模型目录访问

Omni HTTP Adapter
  - 当前 HTTP/SSE/WebSocket API
  - Native CI
  - CLI 和开发调试

Voxt XPC Client
  - Swift async API
  - transport-independent request/result 类型
  - XPC 断连、服务重启、取消和错误映射
```

### 3.2 App bundle 形态

```text
Voxt.app/
└── Contents/
    ├── MacOS/Voxt
    ├── XPCServices/OmniInference.xpc/
    │   └── Contents/
    │       ├── MacOS/OmniInference
    │       ├── Frameworks/libOmniCore.dylib
    │       ├── Frameworks/libMLX*.dylib
    │       ├── Resources/*.metallib
    │       └── Info.plist
    └── Frameworks/
```

模型权重位于 App Group 或 App Sandbox 的 Application Support 容器中：

```text
Application Support/Voxt/Models/<model-repo>/
```

XPC 服务不需要用户单独安装，也不需要启动常驻 LaunchAgent。它由 macOS 按需启动，Voxt 退出或服务空闲时释放。

## 4. 方案决策

### 4.1 正式产品路径

采用“内嵌 XPC Service + Native Core”。

- App 内嵌并签名 XPC executable、Omni Core、MLX dylib 和 Metal resources；
- App 和 XPC Service 共享 App Group 模型目录；
- 主 App 负责下载、校验、删除和展示模型状态；
- XPC Service 负责加载和执行模型；
- 生产路径不依赖 localhost port 和外部环境变量。

### 4.2 开发和 CI 路径

保留当前 HTTP server：

```text
Python / CLI / golden test -> HTTP -> Omni Core
Voxt release              -> XPC  -> Omni Core
```

不做运行时自动 fallback。HTTP 只作为明确的开发/测试 transport，避免两条生产路径产生不可控的行为差异。

### 4.3 迁移策略

先完成“可发布的内嵌 Helper/Runtime”验证，再切换 XPC transport：

1. 将 Native runtime 构建和签名纳入 Voxt Release；
2. 先让 App bundle 能够定位并启动内嵌 Native binary；
3. 抽离 Omni Core；
4. 增加 Omni XPC Service；
5. 将生产 Voxt client 切换到 XPC；
6. 保留 HTTP adapter 给 CI 和开发。

这样可以把“打包问题”和“通信架构重写问题”分开验收。

## 5. 实施阶段

### Phase 0：冻结接口和验收矩阵

输出一张 capability matrix，覆盖每个模型的：

- model load/unload；
- final transcription；
- streaming/live preview；
- timestamps；
- speaker segments；
- language/prompt/hotwords；
- cancellation；
- service crash/restart；
- VAD 和 diarization 并行运行。

同时确定最低 macOS、Apple Silicon 架构、App Sandbox、App Store/Developer ID 两种发布方式。

### Phase 1：Runtime 构建和发布链路

目标：不改变 HTTP 协议，先让 Native runtime 成为可发布产物。

工作项：

- 将 `build_runtime.sh` 的 CMake 构建接入 Xcode/Release pipeline；
- 明确只打包 server 必需产物，评估是否排除 CLI transcribe binary；
- 生成 Release arm64 runtime；
- 对 executable、dylib、Metal library 做 strip 和依赖审计；
- 将 runtime 嵌入 App 的标准位置；
- 删除生产环境对 `VOXT_OMNI_RUNTIME` 的依赖；
- 加入签名、notarization 和 packaged app smoke test；
- 输出真实体积清单：App、XPC、Native Core、MLX、Metal、模型数据分别统计。

验收：从全新机器安装 Voxt.app，不设置环境变量，不安装 Python/uv，能够启动一个 Native server 并完成 Qwen final transcription。

### Phase 2：抽离 Omni Core

目标：让 HTTP server 和 XPC Service 共用同一套推理代码。

工作项：

- 从现有 `*_server` 中分离模型加载、session、推理和结果结构；
- 形成 `OmniCore` C++ library 或稳定 C ABI；
- HTTP server 改成调用 `OmniCore`；
- 保持现有 API 和 golden 输出不变；
- 明确线程、MLX stream、模型切换和 session 的所有权；
- 不把 MLX C++ 模板类型直接暴露给 Swift。

验收：HTTP golden/API 测试结果与当前一致；同一 Native Core 能被一个最小 CLI 调用。

### Phase 3：增加 Omni XPC Service

目标：建立 App 内部的正式 Native transport。

工作项：

- 新增 `OmniInference.xpc` Xcode target；
- 增加 XPC listener 和 App-side client；
- 定义 load、start session、push audio、finish、cancel、unload、health 和 event API；
- 音频使用二进制 Data/dispatch data，不使用 JSON；
- 将 final、preview、VAD、speaker event 映射为 Voxt 自己的类型；
- 实现服务断连、崩溃、重启和未完成请求的错误处理；
- 将 App 和 XPC Service 统一到 App Group 模型目录；
- 保持服务无常驻后台状态，按需加载和卸载模型。

验收：XPC 服务可以独立崩溃并被 Voxt 识别；重连后下一次请求可以重新加载模型；App 主进程不被 Native crash 影响。

### Phase 4：切换 Voxt 生产客户端

目标：正式 Voxt 运行不再依赖 HTTP 和外部 runtime path。

工作项：

- 将 `OmniASRRuntime` 重构为 transport-independent runtime client；
- 增加 `OmniXPCClient`；
- 将 `MLXModelManager` 的 Omni 分支切换到 XPC；
- 保留 `OmniHTTPClient` 给开发和测试；
- 保持模型切换、idle unload、delete、quit、cancel 和 crash recovery 语义；
- 清理 `VOXT_ASR_BACKEND`、`VOXT_OMNI_RUNTIME` 在 Release 中的使用。

验收：Release 构建的 Voxt.app 在干净环境中完成 Qwen、Whisper、Cohere、MOSS 的已支持能力，并能正确使用 VAD/Sortformer。

### Phase 5：体积、性能和稳定性验收

必须分别测量：

- 安装包下载大小；
- 解压后 App 大小；
- XPC runtime 大小；
- MLX dylib 和 Metal kernel 大小；
- 首次启动耗时；
- 首次模型加载耗时；
- 模型切换耗时；
- ASR + VAD + Sortformer 并行内存；
- 服务崩溃恢复时间；
- 长时间会议内存增长。

模型权重单独统计，不计入固定 App runtime 体积。

## 6. 需要修改的主要位置

### Voxt

- `Voxt/Voxt.xcodeproj/project.pbxproj`：新增 XPC target、target dependency、Embed XPC Service、签名配置；
- `Voxt/Voxt/Transcription/OmniASRRuntime.swift`：从 Process/HTTP client 演进为 transport-independent client；
- `Voxt/Voxt/Transcription/OmniASRBackend.swift`：从环境变量路径配置改为 bundled XPC 配置；
- `Voxt/Voxt/Transcription/OmniNativeStreamingSession.swift`：切换到 XPC event stream；
- `Voxt/Voxt/Transcription/OmniVoiceActivity.swift`：切换 VAD session transport；
- `Voxt/Voxt/Transcription/OmniSpeakerDiarization.swift`：切换 diarization transport；
- `Voxt/Voxt/Transcription/MLXModelManager.swift`：统一模型目录和 XPC service 生命周期；
- `Voxt/Voxt/Core/Models/*Download*`：保留下载逻辑，改为 App Group/正式缓存路径；
- `Voxt/.github/workflows/*`：增加 Release runtime 构建、打包、签名和 smoke test。

### sglang-omni Native

- `sglang_omni_mlx/native/CMakeLists.txt`：增加 Omni Core library/XPC 可链接产物；
- `sglang_omni_mlx/native/scripts/build_runtime.sh`：区分 CI runtime、开发 runtime 和 Release embedded runtime；
- `sglang_omni_mlx/native/*_server`：保留 HTTP adapter；
- 新增 Omni Core 的稳定 C/C++ API 和 XPC host target。

## 7. 关键风险

### 体积重复

Voxt 已经使用 MLXAudio Swift；Native C++ MLX 可能带来另一套 MLX dylib。必须通过 Release 构建确认是否重复，不能假设两者可以直接共享。

### Sandbox 和模型目录

XPC Service 有自己的 sandbox。模型目录应使用 App Group，或者由主 App 通过安全作用域 bookmark 明确授予访问权限。

### Native 代码签名

XPC executable、Omni Core、MLX dylib、Metal resources 的签名顺序和 entitlements 必须纳入自动化，不能依赖手工复制。

### Streaming 和背压

XPC 传输音频 chunk 和 transcript event 时要明确队列上限、取消语义和服务断连行为，防止录音过程中积压数据。

### 模型能力不完整

XPC 只是 transport 替换，不会自动补齐 Parakeet、Nemotron、SenseVoice，也不会自动解决 Cohere realtime 和 Whisper realtime 的能力差异。

## 8. 完成标准

方案完成不以“XPC target 能编译”为准，而需要满足：

1. 用户只安装一个 Voxt.app；
2. 不需要 Python、uv、环境变量或外部 runtime path；
3. Native runtime、MLX、Metal kernel 全部随 App 正确签名；
4. 模型权重独立下载、校验、缓存和删除；
5. App 和 XPC Service 通过共享目录访问模型；
6. Qwen、Whisper、Cohere、MOSS 的既有 Native 能力通过 App 端到端测试；
7. XPC 服务崩溃不会导致 Voxt 主进程退出；
8. 服务可以被取消、卸载、重启，且不留下孤儿进程；
9. HTTP API 继续通过 Native CI golden/API 测试；
10. Release artifact 有真实的体积、签名、notarization 和干净机器安装记录。

## 9. 当前建议

正式迁移目标确定为 XPC，不再把 Helper + HTTP 作为产品交付的替代方案。第 11 节的内嵌 HTTP runtime 是验证基线，可以用于对照测试，但不满足最终迁移验收。

先做最小的真实签名 XPC + MLX/Metal + 模型目录访问验证，再逐个迁移模型。无需先抽离所有 server，也无需等待 Parakeet、Nemotron、SenseVoice 补齐。优先复用已有模型静态库，将 HTTP/session 耦合按实际需要拆开。

必须将模型可用性、Voxt 自有结果类型、VAD/Sortformer 和下载验证一起纳入迁移；仅替换 ASR transport 不能移除 MLX Audio。具体任务、依赖和发布门槛见第 12 节。

## 10. Phase 0/1 前置验证记录

验证日期：2026-10-10。以下结果来自 Apple Silicon 本机的 Release 构建和产物检查。

### 10.1 Phase 0 结果

当前 Native 能力还不是完整的 Omni 替换矩阵：

| 能力 | 当前 Native 情况 | 结论 |
|---|---|---|
| Qwen3-ASR | final、realtime | 可以由 Native 替换 |
| Whisper | final、batch preview | 可以替换，但没有 Native realtime |
| Cohere | final、batch preview | 可以替换，但 realtime 需要继续保留 Swift 或补齐 Native |
| MOSS | final、realtime、speaker segments | 可以由 Native 替换 |
| VAD / Sortformer | 已有 Native probe/runtime | 可以作为 Native 依赖使用 |
| Parakeet / Nemotron / SenseVoice | 当前仍由 Swift MLX 实现 | 不能宣称已完成全模型替换 |

平台验证确认当前 Native runtime 的最低系统版本为 macOS 26.2：`qwen3_asr_server` 最低系统版本约为 macOS 26.0，`libmlx.dylib` 和 `libjaccl.dylib` 为 macOS 26.2。因此本验证版本将 Voxt 的最低系统版本统一设为 macOS 26.2；后续若要恢复 macOS 15 支持，需要重新构建兼容的 MLX 和 Native runtime。

当前 App 开启了 App Sandbox，但 entitlements 没有 App Group。现有模型目录默认是：

```text
~/Library/Application Support/Voxt/model-storage
```

同时支持用户选择外部目录，并用 security-scoped bookmark 保存授权。对于 XPC，默认目录应迁移到 App Group；用户选择的外部目录则需要由主 App 统一管理授权，不能直接假设 XPC 能复用主 App 的 bookmark。这个问题尚未通过验证。

### 10.2 Phase 1 结果

已完成的本机检查：

- `build_runtime.sh` 成功生成 arm64 Release runtime；
- 当前完整 runtime 约 `213 MB`；其中 `mlx.metallib` 约 `182 MB`、`libmlx.dylib` 约 `20 MB`、`libjaccl.dylib` 约 `1.5 MB`；
- 只保留四个 server binary 时约 `208 MB`，因此生产包不应携带 CLI transcribe/probe binary；
- Voxt 当前 Release App 构建成功，未嵌入 Native runtime 时约 `125 MB`；
- App 与 server-only runtime 合并后，未压缩体积估算约 `333 MB`，还没有计算模型权重；
- App 内已有 Swift MLX 的 `default.metallib`，约 `3.6 MB`。App 使用 `mlx-swift 0.31.6`，Native 使用 Python wheel 中的 MLX `0.32.3`，两套 MLX 不能简单视作同一个可共享二进制；重复的 Native MLX dylib 和 Metal kernel 已经确认是主要体积来源；
- 当前 Xcode 工程只有 Voxt 和 VoxtTests target，没有 `OmniInference.xpc` target，也没有 XPC service 的嵌套签名链；本次构建使用 `CODE_SIGNING_ALLOWED=NO`，所以还没有验证 Developer ID/App Store 签名、notarization 或 XPC 嵌套签名。

### 10.3 阶段判断

Phase 0：能力矩阵已经足够支持继续做接口设计，但“完整 Omni 替换”尚未成立，且最低 macOS 版本必须先定下来。

Phase 1：Native 构建和体积测量已通过；发布链路尚未通过，具体阻塞为：

1. MLX/native runtime 目前只支持 macOS 26.2 及以上；
2. 生产包还没有只包含 server 的正式布局；
3. 没有 XPC target、App Group 和真实签名验证；
4. 模型目录的主 App/XPC 共享访问策略尚未落地。

因此现在不应直接进入“把现有 HTTP server 改成 XPC”的大规模重构。下一步应先固定最低 macOS 支持范围，在该环境重新构建并检查 `libmlx.dylib`，然后做一个最小的 signed XPC package smoke test，再决定是否继续抽离 Omni Core。

## 11. Native Runtime 验证版本实现记录

在当前验证分支中，目标调整为先交付 macOS 26.2+ 的单 App Native Runtime 版本，不等待 XPC。

实现内容：

- `OmniASRBackend` 优先读取开发环境中的 `VOXT_OMNI_RUNTIME`，没有环境变量时自动查找 App Bundle 内的 `OmniRuntime/bin/qwen3_asr_server`；
- `VOXT_ASR_BACKEND=swift` 可以显式关闭 Native backend，方便开发和回归测试；
- `package_local_app.sh --native-runtime <runtime-dir>` 会把 runtime 注入 `Contents/Resources/OmniRuntime`；
- 打包脚本会验证 Qwen、Whisper、Cohere、MOSS server 以及 MLX dylib/Metal library 是否齐全；
- Developer ID 打包会按嵌套顺序签名 runtime、framework、Sparkle XPC 和 App；
- 模型权重仍然独立下载到用户模型目录，不会进入 App 安装包。

本机验证结果：

- Voxt Release App 构建通过；
- Native runtime 成功注入 App Bundle；
- Developer ID Application 签名通过；
- `codesign --verify --deep --strict` 通过；
- 验证 App 未压缩约 `337 MB`；
- ZIP/PKG 约 `105 MB`，DMG 约 `120 MB`；
- 当前 runtime 仍包含 CLI/probe binary，后续正式发布前可以继续裁剪；
- Native runtime 和 App 的实际最低系统版本均按 macOS 26.2 处理；Intel 版本只使用 Remote backend，不启动 arm64 Native runtime。

因此这一版的产品形态已经从“外部环境变量指定的开发 server”变成“App Bundle 内置 runtime、App 自动启动 localhost server、用户只安装一个 App”。这只是内嵌 runtime 的验证版本；按当前目标，正式迁移还需要完成 XPC 和 MLX Audio 移除。

## 12. 当前迁移任务方案

### 12.1 范围与产品规则

- 正式路径为 Voxt -> 内嵌 OmniInference.xpc -> Native Core -> MLX/Metal，不在 XPC 内另起 HTTP server。
- 完成迁移后，App 的源码、SwiftPM 依赖图和构建产物不再依赖 MLXAudioCore、MLXAudioSTT、MLXAudioVAD。
- 保留独立的本地 LLM/VLM 与 Remote ASR/LLM 路径；本次不迁移 LLM/VLM runtime。
- 不支持的本地模型显示“暂不可用”，禁止下载、选择、预加载和推理；已经下载的权重保留，允许查看和删除。
- 已保存的禁用模型配置不能绕过限制；保留原选择供后续恢复，提示用户选择可用模型或 Remote，不静默切换到云端。
- 同一模型按 final、batch preview、native realtime、timestamps、speaker segments 分别声明能力；不能用“支持 streaming”混淆 batch preview 和真正的 realtime。
- 不支持的选项禁用，而不是通过保留 MLX Audio 实现补齐。后续支持是路线图，当前启用必须以具体 checkpoint 和能力的验收结果为准。
- 当前平台基线暂沿用 macOS 26.2+、Apple Silicon 本地推理、Intel Remote-only；本轮不扩展最低系统版本。Developer ID 为首条建议验证链路，App Store 支持单独验收。

### 12.2 初始能力清单

下表来自现有方案与 Native 路由的静态核对，不是本轮实际模型运行认证。XPC 实现后需要逐项重跑。

| 模型/组件 | 本轮目标 | 暂时禁用内容 |
|---|---|---|
| Qwen3-ASR | 已列入 Native 路由的 checkpoint 的 final、realtime | 未验收的 checkpoint 或选项 |
| Whisper | 已列入 Native 路由的 checkpoint 的 final、batch preview | Native realtime；不能将 batch preview 标为 realtime |
| Cohere Transcribe | 已列入 Native 路由的 checkpoint 的 final、batch preview | 当前 Swift-only realtime |
| MOSS Transcribe Diarize | 已列入 Native 路由的 checkpoint 的 final、realtime、speaker segments | 未验收的选项 |
| Silero VAD | Native streaming/offline、配置和模型验证 | Swift MLX Audio 实现 |
| Sortformer | Native realtime/final diarization、配置和模型验证 | Swift MLX Audio 实现 |
| Parakeet / Nemotron / SenseVoice | 保留 catalog 与已下载数据 | 下载、选择、预加载、推理；待 Native 支持后启用 |
| Remote ASR/LLM、本地 LLM/VLM | 保持既有功能 | 不因 ASR 替换而禁用 |

能力表必须按 repo/checkpoint、量化格式、任务和平台维护，不能仅根据模型家族名称放行。App 的静态支持清单与 XPC 的协议版本/实际能力握手共同决定是否可运行。

### 12.3 任务拆分与验收

T0、T1 的实现和验证进展见第 13 节，其余任务待实施；已有 Helper 打包和 Native golden 是基线证据，不计作 XPC 任务完成。

| 任务 | 主要工作 | 依赖 | 完成标准 |
|---|---|---|---|
| T0：能力门禁与旧配置处理 | 统一模型/功能可用性来源；覆盖设置、onboarding、debug、快捷键、会议、文件转写、下载与加载入口；禁用缺失模型/能力 | 无 | 禁用模型从任何入口都不能执行；旧配置不会回退 Swift 或自动上云；已有权重可删除 |
| T1：Voxt 自有 ASR 类型 | 替换 STTOutput、TranscriptionEvent、STTGenerationModel 等上层依赖；统一文本、语言来源、时间戳、speaker、生成元数据与错误 | T0 | App/会议使用自有契约；在迁移期用现有 adapter 验证 final、preview 和 speaker 结果，不复制整个 MLX Audio API |
| T2：真实签名 XPC 验证 | 新增 target、嵌入配置与最小 bridge；链接已有 Qwen 模型库；验证 MLX/Metal 资源发现、App Group 与真实模型访问 | 可与 T0/T1 并行 | 干净环境的签名 App 经 XPC 完成一次 Qwen final；XPC 崩溃不退出主 App；重连后新请求成功 |
| T3：Core/session 与 XPC 协议 | 分离 HTTP 耦合；实现 final、load/unload、session、push/finish/cancel、event；确定 worker、资源和异常所有权 | T1、T2 | Qwen final/realtime 跨 XPC；取消/断连只产生一次终态；HTTP adapter 的原有 API/golden 不退化 |
| T4：VAD、Sortformer 与目录生命周期 | 迁移 streaming/offline VAD、realtime/final diarization；移除 Swift 推理式下载验证；实现缓存迁移、目录授权、lease 与删除协调 | T3 | ASR + VAD + Sortformer 可共同工作且状态隔离；模型下载不在主 App 加载 Audio 模型；使用中不能误删权重 |
| T5：其余 ASR 与客户端切换 | 接入 Whisper/Cohere/MOSS；保留其分块、prompt、语言、speaker 和 final/preview 语义；Release 全部走 XPC | T3、T4 | 所有声明支持的能力完成 App 端到端回放；runtime 缺失或失败明确报错，不回退 Swift/HTTP |
| T6：依赖移除与构建审计 | 删除 Swift Audio loader/分支、迁移测试、移除 SPM products/package；更新 lockfile、依赖审计脚本和文档 | T5 | 严格解析和 Debug/Release 构建通过；源码与实际依赖/产物审计无 MLX Audio；本地 LLM/VLM 仍可用 |
| T7：发布与稳定性门槛 | 将 XPC/Core/dylib/Metal 的构建、签名、公证和运行 smoke 接入 CI；运行性能与故障矩阵 | T6 | 签名、公证、干净机器安装、长会议、崩溃恢复与资源测量都有实际记录 |

建议以这些可独立验收的任务拆成后续 PR；当前 PR #2683 继续定位为 Native runtime 打包验证，不宣称已经完成 XPC 或 MLX Audio 替换。

### 12.4 必须提前冻结的接口与生命周期

**XPC 消息与音频**

- 区分 App 内部 Swift 类型和 NSXPC 可编码的 DTO；使用明确的 Objective-C 协议、NSSecureCoding/允许类型集合，并带协议版本。
- 请求包含 request/session ID，事件包含递增序号和服务实例标识；服务重启后的旧事件不能污染新录音。
- 固定音频格式、采样率、声道、时间基准和最大 chunk 大小。短音频使用有界 Data；长录音使用分块或明确授权的文件访问，不把整场会议塞进一次 XPC 消息。
- XPC Data 不保证零拷贝。先测实际复制、延迟和内存，再决定是否需要共享内存；不得在录音实时回调中等待 XPC。
- 定义 push 的接收确认、最大在途 chunk/排队音频秒数、finish 的末尾 drain、终态只发送一次，以及失败后的处理。可以合并 preview，不能静默丢失音频或 final。

**资源与恢复**

- 现有 Native worker 保持同一线程加载与推理的约束；XPC 回调只排队，不能直接并发调用 MLX。
- 初版采用单 XPC host，ASR 同时只保留一个活动模型；VAD/Sortformer 使用独立状态和明确的 worker/MLX stream 所有权，并验证 GPU 并行安全性及内存。
- 移除模型时只取消/卸载相关 session，不能照搬 HTTP 的 kill-process 逻辑杀掉整个 XPC host。单服务崩溃会影响所有本地 session，必须全部显式失败并清理 lease。
- 区分连接 interruption 和 invalidation；为在途请求设置超时并完成其等待者。仅允许下一次新请求重连，默认不自动重放已提交音频。
- cancel 先协作取消，释放模型前等待在途工作结束；超时恢复若需要重置服务，必须显式通知其他受影响 session。
- 空闲时显式卸载模型并释放 MLX 缓存；macOS 按需启动 XPC 不意味着关闭连接就保证进程立即退出或显存归零。

**目录、签名与发布**

- App Group 标识、两侧 entitlements 和 Developer ID 授权必须在 T2 用真实签名确认；不通过给主 App 任意文件访问权限绕过。
- 缓存迁移使用临时目录、完整性校验和原子发布；更新成功前保留旧目录，避免重复下载、磁盘不足和升级后旧版本无法读模型。
- 外部模型目录单独验证 security-scoped bookmark/文件访问授权的跨进程语义、权限撤销和服务重启；不能只给 XPC 传路径字符串并假设可访问。
- 主 App 负责下载与发布权重，服务负责推理；删除/替换前等待所有模型 lease 释放，加载未完成的下载目录必须失败。
- XPC/Core 使用标准 bundle 位置和可迁移的 install name/rpath；验证 MLX 在新布局中找到 mlx.metallib。Core 优先复用已有静态库，无需强制新增动态库。
- 从最内层 Mach-O 到 XPC 再到 App 签名；检查真实加载依赖、架构、最低 OS、Gatekeeper 和公证。Metal 文件作为 bundle 资源验证，不视作可独立 codesign 的 Mach-O。
- 正式包不携带 HTTP server、CLI/probe 和开发覆盖入口；保留其他功能必需的网络权限，仅在审计确认后删除本地 HTTP 专用 server entitlement。
- 移除 Audio 不会自动移除本地 LLM/VLM 所需的 Swift MLX。两套 MLX 的体积与内存分别实测，不能承诺替换后只有一套 runtime。

### 12.5 回归和发布验收矩阵

- 模型门禁：全新安装、已下载禁用模型、旧默认模型、不同 feature 保存的选择、Intel 和 runtime/protocol 不兼容。
- 音频结果：固定语料的各模型 final/preview/realtime；中英混合、静音、短录音、长录音、采样率转换、语言/prompt、时间戳与 speaker 对齐。
- 会话：load 中取消、推理中取消、finish/cancel 竞争、重复 finish、晚到事件、模型切换、并行 VAD/diarization、idle unload、退出。
- 故障：加载中/录音中/finish 中服务崩溃、反复重连、队列满、模型文件损坏、外部目录授权撤销、下载/删除与推理竞争。
- 产品回归：Remote ASR 的本地 VAD、会议 live/final、文件转写、历史展示、本地 LLM/VLM；移除 Audio 后不能遗漏这些跨功能调用者。
- 打包：真实签名 App 在无 Python/uv/开发环境变量的机器运行 XPC 与 Metal；测 App/XPC/MLX/模型体积、首次加载、preview 延迟、峰值内存与长会议内存趋势。
- CI：继续跑 HTTP Native golden/API，再新增 XPC 契约与真实签名 packaged-app smoke。unsigned build 和 codesign verify 都不能单独代替运行验证。

第 10、11 节的本机验证记录为原分支历史证据，应在执行 T2/T7 时针对新的提交与产物重新验证。当前各阶段的实际验证范围见第 13 节。

## 13. 实施与验证记录

### T0：Native ASR 能力门禁

状态：代码实现与 Linux 检查完成，macOS App 构建/运行验收待补。不将此阶段视作 XPC 或 MLX Audio 依赖移除完成。

实现范围：

- 保留完整 ASR catalog 和暂不可用模型的已下载文件；Native eligibility 与 catalog membership 分离，保存/读取 feature 设置不会将 Parakeet、Nemotron、SenseVoice 改为默认模型或云端。
- 所有实际 ASR 加载必须进入 Native runtime；runtime 缺失或开发配置关闭 Native 时返回明确错误，移除生产 Swift loader fallthrough。既有测试注入 loader 仅用于生命周期测试。
- 下载、恢复下载、模型选择、录音启动、会议和文件导入加入门禁；设置、引导、调试和 feature selector 显示禁用原因，保留取消、卸载与目录查看。
- Qwen/MOSS 的 Native live 能力与 Whisper/Cohere 的 batch preview 分开；Cohere 不再显示 Native realtime 标签，Nemotron 不再创建 live session。
- Whisper 的 npz 权重识别不再依赖 runtime 发现，保证未配置 runtime/Intel 环境仍能管理已下载数据。
- 保留本地 LLM、Remote ASR/LLM 与辅助 VAD 的既有路径；VAD/Sortformer 的 Swift 依赖在 T4/T6 处理。

已执行：

- git diff --check：通过。
- pre-commit run --all-files：通过；pre-commit 与 Rust 检查工具安装在仓库外的临时目录，没有修改项目依赖或跳过 hook。
- Swift 6.2.3 frontend parse：当前阶段修改的 Swift 文件全部通过语法检查。
- 实际 catalog、Native backend、RecordingStartPlanner 和安装 action resolver 源码的 Linux 隔离 harness：69 项断言通过；外部 MLX/SwiftUI/Hub 和资源依赖使用 stub，仅证明这些策略代码的编译及行为，不证明完整 App 或 GPU 推理通过。
- python3 -m unittest discover -s Voxt/tools -p 'test_*.py'：20 项现有工具测试通过。
- 在 Voxt 目录运行 tools/audit_model_stack.py 的源码审计与 --resolved lockfile 审计：均通过；未做实际 App/link map 产物审计。
- 分工：主线程负责 runtime/执行边界，subagent 负责 UI/设置；另行做只读入口审查和最终 diff 审查。已补充入口审查指出的录音/文件导入与权重识别遗漏；最终审查未发现具体代码错误，不代表 macOS 编译或运行验证通过。

macOS 待执行的验收：

```bash
xcodebuild build -project Voxt/Voxt.xcodeproj -scheme Voxt \
  -configuration TestDebug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Voxt/Voxt.xcodeproj -scheme Voxt \
  -configuration TestDebug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Voxt/Voxt.xcodeproj -scheme Voxt \
  -configuration TestDebug -destination 'platform=macOS,arch=x86_64' \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

此外，在实际 App 中检查已有禁用模型配置、安装/恢复/选择禁用、卸载/查看目录、会议/文件/调试入口、Native runtime 缺失提示，以及 Remote 与本地 LLM 不受影响。T2 必须在 Apple Silicon 上完成真实签名 XPC/Metal 验证，不能以 Linux 检查替代。

### T1：Voxt 自有转写契约与兼容边界

状态：结果/事件/生成配置类型迁移和 Linux 子集验证完成；完整 macOS App 编译、XCTest 和模型回放仍待补。

实现范围：

- 新增 ASRTranscriptionTypes：自有结果、可选时间戳分段、语言来源、生成元数据、流式事件、错误和带单位的生成选项。结果/分段可 Codable 往返；缺失分段统一为空数组，不根据语言字符串臆测语言来源。
- ASRStreamingSession 不再暴露 MLX Audio 事件。Native streaming、会议、可靠分段和 SenseVoice 元数据消费自有类型，保留 MOSS 标签清理、零时长 speaker segment、时间偏移与替换已有 partial ID 的语义。
- MLXAudioASRAdapter 是临时兼容转换边界：映射旧输出及语言来源，过滤上层原本忽略的 confirmed/provisional/stats，只传 display/ended/failed；生成选项仅在真实 Swift 模型调用处转换回包类型。旧输出没有提供停止原因时，hitLengthLimit 保持未知而非假设 false。
- LoadedASRModel 保存 app-owned 兼容模型包装，Native backend 文件不再直接导入 STT 包；主模型管理器和会议转写处理也去掉不再需要的 Audio 导入。T0 的实际加载门禁继续生效，兼容包装不恢复生产 Swift fallback。
- 此阶段不删除 SwiftPM Audio products，也不重写音频重采样、VAD/Sortformer 或权重验证。HTTP 的 wire request/result 仍在 HTTP adapter 路径中；XPC DTO、Core ABI、权限和签名不是此阶段已交付内容。

已执行：

- git diff --check、全部修改/新增 Swift 文件的 frontend parse：通过。
- Linux Swift 6.2.3 编译实际契约、兼容转换、live runtime、分段、MOSS 渲染和 SenseVoice 元数据代码；兼容包的数据类型/生成参数来自锁定的 Audio revision 2a6e75d，MLX array、库 streaming session、App 资源与隔离宿主依赖使用 stub。
- 上述隔离模块运行实际 XCTest：MLXNativeLiveRuntimeTests 的 10 项与 SenseVoiceMetadataTests 的 10 项通过，共 20 项、0 failures。SenseVoice 的 UI configuration summary 测试没有纳入此子集；这不是完整 Voxt test target 编译或 macOS 测试通过。
- 6 项额外 adapter/structured transcript 场景通过：事件过滤及顺序、取消转发、chunk timing 不升级为可靠时间戳、无效 timing 过滤、MOSS speaker/tag 处理、无分段元数据回退。
- T0 的 69 项隔离门禁检查重新运行通过；Voxt/tools 的 20 项工具测试通过；源码与 lockfile 依赖审计通过。
- pre-commit run --all-files：通过。
- 两个实施 subagent 分别处理上层调用方与 batch/planning；最终只读审查发现一个旧测试的 endTime 字段引用，已更新为 endSeconds。未把审查或 Linux 子集通过解释成 GPU/签名验证通过。

macOS 待补：第 13 节的 Debug/TestDebug、Intel 构建和完整 XCTest；重点关注 MLXNativeLiveRuntimeTests、MLXInferenceConfigurationTests、SenseVoiceMetadataTests、ASRHintSettingsTests、MeetingLiveSessionSupportTests、MeetingMLXNativeFeedSchedulerTests、OmniTranscriptionRequestTests，以及真实 Native final/realtime/会议回放。下一任务为 T2 最小真实签名 XPC + Qwen/MLX/Metal smoke；已定义的 Swift Codable 值不能直接当作 NSXPC 安全编码协议使用。
