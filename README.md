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

用 DevEco Studio 打开 `client/`，配置签名（见 [client/README.md](client/README.md)），构建安装：

```bash
cd client
./hvigorw --mode module -p product=default -p module=panel@default \
  -p buildMode=debug assembleHap --no-daemon
hdc install -r panel/build/default/outputs/default/panel-default-signed.hap
```

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

推一个 `v*` tag 就会构建 HAP，和 Android 项目打 tag 出 APK 一个意思：

```bash
git tag v0.2.0
git push origin v0.2.0
```

工作流：`.github/workflows/release-hap.yml`

1. `ErBWs/setup-ohos@v2` 安装 HarmonyOS 命令行工具（hvigorw + SDK），按 `HOS_CLI_VERSION` 选版本
2. `hvigorw --mode module -p product=default -p module=panel@default -p buildMode=release assembleHap`
3. 产物上传为 artifact，并附到对应 GitHub Release

### 签名

CI **默认只出未签名 HAP**：HAP 的签名 profile 必须是绑定你华为开发者账号 + bundleName 的，CI 没法自己生成。

想让它出可直接安装的包，在仓库 secrets 里放签名材料（都是 base64）：

| Secret | 内容 |
| --- | --- |
| `SIGN_KEYSTORE_BASE64` | `.p12` 密钥库 |
| `SIGN_KEYSTORE_PWD` | 密钥库口令 |
| `SIGN_KEY_ALIAS` | 密钥别名 |
| `SIGN_KEY_PWD` | 密钥口令 |
| `SIGN_PROFILE_BASE64` | `.p7b` 签名 profile |
| `SIGN_CERT_BASE64` | `.cer` 证书链 |

有这些 secret 时，工作流会用 SDK 自带的 `hap-sign-tool.jar` 走 `localSign` 签一遍。

### 注意

- 命令行工具必须包含你 `compileSdkVersion` 对应的 SDK（这里是 API 26）；如果公开的最新版还没跟上，把 `version` 钉到你本地 DevEco 的 CLI 版本
- 未签名的 HAP 装不上设备，需要本地用 DevEco 签一次