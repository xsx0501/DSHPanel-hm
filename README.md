# DS-Harness-HM · DSH 鸿蒙面板

DeepSeek Harness（DSH）的 HarmonyOS NEXT 客户端 + 配套宿主机插件。手机不在电脑前也能看到 turn/step 进度、接收审批并直接通过。

```
DSHPanel-hm/
├── host-plugin/     DSH 宿主机插件（npm 包 dsh-panel-bridge）
└── client/          HarmonyOS NEXT 客户端（ArkTS / Stage 模型）
```

| 部分 | 作用 | 文档 |
| --- | --- | --- |
| **host-plugin** | 设备配对、后台事件流（SSE）、站外审批、配对二维码 | [host-plugin/README.md](host-plugin/README.md) |
| **client** | 手机端面板：概览 / 会话 / 日志、悬浮球、闪控窗、通知栏审批 | [client/README.md](client/README.md) |

---

## 30 秒看懂它能干什么

| 场景 | 表现 |
| --- | --- |
| 任务在跑，人离开电脑 | 桌面悬浮球常驻显示 `T2·S1`，点一下展开卡片：会话名、进度、最新 3 条事件 |
| DSH 要执行命令需要审批 | 通知栏弹出带「允许 / 拒绝」按钮的审批，或直接在悬浮卡片上点 |
| 想看完整面板 | 打开 App：概览、会话列表、事件日志，支持左右滑动切换 |
| 换服务器 / 多节点 | 节点页扫码配对，多节点切换 |

---

## 快速开始

### 1. 宿主机装插件

```bash
# 插件在 host-plugin/ 子目录，用 git 子目录语法直装（实测 pnpm 12 可用）
dsh plugin --profile web add "https://github.com/xsx0501/DSHPanel-hm.git#path:/host-plugin"
./node_modules/.bin/dsh-panel-bridge enable --profile web
# 重启 DSH
```

> pnpm 版本不认 `#path:` 时，clone 后从目录装：
> `git clone https://github.com/xsx0501/DSHPanel-hm && dsh plugin --profile web add ./DSHPanel-hm/host-plugin`

细节（配置项、故障排查、Termux/proot 重启）见 [host-plugin/README.md](host-plugin/README.md)。

### 2. 手机装客户端

Release 里下载的是**未签名 HAP**，装到真机前必须先签名。两条路，任选其一。

#### 路线 A：自己签名（可控，推荐正式使用）

用 DevEco Studio 打开 `client/`：

1. *File → Project Structure → Signing Configs* → 勾选 **Automatically generate signature**（登录华为账号）
2. App 用了 `FLOAT_VIEW` 等受控权限，需要在签名 profile 里补 ACL —— 在 DevEco 的 `signingConfigs` 界面展开 *Advanced*，或直接编辑生成的 `.p7b` 前先在 `build-profile.json5` 里声明 ACL
3. *Build → Build Hap(s)/APP(s)*，或命令行：

```bash
cd client
./hvigorw --mode module -p product=default -p module=panel@default \
  -p buildMode=debug assembleHap --no-daemon
hdc install -r panel/build/default/outputs/default/panel-default-signed.hap
```

已有签名材料（`.p12/.p7b/.cer`）也可以直接对下载的 HAP 重签：

```bash
java -jar "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-app \
  -mode localSign -signAlg SHA256withECDSA \
  -keyAlias "<别名>" -keystoreFile "<keystore.p12>" -keystorePwd "<库口令>" -keyPwd "<密钥口令>" \
  -appCertFile "<cert.pem>" -profileFile "<profile.p7b>" \
  -inFile DSHPanel-v0.2.0-unsigned.hap -outFile DSHPanel-signed.hap
```

#### 路线 B：用 Auto-Installer 一键装（小白省事）

[`likuai2010/auto-installer`](https://github.com/likuai2010/auto-installer/)（现名**小白调试助手**）基于 `hdc`，能直接装 `.hap` / `.app` / `.hsp`，并支持**自定义证书**替换：

- 下载：<https://github.com/likuai2010/auto-installer/releases>
- 支持平台：Windows(x86) / macOS(x86、M1) / Linux(x86) / Android(arm64)
- macOS 首次打开需执行：`xattr -d com.apple.quarantine xxx/hap_installer.app`
- Linux 需先装 zenity，且**不要用 root/sudo 启动**
- 手机端（HarmonyOS NEXT arm64）不能直接跑这个工具，要从电脑或 Android 设备连过去装

把本仓库 Release 里的 `DSHPanel-*-unsigned.hap` 拖进去即可；工具会用自己的证书签名后安装。

> 受控权限（`FLOAT_VIEW` 等）需要 profile 里带 ACL。Auto-Installer 的默认证书通常不含 ACL，这种情况请走路线 A，或把带有 ACL 的 profile 导进工具里替换默认证书。

### 3. 配对

浏览器打开 `https://<你的公网域名>/panel`（或宿主机上 `http://127.0.0.1:3080/panel`）——页面直接显示二维码和深链。

手机：App 底部「更多」→「节点」→「扫码」。

> 页面内置活 token：只有 loopback 或已登录 DSH 的浏览器能打开；匿名访问返回 403。

---

## 设计与需求文档

| 文档 | 内容 |
| --- | --- |
| [docs/prd.md](docs/prd.md) | 产品需求基线（场景、验收口径、NFR） |
| [docs/design.md](docs/design.md) | 技术方案：DSH 契约、承载形态（L0/L1/L2）、审批链路、安全模型、任务拆分 |

> 文档里的域名统一用占位符 `dsh.example.com`，令牌一律写成 `<TOKEN>`；真实部署信息不入库。

---

## 系统要求

| 部分 | 要求 |
| --- | --- |
| 宿主机 | DSH ≥ 0.2.1，Node ≥ 22，pnpm |
| 客户端 | HarmonyOS NEXT，API 20+（`compatibleSdkVersion 6.0.0(20)`，target 26） |
| 权限 | 悬浮球 `USE_FLOAT_BALL`、闪控窗 `FLOAT_VIEW`、常驻 `KEEP_BACKGROUND_RUNNING_SYSTEM`（均为 ACL 级，需在签名 profile 里声明） |

---

## 已知平台限制

| 限制 | 表现 |
| --- | --- |
| 后台拉起 Ability 需要 `START_ABILITIES_FROM_BACKGROUND` | ACL 通常申不下来；点球的「打开」退化为推送一条可点通知 |
| 应用主窗口不可见时无法创建悬浮窗 | 悬浮球必须在**前台**创建，之后切后台常驻（`1300020 / err 1017`） |
| 后台启动浮窗被拒 | 点球展开依赖「先 bind 再启动球」，不能事后 bind（`1300025`、`1300033`） |

---

## License

MIT
---

## 图标与素材

应用图标使用「鲸鱼娘」同人形象，素材来自 [蓝色大肥鱼档案馆](https://github.com/EDMOK/blue-fish-archive)（`previews/deepseek-jushou-dazhaohu.webp`）。

- 角色原作：**上善无形**（[Bilibili](https://space.bilibili.com/4456176)）
- DeepSeek 元素女仆鲸鱼娘二次设计：**ZipZipPipe**（[Bilibili](https://space.bilibili.com/4168597)）
- 整理与收录：**EDMOK**（[蓝色大肥鱼档案馆](https://fisharchive.cc/)）

二次设计作品依 **CC BY-NC-SA 4.0** 授权：非商业使用，二创需遵循相同协议。本项目为个人非商业工具，图标仅用于客户端标识；如原权利人提出异议，会立即替换。
## 自动出包（GitHub Actions）

推一个 `v*` tag 就会构建 **未签名 HAP**，和 Android 项目打 tag 出 APK 一个意思：

```bash
git tag v0.2.0
git push origin v0.2.0
```

工作流：`.github/workflows/release-hap.yml`

1. `ErBWs/setup-ohos@v2` 安装 HarmonyOS 命令行工具（hvigorw + SDK）
2. `hvigorw --mode module -p product=default -p module=panel@default -p buildMode=release assembleHap`
3. 产物改名 `DSHPanel-<tag>-unsigned.hap`，上传 artifact 并附到对应 GitHub Release

## 为什么只出未签名包

HAP 的签名 profile（`.p7b`）绑定**你的华为开发者账号、bundleName 和设备白名单**，CI 无法代生成。
把签名材料塞进仓库 secrets 也意味着把调试私钥托管给 GitHub，不值得。

安装步骤：下载 HAP 后，用 DevEco Studio 打开 `client/` 配好签名（*Project Structure → Signing Configs*），
签名构建一次即可装到设备；或者用 SDK 里的 `hap-sign-tool` 对下载的 HAP 重签。
