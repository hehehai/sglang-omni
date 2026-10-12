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

T0、T1、T2 验证链路和 T3a final session 的进展见第 13 节；真实签名/macOS 验收仍待补；T3b1 已抽离 realtime engine，T3b2a 已实现 realtime C ABI，T3b2b 已接共享 contracts package 与 opt-in XPC realtime；T4a 已抽离 auxiliary model 的非推理下载校验，T4b1 已新增 Silero Core ABI4、T4b2a 已接 opt-in offline Silero XPC、T4b2b 已接 bounded streaming Silero XPC，T4c1 已加 atomic publication/cooperating directory leases、T4d1 已加 Sortformer Core ABI5；Sortformer XPC、完整缓存迁移及 T5 以后仍待实施；已有 Helper 打包和 Native golden 是基线证据，不计作 XPC 任务完成。

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

macOS 待补：第 13 节的 Debug/TestDebug、Intel 构建和完整 XCTest；重点关注 MLXNativeLiveRuntimeTests、MLXInferenceConfigurationTests、SenseVoiceMetadataTests、ASRHintSettingsTests、MeetingLiveSessionSupportTests、MeetingMLXNativeFeedSchedulerTests、OmniTranscriptionRequestTests，以及真实 Native final/realtime/会议回放。已定义的 Swift Codable 值不能直接当作 NSXPC 安全编码协议使用；T2 的具体实现与平台验证边界见下节。

### T2：最小 XPC/Qwen 验证链路

状态：代码和构建/运行工具已实现，Linux 契约、C ABI 与结构检查通过；真实 macOS XPC/Metal、签名和 App Group 授权尚未验证。此阶段不能勾选为完整验收通过，也未切换生产 backend。

实现范围：

- 新增 OmniInference XPC target、OmniXPCDebug 配置和 VoxtOmniXPCSmoke scheme。新 scheme 顺序构建服务与 App；普通 Debug/TestDebug/Release、原 Voxt scheme 与 Intel 路径不依赖此 target，也不嵌入验证服务。
- libOmniCore.dylib 以 C ABI 调用已有 Qwen transcriber/worker，不启动 HTTP server，不把 MLX 模板类型暴露给 Swift。头文件明确 malloc 结果/错误的释放方法，模型 load/infer/destroy 保持在同一 Native worker 线程。
- XPC 使用 Foundation 可编码的 Data、String、整数、Bool 和 NSError；音频为单声道 16 kHz little-endian Float32，验证版限制 30 秒、4096 tokens，并检查有限值、消息/文本长度、相对模型目录及 Native 会读取的文件 symlink 范围。
- 单服务只接受一个活动推理，不积压排队音频。每次验证请求加载并在 reply 前释放模型。断连取消已提交工作；C ABI 的取消状态会锁存，避免断连发生在 Swift 活跃检查后、Native Submit 前时漏掉取消。取消后的 handle 必须销毁，新请求创建新 handle；它不是 T3 的模型常驻/逐 session 取消协议。
- App 与服务必须配置同一真实 App Group，彼此用 bundle ID + Apple generic anchor + signing team 的代码签名 requirement 校验。NSXPCConnection.setCodeSigningRequirement 的公开 API 已核对，macOS 13.0 起可用；实际授权与消息运行只能在 Mac 上验证。
- Runtime dylib 和 sibling mlx.metallib 放入服务 Frameworks，嵌入工具检查 arm64、install name、rpath 和依赖 allowlist。只签 Mach-O，从 dylib 到 XPC 到 App；签名验证失败不能继续作为签名包交付。
- App 的 smoke 入口仅在显式验证构建启用，在普通启动服务之前执行。prepare 返回经检查的共享容器；infer 从独立 fixture 目录读音频/预期文本，验证首次转写，主动结束服务，重连后再次转写并核对预期。诊断退出接口不作为生产功能。
- 构建与执行工具分离。build_omni_xpc_smoke.sh 只证明构建/签名结构，不能代替 run_omni_xpc_smoke.sh 的真实运行。--no-sign 仅用于结构检查，不算签名、共享授权或可运行证明。

已执行：

- 实际 OmniXPCProtocolTests 在 Linux Foundation 模块运行：16 项，15 通过、1 跳过、0 failures。跳过的大小写变体 symlink 用例需要 case-insensitive 文件系统，留待 Mac 验证。没有使用模型或 XPC 平台 stub；只证明配置、路径和音频契约。
- Native 公共 C ABI、实际 worker 与明确标注的模型/MLX stub：GCC 10 项通过；Clang ASan/UBSan 同组 10 项通过。覆盖纯 C 头文件/linkage、无效输入、内存所有权、分配失败、运行中取消、提交前取消、并发与销毁线程。
- 29 项 Voxt/tools 工具测试通过，其中新增的打包结构场景使用 fake lipo/otool/codesign，不代表 Mach-O 或真实签名通过。
- T0 的 69 项隔离门禁检查、T1 的 20 项隔离 XCTest 与 6 项 adapter/分段场景重新运行通过。
- Swift frontend parse 与 C interop/客户端/服务 helper 的平台替身 typecheck 通过；后者移除了 Objective-C 平台声明并使用 compile-only Foundation XPC stand-in，仅用于检查 Swift/C 指针和数值类型，不证明真实 NSXPC 编码、SDK 编译或运行成功。
- Shell/内嵌 Python 语法、plist/scheme/工程结构、源码/lockfile 审计、git diff --check 和全仓库 pre-commit：通过。
- 两轮审查指出提交前取消竞态、模型文件 symlink 越界及大小写不敏感卷的文件名绕过，均已补检查并增加回归测试。固定文件按 Native 实际打开的路径检查，不依赖目录项拼写；并未把预加载检查视作跨进程文件更新的原子性保证。T4 仍需完整发布/删除/lease 协调。

Mac 上的执行步骤（使用自己已经授权的真实值，不要提交个人 Signing.local.xcconfig）：

```bash
export VOXT_OMNI_TEAM_IDENTIFIER="<your-team-id>"
export VOXT_OMNI_HOST_BUNDLE_IDENTIFIER="<your-validation-host-id>"
export VOXT_OMNI_XPC_SERVICE_ID="<your-validation-service-id>"
export VOXT_OMNI_APP_GROUP_ID="<your-authorized-app-group>"
export VOXT_OMNI_NATIVE_RUNTIME_DIR="<absolute-runtime-output-directory>"
bash sglang_omni_mlx/native/scripts/build_runtime.sh "$VOXT_OMNI_NATIVE_RUNTIME_DIR"
bash Voxt/tools/build_omni_xpc_smoke.sh \
  --app-sign-identity "<Apple Development or Developer ID Application identity>"
bash Voxt/tools/run_omni_xpc_smoke.sh \
  "<app-path-printed-by-build-tool>" "<Qwen-checkpoint-directory>" \
  "<short-speech-audio-fixture>" "<expected-transcript-text-file>"
```

运行工具使用 Mac 自带 afconvert 和 Python 标准库准备 fixture；这些不是 App 推理的运行依赖。模型权重复制并解引用到独立 App Group smoke 目录，原权重不修改；失败时保留副本，确认服务空闲/退出后再手工删除，避免超时加载尚未结束时误删。成功时清理副本。工具不会输出转写内容，也不会自动修改生产模型路径或迁移用户缓存。

剩余验收/限制：

- 在 Apple Silicon macOS 26.2+ 完成实际 App/服务编译、双向 signing requirement、共享目录读写、bundled MLX/metallib 定位，以及两次真实 Qwen 转写与服务崩溃恢复；记录 SHA、机器、体积和运行结果。
- Native model create 仍是同步加载，加载中无法立即抢占取消；断连后会在加载返回时检查状态并释放，不继续推理。T3 需明确完整 loading 取消/超时恢复和常驻资源状态机。
- T2 只支持 Qwen final 的验证接口，不支持 streaming、其他 ASR、VAD/Sortformer 或正式客户端切换。T0/T1 的 macOS 全 App 回归仍需补齐。
- 仅本地真实签名结构检查不是公证/Gatekeeper/干净机器安装认证。发布与历史缓存迁移继续由 T4/T7 验收。

### T3a：常驻 Qwen 模型与 final-only session

状态：T3 的第一个可回归子阶段；不等于 T3 完成。实际 realtime/preview 仍由既有 HTTP 路径提供，T3b 才抽离其消息耦合并接入 XPC。此阶段只在 finish 后推理，不将分块接收称作 realtime。

实现范围：

- Native Core ABI 升为 2；保留旧函数/result 布局和 model-wide sticky cancel，新增独立的 single-use request token。请求取消在 Submit 前锁存，已提交 worker 持有共享 cancellation flag；取消/销毁一个 token 不污染常驻模型或其他请求。
- XPC 新增显式 load/unload、startFinalSession、pushFinalAudio、finishFinalSession、cancelRequest。模型只由一个连接拥有，model UUID 每次加载更新；session 与后续消息共同绑定 model ID，返回还带 service-instance ID。
- 客户端模型引用绑定创建它的 connection ID；旧请求的清理不重连、不关闭替换连接。取消 RPC 的业务拒绝不被当作 transport failure，避免取消被拒绝的请求时误终止另一个活动 session。
- 每个模型最多一个 receiving/finishing session；chunk 最大 2 秒，ACK sequence 从 1 递增，重复/乱序/非有限值/超预算音频不改变已接收状态。总验证音频预算仍为 30 秒；用户音频不自动重放。
- final session 状态覆盖 receiving、finishing、cancelling、completed、cancelled、failed。finishing 的取消等待 Native 结果归并为 cancelled；一次终态不能被后续 complete/cancel 改写。模型卸载在活动 session 下拒绝，断连则取消并排入释放 barrier。
- 模型保留在 ready 状态供多个 final session 使用。load/unload 和 Native 计算/销毁串行执行；session/operation 历史有明确上限，不能无界增长。
- load/unload Task 取消关闭原连接以避免未消费的 model ID 留下资源；final session 使用请求级取消。同步模型加载仍不能立即抢占，加载返回后检查取消/断连并释放，硬超时通过连接恢复，不宣称已经实现完整可抢占 loader。
- opt-in smoke 升级为 ABI 2：取消一个 receiving session，复用同一 model ID 完成两个 final，显式 unload，随后服务退出/reconnect 并重新加载推理。新 dylib 与 App/service 必须一起重建，不能沿用 ABI 1 artifact。

验证与限制：

- Native public ABI/实际 worker + 明确的模型/MLX stub：GCC 22 项、Clang ASan/UBSan 同组 22 项通过，包含预取消、single-use、排队取消、token 销毁、模型复用与旧 API 回归。
- 实际 Foundation policy/final-buffer XCTest：24 项，23 通过、1 case-insensitive filesystem 用例跳过、0 failures。覆盖序号/预算、空 finish、取消/finish 竞争和一次终态；不代表 NSXPC 或模型推理通过。
- 使用实际服务 engine、Native C ABI、worker 的隔离 host harness 跑过 ownership、常驻模型复用、receiving/native 取消、活动 work 禁止 unload、重复 finish、模型重载后的旧引用隔离与断连释放。平台和模型使用替身，明确不是真实 XPC/GPU 证明。
- Swift helper/platform-stand-in typecheck、frontend parse、29 项工具/结构测试、源码/lockfile 审计及全仓库 pre-commit 重新执行通过。T0 的 69 项隔离门禁检查、T1 的 20 项隔离 XCTest 与 6 项 adapter/分段场景也重新通过；SDK Objective-C 编码、签名/App Group、Metal、真实模型回放仍需 Mac 验证。
- 三轮只读审查发现取消业务拒绝误断连接、旧清理影响替换连接、重载模型后的 session ID 混用及同连接新模型被旧清理误重置。已增加 connection/model 双重绑定，cleanup 不再为业务拒绝重置连接；one-shot convenience 改为显式 load/transcribeFinal/unload。最终静态复查未发现具体剩余错误，不能代替 Mac 运行验收。
- 当前 cancel ACK 表示请求取消已受理，不是 Native work 已全部退出；finishing 的 barrier 完成前，新 session/unload 会拒绝。T3b 的 event/session 客户端需明确展示和等待 terminal/drain。
- 保留生产 HTTP routing 和其 API；没有运行真实 HTTP/golden GPU 测试，不把源代码未修改解释为 golden 已通过。T3b 的真正 realtime 抽离应在这些测试基线上验收。

### T3b1：transport-independent Qwen realtime engine

状态：T3b 的第一个代码检查点，仍不是 realtime 已跨 XPC，也不是完整 T3 验收。ABI 保持 2，App/XPC final 路由未改变。

实现范围：

- 将现有 Qwen segment/preview/final 状态机抽为 RealtimeEngine；接收 mono 16 kHz float 样本，使用 typed updated/segment/completed/failure event，不处理 JSON、base64、socket 或 XPC。
- 保留 RealtimeSession 作为 HTTP adapter：原 manual-turn、PCM16/base64、session/error 字段、segment ID/final flag、event ID/index 和完成文本不改变。RealtimeConnection base 与 MOSS 的算法/adapter 均未修改。
- 沿用实际 TranscriptionWorker 和原算法：两次尝试后使用前缀，回退 5 tokens；保留 preview cadence、leading silence、分段语言快照/推断语言继承、自动 cut、English/CJK 拼接及失败恢复。
- 修复 preview 发布与 final 之间的原有竞争：worker 在 preview event 发布后才解除 refreshing，final/completed 不再抢到 preview 之前。新增 typed engine 的 Finish 只产生一次 completed，完成后不再接收新命令。
- engine 持有独立 cancellation flag；HTTP adapter 共享其原 flag。Close 可与命令并行，等待活动 event sink 返回、抑制晚到事件，但不把取消当作 Native work 已 drain。同步等待的 Commit/Finish 使用同一状态 mutex 与取消唤醒，避免丢失 notification。
- engine/HTTP callback 使用 weak ownership，不捕获已销毁 adapter 的裸指针。命令必须串行，event sink 不得抛错或重入命令（Close 除外）；worker/model 必须活到所有排队/运行 work drain 后。后续 Core ABI 必须实现资源 barrier，不能直接销毁借用的 model。
- 验证 cadence/segment settings 的正数、有限值、换算溢出，避免除零/整数溢出；有效 settings 的原截断行为保留。

验证：

- 新增可独立复现的 CPU 合约 suite 与 README：14 项 HTTP recorded-baseline、14 项真实旧/新源码 live replay、14 项直接 float/typed engine，共 42 项；显式使用 scripted model/audio/Unicode/tokenizer/MLX 替身，不重写 production 源码。
- baseline 取自 f2e2cf4 的真实 realtime.cpp/.h，记录并校验完整 public event、返回值和 decode inputs/options，只有随机 event ID 在验证格式后移除；不是手写模拟旧实现。无 baseline 源码时 14 项 live BEFORE replay 明确 skip，但 recorded AFTER 和 engine checks 仍运行。
- 更新后 realtime 42 项 + ABI/实际 worker 22 项，GCC 64 项通过，Clang ASan/UBSan 同组 64 项通过。覆盖 Close 在不配合取消的 preview 仍阻塞时唤醒 Commit/Finish，以及之后释放/drain 不发布晚到 success。
- 29 项 Voxt 工具测试、6 项 golden 工具单元测试、源码/lockfile 审计通过。全仓库 pre-commit 重跑通过；不把 CPU 合约、golden 工具单测或静态代码审查称作 GPU golden 已通过。
- 两轮只读审查发现并修复 Close 的丢失唤醒；复查独立重跑 GCC 和 Clang sanitizer 各 64 项通过，在已说明的调用/借用生命周期契约下未发现具体剩余错误。
- 已在现有 gated Mac CI 中添加 Core/realtime CPU 合约和 OmniXPCProtocolTests；使用 runtime build 已 provision 的 JSON headers，不在 test 中下载。没有启用 CI gate、签名发布、公证或任何生产 XPC routing；CI 本身仍待真实 runner 执行。

后续 T3b2 拆成 Native C ABI 和 Foundation XPC 两个独立代码检查点，进展见下节。真实 Mac signed smoke、模型 realtime/golden、HTTP/WebSocket 与 MOSS 回归必须补齐，才能将 T3 标为验收完成。

### T3b2a：Native realtime C ABI、背压与资源 drain

状态：实现阶段完成，真实平台/模型验收未完成。Native Core ABI 升为 3，旧 final/result/request 函数和布局保留；App/service probe 与 smoke artifact 检查同步升级，必须一起重建，不能混用 ABI 2 artifact。没有新增 XPC realtime RPC，没有改变生产路由。

实现范围：

- 新增 opaque OmniQwenRealtime 与 create/push/finish/poll/cancel/drain/destroy/event_free；由已加载模型的实际 RealtimeEngine 产生 typed event，ABI 不传 JSON/socket 或裸 C callback。nonzero session identity、严格 audio sequence/ACK 和无 gap 的 event sequence 贯穿 owned poll output。
- Native 参数覆盖语言/context/token budget，使用 kVoxtSwift、EOS/token-loop stopping；HTTP 构造的默认 options 不变。音频 chunk 最大 32000 samples，session admission 最大 480000 samples，非有限值/空/过量/重复/乱序输入被拒绝，不消耗序号。
- 每个 session 事件队列最多 64 项，预留一个唯一 terminal；单个输出最多 64 KiB、排队字符串最多 4 MiB。背压拒绝未 admission 的 audio，不静默丢音频；已 admission 的处理失败通过 FAILED terminal 返回，ACK 不冒充推理成功。
- 除 poll queue 外，限制 Core 常驻 committed transcript：最多 512 个 final segment，最多 64 KiB committed text（保守包含可能的连接空格）。即使消费者不断 poll，也不能绕过 session 内部文本/空段存储预算。
- poll 的字符串由 ABI 单独拥有，event_free 清空、可重复调用；输出/错误在调用前清空，原 allocation 需调用者先 free。poll allocation failure 不弹出 head，重试不会丢事件。错误使用固定的 sanitized message，不泄露音频/文本/模型路径。
- model state 与 realtime lease 共享所有权；model handle destroy 阻止 admission、取消并 drain session，不会提前销毁 engine 借用的 model/worker。已存活的 realtime handle 可保留模型直到最后一个 session destroy；最终 model 释放仍在 loading/worker thread。没有 realtime lease 时保留旧 shutdown 行为。
- 取消绕过 push/finish command mutex；状态/队列/model 锁不在等待 worker/sink/join 时持有。drain 仅接受已 latched terminal，关闭 engine 后使用两次 completion barrier，覆盖 Close 与 worker callback 的晚到 refresh Submit，且 model cancel 不能使 barrier 提前跳过 completion。
- 原异步 engine completion 的字符串 copy/后续 refresh allocation failure 现已捕获、发布预分配 failure event、清理 refreshing 并唤醒 waiter；不会让异常越过 worker completion 导致 std::terminate。

验证：

- 公共 ABI suite 扩到 43 项，含既有 22 项回归及 realtime identity/limits/options/ownership、预取消/活动/排队取消、finish/cancel、model cancel/destroy、poll allocation、queue terminal reserve、持续 poll 的 committed transcript 上限。
- 特别加入 deterministic operator-new fault：预先构造的 model output 通过 move 返回，其 4098-byte preview copy 在 worker completion 内失败；验证 FAILED、drain、无晚到事件及后续 final 复用模型。此项和 malloc injection 在非 Linux 平台明确 skip。
- ABI 43 项 + typed engine/真实旧新 HTTP replay 42 项，共 85 项，GCC 与 Clang ASan/UBSan 各通过。复查独立执行 ABI 两组 43 项、HTTP 42 项，在已说明的 raw-handle 同步与调用契约下未发现具体剩余问题；不是实际模型 golden。
- Swift 导入并链接实际 ABI3/Core/worker/engine + model stub 的 smoke 通过：create/push/owned event/finish/drain/destroy；Foundation policy XCTest 24 项中 23 通过、1 case-insensitive filesystem 用例跳过。不是 macOS SDK/NSXPC 验证。
- Voxt 工具 29 项、源码/lockfile 审计、frontend parse、smoke shell syntax 和全仓库 pre-commit 重跑通过。

T3b2b 的 opt-in XPC/ASRStreamingSession 接入见下节。完整签名 Mac smoke、Metal/model inference、HTTP/MOSS network/golden 及原 App/Intel 回归仍需验收。

### T3b2b：共享 contracts package 与 opt-in XPC realtime

状态：代码检查点已实现，不等于完整 T3 平台验收完成。Qwen realtime 已有 NSXPC RPC、helper Native lease 和 App ASRStreamingSession adapter；仍为 opt-in 验证路径，production model-manager routing/HTTP/LLM/VLM 未切换。

模块边界与实现：

- 新增本地 Swift Package Packages/OmniXPCContracts，只有 Foundation、无第三方依赖。实际配置、错误/预算、model/session references、final-buffer、macOS XPC protocol 和 bounded realtime codec 均由 App/helper 直接 import；移除重复编译共享源文件，不使用 re-export/typealias facade。
- Package 的真实 XCTest 可直接 swift test，无需 App build、Xcode/MLX/model 或平台替身；原 24 项 policy/buffer 测试迁入并增加 13 项 realtime settings/wire schema/UTF-8 bytes/sequence/terminal/drain/replay 编解码用例。
- helper 单一 coordinator 拥有连接/model/identity ledger/锁与 serial inference queue；生命周期、final commands、realtime commands、ACK batch retention、Native lease 是各自内聚的文件，不再堆成一个巨型 engine。
- 新增 startRealtimeSession、pushRealtimeAudio、finishRealtimeSession、pollRealtimeEvents、closeRealtimeSession；model 与 connection owner 同时校验，模型只允许一个 final 或 realtime session。最终 Native token 的取消也带 session ID，防止延迟取消打到替换 final request。
- poll 一次最多 16 项/2 MiB，retained batch 必须整体 ACK；同旧 ACK 的重试返回完全相同 Data，改变 batch count 或未来/局部/回退 ACK 明确拒绝。已从 Native 弹出的 event 保留到成功编码/ACK，JSON escaping 超预算可缩小 batch，不丢 suffix。
- terminal ACK 才触发 Native drain/destroy 并释放 active slot；terminal 未 ACK 或 drain 未返回时拒绝 unload/replacement。close 是显式 abandon cleanup，cancel ACK 只受理取消。最后一个 drained response 限定 owner/model/session，可安全重试，不清理新 session。
- Native push/finish/drain 在 helper serial queue，不在 model worker或 global model lock 中执行；取消绕过队列，创建前取消锁存到 lease。disconnect 排入先 RT drain/destroy、后 model close 的 barrier，失败则保留资源而非提前 free。
- App 的 OmniXPCRealtimeClient 扩展原 MainActor transport：origin connection 强校验、顺序音频、batch identity/sequence/ACK/replay 检查，业务拒绝不当作 transport failure；不自动重放已 admission 的音频。
- OmniXPCStreamingSession 实现原 ASRStreamingSession：4 秒 pending audio、30 秒 validation input、2 秒 chunk、单个 latest presentation event；复用现有 assembler/joining，保留 partial replacement，不伪造 language/token/timing metadata。completed/failed 在 Native drain或 cleanup 返回后由 owner 发布一次。
- 本地 overflow/nonfinite failure 先锁存、关闭输入并取消 worker，不能在 Native 仍阻塞时提前发布失败终态；原诊断不会被后续 CancellationError 改写。cancel 可无结果结束 presentation，但 waitUntilClosed/closeAndWait 才是 cleanup barrier。
- consumeEvents 提供 structured consumption：false/早退/throw/task cancel 触发 closeAndWait，实际 smoke 两个消费者已使用。保留的 raw AsyncStream 不会观察 for-await break；其调用者必须显式 closeAndWait，不声称 onTermination 能自动检测早退。
- Xcode App/helper 实际链接同一 local package product，Mac gated CI 新增 standalone package 与 streaming XCTest；依赖审计只允许该唯一 contracts package path，任意 local model package override 仍拒绝。

验证与边界：

- 真实 Package Debug/Release 各执行 37 项 XCTest：36 passed、1 case-insensitive filesystem skipped、0 failure，无平台/模型替身。
- 实际 portable buffer/session/domain + existing assembler/protocol 的 12 项 XCTest 通过（Native owner cleanup 用明确 continuation gate 模拟），额外 20 次重复执行通过。覆盖失败不早于 owner completion、晚安装 worker、consumer false/throw/cancel、raw break 显式 disposal、bounds/partial/未知 metadata。
- 主助手隔离 host harness 执行实际 helper/Native ABI/worker/engine，覆盖 owner隔离、Native admission、ACK raw byte replay、非法 count/ACK、terminal ACK/drain、cancel/close幂等、模型复用。
- 主助手进程内 RPC harness 连接实际 client → exported service methods → Native ABI/worker/engine → ASRStreamingSession，覆盖 ACK replay、取消、ended/drain、早退消费、Native preview 阻塞时本地 NaN failure 未提前发布、释放后一次原失败，以及随后同一模型 final 复用。
- 以上 host/RPC harness 使用明确 NSXPC/signing/container/model 替身，不是实际跨进程 NSXPC 或 Metal/GPU 证明。Mac opt-in smoke 增加实际 ASR adapter realtime 和 cancel/drain/reuse 回放，但尚未执行。
- Native ABI 43 + typed engine/真实旧新 HTTP source replay 42，Clang ASan/UBSan 85 项通过；32 项工具测试、model source/lockfile 审计通过。Swift parse/strict platform-stand-in typechecks 与全仓库 pre-commit 重跑通过。
- 两轮只读审查发现并修复 local failure 提前终态、保留 AsyncStream 早退不清理两处生命周期问题；复查在已声明的 owner/consumer/Native contract 下未发现具体剩余问题，不能代替 Mac acceptance。

下一工作：优先运行 signed Apple Silicon XPC final/realtime/model smoke 与完整 App/Intel/HTTP/MOSS/golden 回归；继续 T4 Native VAD/Sortformer、缓存迁移/授权/lease-delete 协调。未经这些验证，不将该 30 秒 opt-in validation session 当作生产长会议 backend，也不提前删除 MLX Audio 或切换 production routing。

### T4a：将 auxiliary model 下载校验与推理解耦

状态：T4 的部分代码检查点，非完整 T4 验收。production VAD/Sortformer 推理与选择、Remote ASR/LLM、本地 LLM/VLM、现有缓存路径均未切换。

- 新增独立 Foundation-only OmniModelArtifacts package。只读 root config.json 与 Native 实际读取的 top-level safetensors，单个 artifact 最多读取 16 MiB config/length-prefix/header，不读取权重 payload 或实例化 MLX/Audio/model。
- 校验 JSON object/UTF-8、tensor schema/dtype/unsigned shape、overflow、offset 数量/范围/相邻覆盖、payload 文件长度；拒绝损坏、截断、重叠、gap、未知 dtype 等结构错误，兼容标量、空 tensor、metadata 和普通 HF cache symlink。仅支持已声明 dtype，不是任意未来 safetensors 格式自动兼容。
- Silero 的实际 inference loader 原样移到 SileroVADModelLoader，多处 runtime inference 仍使用 scoped MLX withError；provisioner 不再 import MLX/MLXAudioVAD，不通过加载 GPU 模型来“验证下载”。
- MLXModelDownloadSupport 对 Silero repo 在临时下载目录发布前调用 artifact validator；provisioner 对返回目录也进行后台结构检查，取消/退出仍等待已有 owner task。
- Sortformer 保留原 presence/shard-index 检查，新增 temp artifact 检查后才允许原目录 remove/move，不再发布后调用 SortformerModel.fromModelDirectory；取消传到 detached publication task，只在破坏性 remove/move pair 之前检查，避免旧目录已删却因新增取消点跳过 move。
- 存量 cached-directory presence fast path 保持原语义，不自动删除或迁移旧权重；实际 inference 仍负责 tensor keys、config semantic 与模型兼容检查。新结构检查不表示 GPU/model 正确，也不实现跨连接 lease-delete/原子 publication/TOCTOU-safe cache。
- App 实际链接 artifact package，helper 暂无调用因此不增加无用 dependency。依赖审计仅允许两个明确的 Foundation package path，仍拒绝未审查 local model override；gated Mac CI 增加 standalone artifact tests，未开启 gates。

验证：真实 package 的 authentic safetensors 二进制 fixture（含结构损坏/超限/8 GiB 稀疏 payload）独立 Debug/Release 各 34 项通过；主助手实际 Silero provisioner + artifact validator 的隔离 harness 覆盖 cached-presence、有效/损坏下载、并发 coalescing、取消/退出 barrier（下载/storage/runtime 为明确替身，非 GPU/真实 Mac 验证）。已有 OmniXPCContracts 37 项（1 filesystem skip）、T0 69 项 policy 回归和 33 项 tools/audits 通过。完整 App typecheck/macOS XCTest、真实 Silero/Sortformer checkpoint/GPU/网络与性能验收仍需 Mac 补证；Native ABI/HTTP 未修改。独立审查发现 Foundation 接受 trailing commas，已将 UTF-8/重复字段/逗号 token 检查抽成 config/header 共用实现并增加回归；修复后重跑真实 package 与 provisioner harness。全仓库 pre-commit 重跑通过。

T4b1 的 Silero Core 接入见下节；Native VAD/Sortformer XPC、缓存迁移、授权、模型 lease/下载/删除协调继续待实施。本检查点不等于移除 MLX Audio 的条件已经满足。

### T4b1：bounded Silero offline/stream Core ABI4

状态：Native Core 代码检查点，不是完整 T4 平台验收。只接 Silero C ABI，尚未新增 VAD XPC RPC、App VAD client 或 Sortformer ABI；production VAD/ASR/diarization、HTTP/MOSS wire/defaults、LLM/VLM、用户模型选择与缓存均不切换。

- ABI4 只追加 OmniSileroHandle/Request/Stream、固定字段 settings、owned timestamp/probability arrays 与 15 个 C 函数；保留全部既有 Qwen functions/result/realtime layouts。App/shared contracts/helper probe/smoke 的 ABI expectation 同步 4，旧 runtime 不匹配时显式拒绝。
- 复用实际 SileroVAD constructor/Feed；不通过 HTTP、不为每个 stream 重新加载模型、不伪装成 Qwen TranscriptionResult。真实 ProbabilitiesToTimestamps 与 types/constants 抽成无 MLX 依赖的 header，原 HTTP/CLI 调用算法不变；公共 error declarations 也独立共享，不让 VAD import Qwen-specific ownership。
- 专用持久 worker 拥有 model 与至多 16 个 native stream-state slot，所有 MLX 模型/LSTM state 的创建、使用与释放都在该线程。caller shared command gate 在 audio copy 前串行化，使每个 model 最多一个 bounded copied input/queued-running command，避免无界排队缓存。
- Offline 接受 1..480000 finite mono 16 kHz samples、显式 threshold/ms settings；独立 single-use request 第一次尝试即 consumed，取消可早于 submission，不污染可复用模型。每个 512-sample Feed 前后检查取消，最后 partial frame 零填充，timestamps 裁到真实输入长度。
- Stream 每 push 最多 32000 samples，sequence 从 1 开始。无效输入/sequence/overflow/pre-admission copy allocation failure 不消耗序号、可重试；admission 后 inference/output-allocation failure 或 cancellation 锁定失败/取消，不能因 ACK=0 而自动 replay audio。
- Stream 仅保留少于 512 pending samples 和 native recurrence state，不设 30 秒 total cap，可持续 VAD；每次 owned probability array 至多 ceil(chunk/512)，返回 finite 0..1 probability。processed_sample_count 是已推理整 frame 的 sample 数（含 finish padding），不是录音接收 sample 数；counter/sequence overflow 拒绝 admission。
- finish 补最后 frame，成功 terminal immutable；重复 finish 返回空 array 和相同 processed count。cancel 绕过 command gate且独立 model；drain 只接 terminal，等待 work/barrier 后由 worker 释放 native state。model destroy 停 admission、cancel/drain，live stream lease 可继续保留 model/worker 到最后 destroy，不提前 free。
- C ABI 清 outputs、sanitized errors、owned/free 幂等、exception containment 与 raw-handle destroy 同步条件写入 header。加载仍 synchronous/nonpreemptible，取消不声称硬 GPU preemption；每 frame 已评估 state 和 cache 的真实 GPU 行为仍需平台验证。

证据与边界：

- 旧 ABI 43 + Silero 31 = 74 项，编译实际生产 Core/worker/header/pure timestamp，只有模型/MLX/tokenizer/audio 等明确替身。覆盖 pure C layout/link/export、worker ownership/destruction thread、partial padding、continual stream、独立 recurrence、lease limits、request/stream/model cancellation、blocked Feed→drain/model destroy、allocated output failure、invalid probabilities、input/settings/sequence bounds、串行化/隔离和 legacy Qwen。UInt64 processed counter 上界不可通过可行长度回放到达，未通过修改 private layout 伪造覆盖。
- 主助手完整 ABI74 + typed engine/真实旧新 HTTP source replay42：GCC116、Clang ASan/UBSan116 全通过。独立审查另跑 ABI74 sanitizer，声明的 caller-lifetime/worker contract 下未发现具体问题；不是实际 GPU/跨进程验收。
- 从提交 7d975c0 的真实 Silero source 提取 BEFORE timestamp body，与实际 AFTER header 作 10000 组确定性输入/threshold/duration/padding replay，ranges 全一致；此纯算法证据无 MLX/model/network 替身，不能证明 Feed 数值/GPU模型一致性。
- Swift 导入/链接实际 ABI4 header/Core，与明确 model/MLX 替身回放 owned probability/timestamp/free、stream terminal drain 与同模型 offline reuse。真实 Qwen client→exported service→Core/worker→ASRStreamingSession 的既有 in-process RPC harness 在 ABI4 上重跑通过，仍不等于 NSXPC/签名/Metal 验收。
- OmniXPCContracts 37 项（1 filesystem skip）、33 项 tools/source/resolved audits 与全仓库 pre-commit 重跑通过。Native test suite 已在现有 gated Mac CI 选择范围内，不启用 gates，也不声称该 runner 已执行。

Silero offline XPC 的独立闭环见 T4b2a；streaming VAD RPC/调用者与 Sortformer typed state/Core/XPC 继续待实施。完整 cached-directory 授权/迁移/lease-delete 与实际 ASR+VAD+diarization GPU 并行安全性、内存/长会议/性能/golden/Mac App 与 Intel 回归验收仍待补。

### T4b2a：opt-in offline Silero XPC 模型与 request 复用

状态：部分 T4 代码检查点，尚未切换 production VAD/ASR/diarization，也不是完整 T4/平台验收。Core 仍 ABI4；此步只有 load/offline sample ranges/scoped cancel/unload，不添加未来 streaming/Sortformer stub 或删除 MLX Audio。

- OmniXPCContracts 新增 typed settings、独立 Silero model reference 与 sample-unit timestamp batch；配置最多 1 KiB、结果最多 64 KiB/938 ranges，strict keys/UUID/整数/range顺序与边界检查。公共 bounded Float32 LE parser 由既有 Qwen 与新 VAD 共用，不伪装成 ASR token/options。
- 四个实际 NSXPC RPC：loadSilero、unloadSilero、sileroSpeechTimestamps、cancelSileroRequest。SileroCoreModel 直接调用真实 ABI4、保留同一模型和 UUID-scoped single-use request，copy 前检查 Native count/ranges并 free owned outputs/errors。
- Silero engine 只保留一个活动 offline request，最多 256 request IDs/model；无效或 busy/foreign admission 不占历史、不复制大型 audio array。decoder/copy 在 owner/history/busy 检查后进行，Native inference 不在 engine/service lock 下执行。
- Qwen/Silero 各有独立 lifetime/lock/queue/token ownership，不能在两个锁下共享同一 mutable connection flag/history。共同 service UUID 与 container/admission policy 抽到现有 helper service 边界；ASR engine 不扩成巨型 VAD state holder。
- Shared admission gate 只串行化两种 model load 的同步登记与诊断 idle reservation，固定 service→engine→token lock 顺序；只有两个模型均卸载且无法再登记新 load 时才能诊断退出。诊断拒绝不永久禁用后续加载。
- cancel request/model reference/operation ID 严格 scoped；completed current-load operation 也可清理 response-lost model，只影响该 Silero load，不关闭健康 Qwen或后来的 replacement。取消 ACK 不等于 drain，pending/cancelling request 的 unload/replacement 明确 busy；disconnect 按先取消 token、队列等待 Native 返回、后 close 模型顺序清理。
- App 明确 load→timestamps→unload，验证 originating connection + model/service/request identity + sample count；reuse 既有 LE encoder，不自动 replay audio、替换模型、走 Swift/cloud 或更改生产 factory。parent cancel、Silero deadline 走 typed Silero cancel RPC，不把健康 Qwen ownership 一并 invalidation；真正 transport failure 仍影响同连接两个模型。
- 原 signed smoke 保留四参数，新增可选第五参数 Silero model directory：只复制到独立 shared Models run 目录，在 Qwen model 已加载时两次 VAD 请求，crash/reconnect 后再两次，卸载后才成功清理。只检查 ranges 合法/同模型重复一致（允许合法无 speech），不冒充 VAD range accuracy golden 或 GPU 并行安全验收。

验证：

- 真实 SwiftPM Debug/Release 各 61 项：60 passed、1 case-insensitive filesystem skipped、0 failure，包含 18 项 Silero wire/options 与 6 项 shared audio regression；独立 reviewer 也重跑两配置。
- 主助手实际 client→exported service methods→ABI4/worker 的进程内 harness 通过 ranges/no-speech/model reuse、foreign/stale ownership拒绝、Native blocked Feed cancellation/unload barrier、健康同时加载 Qwen final、VAD-only diagnostic busy、response-lost load cleanup与 stale operation isolation。五次重复回放通过；NSXPC/signing/container/model 为明确替身，不是跨进程/GPU证明。
- 独立审查发现 Silero deadline 原先沿用 transport timeout invalidation 会误伤健康 Qwen；已抽到 typed scoped cancel 路径。新增 50 ms blocked Native deadline 回放：连接和 Qwen final 保留、VAD unload 仍 busy，release 后才允许卸载；独立复查重跑 VAD/Qwen harness，未发现具体剩余问题。
- 实际既有 Qwen final/realtime client/service/Core/ASRStreamingSession harness 回归通过；Native ABI74 + typed/旧新 HTTP replay42 的 Clang ASan/UBSan116 通过，Core/HTTP source 未修改。
- source/resolved model-stack audits 与 33 项 tools 检查通过；改动后 helper/client/smoke 的 Swift parse、补充 Linux platform-stand-in typecheck 通过，完整 App/macOS XCTest 与实际 ObjC NSXPC/Metal 尚待验收。全仓库 pre-commit 重跑通过。

Mac 复现：在第 13 节原 build_omni_xpc_smoke.sh 签名流程后，可调用 run_omni_xpc_smoke.sh <signed-app> <qwen-model-directory> <audio-file> <expected-transcript-file> <silero-model-directory>。可选 VAD 检查尚未在真实 Mac 执行；发布/缓存迁移与 GPU 并行、范围准确性/性能/长会议验收不得由 CPU harness 或 compile-only evidence 代替。

T4b2b 的 streaming 接入见下节；之后继续 Sortformer 状态/ABI/XPC，以及目录授权/缓存迁移、shared lease-delete 协调。

### T4b2b：bounded Silero streaming XPC 与 VAD owner

状态：opt-in 实现检查点，production HTTP/Swift VAD/会议/Remote ASR 与 LLM/VLM 路由仍不切换，Core 仍 ABI4。实际 Mac NSXPC/Metal/model/concurrent-GPU 验收待补；不是完整 T4 或长会议平台认证。

- 新增 startSileroStream、pushSileroAudio、finishSileroStream、closeSileroStream 四个实际 RPC；继续用 scoped cancelSileroRequest，不增加 model-wide stream cancellation。Foundation typed stream reference/probability batch 按 model/service/stream/connection identity 校验，结果最多 4 KiB/63 probabilities、finish 最多 1 个；counter 是含 padding 的 whole-frame samples。
- Helper 同一 Silero 模型至多 16 streams，各自保持独立 recurrence/pending samples，单 stream 最多一个排队/执行 command；copy/decoder 在 owner/history/busy 检查后执行。offline + stream 共用最多 256 IDs/model，不能与 operation/retired/offline UUID alias；持续 streaming 不受 ASR 30 秒 cap 限制。
- 每 push 最多 32000 samples。只保留一个 last successful audio/reply，最后同 sequence+完全相同 bytes 重试返回原 encoded Data，不再次调用 Native；改 bytes、未来/过旧 sequence 明确拒绝，client 不自动 replay。失败发生在 admission 后则锁定 failed/cancelled，只允许显式 cleanup。
- SileroCoreStreamLease 保留模型、登记 live lease、检查/复制/释放 C owned arrays；model token lock 不包 Native create/drain/destroy，避免 GPU Feed 阻塞独立取消。finish 只有真实 Native finish→drain→destroy 后才释放 active slot/回复 final；一条 scoped completed batch 可重试。close 取消绕过 inference queue，barrier 仍在队列等待 work，失败保留资源而非提前 free。
- load-OP cancel/disconnect 清理该 owner 的所有 streams/offline，先独立 cancel、后全部 drain/destroy、最后关闭模型。模型 unload/replacement 在 pending stream/cleanup 时 busy；旧模型/连接回调不能误伤 replacement，健康 Qwen 不受 VAD cancellation/deadline 影响。
- App MainActor client 维护 bounded stream records、精确 sequence/累计 samples/processed delta/identity/terminal 校验；actor 只允许一个 feed/finish，无 unbounded tail-task 链。probability 返回最新实际整 frame probability/nil，finish 显式补尾；structured scope 在 return/throw/cancel 后等待 close。Raw actor/ref 必须显式 close，不声称 deinit 或 callback早退自动成为 barrier。
- 审查发现并修复 rejected start 留 provisional slot（16 次拒绝会阻止健康模型）与 actor close 失败永久缓存不可重试两项问题。只识别来自 start RPC 的确定 pre-admission invalidRequest/busy 错误释放 provisional binding；timeout/nativefailure/ambiguous error 仍保留 owner 等待 cleanup。actor 失败 close 可重试且保留 terminal/coalescing，不伪造已 drain。
- 既有 optional Silero signed smoke 增加 structured streamed chunks/finish，helper reconnect 前后各一个 stream；报告验证 4 offline requests + 2 streams。此模式尚未在真实 Mac 执行，不是 VAD accuracy/concurrent-GPU golden 证据。

验证：

- 真实 Package Debug/Release 70 项：69 passed、1 filesystem-specific skipped、0 failure，包含全部 61 旧用例与 9 项 bounded stream DTO 用例。
- 实际 portable client state 8 项 + 实际 client/actor ownership 14 项通过，共 22 项；有明确 controlled transport peer/macOS-gate stripping，非并行 fake state machine。新增用例修复前失败、修复后 Debug/Release 与重复运行通过；ownership suite 不是未执行的真实 macOS NSXPC XCTest，gated Mac CI 仅选择实际可编译的 client state suite。
- 主助手实际 client→exported service→ABI4/worker 的 two-endpoint 进程内 harness，通过 byte-identical lost-reply/no-reinfer、改变 payload 拒绝、两个 recurrence state 隔离、finish/drain/retry、持续 >30 秒、blocked Feed cancel/close/unload barrier、健康 Qwen、structured disposal；另覆盖 transient RPC close rejection 后同 actor 重试、older completed ref close、16 次 stale starts 后同连接健康模型、disconnect 拒绝早替换并在 Native release 后重连。三个重复全链路回放通过。
- client-fix agent另以 test-only drain fault interposer 回放真实 helper/Core：barrier error保留模型且 unload busy、同 actor coalesced retry 到真实 Core drain成功；不是自然 Core/GPU fault 验收。独立复查重跑 22 portable 与最新 whole streaming harness，声明 lifetime/worker contract 下未发现具体剩余问题。
- 既有 Qwen final/realtime 与 offline Silero 整体 harness 回归通过；Core/HTTP source 未修改，Native Clang ASan/UBSan116 通过；33 项工具/source/resolved audits 通过。helper/client/smoke parse 与 supplemental Linux platform-stand-in typecheck 通过，全仓库 pre-commit 重跑通过。

Sortformer Core 与 cooperating publication/lease 进展见 T4d1/T4c1。Sortformer XPC、完整缓存迁移与 actual ASR+VAD+diarization GPU 并行、内存/长会议/性能/golden、Mac App/Intel/signing/notarization acceptance 仍待补。production factory 与 MLX Audio 依赖未切换。

### T4c1：cooperating directory leases 与 verified atomic publication

- OmniModelArtifacts 新增系统 POSIX shared/exclusive nonblocking flock、稳定 payload 外 lockfile与同 filesystem directory exchange（macOS renameatx_np SWAP/Linux renameat2 EXCHANGE），无 delete-old/move-new fallback。App 使用既有 bounded disk queue，staging lease跨下载持有、发布前 validate/检查取消，已有 destination 不在 commit 前删除。
- 成功 commit 后取消不能回滚或误报未安装；旧 payload cleanup 失败返回 committed outcome/retained staging。interrupted commit/retained staging 通过稳定 lock marker quarantine，不盲目当新下载继续。partial cancel 不删安装目录；explicit ASR uninstall 协调 mutation leases。Whisper NPZ-only 既有判定保留，不伪称 NPZ integrity 验证。
- opt-in helper Qwen/Silero Reader lease 在 Native 创建前取得并持续到 Swift model/stream ownership释放；lease 下再次授权 XPC shared model files。URL trailing-directory语义不能用于identity equality，已改为 canonical path比较。helper实际链接 ModelArtifacts product，LLM/VLM 非本任务 reader/缓存不自动迁移。
- 审查复现并修复 publication relocation-sensitive symlink 可发布坏权重/删旧 payload 与 parent mutation绕过 child reader两项问题。公开发布限制 canonical sibling roots并在 commit 前比对 staged symlink future resolved file device/inode；稳定外部 blob与relative内部regular链接支持，unsafe/directory links明确拒绝。coordinated roots不得重叠，persistent claim/namespace 双向检查与 post-flock recheck 保留 lock inode；不声称防御 hostile UID/uncoordinated writer。
- 实际 Package Debug/Release70 项均通过（含原34结构与publication/lease/独立process/crash/race案例）；before-regression 六项失败，修复后通过。实际 ModelDiskOperations Debug/Release验证取消/reader-blocked删除/commit后取消结果；独立审查重跑两配置和50次parent/child competing claims，never both admitted。actual helper/client/Core5 stream回放包括 loaded-model reader阻止exclusive mutation，配合路径修复后通过。Linux证据不等于APFS/XPC/GPU认证。
- 限制：无 automatic cache migration、fsync/power-loss durability、immutable snapshot 或 automatic marked-staging reconciliation；并发first claims可保守双拒绝并留下永久不兼容claim，需明确维护。未覆盖 legacy repair/shadow等所有reader；完整目录授权/迁移/删除协调验收仍待补。

### T4d1：bounded Sortformer Core ABI5

- Native Core追加四speaker AOSC streaming handle/settings、owned row-major probabilities/absolute-time speaker segments、strictsequence/cancel/finish/drain/model leases；同一专用worker加载/InitState/Feed/释放native arrays，至多16states、每model一个command/audio copy、2秒input及frame/state/encoder/compression/counter bounds。legacy Qwen/Silero functions/layouts保留，HTTP defaults/wire不切换，App/helper/smoke ABI expectation同步5。
- 复用实际Sortformer Init/Feed/cachecompression；pure ProbabilitiesToSegments抽离真实body。config-taking constructor使实际Native config whitelist/arithmetics在feature/weight allocation前检查；initial architecture明确16k/hop160/subsample8/four-speaker FC512/TF192。actualFeature新支持1sample，无empty-remainder op；既有≥2input算术及HTTP最低2sample拒绝保持；实际单sample MLX执行仍待Mac。
- 审查发现legacyJSON loader在验证前 unsafe narrowing，huge int wrap/fraction truncation/float-cast UB可绕Native whitelist。已以同一parser的strict native mode在所有33int/8float/4bool字段转换前检查type/range，safe legacy coercion保持，unsafe转化现在明确error；真实parser编入测试，不再被LoadConfig stand-in遮住。
- 原96ABI +42realtime/golden-tool6 +1298真实config cases，Clang/GCC ASan/UBSan/float-cast-overflow各1442passed；legacy真实BEFORE/AFTER772fixtures/compiler全一致，pure segments10000 cases byte-identical。独立复查310focused +161额外边界，未发现具体剩余numeric defect。模型/MLX仍明确替身；真实checkpoint、single-sample/Metal/compression numerical golden未验收。
- Main Swift真实ABI5 header/link验证 owned probabilities/segments/free/finish/drain；model/MLX为替身，不是SDK/Metal认证。Sortformer XPC/上层diarization client尚未实现，不能把Core独立检查点计作完整T4。

### T4d2a：Sortformer shared transport schema 前置检查点（尚非 XPC 路由）

- 实际 OmniXPCContracts product 新增独立 Sortformer model/stream references、显式 settings、row-major 四speaker probability/absolute-time segment batch；不添加尚无 service 实现的 RPC selector，不切换 App meeting/production diarization。
- Settings wire≤1024 bytes；batch wire≤32768 bytes、1..26 frames、精确frameCount×4 probability值、≤104 segments、processed frames≤Int32.max。constructor/Codable/有界encode-decode都检查value domains；byte/count bounds在解析/typed array formation前执行。所有设置用明确seconds/frame单位，无Native defaults。
- 保持实际 Native Float 时间计算再widen Double（不是literal Double0.08）；允许不同speaker重叠、同时start及long-stream Float舍入的zero-length intervals。finish无新增audio/padding/result，契约不伪造final batch或speaker summary。
- 18个新增真实Foundation tests覆盖fields/types/shapes/counters/bytes/NaN/Inf/segment范围/sort/overlap/longstreamrounding，独立review两配置18pass、无具体剩余schema finding。Main最终actual Package Debug/Release各88（87pass/1case-sensitive-filesystem skip）；真实Swift ABI5→专用worker/真实config parser→ownedresult→DTO往返60push，含1/2samples/hop边界、两次独立stream与continual>30s/finish-drain。model/MLX为明确替身，不是concurrentGPU或NSXPC认证。
- continuation完整包回归揭示旧Silero两条literalABI4 assertion；已以097f845单独修成ABI5并保留旧budget检查。隔离published package、排除并行Sortformer新代码后Debug/Release70均通过，随后当前完整88也均通过。旧失败日志保留，不把旧ABI4检查点的70结果当作ABI5包认证。
- 消费者的origin/service/model/stream ownership、expected sequence/frame progression、model-specificcompression/admission/replay/cancel/drain须在下一helper/client checkpoint验证；DTO静态值检查不能代替runtime生命周期。下一步仍为actual Sortformer Core wrapper→XPC engine→App client/structured scope。

### 最新官方 main 同步：7f78bf3（保留 ancestry 的 merge）

- 合并基线为官方7f78bf3，包含Nemotron3.5/Parakeetv3/SenseVoiceSmall Native model/transcriber/server及golden fixtures、移除旧PythonQwen server/OmniTyper与其他官方pipeline更新。此前本地schema检查点d307c5f保留；无rebase/force-push，不是把PR合入官方main。
- 当前11个offered ASR checkpoints均有Native HTTP mapping，Qwen/MOSS/Nemotron可realtime，Parakeet/SenseVoice仍batch-only。既有unsupported/platform/no-ASR-Swift-fallback gates保留；canonical aliases仍沿用原策略，不自动删改已安装权重/新造cloud fallback。
- 无文本冲突不等于语义正确：真实merged Native entry body在portable typecheck复现Parakeet旧parameters变量未定义、SenseVoice STTOutput→自有ASR result不匹配；已改为app-ownedchunkDurationSeconds与ASRTranscriptionResult/ASRTranscriptSegment。actual literalentry/helper/request body修复后5个short/long/metadata/missing-VAD/timing场景通过，runtime/logging明确替身，不是fullApp SDK/network/model测试。
- 修复catalog遗漏的Nemotron nativeNemotronLive route与一批过期T0 fixtures；未知模型测试先确认不支持再调用ensure/download，避免误入真正下载。277portable assertions分别覆盖host与临时Apple-Silicon-policy分支（只替换architecture directives，不是Mac/arm64执行）；Main75 policy/action checks通过，12个修改的macOS XCTest suites未实际执行。
- packaging统一调用小型filesystem checker，确保7个server executable及MLX资源齐全；CI同checker检查artifact与解包ZIP，gates/signing不变。13实际checker tests及8个syntheticZIP场景通过，placeholder不是Mach-O/签名/model证明。
- Native CMake保留Core5的44 exports与原lease/thread/algorithm逻辑；上游共享LstmStep/RelativeShift的改动保留。独立source review+19focused tests与synthetic vocabulary/MOSS/metadata replay通过；同步2份test-only SpeakerSegment新增language/emotion/event fields以免旧类型遮蔽事实。MainClangASan/UBSan/float-cast1442通过，同步stub后最终ABI96+realtime42=138再次通过。
- 真实PackageContracts88（87pass/1filesystemskip）与Artifacts70通过；ASR自有contracts20+adapter6回归通过；当前46tool tests/source/resolved audits通过。上述均不能替代真实Mac SDK/NSXPC/Metal/model/golden/concurrency/长会议验收。
- 上游补齐的是model/NativeHTTP实现，不是完整Core/XPC/App dependency切换。下一轮直接复用这些模型补Core/XPC与调用者；Nativeinput仍用MLXAudioCore resample、VAD/Sortformer配置及生产Swift辅助路径仍用MLXAudio，现时unlink会导致编译/功能断裂。保留MLX Swift本地LLM/VLM及Remote ASR/LLM；完成这些真实consumer迁移和MacSwiftPM/App验收后再移除Audio，而非从零重做模型。

### T4d2b：actual Sortformer XPC/helper/client（opt-in）

- shared protocol新增7个实际selectors：load/unload/start(settings)/push/finish/close/cancel；Core ABI仍5，未改Native算法/布局。helper由专用Swift queue/lifetime/lock拥有SortformerCoreModel/stream leases，共用服务load/diagnostic admission（service→engine→token），Qwen/Silero/Sortformer状态分开。Xcode helper真实source membership与同一个Contracts/Artifacts product linkage保留。
- directory reader在Nativeload前获取并保持到NativeDestroy后同步释放；16 live streams/256model stream IDs、每stream一个normal command及coalescedclose、最新audio≤128KiB/reply≤32KiB retained。Owner/busy/history/sequence/finite/bounds先检查再构造array；expectedframe delta依实际Native `(1 + samples/160 + 7)/8`，row-major4speakers/≤26frames/≤104segments及Float absolute times在ownedArraycopy前校验，Nativeowned result/errors及时free。
- exact last sequence+audio bytes只返回原encodedreply、不再Feed；changed/future/old input拒绝，invalidnext input不消耗sequence。Nativepostadmission failure terminal；client不自动重发audio。finish无output/padding/tail，成功finish/close只在Native finish/cancel→drain/destroy后释放slot/回复；失败retainmodel/reader/lease，可同actor/stream retryclose。原cancel ACK/deadline非barrier。
- MainActorclient捕获originconnection/service/model/stream，检查sequence/frameprogress；新actor `OmniXPCDiarizationStream.feed(samples16k:)`返回真实完整DTO。structured `withSortformerDiarizationStream`在return/throw/cancel后awaitclose，retained rawactor需显式close；noncooperativecallback不可强制返回。Sortformer deadline使用typedscopedcancel，健康Qwen/Silero不会因此disconnect。
- 独立review发现P2 malformed successful load identity时Native model/reader无清理入口。actual BEFORE/AFTER client+helper+Core harness复现：Before malformedserviceUUID导致reader retained/reloadbusy；After用原connection+loadOP nil-model scoped cancel，eventual reader release/reload成功且Qwen/Silero/连接健康。cleanup ACK仍不冒称drain；RPCcleanup失败会surfaced而不是假成功。21 actual portable state/controlled-peer tests（10state+11ownership）两配置均通过，非真实NSXPC XCTest。
- actual combined client/exportedservice/Core/worker harness通过last-reply重复回放/no extraFeed、NaN/sequence拒绝后正常nextseq、独立states、continual>30s、无tailfinish/idempotency、blockedFeed timeout/close/unload barriers、健康Qwen/Silero、structuredscope、same-actor transientRPCclosefail retry、16states/stale starts、disconnect→Native release→reconnect。model/MLX及RPC/platform为明确替身，不是concurrentGPU/recognitiongolden；重复payload测试不是实际跨进程网络丢包。service额外harness包括blockedcreate、256history、Native settings/outputfailure、Native drain-fault interposer close/loadOP/disconnectretry及旧OP不误伤replacement，重复3runs通过。
- 独立followup重跑BadLoad BEFORE/AFTER、combinedharness与21 portable tests，scope内无新增具体finding。Clientagent在已写完source/20tests后遇modelpool concurrencylimit，未提供finalhandback；Main接管并按finalsources独立重建/补回归，不声称该agent提供完整认证。Main初次portable调用遗漏测试containerENV导致10fixture failures；正确ENV后21两配置通过，原日志保留。
- Package Debug/Release各88（87pass/1filesystemskip），Native GCC ABI96/ClangASanUBSan+floatcast ABI96+realtime42=138通过；46tool tests/source+resolvedaudits通过。helper/client/smoke supplementaltypecheck只去掉macOS/@objc/Darwin gates并使用平台替身，actualSDK/Objective-C selector/NSXPC/签名/Metal/model仍未验证。
- Signed smoke保留原4/5参数，新增可选第6Sortformer fixture（第5可空字符串），stage `Models/OmniXPCSortformerSmoke/<run-id>` dereferencedweights；report optional `sortformer_stream_count=4`（每helper2 structuredstates再reconnect2states），成功unload后清fixture，失败retain。真实signedrun未执行，不等于modelaccuracygolden。gatedMacCI只增加portablestate suite选择，未启用gates。

当前production说话人分析/HTTP factories未切换，MLXAudio和MLXSwift LLM/VLM保留。下一步复用actualSortformerXPC actor迁移productioncaller及配置依赖，然后扩展六个HTTP-onlyASR families Core/XPC；目录/平台/发布硬门槛不跳过。

### T4d3：meeting consumer seam 与 Audio-free Native scheduling config

- 把原413行混合engine按真实责任拆为common protocol/default wrapper、isolated MLX legacy actor、Foundation-only Native HTTP actor；默认仍HTTP when enabled/else原Swift，不把opt-in XPC提前设为production。common/HTTP不再import MLXAudioVAD，MLX/Audio仅保留在legacy modeladapter。3个共享Sendable audio/descriptor/turn值及protocol/extensions显式nonisolated，避免MainActor-default错误推断到纯值和actor initializer。
- 新增9field `MeetingSortformerConfiguration`：实际appownedFoundation projection，保持pinnedSwift默认/nestedsection/absent-null fallback，boundedconfig read≤16MiB+1、及时close、不读weights；encoder capacity reportingOverflow后检查。不复制30余无用模型字段，不替代Native fullarchitecture/compression/model compatibility。正常HF config symlink先resolve目标再regular/readable检查，保留cachedblob权重位置；pathauthorization/leases仍由外部loader/helper处理，未自动cache迁移。
- `makeXPC(client:model:configuration:coordinator:)`可注入实际 `MeetingSpeakerDiarizationEngine` pipeline，预加载model/client由外部owner保留并最终unload；adapter只own/close自己streams。刻意不把model load cancelACK误当GPU资源barrier或自动在filepermit内放弃未完成modelload。singleoperationgate与operationUUID隔离late cancel，missing/empty assets、metadata/openerror、progresscancel均awaitclose；failedbarrier保留stream并在再用前retry。
- XPC使用实际wholeDTO与既有feedPolicy.mappedRange、speakerID/displayformat/confidencenil，保持descriptor顺序、同source+gap<0.05连续判定、reset先close再open。≤32000 realPCM、单sampletail无fakepadding/FIFO；不同于原HTTP≤5秒feed，numerical/golden parity必须Mac补验。filefeeds通过actual coordinator，native feed返回后才检查30秒elapsed，cancellation/error/tooSlow在permit scope内awaitclose，不凭ACK释放lane；noncooperativecallback不可forcedreturn。
- 独立审查复现2项：原config目标symlink被错误拒绝（旧pinneddecoder接受），Main已修复并补HFexternalblob/danglinglink回归；XPC一般config若hop80/sub4会无错误偏移/丢掉turn，已在adapter边界拒绝非16k/hop160/sub8/AOSC，保持generalprojection对HTTP/Swift可用，不改mapping掩盖不匹配。
- actual main caller→client→exportedhelper→Core5 harness验证clippedturns/progress/source-reset/externalmodelreuse/blockedcancel-close-unload/nilasset错误传播；明确MLX/model/平台替身，不是recognition/Metal。实际未改before class+newdefaultwrapper分别执行Swift/HTTP controlledbackend共20场景（file/live、tails/large、resampling/source/reset），除随机turnUUID外ordered turns/progress完全一致，不是神经模型/网络golden。
- Main最终11 portable controlled-peer caller tests与15 config+1 pinned-reference compare=16 tests，Debug/Release均通过；初次10caller tests不含修复后的geometrycase。原型Decoder保留原revision，12validprojection fixtures对比真实pinnedSwiftdecoder，不以手写fake decoder作oracle。46 tooling/source-resolved audits与supplemental helper/default/HTTP/legacy/XPC/smoke compile通过；Linux thermal/cache/runtime/model hooks为明确替身，fullSDK/NSXPC仍待补。
- optional signedSortformer smoke新增actualmeeting consumer调用，每helper2 structuredstreams+1caller，再reconnect重复：`sortformer_stream_count=6` / `sortformer_caller_count=2`；原4/5参数和optional第6fixture保留，actualsignedrun未执行。MacCI仅补config/feedPolicy选择，不启用gates。

production factory、cache路径、AudioSPM/MLXSwift LLM/VLM/Remote routes未切换或删除。后续完成shared-model preparation/authorization/lifecycle协调、productionfactory验收切换及六个ASR families Core/XPC；移除Audio仍需VAD policy/重采样/legacySTT adapters/tests等consumer迁移和真实Mac resolution/build。

### T4c2：Native HTTP process lifetime reader coordination（非cache迁移完成）

- 7个ASR families + Silero/Sortformer的实际 `OmniASRRuntime.launch` 在spawn前经bounded `ModelDiskOperations` 获取同一Artifacts的canonical sharedRead；新增await后重检starting，retire先发生则不得后来spawn。directorybusy直接错误，不换savedchoice/复制cache/自动download/HTTP-in-XPC。
- reader跨idle/activeuse/retire/processshutdown。liveChild terminationclosure保留runtime，避免最后caller丢掉actor使reader先释放；只有真实child exit才breakcapture/release。spawn/failedstartup/startupdeadline会stop并释放。Native supervised binary本身包含MLX model/server，不把任意detacheddaemon/tree退出当作证明。
- 原stop把Process提前nil且忽略SIGKILL后的failedexitwait，不能承载readerbarrier。现在保留actualProcess/reader直到isRunning=false；15s shutdown/10s SIGTERM grace不变，SIGKILL后可能无限等待，不能凭timeout返回stopped。取消/期限不是Native/GPU preemption承诺，真实Mac资源回收仍待补。
- Native HTTP Sortformer先获取短期configreader，跨boundedprojection read和sharedruntime.acquire，成功后由runtime长期reader接手；权重/目录未copy。Main额外发现同canonicaldir的isDirectory URL/alias与这个handoff碰撞：旧SharedModelRuntime的URL equality会把健康server连续retire/relaunch（三次acquire三PID），现在canonicalpath比较保留同PID，不破坏前两个reader/use。实际BEFORE 2个assert failures→AFTER通过，追加第13test。
- 原673行runtime按真实责任拆为process/reader/state core、Support values/diagnostics/line buffer、FinalRequests family-specific request builders。支持和全部request/planning extensions与baseline逐字节相同（Support仅由EOF hook移除尾部多余空行），numeric/token/chunk/language逻辑未改。Xcode filesystem-synchronized membership已含新source/tests，未假称SDKbuild。
- actual Foundation Process/shell fixture/POSIX locks + actual app disk adapter/publicprepare/beginUse/endUse/retire测试：13 ownership + 5原launch/support=18 tests，Main Debug/Release通过；包含9kinds、mutation阻止spawn、真实delete/exchange blocked→exit后成功、activeuse/gatedshutdown/共享prepare/重复retire、missingspawn/failedstartup/deadline、symlink、dropcaller、原15/10s grace后的实际SIGKILL/exit。旧runtime原11test snapshot有8tests失败（20assert/error records；其中误成功publish诱发后续stagingreuse错误），不以fakebefore替代。
- 独立read-onlyreview初12+原5 tests两配置通过；另3 externaltests覆盖queuedreader-acquisition中retire、startupfailure与retire重叠、SIGTERM-ignoring samePID child在16s仍retainreader直到约25s实际exit；非项目test，不冒称GPU/model。Main final13th路径identity回归另followup确认。原Swift6strict无类型JSONstream sending错误在baseline/current均复现；actualApp Swift5 language mode/defaultMainActor，未把这次18tests包装为Swift6全App通过。Linux只替换Darwin F_SETNOSIGPIPE并移除不支持的AsyncBytes transport入口。
- Artifacts真实70tests Debug/Release、20原/newdefaultwrapper Swift/HTTP controlledbackend调用层回放、46tooling及source/resolvedaudits通过。Native/client/helper/CoreABI/SPM/Audio/LLM/Remote/生产factory与cachepath没有切换；MacCI只加ownershipsuite选择，disabledgates不变。

这里覆盖App存活正常操作中HTTP child lifetime，不解决Appcrash释放lock之后orphanNative在parentdeath cleanup/load期间继续活着的窗口，也不覆盖不合作的namespace/blob mutation、全部legacy Swift readers、HFshadow/cache repair、immutable snapshots/powerloss或cache迁移。仍需XPC shared-directory preparation/authorization/完整modelload cleanup barrier和owner接入，六ASR families Core/XPC、Audio其余consumer迁移与实际Mac验收。

### 官方main再同步与T4c3：legacy Sortformer reader coordination

- 用户确认目标为 `sgl-project/sglang-omni/main`。初次freshfetch为7f78bf3，已是ec43cae祖先，实际merge返回Already up to date；不制造空merge、不rebase/重写local checkpoint。后续复核fetch新增e3d7dc378c749914ffca07576c00b16d32b08739（父7f78bf3），仅README发布news，单独正常双亲merge。
- 用户所述1.16确认发布于SGLang-Omni仓库 `voxt-v1.16.0`，发布时间2026-10-11T19:12:10Z；annotatedtag实际source为5f3a4e25dc1292f2e565ad10b37357416a07813c，独立发布分支，未进入本轮官方main。与旧main的共同祖先740576d7，含快速packaging、版本、Developer ID provisioning/signing、MacCI默认启用等提交；不能把main README news当作这些发布实现已合入，更不因merge请求自动开启CI/更改签名。按用户确认只mergeofficialmain，未混入tag分支或独立Voxt仓库根目录。后续若合入发布分支须明确scope与保留迁移gates。1.16短期发布实现不改变Core/XPC/owned contracts/协作目录/真实平台验收终点，发布成功不等于迁移完成。
- 从RealtimeDiarization拆出实际 `MeetingSortformerModelStorage`（Foundation/HF/Artifacts，无MLXAudio）；原path/readable/write/temp/cache/presencechecker策略保留。新增validatedModelDirectoryLease在原readable root顺序下，先sharedRead再presencevalidation；missing/invalid返回nil，busy/unsafe直接抛错，不静默换另一个cache。
- 新paired `MeetingSortformerModelLease`，被actual MLX meetingengine和realtimeannotationstage两处使用；reader覆盖真实Swiftmodelconstruction，model先销毁再释放reader。每次operation用localholder/defer pin跨所有await，file结束/cacheclear/realtime reset不让正在feed的旧model提前失去reader；file/live feed用捕获的model，而非afterawait再读可能被换掉的cache。reader acquire后checkcancellation并再次checkcache，防止actorreentry不必要的duplicate load。
- 不改变旧Swiftmodel数值/阈值/padding/state/mapping/progress，也不把Swiftcancel/stream/presentation completion冒称MLXworker/Metal barrier。pinnedmodel内部eval仅source检查，实际GPU teardown/ARClazygraph仍需Mac。
- 4 Foundation XCTest正常图 +4 actor/model tests仅OMNI_SORTFORMER_PORTABLE_TESTS；actualstorage/disk/indexvalidator/完整两个actor/commonprotocol/feedpolicy/mapping执行，实际pinnedSwiftconfigdecoder，MLX/model/HF/rootresolution/thermal/transcriptDTO/assembly替身明确。8tests Debug/Release通过；实际旧两个actor同fixtures有3reader回归失败（cachedmodel、blockedfilecancel、reset/inflight），after通过。另actual原/新engine10 file/live输入场景orderedturn/progress一致，忽略freshUUID；是controlledbackend调用层而非neural golden。
- 46tooling/source-resolvedaudits与sourceparse通过；MacCI只选择正常Foundation suite，不启用gates。真实Mac/Xcode/签名/Metal/model/长会议仍待补，cache/LLM/VLM/Remote/AudioSPM/defaultASR/XPCfactory未改。

依然没有解决legacySwiftSilero及所有其它reader、Hubshadow/blob/cacheclear/repair、immutable snapshots/Appcrash-orphan、XPCshared目录准备/授权/完整model-load cleanup barrier与六ASRfamilies Core/XPC。1.16快捷实现和现有fallback边界仅兼容过渡，不替代规划终点。

### T4d4：Sortformer failed-load drain + checked Native release（ABI6，opt-in）

- 新增actual shared `drainSortformerLoad(operationID:withReply:)` selector，以原load ID而非猜测modelUUID关闭scope。helper各connection拥有独立non-evicting load ledger（active/closed，≤256），unknown drain先记录closed tombstone再success，later/delayed同IDload不得admit；general256 operationhistory仍独立，旧loadID不因eviction损害replacement/重开。每connection最多1 queueddrain，duplicate busy而非累积callbacks。其它businessID/wrongowner拒绝，fullledger拒新ID但允许原IDdrain/retry，不重置健康Qwen/Silero。
- drain在原create/commands/cleanup之后的实际Swift serialqueue执行，cancel在locks外；成功只在实际stream drain/destroy、modeldestroy、readerrelease或closed/no-future-admission scope之后。cancel ACK仍非barrier。失效connection回复disconnected，不凭serverevent冒称App观察到释放；failedbarrier保留rawleases/models/readers可retry。
- SERVICE第一版按原ABI5 voiddestroy调用测试通过，但Main sourcefollowup确认真实漏洞：void函数catch异常只log retained而不回报失败。扩展为两checked C APIs：model destroy拒绝live leased streams（不破坏健康stream）；checked0保留rawhandle/error可retry，checked1销毁完成；旧void函数/layouts/numericalmethods保留。Core/shared epoch升至6、exports46，防止旧ABI5通过guard后缺checkedexport、清理时才崩溃；必须重编matchedCore/helper/App，历史ABI5success不冒称ABI6。
- Helper `SortformerCoreModel.close()` throws且status1之前不清handle/reader；stream在drain后checkedDestroy0会restore rawhandle，不释放modellease/slot。cancelled unpublishedload先把model挂回engine再尝试close，失败不会在localdeinit误释放/触发precondition；failedunload保留model，pending命令退役后可同reference重试。cleanup body复用explicitdrain/cancel/disconnect，不拿异常ACK或timeout释放任何ownedreader。Qwen/Silero旧voiddestroy的exception observability尚未整体改造，不把此Sortformer修复推广为全runtime已验收。
- App每client≤1 pendingloadticket捕获originconnection+operation，cancel/timeout/malformed/native error均awaituncancelled drain。cleanup error/deadline surface并retain ticket、阻止replacement；`closePendingSortformerLoad(timeout:)`同origin retry/coalesce，不audio/model重发。lostconnection保留unknown ownership，不能通过新connection close；不能因此把load放进file coordinatorpermit而提前放弃旧owner，productionpreparation/失联恢复政策仍待补。
- 独立审查复现P1跨load cleanup task竞态：ticket先nil、外层defer尚未退役Task时，高优先级coalescer立即发新失败load可能复用旧completedTask，少发新drain；实际Debug/Release多次复现。Main改为typedattempt（attemptID+loadOP+Task），仅sameOP coalesce，Task自身完成前原子退役，不让旧waiter清新attempt；补100pair publicAPI回归。旧noncooperativecallback test也改为wait operationgateentered（start ACK不证明callback已进），消除原测试假完成不稳定。独立followup在actual pre-fix Debug/Release复现，修复后40次stress/8000pairs通过，最终51tests两配置各5runs及retry/cancel/disconnect补验通过，P1closed/noadditionalconcretefinding；不是SDK/Metal验收。
- Main最终client51 tests/config（原43+8load cases，部分case多场景）Debug/Release通过，Contracts88/config（87pass/1Linuxfilesystemskip），Native Clang ASan/UBSan/floatcast ABI99+realtime42=141通过；新增3 checkedrelease Nativecases、pureC checkedfunctions/linkage与46exports检查。ABI6首轮Cfixture仍assert5导致98/99失败，单独修复并保留失败日志，完整141rerun不是复用旧99报告。
- actualApp client→exportedhelper→Nativeworker combined harness：blocked actualmodelconstructor取消/期限后error仍等checked销毁与readerrelease，健康Qwen+Silero可服务；Native/malformedload错误、cleanupRPC失败ticketretained/coalescedretry、ABI5报告拒绝beforecreate、取消未发布model三次checkedDestroy人工失败、stream checkedDestroy0restore/retry、unload checkedDestroy0保留/retry、lostconnection不certify。私有modelGate/Native-fault interposer是明确替身，不是自然GPUfailure。SERVICE独立load/drain/tombstone/history/fullcap/latecreate/blockedFeed/failure-retry tests与原service regression已重编Core6重跑，原print ABI5只是历史banner不当proof。
- helper新file真实Xcode Sources membership、同sharedproduct链接、所有testconformers与peer extraction更新。没有启用CI/signing/productionXPC、没有Audio unlink/下载copy/savedmodel替换/云fallback。macOS SDK/ObjC NSXPC/Metal/真实weights/golden仍待补，RPC/helper/C API smoke CPU不冒充这些验收。

下一步仍是实际sharedModels路径准备/authorization/外部owner与coordinator资源屏障、失联/旧owner释放恢复策略，再推进六ASR families Core/XPC；没有拿1.16快速发布或本次ABI6当作全部规划完成。

### T4d5a：successful-model 原load scope退休身份（Owner/coordinator前置）

- App successful load保留originaloperationID+完整model/service/connection reference，当前connection最多1modelbinding与≤256closed-modelreference历史。`closeSortformerModel`复用actual八RPC中的drainSortformerLoad，以原OPawait完整Native stream/model checked销毁，不猜modelID、不在timeout后冒称清理完成；model/streams先terminal以拒新start/lateoutput，成功才retire bindings。失败/deadline保留可retry，同modelclosingTask coalesceuncancelled且insideTask退役，不影响replacement。
- 既有unload仍拒live streams，pendingunload阻止newstarts，busy/failure不本地误关健康model。lost successfulunloadreply可用originalloadtombstone确认完整退休，避免server已销毁但client只有stale modelID。旧成功close在exacthistory内idempotent，forged svc/model/conn与evictedunknown refs本地拒绝；service复用retired UUID回复会进入scoped failed-load cleanup。
- genuineinvalidate/disconnect清success-modelmap/history（与旧streammap一致），不当作Nativebarrier、不能旧refretarget新connection；T4d4 failed-load未知ticket仍retain。未来externalOwner必须自行retainlease/modelRef/permit失联路径，不能凭map absence放开GPU lane。client仍支持原actualhelperdrain后reconnect，不引入自动重发model/audio。
- 5项newmodelpublicAPI cases追加已有loadownershipsuite，总portable56/config Debug/Release；controlledpeer每load更新UUID对齐实际helper而非staticID掩盖generation。独立read-onlyreview56/config、9extra lateUnload/start/feed/deadline/retiredUUID/history/conn/provisional cases两配置通过（额外不是项目test），noadditionalscopedfinding。actualNative代码/service/protocol/ABI6不变。
- Actualclient→exportedhelper→Core6 CPU chain：blockedFeed关model时reader仍busy/不earlyreturn且Qwen/Silero健康，streamcheckedDestroy人工失败retainbindings/same-scope retry，实际已成功unload却reply丢失后OPtombstone确认、oldclose不伤replacementfeed。原Sortformer+Qwencombinedregression重编当前client通过；实际签名smoke改成功/异常terminalcleanup为closeModel，原6streams/2callersreport不变，signedrun未执行。

这里是owner所需的退休入口，并未实现sharedModels copy/迁移或完整ModelOwner/coordinator wiring；下一步用retainableowned permit覆盖prepare/失败cleanup/close失联资源未知路径，不能把load/close丢进原always-defer-release withPermit就宣布安全。production factory、Audio/LLM/VLM/Remote/settings/cachepaths/签名/CIgates均未切换。

### T4d5b：owned coordinator permit + 显式shared Sortformer model Owner

- `reserveOwnedPermit` 返回fileprivate identity绑定到coordinator/active token的Sendable token；只有matching `completeOwnedPermit` trim/restore cache并释放lane。token/caller return/cancel/error/deinit不自动释放，wrong/repeated/stale token错误不释放其它activework。bounded activeownedrecord=1；postacquire取消在transfer前释放ordinarylane，不装cachehooks。旧withPermit语义与policy保持；纯policy/errors/stats按责任从actor拆出（330/100行）。
- 新实际 `.modelCleanup` priority110，不受recording/thermal/memory defer（cleanup要能回收内存），仍排在正在运行lane之后；thermal注入hook生产默认ProcessInfo原值，用于确定性测试。新增invalidPermit诊断stable `invalid-permit` exhaustivecase与回归。
- `OmniXPCSortformerModelOwner` raw显式init(client,directory,coordinator)，prepare返回borrowed真实model/config。原sharedModelsURLauthorize→bounded diskqueue sharedreader→lease下重新authorize/canonicalpathcompare→Foundation config geometry/capacity→Native load，不copy/cache迁移/下载替换。成功Nativeload完成释放prep commandpermit，但reader/model继续owner保留；modelresident不是activeGPU命令。
- prepare/close真实用ownedpermit，failedloadcleanup未确认保留permit/reader/原OP；close复用failedpreparepermit，readyclose reserve.modelCleanup。同ownerpreparation最多1Task，closeuncancelled/coalesce且await canceled prep.result再directscopedretire；prepworker不调用owner.close避免self-wait。public latecancel在model已stored后也awaitclose。失联保留unknownref/reader/lane，不能借新transport cleanup，不能凭map absence放lane；rawowner/token必须retain并explicitclose，no deinit释放或保证恢复，失去owner可fail-closed blocklane。
- client可由owner显式给loadUUID，requiredOperationID cleanup guard防止owner误清其它pendingload。授权helper由client+owner共用actualvalidation；cachedpreparedmodel返回前检查client exactowned/retiringbinding。empty close不reserve phantomcleanup（optionalnil==nil问题在Main源码检查中修正）。其它owner模型busy/未发Native请求不会被这个owner关闭。
- 签名smoke使用actualOwner.prepare匹配model/config +close，6streams/2caller/参数不变，actualsignedrun未执行。此slice只协调MODELprepare/RETIRE：原meetingengine每feed withPermit不变，borrowed work先finish/cancel才能close取得lane，没有hardGPU preemption或per-feed failurelane已转换承诺；production factory未切换。
- Main actualportableOwner7+coordinator23+原client56=86 Debug/Release通过；加2原diagnostics literal-source cases=88/config通过。Coordinator旧/owned tests按责任分245/315行，实际sharedTestSupport111，无改变23methodbody（pollhelper rename后3个trailingclosure漏替换的编译错误修复/log保留）。独立coordinator23/重复/并行/strict build，read-onlyfinal86+11extra=97/config、补110 executions、strict productiontarget通过/noadditionalscopedfinding；fullstrict Linux XCTest discovery wrappers sending-self错误保留，不当fullSDK通过。
- actualOwner/coordinator/diskreader/client→exportedhelper→Core6 CPU：Nativeconstructor blocked cancel/deadline时error仍等drain/permit/cache/reader，人工checkedDestroy持续失败保留lane+reader/原OP后sameowner retry，ready borrowedstream+modelclose失败重试，Qwen/Silero保持健康。Model/MLX/gate/fault/NSXPC/thermal/cachehooks替身明确，非Metal/NSXPC/真实model/GPUconcurrency。

Native/service/protocol/ABI6/Audio/LLM/VLM/Remote/catalog/settings/cachepaths/签名与releasegates均未改，MacCI仅新增正常coordinator/owned suite选择。完整sharedModels迁移/recovery/old-owner失联确认、per-feed retainedlane/生产Owner factory、六ASRfamiliesCore/XPC及Mac平台验收仍待补。

### 加速并行实施：ABI7 final六families + per-command ownership / 目录准备 / AudioCore seam

本轮按独立文件责任并行交付并由Main集成，不代表用户要求的1–5已全部验收。默认HTTP/meeting factory、catalog/保存选择/已安装权重、Remote ASR/LLM、本地MLX Swift LLM/VLM/llama.swift、签名与release gates保持不变；没有自动fallback/replay/substitution或隐式远端操作。

1. **Sortformer实际per-command lane ownership已接通**：open/file+nonfile feed/close使用identity-owned permit，provisional start ticket明确notSubmitted/submitted/drained，不从disconnect/missing maps猜drain。actor explicitclose先取消并awaitactiveopen/feed/admission task，再checkedcleanup；failedbarrier保留原ticket/permit，retry不reserve第二lane。ModelOwner caches concreteengine，close先permanentretire engine，再reserve模型cleanup，lateborrowedwork不能reopen。smoke实际meetingcaller改用此Ownerconsumer；rawfactory返回concreteengine以便explicitclose。生产defaultfactory未切换。
2. **实际shared Models preparation已补**：`OmniModelPreparation`→bounded `ModelDiskOperations.prepareModelCopy`，source sharedreader→regular-file/HFlink dereference copy→exclusive sibling hiddenstage→bounded structuralvalidate+授权callback→existing atomicpublish。默认拒绝覆盖，explicitreplace才能替换，destinationreader阻止mutation，originalinstalledweights不改。失败stage保留，不自动resume/recovery；100kentries/128GiBfilebytes只约束总预算，初始directorylisting不据此声明memorybounded；externalblob/noncoopnamespace/immutablechecksum/hostile/powerloss仍不认证。Main修正adapter创建parent前先reader/overlapguard，防止拒绝nestedcopy却先改source目录。
3. **legacy Swift Silero两actualactors reader迁移**：pairedholder先销毁model再reader；load/postawait取消/reset/unload/reentrantcache不复活，activecapturedholder跨所有推理work。真实NativeHTTP原路径保留。主要actor/provisioner/private-model fixtures无下载。另已将MLXTranscriber longform cachedVAD改为同一真实pairedholder，reader先于model构造，postawait cancellation/sessionRevision/cache重检，existingexplicitlyunsafeBox携holder跨detached inference全部await/error/cancel，不新增Sendable保证。literal-production14primary+3scheduler-delivery probes/两配置/340stress通过，真实HEAD Before53expectedassertfailures，24losslessinferenceargrecords旧新一致；整App仅parse/fullSDK仍待补，raw model-enabled integrationtest reader消费者尚未迁移。
4. **Native + XPC六family bounded final已实现**：Whisper/Cohere/MOSS/Nemotron/Parakeet/SenseVoice actualTranscriber::Transcribe，persistentdedicated load/infer/destroy thread、每model1requestlease、independentcancel/checkedrequest+model destroy、status-onlyerrors、typedownedfullmetadata。≤30秒finite mono16k final，保留familyFloat/Double/default语言/stop/token/ITN/chunk语义，oversize输出fail不截断。Native增加10exports，**ABI7 / 56exports**；CMake同时补原漏掉的2个Sortformerchecked maclinkerexport。旧functions/layouts/numerics/HTTP完全保留。
5. **5个实际batchselectors及sharedproduct/client**：loadBatch/transcribeBatch/cancelBatchRequest/drainBatchLoad/unloadBatch直接Core7，非HTTP-inside-XPC。original-load256non-evictingconnectionledger、独立businesshistorycap，drainbeforeload tombstone、wrongowner/businessaliases/stalereplacement隔离、reader跨checkedbarriers。cancel出queuepin真实rawhandle；failedrequestdestroy/actualmodelBUSY保留retry。client成功/失败scope断连仍保留claim、uncancelledcoalesced task在completion内retirestorage，无retarget/replay。Namespace检查补tokenizer.model/generation/processorconfig/npz/am.mvn等实际新families读文件。Main配套epoch7/原peer显式selectors/helper6source membership。仍没有6families longform或MOSS/Nemotrontypedrealtime，也未完成defaultASR caller/coordinator切换。
6. **AudioCore重采样seam已抽取**：actualpinned AudioUtils AVAudioConverter算法/MonoFloat32/ceil+64/inputonceEOS/status/error/framelength保持，caller原rate阈值/Int截断不变，非linearresampler替换。仅该Nativeinputprep不再importAudioCore；STT/VAD/legacyconfig/adapters仍编译用Audio，**package不能删除**，真实SDK/DSPparity未验收。
7. **平台tooling但不是平台验收**：signedsmoke models由App实际coordinatedstage取代Pythoncopytree，Main发现旧发布脚本ABI5literal在Core6时代已不匹配，现在改7并新增actualembeddedPython guard执行/epochparity tests。6streams/2meetingcaller/count/args仍兼容。Mac环境询问AFK超时无选择，不构成SSH/runner/signing授权，没有实际Mac/SDK/NSXPC/Metal/weights/notary/gates验收或生产cutover。

已执行：Main GCC Core99+batch104=203、Clang ASan/UBSan/floatcast Core99+batch104+realtime42=245（无skip）；真实Contracts95/config（94pass/1filesystemskip）、Artifacts79/config；Main actualApp-source/coordinator/Owner/engine/client整合120/config，加actualsignedstage/adapter三场景最终123/config；Main actualclient→helperreader→Core7六family全部roundtrip、helper11behaviorgroups通过；tools49/audits通过。Engine19tests按ordinary/ownership/sharedfixture责任拆260/219/168行，保持body与actorannotation；initialportablewrapper endif错配/拆分annotation错位编译失败修复后完整120/config rerun，日志保留。

独立read-only两轮：A/B/C/D/Mainowner/prepreview无actionablefinding，engine114Release含4extra、79+1prep、Silero20/config/104bitpatternrecord真实beforeafter一致、resampler10strictplatformhooks、Native104sans+6000cancel/admissionraces+600requestreuse、macwhitelist56/56；Ereview当前无epochoverride，17files仅Main6→7差异，95contracts/69client各config、helper11groups/6fullstackfamily各config、independent4helper+5fullstack async groups/20optimizedstress、非法UTF8/null/times/outputfreeexactonce probes、final245NativeClangsans皆通过，无actionablefinding。所有Mac/@objc/RPC/model/MLX/Transcriber/AVFoundation/gate/fault替身明确；真实POSIX测试非APFS，twoCPUdylibs非productioncombinedCMake/MacLLVM链接认证，parse非SDKtypecheck。历史Core6/ABI5/parser1442结果不重标ABI7。本轮无agentstage/commit/push；Main在稳定handoff后集成提交，新增checkpoint未授权再次发布。

仍需：所有实际生产caller/Owned coordinator/defaultfactory与失联owner恢复、完整cache/repair/shadow/blob/orphan-window政策、6ASR longform和2typedrealtime、剩余Audio消费者迁移/真实macSwiftPM unlink graph、全部平台/GPU/golden/长会议/签名公证矩阵。保留真实Macgate，不宣称“1–5全部完成”。

### 六family batch external Owner + 实际validation consumer（ABI7保持，30秒保持）

- 新actual `OmniXPCBatchModelOwner`：explicitprepare（不外借rawmodelreference）、sharedModels授权→Appreader下重新授权/canonicalcompare+结构验证→own loadUUID。只准.fileASR/.finalASR正常work；每load/request用identity-owned coordinatorpermit。successcommand释放lane但保留residentmodel/reader；error/cancel/malformed/deadline先await原load-model scope checkedretire，failure/原connectionlost保留reader/ref/permit供explicitclose retry，无mapabsence/cancelACK/timeout证明。
- transcribe先正timeout/kind/strictsettings/≤480000 finiteFloat32验证，必须显式prepare，不自动reload/replay/chunk。close永久terminal、uncancelledcoalesce、先cancel/awaitprivateprep/request Tasks.result；heldpermit重用，不reserve排在自己lane后。cleanup Task在completion内retirestorage，wrongowner/empty状态不清其它pendingload（非nil ownOP才match）。cachedprepare检查exactclient/ref/closing/requesting/connection；rawOwner必须retain+awaitclose，没有deinitbarrier或保证失联恢复。
- BatchClient目录授权按真实2callsite抽出供Owner+load复用，原namespace/错误语义保持。Native/Core/protocol/ABI7/numerics/30秒/生产default/catalog/保存权重/Audio/Remote/LLM/VLM/signing/releasegates都未改。
- signedApp smoke增加显式可选batchfixture：ALL3 env `VOXT_OMNI_XPC_SMOKE_BATCH_KIND`（1Whisper/2Cohere/3MOSS/4Nemotron/5Parakeet/6SenseVoice）、`...BATCH_MODEL_SOURCE`、`...BATCH_EXPECTED_SOURCE`。缺/空/partial/unknown/非canonicalkind/不存在source/非regular expected/非法UTF8/expected>65536bytes全部明确拒绝，不猜model/kind/golden。Python只whitelist3值，ambientDYLD/其它smokeoverrides原过滤保留，CLI4/5/6args不变。
- optionalmodel实际Appcoordinatedsource-reader/staging/atomicpublish到Models/OmniXPCBatchSmoke/runUUID，script不copyModels；expected有界snapshot到artifact/batch-expected.txt。Appinfer按probecontainer+nonce定位，不信任envdestination。实际Owner prepare→samePCM2requests→checkedclose，helperreconnect前后各跑1caller，报告4requests/2callers/kind；absentbatch不改旧counts。成功须trimmedtext精确expected且finishStop，matchingtruncatedfixture不能冒充通过。失败close静态保留Owner/client/reader/lane，outerfailure不invalidate/terminatehelper，failclosedprocess退出不是资源proof。
- Main当前Owner finalUUID构造无forceunwrap：actualportable21Owner+原coordinator23+client10=54/config；testagent210optimized重复、strictsource target通过，fullstrict Linux generatedXCTestdiscovery失败保留不当fullsuite成功。Smoke actualcompleteguardedentry/Owner/coordinator/publish source +显式platform/peer hooks7/config通过，Pythonactualembeddedtransaction10新+3已有=13且整个tools59通过；Macguardparse非SDK。
- Main actualOwner→client→exportedhelper→reader→Core7 CPU两配置：六kinds prepare/reuse/close全通过；blockedconstructordeadline与blockedrealworkerrequestdeadline时Appreader/lane不放行；人工checkedrequestdestroyfailure→actual额外Nativelease使model BUSY→原Owner同scope重试成功才恢复writer/cache/lane。twoCPUlibs、Transcriber/model/MLX/gate/fault/NSXPC/thermal/cache替身明确；非Metal/真实weights/productioncombineddylib。
- 独立readonlyOwner/currentauthclient以当前hash冻结：actual6family baseline+每配置6次independentprobe complete运行通过，queuedcancel/wrongowner/input/latecancels/malformedforeignlostoutput/coalescedcancelledclose/失联scope/heldpermit/reentrantcache等；4个private negativecontrols均检出：unsafe退休成功、移除requestidentity、nestedownpermit再reserve（hang）、Appreader提前释放。strictSwift6/warningsaserrors通过，无actionablefinding。Main另审Smoke真实caller、private7cases复跑，未授权/执行actualMac。
- 外部fixture搬迁遗留旧Artifacts source与已编译PCH路径错误、Main测试包missingrelativefrozen sibling失败已保留logs；复制完整source并新scratch重建后完整54/7/actualCoreCPU debug+optimized通过，不把failedattempts改成通过。

下一步仍是各family长音频/typedMOSS-Nemotronrealtime、实际生产ASR caller切换/共享models恢复与其它Audio消费者、真实SDK/NSXPC/Metal/weights/golden/GPU并发/longmeeting/签名公证矩阵。此Owner不提高30秒接口预算，不机械切长录音，不删除仍被用的Audiopackage，不发布新增localcheckpoint。

### MOSS/Nemotron typed realtime prerequisite（不新增 ABI/Core/XPC 支持）

- 原两个真实HTTPsession分别委托 `MossRealtimeEngine` / `NemotronRealtimeEngine`，直接调用原MossTranscriber/NemotronStream，未重写数值/model/streamcache。共享typed speaker events和两adapter使用的JSONserializer保留preview segments absent、final/completed segments present（包括empty）与原speaker/times/metadata；原PCM16 ingress只留HTTP边界，typedengine直接接Float。
- MOSS保持4swindow、≥1.25s preview、last2.5s tail、1s实际steadyclock节流、同prompt更新时机/stopflags/ceil-scaled token min/max1024/offset16k/trim/newline/<8s剩余合并/≥8s backlog分窗。Nemotron保持80/160/320/560/1120ms nearest+strictly-less tie早档、原frame_seconds/lround/optional language不新增normalize、同stream复用/orderedappends/finaltailonce、24h计数护栏、failedstream不继续推进与原failed-completed empty payload。
- Close在engine waitmutex下cancel+notify，并等待active event delivery，不代表GPU/queuedjob/model retirement。commands需caller串行，只有Close可并发/typedSink内reentry；Owner/worker/model必须保留至真实worker drain，deinit不是资源barrier。取消可以让Commit/Finish的等待返回，但blockedmodel仍在真实worker里，不能释放model。
- 真实旧源码77a919c5 CPU回放：29 ordinaryHTTP场景liveBefore/After+lossless20MB JSON（XZ120340bytes fixture，仅randomeventID被normalize）保持完整audio/options/events/metadata。原MOSS已有publication barrier，不声称它有preview-overtaking bug。原Nemotron成功preview时确实提前enqueue final，但singleworker不允许成功finalevent超车；真正复现的是failurelog阻塞下 `[completed,error]`→`[error,completed]`，不伪造成功final-before-preview。旧Close不wake等待blockedpreview/final的command，新的cancel-aware Submit/wait唤醒命令但仍须实际worker drain。
- Main额外catch两family的directHTTPerror SenderClose/workerPreview跨锁倒置：localintegration BEFORE两程序timeout124（实际sharedserializer入口仅notification hook确认worker已在engine sink内，未插入bug）；sharedbaseSend记录currentSender并在delivery解锁后defer virtualClose，adaptercallbackClose先base cancel/closed/defer，之后实际engine waitmutex notify/activeSinkwait。移除family-specific threadtracker，shared2adapter方法避免transport→engine和engine→transport倒序。新永久4cases包括正常/throw-after-close×2family，测试只rename真实serializer函数symbol并由notification wrapper转发原body，original/compiled hashes分别留存，无productionhook/假serializer。
- 当前Mainfinal suite107普通+107 ASan/UBSan/float-cast-overflow全通过（agent earlier103属于旧sourcefreeze，不重标）；Qwen42 genuineBefore/After回归在base virtual/recursive/deferredClose后通过。strictWall/Wextra/Werror；controlledmodel/MLX/PCM/Unicode/helper/frontEnd/clock/publication/allocation hooks明确，24hguard用samplingrate1，不是24h16k实音频。没有SDK/Metal/modeltokenizer/golden质量/TSAN/race-freedom/production Native combinedlink验收。
- 独立readonly sourcefreeze审查：103Clang/103san/103GCC与后增107san分别记录；Qwen42；19普通+19san=38独立callback/lock-crossing/外部并发Close/allocation/active+queuedworkerjoin probes通过。6negativecontrols分别检出两family缺notify、nearesttie错误、MOSS tokenrate drift、presentemptysegments丢失、failurebarrier提前释放（assert/mismatch，不只timeout）；无productionblocker。Main应用格式follow-up后107san完整重跑、Core7/batch203san回归、tools59/audits通过。fullprecommit首遍formatter改6taskfiles记录failure，restage后重新执行，不把agent旧hash当当前hash。
- Native ABI7/56exports、bounded batch≤30秒、shared DTO/XPChelper/client/defaultFactory/签名/releasegates/Audio依赖未改；此typedseam已经被真实HTTP入口调用，但还不是两family Core/XPC realtime。下一步需要同loading-thread模型worker、bounded Native realtimelease/events/input/result、独立cancel+checkeddrain与App原scope/coordinator ownership及平台接受；不能把typedengine Close当这些barrier。

### ABI8：实际 MOSS/Nemotron bounded Native leases + 共享 speaker DTO

- 新standalone `omni_native_speaker.h`，13真实C exports（总69）与Core/shared/现有ABI断言/smokeguard匹配8；ABI7不能满足新surface。MacCMake注册全部4Native实现cpp/13exports/installheader，旧C结构/layout/exports保留，epoch变更不是已验收actual69export生产dylib/SDK。Qwen/Silero/Sortformer/sixbatch默认路由/权重选择/Audio/Remote/MLXSwiftLLM-VLM/signing/CIgates未改。
- 新independent NativeModelkind MOSS1/Nemo2（非Batch3/4）persistent actualTranscriptionWorker，emptyworkerstartup后actualmodel load为caughtjob，避免constructor故障丢失原worker；load/evaluate/eagerNemotronStream/engine+streamcache/modeldestroy与显式sync/clear都在该loadingthread。Native调用PrepareStream+原HTTP SubmitDecode复用EnsureStream，HTTP仍lazy/default unchanged。仅新NativeWorker releases_cache_when_idle=false；旧default true保持。Native显式sync/reset/clear/sync置于caughtjob，idle不会在失败checkedcleanup后抛出uncaughtsync导致线程终止；不声称修复所有旧Q/S异常观察。
- 每模型1lease到checked streamdestroy才释放，completed/drained也modelBUSY；rawdestroy须caller对所有rawcalls同步。模型cancel sticky停止newlease、streamcancel独立durable；Cancel只activeSink/wake，不是GPU/queue/model drain。Drain取消admission并等command+actualqueuedworker barrier/callbackweakself/jobcapturedrefs结束，sync前不reset原engine/cache，sync/reset/clear/sync全成功才标drained。取消持enginepointer guard；Receive不获取该guard以免cancel等sink时倒锁。failed/unknown清理保留原pointer/model/lease重试，不排新lease替代。
- 初始invalid输入返回NULL；postNativeadmission创建失败先checkedcleanup，未确认时返回**NONNULL owned handle/stream + failure status**，caller必须保留并原scope destroy重试，不因nonOK忽略nonnull、也不产生unreachable retainedGPU。load nonpreemptible、原connectionlostscope恢复仍须futurehelper ledger/Owner；没有implicitretarget/replay/fallback。
- 新C ingress finite mono16k，chunk1...32000 /total≤480000，trylockBUSY在copy前，nonzero contiguousseq，拒绝不consume/ACK=0；OK只是boundedcopy/engineadmission，非numerical完成。MOSScommit nonterminal/Nemocommit sealinput、finishonce，immutableprompt/lang/chunksettings不新增语言normalize或frame计算。promptUTF8≤8192/真实placeholder规则，lang128，haschunk0/1+nilcanonical0、Doublechunkfinitepositive≤120000ms；rawDirUTF8existing≤8192。
- Ring64slots保留terminalslot，queue字符串≤4MiB；text65536/meta128/segments512/per-event字符串含NUL262144。owned C events直接typedvariants，UTF8/NUL/finite有序nonnegativeDouble时间/segmentsbudget错则terminal LIMIT，绝不truncate；failure literalstatus4/5/6与cancel3无privateexceptionstrings。pollmalloc/calloc任一位置失败freepartial、保留同queueevent/sequence供pollretry，不replayaudio；previewsegments absent，final/completed present-even-empty，metadata nil/empty不丢失。
- Foundation新5文件/24测试：kind+complete model/service/connection/originalload UUID+session UUID，Native uint64 sessionID以后由service投射（不hash/truncUUID）；strictunion exactkeys immutable settings、UInt64正序/nooverflow、typedsegments复用DoubleBatchSegment、terminal-last/exactsessions/64events/4MiB batch、字节boundedencoded/decode在JSON前gate/array数量先于elements/nativeUTF8NULaggregate渐增。batch.isDrained/ACK/emptyPoll/completed只是schema，不能独立证明Nativecleanup。**还没有speaker RPCselectors/helper/client/App生产消费者**，不是借DTOfuturecaller声称切换已完成。
- Main119Contracts/config（118pass+1既有Linuxcase-sensitivefilesystemskip）与strictsource同行；Native298GCC普通/298ClangASan+UBSan+float-cast-overflow、149typedHTTP/Qwen回归、旧Core/batch203san通过；实际Swift C headerimport/link验证两uniondefaults、invalid load、checkednullcleanup/pollfree（13exportCPUlib，非actualcombinedCore/NSXPC）。TestAgent最终298×4(GCC/Clangplain/san)、3000controlled生命周期执行、39真402typed/HTTP完整traces一致；NativeAgent292是较早privatefixture修正counts，不重标repo298。所有model/audio/Unicode/MLX/worker observer/sink/callback/sync/allocator hooks显式，实际wrapper4cpp byte-identical，线程/args/ownership控制流非真实GPU数值质量。
- Independent final readonly冻结290files：298san、119Contracts/strictsource、4独立rawCore拒绝不consume/metadata-ownedsnapshot/blockedactualWorker/cancel/syncfail原handle retry/加载线程probes、16实际header枚举/limits匹配Swift、13smoke parser+136subtests通过。2强negativecontrols共3invocations检出sync前reset和lease提前release（assertstatus/mismatch，mutants leak额外告警，不拿timeout当proof），无productiondefect；69decl/CMake staticinventory通过。第一次review因等TestAgent READY1200s超时仅incomplete，final重新freeze真正review，无偷换approval。review期firstsmoke privatecopy缺原Apptextdependency失败保留，加byte-identical依赖后全部重跑。
- transitionalNative私有prompt抽取漏constant与构建工具PATH错误、Test busyFinish probe已接受seq复用/Finish也可BUSY导致probe自耗budget、livefixture header/layout中途变化旧parity错误全部logs保留；最终repo测试用actualFinishentry gate做一次BUSYprobe，未弱化Native行为。Agenthooks CargoPATH缺失非fullpass；Main最终staged全库hooks另验。macSDK/Metal/staticdtor/weights/tokenizer/golden/NSXPC/signing/CMake真实69exports/TSAN/globalGPUmem/perf/长会全待验。

ABI8检查点时下一步为两family actualhelper RPC+原loadscope非evictledger/reader/checkedNativeHandles+clientticket/coordinatorOwner，以下ABI9继续实现该阶段；历史ABI8证据不重标。

### ABI9：实际 speaker RPC、client load ticket 与 App Model Owner（opt-in）

- Core/shared/helper/App匹配epoch9，新增十个真实NSXPC selectors：load/unload/drain load、start/push/commit/finish/poll/close session/cancel。原69个C exports、headers/layout、typed engines与数值实现不变；旧8被compatibility gate拒绝。helper九文件显式Xcode membership，独立engine/queue；每条连接独立lifetime与model/service/connection/original-load/session完整identity。Native session用private monotonic UInt64计数，绝不hash UUID。
- helper在实际C constructor前保存model/stream shell，先接管failure status所附非空raw handle再抛错；reader直到checked model release成功。256个非驱逐load/session ledger、closed tombstones保留原scope，delayed load/drain、failed unpublished creation与lost-reply cleanup能同scope重试。独立cancel不排到blocked decode之后；timeout/disconnect只启动清理，不等于资源退役。poll保存整批owned事件并精确ACK/replay；不重放音频、不截断字段、不把raw poll无事件/terminal/isDrained当barrier。
- raw client保留成功/失败original binding跨disconnect；同scope uncancelled/coalesced cleanup、completion内部退役task。LoadOwnership ticket绑定client/operation/kind并区分notSubmitted/submitted/drained，在实际proxy load前标submitted；pre-send拒绝不能误drain别人的prepared model，也不能永久pin自己的reader/permit。Nemotron commit seal input，后续push/repeated commit拒绝而finish允许；MOSS commit非terminal。
- 实际App `OmniXPCSpeakerModelOwner` 显式prepare/start/push/commit/finish/poll/closeSession/close。**一个owned coordinator permit覆盖整个session**，因为push ACK仅入队/复制成功，Native worker还可能执行。checked session close才释放lane，resident model reader仍保留；permanent close按原load scope清理model。失败/unknown cleanup保留同reader/handle/identity/permit。cache-restore期间prepare取消需原scope清理；queued start尚未admit的取消只释放本地admission，不把cached模型排cleanup到incumbent之后形成self-deadlock。
- Main当前24个App owner/reader/coordinator public tests与54个既有batch Owner/client/coordinator回归 Debug/Release全通过；实际Owner→client→protocol→exported helper→Native Core9 CPU链MOSS/Nemotron normal、blocked Finish/deadline/failed sync/original retry各4组/config通过。实际POSIX readers和coordinator执行，模型结果/MLX sync/cache/NSXPC/container/signing为明确hooks，不是macOS SDK/Metal acceptance。Main Core99+batch104+speaker298=501 Clang ASan/UBSan/float-cast-overflow通过；Contracts119/config（118pass+1既有Linux filesystem skip），tools59通过。
- 独立readonly冻结1433files审查：Main24 public tests、4个人check、10 rawclient groups（包在1个XCTest中）合计29 methods/config Debug/Release通过；实际Core chain4组与helper15 scenarios通过，strict生产/helper编译通过。两negative controls检出ACK提前释放permit与用loadOperationID代替submitted-ticket造成foreign prepared拒绝后误pin。Linux generated XCTest严格并发discovery失败保留，不能把普通Debug/Release通过重标strict全suite。
- 生产HTTP/meeting默认factories、签名/CI/release gates、model catalog/installed weights/Remote/MLX Swift LLM-VLM/Audio依赖不改。新route仍finite mono16k chunk1...32000、session≤480000，显式reject oversize；不是生产录音cap/longform/model capacity，也不自动切段或拼接。真实SDK/Objective-C UInt64 selector编码、signed NSXPC/App Group、combined69export dylib/Metal/real weights/goldens仍待授权Mac验收。

下一步是实际ASRStreamingSession/meeting消费者与六family longform的family-specific语义、sharedcache/repair/blob/orphan/recovery、余下Audio迁移/unlink和真实平台门槛；不自动发布localcheckpoint。

### 剩余工作与硬门槛（不能宣布全部规划完成）

| 阶段 | 当前未完成内容 |
| --- | --- |
| T2/full T3 | 实际signed Mac/Xcode/NSXPC/App Group/Metal/model验证；历史包装结果不覆盖新提交 |
| T4 | opt-in Sortformer XPC/client已实现；production diarization调用者迁移、全部cached-directory迁移/授权/lease-delete与真实3runtime并行/golden待补 |
| T5 | Whisper/Cohere/MOSS/Nemotron/Parakeet/SenseVoice Core/XPC、MOSS/Nemotron typed realtime及完整客户端切换；复用上游已实现模型，production仍Native HTTP/辅助路径 |
| T6 | 所有ASR/VAD调用者迁移后删除Audio package/branches与完整App/Intel/LLM/VLM回归；当前依赖保留 |
| T7 | actual signing/notarization/clean-machine、memory/performance/longmeeting/failure矩阵及release gates |

此前请求Mac验收执行方式时用户AFK未选择，不能视为SSH/CI/signing授权。该轮仅推进离线实现、没有publish。之后用户明确请求提交并更新现有PR，已正常push到097f845并保留PR2683原包装说明/历史证据，补最新检查点/回归修正/未完成门槛；未force-push/merge/deploy，不启用CI gates。Sortformer schema后续检查点仍不等于平台或production验收。
