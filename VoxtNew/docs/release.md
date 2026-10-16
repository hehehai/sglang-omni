# 发布与更新

VoxtNew 的发布版本在 GitHub Actions 上构建：打一个 `v0.x.y` tag（正式版）或 `v0.x.y-beta.n` tag（beta 版），[release 工作流](../.github/workflows/release.yml) 就在 macOS runner 上编译辅助进程和 app，用 Developer ID 签名，用 Apple ID 和 App 专用密码公证，用更新密钥签名更新包，然后把这些文件传到一个**草稿** Release：

| 文件 | 用途 |
|---|---|
| `VoxtNew 0.x.y arm64.dmg` | 新用户下载安装（已公证、已 staple） |
| `voxtnew-0.x.y-darwin-arm64.tar.gz` | 完整更新包（里面的 app 已 staple） |
| `voxtnew-<旧版本>-to-0.x.y-darwin-arm64.delta` | 增量更新，最多 3 个旧版本各一个（见 §4.2） |
| `update-darwin-arm64.json` | 更新清单：版本、更新说明、文件的大小和签名 |

人工检查草稿后发布。更新用的是 MyGo 官方方案（`mygo.Updater` + updater 插件的 `native.Plugin` 窗口），说明见 MyGo 的 `docs/updates.md`、`docs/plugins/updater.md`；beta 通道是我们的补丁 0006（`third_party/mygo-patches/`）。

只发 Apple 芯片（darwin/arm64）：辅助进程只编 arm64，Intel Mac 暂不支持。

## 0. 两个通道

| | 正式版 | beta 版 |
|---|---|---|
| 版本号、tag | `0.2.0` / `v0.2.0` | `0.2.0-beta.1` / `v0.2.0-beta.1`（版本号里有 `-`） |
| GitHub 上 | 普通 Release，发布后成为 latest | **prerelease**，永远不是 latest |
| 谁会收到 | 所有人 | 只有打开了 设置 → 诊断与关于 → **Beta 更新** 的人 |

- **Beta 更新开关**：打开时，检查更新通过 GitHub API 列出所有 Release，取版本号最高的非草稿（beta 和正式版都算），比当前版本新就提示；关闭时只看 latest release（正式版）。
- **默认值**：用户没动过开关时，当前运行的是 beta 就默认打开（beta 用户能收到下一个 beta），是正式版就默认关闭。用户拨过一次就以用户为准。
- **不降级**：只会更新到比当前**更新**的版本。beta 用户关掉开关后，要等到比当前 beta 新的正式版发布才会更新（例如在 `0.2.0-beta.1` 上关掉，`0.1.1` 不会装，`0.2.0` 会装）。设置里的说明文字会这样写。
- **API 限额**：GitHub API 对每个 IP 每小时 60 次，每次检查用 1 次（每天自动检查一次，手动点一次算一次）。API 不可用时自动退回只查正式版；正式版也没有更新时，窗口显示检查失败，原因是 MyGo 的英文错误“GitHub takes no more requests from this network for now (60 an hour); try again after 15:04”，后台检查一小时后重试。
- **还没有正式版时**（现在：第一个版本是 beta），关着开关检查更新显示“已是最新”，不报错。

## 1. 一次性准备

需要 Apple Developer Program 账号。签名用 **Developer ID Application: wei guan (779M533DL5)**。mac-air 的钥匙串里还有另一个团队（RY2TQTYSKQ，Xiaofeng Cao）的两张 Developer ID 证书，导出时不要选错；工作流按 `APPLE_TEAM_ID` 选身份，并按证书的 SHA-1 签名（[scripts/release-identity.sh](../scripts/release-identity.sh)），同名证书也不会混淆。

下面的命令都不含秘密值：要输入的地方由命令提示，或者从文件读。都在 **mac-air** 上执行。

### 1.1 Developer ID Application 证书 → .p12

1. 确认钥匙串里有这个身份（应该看到一行 `Developer ID Application: wei guan (779M533DL5)`）：
   ```sh
   security find-identity -v -p codesigning | grep 779M533DL5
   ```
   没有的话：Xcode → Settings → Accounts → 选 779M533DL5 的团队 → Manage Certificates → 左下角 + → **Developer ID Application**。
2. 导出（`security export` 只能把钥匙串里**所有**身份一起导出，所以用图形界面，只导出这一个）：
   1. 打开“钥匙串访问”（Keychain Access），左边选 **登录**（login），上面选 **我的证书**（My Certificates）。
   2. 右上角搜索框输入 `779M533DL5`，只剩 **Developer ID Application: wei guan (779M533DL5)** 一行。点左边的三角展开，下面应该有一把私钥。不要选 `Xiaofeng Cao (RY2TQTYSKQ)` 那两行。
   3. 右键这一行（证书那行，不是私钥那行）→ **导出“Developer ID Application: wei guan (779M533DL5)”…** → 文件格式选 **个人信息交换 (.p12)** → 存为 `~/Desktop/voxtnew-developer-id.p12` → 设一个密码（存进密码管理器，后面 `MACOS_CERTIFICATE_PASSWORD` 用）→ 系统可能会要求输入登录钥匙串的密码。
3. 按工作流的方式检查这个 .p12：导入一个临时钥匙串，只应找到 779M533DL5 的一个身份（会提示输入 .p12 密码）：
   ```sh
   cd ~/code/VoxtNew   # 任何一份 VoxtNew 的 checkout，要有 scripts/release-identity.sh
   kc="$(mktemp -d)/p12-check.keychain-db"
   security create-keychain -p p12-check "$kc"
   security import ~/Desktop/voxtnew-developer-id.p12 -k "$kc" -f pkcs12 -T /usr/bin/codesign
   security find-identity -v -p codesigning "$kc"          # 应该只有 1 个：wei guan (779M533DL5)
   scripts/release-identity.sh 779M533DL5 "$kc"           # 打印 <SHA-1><Tab>Developer ID Application: wei guan (779M533DL5)
   security delete-keychain "$kc"
   ```
   （`security import` 不带 `-P` 时会弹窗问密码，密码不进 shell 历史。）

### 1.2 App 专用密码（公证用）

公证用开发者账号的 Apple ID（york@actnow.dev）加一个 **App 专用密码**（不是 Apple ID 的登录密码）：

1. 打开 [account.apple.com](https://account.apple.com)，用 york@actnow.dev 登录 → **登录与安全** → **App 专用密码** → 生成，名称写 `VoxtNew notarization`。
2. 复制显示的密码（格式 `xxxx-xxxx-xxxx-xxxx`，**只显示一次**），先存进密码管理器。
3. 可选，在本机先验证一次（存进登录钥匙串的 `voxtnew-notary` 配置，和 CI 无关）。不加 `--password`，notarytool 会提示输入：
   ```sh
   xcrun notarytool store-credentials voxtnew-notary --apple-id york@actnow.dev --team-id 779M533DL5
   ```
   成功会显示 “Validating your credentials… Success”。

以后改了 Apple ID 的密码，App 专用密码会全部失效，要重新生成并更新 `APPLE_APP_PASSWORD`。

### 1.3 更新签名密钥

已经在 mac-air 上生成好（线程 #27，`go tool mygo keygen`）：

- 私钥：`~/.config/voxtnew-release/update-keys/mygo-update.key`（只有你能读，600；目录 700）
- 公钥：同目录的 `mygo-update.pub`，内容已经写进 [release/mygo.release.json](../release/mygo.release.json) 的 `updates.publicKey`。

**把私钥存进密码管理器**（例如 1Password 的“安全备注”，或附件）。已安装的 VoxtNew 只接受这把私钥签的更新：丢了它，已安装的 app 就再也收不到自动更新（见第 5 节）。私钥不进仓库，不发给任何人，只放在密码管理器和 GitHub Secret 里。

### 1.4 GitHub Secrets（6 个）

在 mac-air 上执行。mac-air 上 `gh` 的登录已经失效，先重新登录（选 GitHub.com → HTTPS → 浏览器登录）：

```sh
export PATH=/opt/homebrew/bin:$PATH
gh auth login -h github.com
gh auth status
```

然后（每条命令要么从文件读，要么在提示时粘贴，值不会出现在命令行和 shell 历史里；Team ID 和 Apple ID 不是秘密，直接写在命令里）：

```sh
REPO=hehehai/VoxtNew
base64 -i ~/Desktop/voxtnew-developer-id.p12 | gh secret set MACOS_CERTIFICATE -R "$REPO"
gh secret set MACOS_CERTIFICATE_PASSWORD -R "$REPO"            # 提示时粘贴 .p12 的密码
gh secret set APPLE_TEAM_ID -R "$REPO" --body 779M533DL5
gh secret set APPLE_ID -R "$REPO" --body york@actnow.dev
gh secret set APPLE_APP_PASSWORD -R "$REPO"                    # 提示时粘贴 App 专用密码
gh secret set MYGO_UPDATER_PRIVATE_KEY -R "$REPO" < ~/.config/voxtnew-release/update-keys/mygo-update.key
gh secret list -R "$REPO"                                      # 应该列出这 6 个
```

设好以后，把 `.p12` 存进密码管理器，删掉桌面上的副本（`rm ~/Desktop/voxtnew-developer-id.p12`）。工作流里这些值都会被打码（`::add-mask::`），notarytool 也不回显它们。不用 GitHub Environment 审批（用户 10-16 定）：Secret 只在 tag 构建和手动运行时用到，PR 构建拿不到。

### 1.5 第一次试跑

Secrets 设好、本分支合并到 main 后，不打 tag，手动跑一次（签名、公证都会做，但不上传，产物留在这次运行的 Artifacts 里，保留 7 天）：

```sh
gh workflow run release.yml -R hehehai/VoxtNew --ref main -f dry_run=true
gh run watch -R hehehai/VoxtNew
```

日志里 “Signing keychain” 一步应该打印 `Signing as Developer ID Application: wei guan (779M533DL5) (<SHA-1>)`。“Verify the app” 一步会检查：app 和辅助进程的签名（`codesign --verify --deep --strict`）、两者的 `audio-input` entitlement、hardened runtime、时间戳、同一个 Team 而且就是 `APPLE_TEAM_ID`、`spctl -a -vv`（应为 `source=Notarized Developer ID`）、app 和 dmg 的 `stapler validate`、更新清单、`CFBundleVersion` 只有数字。脚本是 [scripts/release-verify.sh](../scripts/release-verify.sh)。

## 2. 发一个版本

### 2.1 共同步骤（beta 和正式版都一样）

1. **改版本号**，两处要一致（`scripts/build-helper.sh` 和工作流都会检查）。beta 用 `0.x.y-beta.n`，正式版用 `0.x.y`：
   ```sh
   v=0.1.0-beta.2        # 或 0.1.0
   jq --arg v "$v" '.version = $v' mygo.json > mygo.json.tmp && mv mygo.json.tmp mygo.json
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" helper/Support/Info.plist   # macOS
   ```
   app 的 `CFBundleShortVersionString` 是完整版本号（`0.1.0-beta.2`，更新比较用它）；`CFBundleVersion` 由 MyGo 写成数字部分（`0.1.0`，补丁 0007，Apple 要求只含数字和点）。
2. **写 CHANGELOG.md**：把最上面的 `## [Unreleased]` 改成 `## [0.1.0-beta.2] - 2026-11-02`（没有 Unreleased 就在最上面加一节；标题里的版本号必须和 mygo.json 完全一样，包括 `-beta.2`），英文在前，中文在后，小标题一一对应：
   ```markdown
   ## [0.1.0-beta.2] - 2026-11-02

   ### Fixed

   - The overlay no longer …

   ### 修复

   - 浮窗不再……
   ```
   更新窗口显示的就是这一节（MyGo 从 CHANGELOG.md 取，`## [版本]` 到下一个 `## `），中英文用户看到的是同一段。没有这一节构建会失败；没有中文工作流会给出警告。
3. 提交、推到 main，等 CI 通过（`gh run list -R hehehai/VoxtNew --branch main -L 3`）。
4. **打 tag**（tag 必须等于 `v` + mygo.json 的版本，否则工作流直接失败）：
   ```sh
   git tag -a "v$v" -m "VoxtNew $v"
   git push origin "v$v"
   gh run watch -R hehehai/VoxtNew
   ```
5. 等 Release 工作流跑完（公证通常几分钟）。日志里 “Build, notarize and upload” 一步应能看到 `Made the delta update from …`（第一个版本没有增量，正常；beta 和正式版的增量见 §4.2）。

### 2.2 发 beta

6. **检查草稿**：工作流把 beta 的草稿标成 prerelease（`mygo build -upload` 建草稿时就带 `--prerelease`，“Draft release”一步再确认一次）：
   ```sh
   gh release view "v$v" -R hehehai/VoxtNew --json isDraft,isPrerelease,assets --jq '{isDraft, isPrerelease, assets: [.assets[].name]}'
   ```
   应该是 `isDraft: true, isPrerelease: true`，有 dmg、tar.gz、update-darwin-arm64.json（第二个 beta 起还有 .delta）。下载 dmg 装一遍：
   ```sh
   gh release download "v$v" -R hehehai/VoxtNew -p '*.dmg' -D /tmp/voxtnew-check
   ```
   装到“应用程序”后 `spctl -a -vv /Applications/VoxtNew.app` 应显示 `accepted` 和 `source=Notarized Developer ID`。
7. **发布**（不要加 `--latest`：prerelease 不能是 latest）：
   ```sh
   gh release edit "v$v" -R hehehai/VoxtNew --draft=false
   ```
   之后打开了 Beta 更新的 VoxtNew（所有 beta 用户默认打开）在下一次检查时看到它；正式版用户看不到。

### 2.3 发正式版

6. **检查草稿**：应该是 `isDraft: true, isPrerelease: false`（命令同上）。正式版的增量同时覆盖上一个正式版和最新的 beta（§4.2）。
7. **发布**，并设为 latest：
   ```sh
   gh release edit "v$v" -R hehehai/VoxtNew --draft=false --latest
   ```
   之后所有 VoxtNew 都会看到它：正式版用户；beta 用户无论开关开没开，只要它比当前 beta 新（`0.1.0` 比 `0.1.0-beta.3` 新）。

### 2.4 第一个 beta（0.1.0-beta.1）

仓库里的版本号已经是 `0.1.0-beta.1`（mygo.json、helper/Support/Info.plist、CHANGELOG.md）。顺序：

1. 完成 §1（证书、App 专用密码、6 个 Secret）。
2. 合并本分支到 main，CI 通过后做 §1.5 的试跑，确认签名、公证、校验都通过。
3. 按 §2.1 第 4 步打 `v0.1.0-beta.1` tag，§2.2 检查并发布。
4. 第一个版本没有增量；没有正式版，关掉 Beta 更新的人检查更新显示“已是最新”。
5. 自己从 ad-hoc 构建换到发布版之前，先重置授权（§3）。

## 3. 从 ad-hoc 换到 Developer ID：授权（TCC）

macOS 按 bundle ID + 代码签名的要求（designated requirement）记住麦克风和辅助功能授权。ad-hoc 签名的要求就是那次构建的哈希，Developer ID 的是“Apple 签发、Team ID 为 X、标识为 dev.hehehai.voxtnew”。所以：

- **第一次从自己编的 ad-hoc 版本换到发布版**，旧授权对不上：麦克风变成“拒绝且不再弹窗”，辅助功能开关看着开着但不起作用。换之前执行一次，再打开发布版重新授权：
  ```sh
  tccutil reset Microphone dev.hehehai.voxtnew
  tccutil reset Accessibility dev.hehehai.voxtnew
  ```
  如果辅助功能列表里还留着一个不起作用的 VoxtNew，用 − 删掉再加。
- **之后的更新**（同一个 Team ID、同一个 bundle ID）授权保留，beta 和正式版之间也一样。`identifier` 发布后就不能再改。
- 开发时用 Apple Development 证书签名的构建，要求和 Developer ID 不同，与发布版之间切换也要 reset 一次。
- 钥匙串里模型服务的 API Key 不受影响：条目是 `/usr/bin/security` 建的，信任的是它，不是 VoxtNew 的签名。

## 4. 更新怎么工作

### 4.1 检查和安装，以及“装好但还没重启”

- 插件每天在后台检查一次（启动后 10 秒起），有新版本时弹出更新窗口（`ShowInactive`，不抢正在打字的 App 的焦点），显示更新说明，提供 **安装更新 / 稍后提醒 / 跳过这个版本**。窗口语言跟随 VoxtNew 的界面语言（插件只取一次：改了界面语言，要下次启动才跟着变）。
- 手动入口：应用菜单（关于之后）、菜单栏图标的菜单、⌘K、设置 → 诊断与关于 → 更新（还有“Beta 更新”“自动检查”“自动安装更新”三个开关和上次检查时间）。三处都按 Beta 更新开关的状态检查。
- 安装时先下载增量，校验签名，用已安装的 app 拼出新版本、逐个文件核对 SHA-256；任何一步不对就改下载完整包。结果和发布的 app 逐字节一致（代码签名、公证票据都在）。
- 装好后插件提示重启（`App.Relaunch`：先走 VoxtNew 的退出流程，停掉辅助进程，再启动新版本）。
- **“自动安装更新”默认关**（插件的默认值）。开着时后台发现的更新会直接装好，但不会自动重启：MyGo 是在 app 运行时直接替换 bundle 的，旧进程继续跑，磁盘上的辅助进程已经是新版本。为此：
  - supervisor 每次启动辅助进程前比较磁盘上 `Info.plist` 的版本和正在运行的版本（`internal/appbundle`）；不一样就不再启动磁盘上的新辅助进程（`helper.FailUpdated`，也不自动重试）；新辅助进程如果说另一个协议版本，同样归为“已更新”，而不是“请重新编译辅助进程”。
  - app 每分钟、每次检查之后看一次磁盘上的版本；变了就在侧边栏底部出一张卡片“已安装更新 / 重启 VoxtNew 以完成更新”，首页和设置 → 诊断与关于也显示“重启 VoxtNew”。重启后卡片消失。

### 4.2 增量（delta）在两个通道之间

MyGo 原来的做法：构建时读“已发布”的清单，也就是 `releases/latest/download/update-darwin-arm64.json`（**最新正式版**），从它和它清单里列的前几个版本（最多 3 个）生成增量。beta 是 prerelease，从来不是 latest，所以：

| 构建 | 原来读到 | 结果 |
|---|---|---|
| `0.1.0-beta.2`（之前只有 beta.1） | 没有正式版 → 404 | 没有增量，beta.1 用户下完整包 |
| `0.1.0`（之前只有 beta） | 404 | 没有增量 |
| `0.2.0-beta.2`（之前 0.1.0、0.2.0-beta.1） | 0.1.0 | 只有从 0.1.0 的增量，beta.1 用户下完整包 |

补丁 0006 加了 `updates.prereleases`（[release/mygo.release.json](../release/mygo.release.json) 里打开）：构建时同时读**最新正式版**的清单和**版本号最高的已发布版本**（含 beta，通过 GitHub API，CI 里带 `GH_TOKEN`）的清单，先放两个通道各自的最新版本，再按版本号从高到低放它们清单里列的旧版本，去重、只取比当前低的，最多 3 个：

| 构建（已发布的） | 增量来自 |
|---|---|
| `0.1.0-beta.1`（无） | 无（第一个版本） |
| `0.1.0-beta.2`（beta.1） | beta.1 |
| `0.1.0`（beta.1、beta.2） | beta.2、beta.1 |
| `0.2.0-beta.1`（…、0.1.0） | 0.1.0、beta.2、beta.1 |
| `0.1.1`（…、0.2.0-beta.1） | 0.1.0、beta.2、beta.1（0.2.0-beta.1 比 0.1.1 新，不算） |

所以两个通道的最新版本的用户总能拿到增量；更旧的版本、或者增量用不上（改过 app）的，下完整包。这张表就是 §6 的 e2e 实测结果。

## 5. 回滚、密钥和证书出问题时

- **发布后发现问题**：已经更新的 app 不会自动降级（只装比自己新的版本）。先把这个 release 改回草稿，阻止还没更新的人继续更新：`gh release edit v0.1.1 -R hehehai/VoxtNew --draft=true`（latest 回到上一个正式版；beta 同理，Beta 用户回到看见上一个 beta）；修好后发一个**更高**的版本（0.1.2 或 0.2.0-beta.2）。不要复用版本号。已经装了坏版本、急需回退的人，可以从旧 release 下载 dmg 拖进“应用程序”覆盖（同一 Developer ID，授权保留），之后照常收到新版本。
- **更新私钥丢失**：已安装的 app 只认这把私钥，再也收不到自动更新。只能用新密钥发新版本（换 `release/mygo.release.json` 里的公钥），并请所有用户手动下载安装一次。所以一定要在密码管理器里留一份。
- **更新私钥泄漏**：拿到它、又能往这个仓库的 Release 上传文件的人，可以给所有用户推送任意代码。立即：用旧私钥签发一个只换了公钥的新版本（之后的更新改用新密钥），撤换 GitHub Secret，检查仓库和 Actions 的访问权限。
- **App 专用密码泄漏或不用了**：在 account.apple.com → 登录与安全 → App 专用密码 里撤销它，重新生成一个，更新 `APPLE_APP_PASSWORD`。它只能用于公证这类服务，不能登录 Apple ID。
- **Developer ID 证书**：有效期 5 年，过期后带时间戳签的旧版本仍能运行，只是不能再签新版本；换新证书（同一 Team）后授权保留，更新 `MACOS_CERTIFICATE` 和密码即可（工作流按 Team 选，按 SHA-1 签）。证书被吊销则已签名的版本可能无法启动。

## 6. 不用证书测试更新

两个脚本在 Mac 上用一把**测试**密钥和 ad-hoc 签名把整条更新链跑一遍，不开窗口、不抢焦点、不启动辅助进程、不碰钥匙串，结束时删掉测试密钥、构建和更新源（`KEEP=1` 保留在 `build/` 下）：

```sh
MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-update-e2e.sh   # 安装方式：增量、完整包、增量失败后改完整包
MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-beta-e2e.sh     # beta 通道
```

[scripts/mac-update-e2e.sh](../scripts/mac-update-e2e.sh)：造 0.1.0-test 和 0.1.1-test 两个版本（bundle ID `dev.hehehai.voxtnew.updtest`），在本机回环地址上起一个 HTTPS 更新源（[scripts/update-server](../scripts/update-server/main.go)，自签证书只通过 `SSL_CERT_FILE` 让这几个进程信任），把装好的 0.1.0-test 用 `-tags updatecheck` 编进去的 `--update-check`（[update_check.go](../update_check.go)，发布版没有）驱动真实的 `mygo.Updater.Check/Install`，检查三种安装方式、装完的 bundle 和发布的逐文件一致、旧进程不启动新辅助进程、新版本“已是最新”。

[scripts/mac-beta-e2e.sh](../scripts/mac-beta-e2e.sh)：一个假的 GitHub（`update-server -github`：一个 HTTPS 代理，github.com 和 api.github.com 由它自己回答，其他主机一律拒绝，所以不会碰真的 GitHub），按发布配置（`github` + `prereleases`）依次构建并发布 `0.1.0-beta.1`、`0.1.0-beta.2`、`0.1.0`、`0.2.0-beta.1`、`0.1.1`（beta 是 prerelease，另外有一个草稿 `0.3.0-beta.1`），每次发布后让已安装的各版本在 Beta 更新开 / 关 / 默认下检查并安装：

| 场景 | 已安装 | Beta 更新 | 期望 |
|---|---|---|---|
| a | beta.1（只有 beta） | 默认（开） | beta.2，增量 |
| b | beta.1（只有 beta） | 关 | 无（没有正式版：已是最新） |
| c / d / e | beta.2 / beta.2 / beta.1（有 0.1.0 后） | 默认 / 关 / 开 | 0.1.0，增量 |
| n | beta.2，app 被改过 | 开 | 0.1.0，增量失败后完整包 |
| f / g | 0.1.0（有 0.2.0-beta.1 后） | 默认（关） / 开 | 无 / 0.2.0-beta.1 增量 |
| h / i | beta.2（有 0.2.0-beta.1 后） | 默认 / 关 | 0.2.0-beta.1 / 0.1.0，增量 |
| j / k | 0.2.0-beta.1（有 0.1.1 后） | 关 / 默认 | 无（不降级到 0.1.1） |
| l / m | 0.1.0（有 0.1.1 后） | 默认 / 开 | 0.1.1 / 0.2.0-beta.1（版本号最高，不是最后发布的），增量 |
| o / p | 0.1.0 / 0.2.0-beta.1，API 被限流 | 开 | 退回正式版：0.1.1 / 报错 “GitHub takes no more requests…” |

还检查每个版本的增量来自哪些版本（§4.2 的表）、`CFBundleVersion` 是数字、草稿从未被取到、没有请求过别的主机。

## 7. 只能用真证书验证的

第一次真实发版（或 1.5 的试跑）之后，在 mac-air 上确认：

1. 公证通过；`release-verify.sh` 全部通过（hardened runtime、时间戳、Team、Gatekeeper、staple）。如果公证因为辅助进程放在 `Contents/Resources` 被拒，看 `xcrun notarytool log` 再处理（MyGo 支持这种布局，目前预期能过）。
2. reset TCC 后授权麦克风和辅助功能，录音、粘贴、读浏览器网址都正常；主程序的 `audio-input` entitlement 在 hardened runtime 下够用（主进程自己请求麦克风、辅助进程录音两条路都要试）。
3. 发 `0.1.0-beta.2` 后：在 beta.1 里“安装更新 → 重启”，**授权仍然有效**；增量和完整包各走一次；
4. 安装后点“稍后”：旧进程还能不能录音和粘贴（磁盘上的代码已经换了），卡片“已安装更新”是否出现，点“重启 VoxtNew”后一切正常；
5. `App.Relaunch` 是直接 exec 新的可执行文件（不经 LaunchServices），重启后的进程麦克风和辅助功能是否正常。

## 8. 为什么这样做

- **`updates` 不写进仓库的 mygo.json**，只在发布时由 [scripts/release-config.sh](../scripts/release-config.sh) 合并 [release/mygo.release.json](../release/mygo.release.json)。核实过：`mygo.Updater.Enabled()` 只在 `mygo dev` 的开发构建里为 false；任何带 `updates` 的 `go tool mygo build`（包括 mac-air 上各线程的 ad-hoc 测试构建）都会链接更新源，放在可写目录里就会每天去 GitHub 检查，发布后会提示、甚至在开了自动安装时用正式版替换掉测试构建（替换只看路径，独立 bundle ID 的也一样）。公钥本身不是秘密，放在仓库里便于审阅。签名身份和公证配置同样只在 CI 里注入，所以 notarize 不会让本地 ad-hoc 构建报错。
- **beta = GitHub prerelease**，不另开更新源：一个仓库、一套 Release，GitHub 本来就区分 prerelease 和 latest；关着 Beta 更新的 app 读 latest，和没有 beta 时完全一样，不多用 API。打开时多一次 API 请求，每天一次远低于限额。
- **按 SHA-1 选签名身份**：codesign 遇到两张同名证书会报 “ambiguous”（mac-air 上 RY2TQTYSKQ 就有两张同名的），按哈希签不会。CI 的临时钥匙串里只有导入的那一张，脚本仍按 `APPLE_TEAM_ID` 核对。
- **主程序也有 `audio-input` entitlement**（[helper/Support/app.entitlements](../helper/Support/app.entitlements)）：hardened runtime 下主进程自己请求麦克风时需要；辅助进程录音时 macOS 也把主程序当作负责进程。成本为零。
- **发布只在 tag 上上传**；手动运行默认 dry run；PR 只做不带 Secret 的 ad-hoc 构建和检查。action 固定到 commit，权限按 job 最小化（只有发布 job 有 `contents: write`），同一个 ref 不并发、不中途取消，缺 Secret 时第一步就报出缺哪几个。
