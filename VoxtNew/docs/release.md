# 发布与更新

VoxtNew 是 sglang-omni 仓库里的开源 app（Apache-2.0）。下载、更新和更新日志都放在官网 actnow.dev：更新源是 `https://actnow.dev/updates/voxtnew`（beta 通道是 `…/voxtnew/beta`），和 Auralink（`https://actnow.dev/updates/auralink`）用**同一把更新密钥**。**不用 GitHub Release**。

> **还差官网这一边**：actnow.dev 上还没有 VoxtNew 这个产品。发布前要在官网（actnow-www 仓库，不在本仓）加上 VoxtNew 的产品、更新源（`/updates/voxtnew` 和 `/updates/voxtnew/beta`）、更新日志和下载页，在面板里登记公钥 `XDaGyDBITqrf5dHt4exZy9jP3VuZY8+mnT3/yI/vy14=`，并发一个 VoxtNew 的 ingest token（Auralink 的叫 `RELEASE_INGEST_TOKEN_AURALINK`）。这些不属于本仓的工作。在那之前，`scripts/release.sh` 可以构建、签名、公证和检查，`--publish` 会因为官网不认识 `voxtnew` 而失败。

发布版本在一台 Apple 芯片的 Mac 上用一条命令构建：[scripts/release.sh](../scripts/release.sh)。它编译辅助进程、Omni 运行时（语音识别）和 voxtnew-llm（语言模型），把三者放进 app，`go tool mygo build` 打包、签名、（可选）公证，[scripts/release-verify.sh](../scripts/release-verify.sh) 检查结果，最后用官网的发布脚本 [scripts/actnow-publish.sh](../scripts/actnow-publish.sh)（`https://actnow.dev/actnow-publish.sh` 的原样副本，见 §2.3）把文件交给官网后台，或者只做 `--dry-run`。

```
scripts/release.sh（在 Mac 上；VOXTNEW_SIGN_IDENTITY = Developer ID）
   │  检查版本号（mygo.json、helper 和 llm 的 Info.plist）、CHANGELOG
   ├─ build-helper.sh              → resources/darwin-arm64/helper/voxtnew-helper
   ├─ build-omni.sh --clean        → resources/darwin-arm64/omni/bin/（qwen3_asr_server、MLX 的库、mlx.metallib）
   ├─ build-llm.sh                 → resources/darwin-arm64/llm/（voxtnew-llm、mlx.metallib、llama.framework、Hub bundle）
   │     （--runtimes DIR：直接用 DIR/omni 和 DIR/llm，不重新编译）
   ├─ release-config.sh            合并 release/mygo.release.json（公钥、url、prereleases）、签名身份、公证配置
   ├─ go tool mygo build           签名每个嵌套的可执行文件、库和 framework（hardened runtime、时间戳），
   │                               dmg；--notarize 时公证并 staple；有 MYGO_UPDATER_PRIVATE_KEY 时还有更新包、增量、清单
   ├─ release-verify.sh            签名、entitlement、运行时都在而且能从 app 里启动、hardened runtime、Team、
   │                               （公证后）Gatekeeper、staple、清单
   └─ actnow-publish.sh --app voxtnew …   --publish 时上传；否则有更新文件就 --dry-run
   结束时 mygo.json 恢复原样，暂存的运行时删掉（--keep-runtimes 保留）
```

只发 Apple 芯片（darwin/arm64），macOS 15 起：辅助进程、Omni 运行时和 voxtnew-llm 都只编 arm64，MLX 只支持 Apple 芯片。

**app 里有什么**（0.1.0-beta.1：app 280 MB，dmg 45 MB；见文末“实测记录”）：

| 路径（`VoxtNew.app/Contents/…`） | 是什么 | 签名 |
|---|---|---|
| `MacOS/VoxtNew` | Go + MyGo 的 app | `helper/Support/app.entitlements`（`audio-input`） |
| `Resources/helper/voxtnew-helper` | Swift 辅助进程：麦克风、快捷键、辅助功能、粘贴 | `helper/Support/helper.entitlements`（`audio-input`） |
| `Resources/omni/bin/qwen3_asr_server`、`*.dylib`、`mlx.metallib` | Omni 原生运行时（sglang_omni_mlx/native）：Qwen3-ASR 和 Silero VAD | 保留原 entitlement（没有） |
| `Resources/llm/voxtnew-llm`、`llama.framework`、`mlx.metallib`、`swift-transformers_Hub.bundle` | 语言模型进程（mlx-swift-lm 和 llama.cpp） | `llm/Support/llm.entitlements`（空：Metal 不需要） |

`mlx.metallib` 不是代码，是资源，由 app 的签名封住。模型本身不在 app 里，用户在 app 里下载（`~/Library/Application Support/VoxtNew/models/`）。

更新用的是 MyGo 官方方案（`mygo.Updater` + updater 插件的 `native.Plugin` 窗口），说明见 MyGo 的 `docs/updates.md`、`docs/plugins/updater.md`；beta 通道是我们的补丁 0006（`third_party/mygo-patches/`，和 Auralink 的同一个）。

## 0. 两个通道

| | 正式版 | beta 版 |
|---|---|---|
| 版本号 | `0.2.0` | `0.2.0-beta.1`（版本号里有 `-`） |
| 更新源 | `https://actnow.dev/updates/voxtnew` | `https://actnow.dev/updates/voxtnew/beta` |
| 清单里文件的地址 | `…/updates/voxtnew/<文件>` | `…/updates/voxtnew/beta/<文件>`（官网后台会检查） |
| 谁会收到 | 所有人 | 只有打开了 设置 → 诊断与关于 → **Beta 更新** 的人 |

- **Beta 更新开关**：打开时检查更新读 beta 通道的清单（官网保证它始终是 beta 和正式版中较新的那个），比当前版本新就提示；读不到时退回正式版的清单。关闭时只读正式版的清单。
- **默认值**：用户没动过开关时，当前运行的是 beta 就默认打开，是正式版就默认关闭。用户拨过一次就以用户为准。
- **版本号只能往上走**（官网后台的规则）：新版本必须高于这个通道发布过的所有版本，已发布或下架过的版本号不能再用。
- **不降级**：只会更新到比当前更新的版本。beta 用户关掉开关后，要等到比当前 beta 新的正式版才会更新。
- **还没有正式版时**（0.1.0-beta.1 是第一个版本），正式版通道的清单是 404，关着开关检查更新显示“已是最新”，不报错（`mygo.ErrNotPublished`）。

## 1. 一次性准备

都在发布用的 Mac（mac-air）上做。下面的命令都不含秘密值：要输入的地方由命令提示，或者从文件读。

### 1.1 Developer ID 证书

签名用 **Developer ID Application: wei guan (779M533DL5)**，已经在 mac-air 的登录钥匙串里（10-16 查过：`security find-identity -v -p codesigning` 列出它，SHA-1 `EBCFF160A0270A61E62504F924CC65A4FF309AFB`）。同一个钥匙串里还有另一个团队（RY2TQTYSKQ，Xiaofeng Cao）的两张同名 Developer ID 证书，所以**按 SHA-1 签**，不按名字：

```sh
scripts/release-identity.sh 779M533DL5          # 打印 <SHA-1><Tab>Developer ID Application: wei guan (779M533DL5)
export VOXTNEW_SIGN_IDENTITY="$(scripts/release-identity.sh 779M533DL5 | cut -f1)"
```

**ssh 里签不了**：登录钥匙串在 ssh 会话里是锁着的，codesign 报 `errSecInternalComponent`（10-16 在 mac-air 上试过）。两种办法，任选一个：
- 在 Mac 的“终端”里运行 `scripts/release.sh`（图形会话里钥匙串是解锁的）；第一次使用时系统会问是否允许 codesign 使用这把私钥，选“始终允许”。
- 或者在 ssh 里先解锁（会提示输入登录密码），并允许 codesign 不经弹窗使用私钥（只需一次）：
  ```sh
  security unlock-keychain ~/Library/Keychains/login.keychain-db
  security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db   # 提示输入登录密码
  ```

### 1.2 公证凭据（notarytool）

公证用开发者账号的 Apple ID（york@actnow.dev）和一个 **App 专用密码**，存进登录钥匙串的 notarytool 配置 `voxtnew-notary`。**mac-air 上还没有**（10-16 查过，钥匙串里没有 notarytool 的配置）。

1. 打开 [account.apple.com](https://account.apple.com)，用 york@actnow.dev 登录 → **登录与安全** → **App 专用密码** → 生成，名称写 `VoxtNew notarization`；复制显示的密码（只显示一次），存进密码管理器。（也可以复用 Auralink 的那个。）
2. 在 Mac 的终端里存成配置（不加 `--password`，notarytool 会提示输入，密码不进 shell 历史）：
   ```sh
   xcrun notarytool store-credentials voxtnew-notary --apple-id york@actnow.dev --team-id 779M533DL5
   ```
   成功会显示 “Validating your credentials… Success”。
3. 以后改了 Apple ID 的密码，App 专用密码全部失效，重新生成，再执行一次第 2 步。

### 1.3 更新签名密钥

VoxtNew 和 Auralink 用同一对密钥。公钥写在 [release/mygo.release.json](../release/mygo.release.json) 的 `updates.publicKey`（`XDaGyDBITqrf5dHt4exZy9jP3VuZY8+mnT3/yI/vy14=`），私钥在 mac-air 的 `~/.config/auralink-release/update-keys/mygo-update.key`（600，目录 700；同目录的 `mygo-update.pub` 和公钥一致，10-16 核对过）。发布时：

```sh
export MYGO_UPDATER_PRIVATE_KEY="$(cat ~/.config/auralink-release/update-keys/mygo-update.key)"
```

私钥必须在密码管理器里有一份：已安装的 VoxtNew 和 Auralink 只接受这把私钥签的更新，丢了就再也收不到自动更新（§5）。

### 1.4 官网的 ingest token

`ACTNOW_INGEST_TOKEN`：官网给 VoxtNew 的发布 token，只能操作 VoxtNew 的版本，只在 `--publish` 时用。官网加上 VoxtNew 之后，把它放进 `~/.config/actnow/ingest-tokens.env`（600），发布时读进环境变量；不写进命令行。

### 1.5 第一次试跑

先做一个不公证、不发布的签名构建，确认签名和检查都通过（时间：编运行时约 10 分钟；用 `--runtimes ~/voxtnew-runtime` 只要 2 分钟左右）：

```sh
cd ~/code/VoxtNew                     # 一份同步好的 checkout（scripts/mac.sh），不要用别的线程的
export PATH=/opt/homebrew/bin:$PATH  # jq
export VOXTNEW_SIGN_IDENTITY="$(scripts/release-identity.sh 779M533DL5 | cut -f1)"
scripts/release.sh --runtimes ~/voxtnew-runtime
```

`release-verify.sh` 这时的模式是 `signed`：每段代码（app、辅助进程、qwen3_asr_server、每个 dylib、voxtnew-llm、llama.framework）都要通过 `codesign --verify --strict`，带 hardened runtime、时间戳和同一个 Team；Omni 服务和 voxtnew-llm 要能从 app 里启动（hardened runtime 下的库验证要求同一个 Team 签名的库）。Gatekeeper 这时会拒绝（“Unnotarized Developer ID”），脚本只把结论打印出来。再加上 `--notarize voxtnew-notary` 跑一次，模式变成 `developer-id`，Gatekeeper 必须接受（`source=Notarized Developer ID`），app 和 dmg 都要 staple。

## 2. 发一个版本

### 2.1 步骤（beta 和正式版一样）

1. **改版本号**，三处要一致（`release.sh`、`build-helper.sh`、`build-llm.sh` 都会检查）。beta 用 `0.x.y-beta.n`，正式版用 `0.x.y`：
   ```sh
   v=0.1.0-beta.2        # 或 0.1.0
   jq --arg v "$v" '.version = $v' mygo.json > mygo.json.tmp && mv mygo.json.tmp mygo.json
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" helper/Support/Info.plist   # macOS
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" llm/Support/Info.plist
   ```
   app 的 `CFBundleShortVersionString` 是完整版本号（更新比较用它）；`CFBundleVersion` 由 MyGo 写成数字部分（`0.1.0`，补丁 0007）。
2. **写 CHANGELOG.md**：把最上面的 `## [Unreleased]` 改成 `## [0.1.0-beta.2] - 2026-11-02`（版本号和 mygo.json 完全一样），英文在前，中文在后，小标题一一对应（`### Added` / `### 新增`）。更新窗口显示整节；官网用同一节，由发布脚本从第一个含汉字的 `### ` 小标题处分成 `notes` 和 `notesZh`。`--publish` 时没有这一节就失败。
3. 提交、推到 main，等 CI（[voxtnew-ci.yaml](../../.github/workflows/voxtnew-ci.yaml)）通过，在 mac-air 上跑一遍回归（`scripts/mac-regress.sh`，[manual-test.md](manual-test.md) §10）。
4. 同步到发布用的 checkout，在 Mac 的终端里（§1.1）：
   ```sh
   export PATH=/opt/homebrew/bin:$PATH
   export VOXTNEW_SIGN_IDENTITY="$(scripts/release-identity.sh 779M533DL5 | cut -f1)"
   export MYGO_UPDATER_PRIVATE_KEY="$(cat ~/.config/auralink-release/update-keys/mygo-update.key)"
   set -a; . ~/.config/actnow/ingest-tokens.env; set +a     # ACTNOW_INGEST_TOKEN（官网加上 VoxtNew 之后）
   scripts/release.sh --notarize voxtnew-notary              # 先不发布：构建、公证、检查、--dry-run
   scripts/release.sh --notarize voxtnew-notary --publish    # 发布（会重新构建；或者见下面“只发布”）
   ```
   公证通常几分钟。增量来自官网两个通道上已发布的版本（§4.2）；第一个版本没有增量。
5. 打 tag 记下发布的提交：`git tag -a "voxtnew-v$v" -m "VoxtNew $v" && git push origin "voxtnew-v$v"`（加前缀，不和 sglang-omni 自己的 tag 混在一起）。
6. 检查：
   ```sh
   curl -s https://actnow.dev/updates/voxtnew/beta/update-darwin-arm64.json | jq '{version, deltas: [.deltas[]?.from]}'
   curl -s https://actnow.dev/updates/voxtnew/update-darwin-arm64.json | jq .version    # 正式版
   ```
   从官网下载页装一遍 dmg：`spctl -a -vv /Applications/VoxtNew.app` 应显示 `accepted` 和 `source=Notarized Developer ID`。

**只发布**（构建已经做好、检查过，在同一个 checkout 里）：
```sh
bash scripts/actnow-publish.sh --app voxtnew --dir build/darwin-arm64 --changelog CHANGELOG.md --min-macos 15.0
```

**发布失败**：脚本打印官网的错误（不含 token）并中止这次会话。常见的：

| 官网回复 | 意思 | 处理 |
|---|---|---|
| 401 / 403 | token 缺失、不对，或是别的 app 的 | 换 `ACTNOW_INGEST_TOKEN` |
| 404 / 422 未知 app | 官网还没有 VoxtNew | 见文首“还差官网这一边” |
| 409 `version_exists` | 这个版本号已经有了 | 发一个新版本号 |
| 422 `version_not_newer` | 不比这个通道发布过的版本高 | 改版本号 |
| 422 `invalid_artifacts` / `verification_failed` | 文件名、大小、sha256、清单地址、签名或 notes 不对（`details.errors` 逐条列出） | 看是哪一条；清单地址不对多半是没走 `release-config.sh` |

### 2.2 不签名的发布式构建（测试用）

不设 `VOXTNEW_SIGN_IDENTITY` 时，`release.sh` 做一个 ad hoc 签名、**没有更新源**的构建，其他步骤一样（运行时都在里面、检查通过）。用来在发版前确认打包没问题，也是 mac-air 上回归用的构建：

```sh
MAC_DIR=code/VoxtNew-rel scripts/mac.sh 'export PATH=/opt/homebrew/bin:$PATH; scripts/release.sh --runtimes $HOME/voxtnew-runtime'
```

签名这一路不用证书也能测：[scripts/mac-sign-e2e.sh](../scripts/mac-sign-e2e.sh) 在一个临时钥匙串里造一个自签的代码签名身份，用它跑 `release.sh`（`release-verify.sh signed`：每段代码都带 hardened runtime、时间戳），结束时删掉钥匙串、恢复钥匙串搜索列表。自签证书没有 Team ID，库验证不让运行时加载它们的库，所以“从 app 里启动”这两项只报告、不算失败：

```sh
MAC_DIR=code/VoxtNew-sign scripts/mac.sh scripts/mac-sign-e2e.sh
```

ad hoc 构建里 voxtnew-llm 和 llama.framework **不带** hardened runtime：hardened runtime 的库验证要求库和进程是同一个 Team 签的，ad hoc 签名没有 Team，llama.framework 会被拒绝加载（M2 在 mac-air 上见过）。真实身份签名时它们都带 hardened runtime。

### 2.3 发布脚本（actnow-publish.sh）

`scripts/actnow-publish.sh` 是官网脚本 `https://actnow.dev/actnow-publish.sh` 的**原样副本**（和 Auralink 的同一份），不在发布时下载最新的：发布用的代码在仓库里、经过审阅。官网改了脚本时同步：

```sh
curl -fsSL https://actnow.dev/actnow-publish.sh -o scripts/actnow-publish.sh
git diff scripts/actnow-publish.sh        # 看改了什么，再提交
```

## 3. 签名细节

- **谁签什么**：`build-helper.sh` 和 `build-llm.sh` 用 `VOXTNEW_SIGN_IDENTITY`（没有就 ad hoc）签各自的产物，供 app 外单独使用；`build-omni.sh` 总是 ad hoc。打包时 `mygo build` 用真实身份把 `Contents/Resources` 里**每个** Mach-O 文件和 framework 重新签一遍（由内向外，hardened runtime + 时间戳；`codesign --deep` 碰不到 Resources，所以 MyGo 自己遍历：补丁之外的 `signNestedCode`），再签整个 app。`macos.helperEntitlements` 给辅助进程和 voxtnew-llm 指定 entitlement，其余代码保留签名时的 entitlement（都没有）。
- **ad hoc** 时 MyGo 只给没有有效签名的代码补签，已有签名的保持原样，指定了 entitlement 的（辅助进程、voxtnew-llm）重签。
- **mygo.json 要求 voxtnew-llm 在**：`helperEntitlements` 里有 `llm/voxtnew-llm`，没有它 `go tool mygo build` 和 `mygo dev` 都会失败（“the resources hold no executable … at llm/voxtnew-llm”）。开发时先 `scripts/build-llm.sh`，或者在 mac-air 上用现成的：`cp -Rc ~/voxtnew-runtime/llm resources/darwin-arm64/llm`。更新的 e2e 测试（§6）不带运行时，自己去掉这一项。
- **不开沙箱**：app 要启动子进程（辅助进程、qwen3_asr_server、voxtnew-llm）。
- **公证**由 MyGo 做：`macos.notarize = {keychainProfile}`（`release-config.sh --notary-profile`）时，`mygo build` 把签好的 dmg 交给 `notarytool submit --wait`，通过后 staple dmg 和 app（更新包里的 app 是 staple 过的）。被拒时看 `xcrun notarytool log <id> --keychain-profile voxtnew-notary`。

## 4. 从 ad-hoc 换到 Developer ID：授权（TCC）

macOS 按 bundle ID + 代码签名的要求记住麦克风和辅助功能授权。ad-hoc 签名的要求就是那次构建的哈希，Developer ID 的是“Apple 签发、Team ID 为 779M533DL5、标识为 dev.hehehai.voxtnew”。所以：

- **第一次从自己编的 ad-hoc 版本换到发布版**，旧授权对不上：麦克风变成“拒绝且不再弹窗”，辅助功能开关看着开着但不起作用。换之前执行一次，再打开发布版重新授权：
  ```sh
  tccutil reset Microphone dev.hehehai.voxtnew
  tccutil reset Accessibility dev.hehehai.voxtnew
  ```
- **之后的更新**（同一个 Team ID、同一个 bundle ID）授权保留，beta 和正式版之间也一样。`identifier` 发布后就不能再改。
- 开发时用 Apple Development 证书签名的构建，与发布版之间切换也要 reset 一次。
- 下载好的模型（`~/Library/Application Support/VoxtNew/models/`）不受签名影响，换版本、更新都保留。

## 5. 更新怎么工作

### 5.1 检查和安装，以及“装好但还没重启”

- 插件每天在后台检查一次官网的更新源（启动后 10 秒起），有新版本时弹出更新窗口（不抢正在打字的 App 的焦点），显示更新说明，提供 **安装更新 / 稍后提醒 / 跳过这个版本**。窗口语言跟随 VoxtNew 的界面语言。
- 手动入口：应用菜单、菜单栏图标的菜单、⌘K、设置 → 诊断与关于 → 更新。
- 安装时先下载增量，校验签名，用已安装的 app 拼出新版本、逐个文件核对 SHA-256；任何一步不对就改下载完整包。app 里有约 260 MB 的运行时，增量只含变了的文件：只改 Go 代码的版本，增量只有几 MB。
- 装好后插件提示重启（`App.Relaunch`：先走 VoxtNew 的退出流程，停掉辅助进程和模型进程，再启动新版本）。
- **“自动安装更新”默认关**。开着时后台装好的更新不会自动重启；supervisor 发现磁盘上的版本变了，就不再启动磁盘上的新辅助进程（`helper.FailUpdated`），侧边栏出现“已安装更新 / 重启 VoxtNew 以完成更新”。

### 5.2 增量在两个通道之间

补丁 0006 的 `updates.prereleases`（[release/mygo.release.json](../release/mygo.release.json) 里打开）让构建同时读**两个通道的清单**：先放两个通道各自的版本，再按版本号从高到低放它们清单里列的旧版本，去重、只取比当前低的，最多 3 个。增量文件和这个版本的更新包放在同一个目录，清单里是完整的 URL，所以正式版的清单复制到 beta 通道以后照样指向 `voxtnew/` 下的文件。两个通道最新版本的用户总能拿到增量；更旧的、或者改过 app 的，下完整包。

## 6. 不用证书测试更新

两个脚本在 Mac 上用一把**测试**密钥和 ad-hoc 签名把整条更新链跑一遍：按发布配置构建（`url` 换成测试的），每个构建先用 `actnow-publish.sh --dry-run` 检查，再由 [scripts/update-server](../scripts/update-server/main.go) `-publish` 像官网后台那样摆进一个代表 R2 桶的目录，`-site` 在本机回环地址上用 HTTPS 模拟 actnow.dev 的 `/updates/voxtnew[/beta]/`。不开窗口、不抢焦点、不启动辅助进程、不碰钥匙串；构建里不带模型运行时（更新器不关心 bundle 里是什么）。

```sh
MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-update-e2e.sh   # 增量、完整包、增量失败后改完整包、已最新
MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-beta-e2e.sh     # 两个通道：0.1.0-beta.1 … 0.1.1，Beta 更新开 / 关 / 默认
```

## 7. 回滚、密钥和证书出问题时

- **发布后发现问题**：在官网面板下架这个版本，或者对上一个版本 Roll back。已经装了新版本的不会降级；修好后发一个**更高**的版本。急需回退的人可以从官网下载旧版本的 dmg 覆盖安装（同一 Developer ID，授权和模型都保留）。
- **更新私钥丢失**：VoxtNew 和 Auralink 的已安装版本都再也收不到自动更新，只能换公钥发新版本，请所有用户手动安装一次。
- **更新私钥泄漏**：两个 app 都受影响：立即用旧私钥签发只换了公钥的新版本，官网面板里的公钥也要换。
- **ingest token 泄漏**：请官网换掉 VoxtNew 的 token；文件仍要过后台的签名校验，推送不了恶意更新。
- **Developer ID 证书**：有效期 5 年，过期后带时间戳签的旧版本仍能运行；换新证书（同一 Team）后授权保留。

## 8. 只能用真证书、真官网验证的

1. 公证通过；`release-verify.sh developer-id` 全部通过。如果公证因为 `Contents/Resources` 里的可执行文件被拒，看 `notarytool log`（MyGo 支持这种布局，预期能过）。
2. hardened runtime 下：Omni 服务和 voxtnew-llm 从 app 里启动、加载模型、出结果（`--smoke` 一次，再按 [manual-test.md](manual-test.md) 各点一遍）。MLX 只用 Metal，不需要 JIT 一类的 entitlement；万一某个运行时被系统拒绝，`log show --predicate 'subsystem == "com.apple.securityd"' --last 5m` 里能看到原因。
3. reset TCC 后授权麦克风和辅助功能，录音、粘贴、读浏览器网址都正常。
4. 第一次真实发布：后台校验通过、两个通道的清单对、dmg 能从下载页下载、更新日志显示中英文说明。
5. 发下一个版本后：“安装更新 → 重启”，授权和下载好的模型都还在；增量和完整包各走一次。

## 9. 为什么这样做

- **在 Mac 上用脚本发布，不用 GitHub Actions**：发布要编 Omni 运行时（CMake、固定版本的 MLX）和 voxtnew-llm（xcodebuild、Metal 着色器），GitHub 的 macOS runner 上每次要 15 分钟以上，还要把 Developer ID、公证凭据、更新私钥和官网 token 放进 sglang-omni 这个公开仓库的 Secret。发布用的 Mac 上这些都在钥匙串和 `~/.config` 里。CI（`voxtnew-ci.yaml`）只做 Linux 上的测试。以后要在 CI 里发布，可以在仓库的自托管 Mac runner 上照 `release.sh` 写一个工作流（见 thread #8 的待决事项）。
- **`updates` 不写进仓库的 mygo.json**，只在签名的发布构建里由 [scripts/release-config.sh](../scripts/release-config.sh) 合并：任何带 `updates` 的 `go tool mygo build`（包括 mac-air 上各线程的测试构建）都会链接更新源，放在可写目录里就会每天去检查，发布后甚至会用正式版替换掉测试构建。
- **和 Auralink 共用更新密钥**：同一个作者、同一个官网后台，面板里每个产品登记同一个公钥。代价是密钥出事时两个 app 一起受影响（§7）。
- **两个更新源，beta 取较新的**：官网的约定，和 Auralink 一样；app 只读一个清单。读 beta 清单失败时退回正式版。
- **按 SHA-1 选签名身份**：codesign 遇到两张同名证书会报 “ambiguous”，按哈希签不会。

## 实测记录

mac-air（M4 / 24 GB，macOS 26.7），10-16，运行时用 `~/voxtnew-runtime`（`--runtimes`）：

- **ad hoc**（`scripts/release.sh --runtimes ~/voxtnew-runtime`，约 3 分钟，大半是辅助进程的 `swift build`）：`VoxtNew.app` 280 MB，dmg 45 MB；`release-verify.sh ad-hoc` 全部通过：8 段代码（app、辅助进程、qwen3_asr_server、libmlx、libjaccl、voxtnew-llm、llama.framework、MyGo 的 libmygo-sqlite3）都签好，Omni 服务和 voxtnew-llm 能从 app 里启动。
- **签名**（`scripts/mac-sign-e2e.sh`：临时自签的代码签名身份代替 Developer ID）：8 段代码都带 hardened runtime 和 Apple 的时间戳，`codesign --verify --deep --strict` 通过；Gatekeeper 拒绝（自签，预期）。Omni 服务和 voxtnew-llm 从 app 里**启动不了**：`libmlx.dylib … not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`。这是库验证在比较 Team ID，自签证书没有 Team；Developer ID 签的进程和库是同一个 Team（779M533DL5），应该能加载，要在 §8 第 2 条用真证书确认。
- **启动**（10-17，合并后的 ad hoc 发布式构建）：`VoxtNew.app/Contents/MacOS/VoxtNew --smoke <dir>`（自己的数据目录，链接快速语音模型、VAD 和快速语言模型）：辅助进程就绪，asr.fast 0.8 s 回答，llm.fast 6.8 s（冷启动，机器上同时有其他线程的模型进程）回答“OK”，退出后没有留下 `qwen3_asr_server`、`voxtnew-llm`、`voxtnew-helper`。`open -g` 正常启动：窗口“VoxtNew”出现、辅助进程就绪；`quit` 后同样一个进程都不剩。
- **Developer ID**：在 ssh 里签不了（`errSecInternalComponent`，钥匙串锁着，§1.1），要在 Mac 的终端里做。
- **公证**：mac-air 上没有 notarytool 的配置（§1.2），没有提交过。
