# dsh-panel-bridge

DeepSeek Harness（DSH）宿主机插件：给 **HarmonyOS 客户端 DS-Harness-HM** 提供

- **设备配对**：一次性启动 token 换长期、可吊销的 device token
- **后台事件流**：`GET /api/panel/events`（SSE），手机切后台/息屏后仍能收到进度
- **站外审批**：审批请求推送到通知栏 / 悬浮球 / 闪控窗，可直接「允许 / 拒绝」
- **配对二维码**：`GET /api/panel/qr` 生成 `dsh://connect?...` 深链二维码

> 本文件同时是**安装说明**。任何 AI 助手或人读完本文即可完成安装，无需其他文档。

---

## 给 AI 助手的执行清单

按顺序执行，每一步都给出「期望结果」；任一步不符就停下并报告实际输出。

```bash
# 步骤 1：确认环境
node --version            # 期望 v22 或更高
pnpm --version            # 期望有输出（没有则先装 pnpm）
dsh --version             # 期望 DSH >= 0.2.1
```

```bash
# 步骤 2：把插件装进 profile
dsh plugin --profile web add https://github.com/xsx0501/DSHPanel-hm.git
# 期望：输出 "+ dsh-panel-bridge 0.2.0" 和 "Done in Ns"
# 说明：HTTPS 形式在只开 443 的机器上也能装；SSH 可用时 github:xsx0501/DSHPanel-hm 等价
```

```bash
# 步骤 3：挂载（写 loader 记录 + 校验 profile）
dsh-panel-bridge enable
# 若提示 command not found（bin 没进 PATH），用：
#   ./node_modules/.bin/dsh-panel-bridge enable --profile web
# 期望：
#   mounted dsh-panel-bridge in profile "web"
#   config OK (NNNN lines)
```

```bash
# 步骤 4：重启 DSH（重启方式见「重启」一节）
# 期望：进程起来后主页面能打开（HTTP 200/401 都算起来）
```

```bash
# 步骤 5：验证插件真的挂上了
dsh-panel-bridge status
# 期望：JSON 里 "version": "v9"，且 routes 含 /api/panel/pair、/api/panel/devices
curl -s -o /dev/null -w '%{http_code}\n' \
  'http://127.0.0.1:3080/api/panel/qr?data=dsh%3A%2F%2Fconnect%3Fx%3D1'
# 期望：200
```

```bash
# 步骤 6：给手机出配对二维码
dsh-panel-bridge qr --url https://<你的公网域名> --svg /tmp/pair.svg
# 期望：打印 deep link: dsh://connect?endpoint=...&token=...，并写出 /tmp/pair.svg
```

完成。手机端：DSH 面板 → 底部「更多」→「节点」→「扫码」。

---

## 安装方式

### A. 从 git（推荐，无需 npm 账号）

```bash
dsh plugin --profile web add https://github.com/xsx0501/DSHPanel-hm.git
dsh-panel-bridge enable
```

SSH 能通（`ssh -T git@github.com` 有回应）时也可以用短写 `github:xsx0501/DSHPanel-hm`。
只开了 443 的机器请用上面的 HTTPS 形式——**实测**在 Termux/proot 主机上 19 秒装完。

### B. 从 npm（若已发布）

```bash
dsh plugin --profile web add dsh-panel-bridge
dsh-panel-bridge enable
```

> 国内机器 npm 默认源常是 `registry.npmmirror.com`（只读镜像）。要立刻装到，加：
> `--registry=https://registry.npmjs.org`。镜像同步通常滞后数小时。

### C. 从本地目录 / tarball

```bash
dsh plugin --profile web add /path/to/repo
dsh plugin --profile web add ./dsh-panel-bridge-0.2.0.tgz     # 先 npm pack
dsh-panel-bridge enable
```

### `enable` 做了什么

只在 `~/.dsh/profiles/<profile>/cordis.patch.yml` 追加（或改写）这一段，然后跑 `dsh --profile <profile> --dump-config` 校验：

```yaml
# DS-Harness-HM companion bridge (panel-bridge)
- insert:
    - id: panel-bridge
      name: dsh-panel-bridge
      config:
        approvalTimeoutMs: 120000
        takeOverApprovals: true
        injectBridge: false
```

幂等：重复执行不会产生第二份。备份文件名为 `cordis.patch.yml.bak-*`（由脚本或手工备份留下）。

---

## 重启

| 部署方式 | 命令 |
| --- | --- |
| systemd | `systemctl restart dsh` |
| macOS / 手动 | 结束 `dsh web` 进程后重新 `dsh web` |
| **Termux + proot** | 见下 |

Termux/proot 上，DSH 是外层 shell 的子孙进程，**必须从容器外重启**，否则新进程绑不上 3080：

```bash
ssh <host> "nohup sh -c 'sh ~/panel-restart.sh' >/dev/null 2>&1 &"
```

`~/panel-restart.sh` 必须按 `exec /usr/bin/dsh web` 匹配进程（从 Termux 看到的是 proot 包装进程，`pkill -f 'node /usr/bin/dsh web'` 匹配不到）：

```sh
#!/bin/sh
pkill -f 'exec /usr/bin/dsh web'; sleep 3
pkill -f 'proot-distro login ubuntu'; sleep 4
sshd 2>/dev/null
nohup proot-distro login ubuntu -- bash -lc 'exec /usr/bin/dsh web --no-open --trusted-host <你的域名>' >> "$HOME/dsh.log" 2>&1 &
```

---

## 配对与二维码

### 网页端（推荐）

浏览器打开：

```
https://<你的域名>/panel          # 已登录 DSH 的电脑
http://127.0.0.1:3080/panel       # 宿主机本机
```

页面直接渲染二维码 + 深链 + 一键复制，手机扫码即可配对，不用敲命令。

访问控制：**loopback 直连**，或**带着 DSH 自己的登录 cookie**（会先向本机 `/` 校验一次）。页面里是活 token，所以对匿名访问一律 403。

不想记 URL 的话，让插件在网页右下角放一个「配对」按钮：

```bash
dsh-panel-bridge enable --profile web --public-url https://<你的域名> --inject
```

（原理：订阅 `webserver/index-inject`，往 index.html 注入一段脚本。注意必须用 `ctx.on(...)` 订阅——事件是在 webServer 自己的 context 上 emit 的，`ctx.webServer.on(...)` 收不到。）

想让页面上显示公网地址（而不是 127.0.0.1），在挂载时给一次：

```bash
dsh-panel-bridge enable --profile web --public-url https://<你的域名>
```

### 命令行

```bash
dsh-panel-bridge qr                       # 深链 + 浏览器二维码地址
dsh-panel-bridge qr --url https://dsh.example.com
dsh-panel-bridge qr --svg /tmp/pair.svg   # 存成 SVG（可直接打印/贴图）
dsh-panel-bridge qr --link                # 只要深链
```

二维码接口（**仅 loopback**，因为 query 带一次性启动 token）：

```
GET /api/panel/qr?endpoint=https://host&token=<start-token>   → image/png
GET /api/panel/qr?format=svg&data=<deep-link>                 → image/svg+xml
GET /api/panel/qr?format=json&data=<deep-link>                → {"ok":true,"data":…}
```

扫码内容：

```
dsh://connect?endpoint=https%3A%2F%2Fhost&token=<start-token>
```

**启动 token 一次性**：手机配对成功后失效；新增设备请重启 DSH 取新 token（已配对设备用各自的 device token，不受影响）。

---

## CLI

```
dsh-panel-bridge enable  [--profile web]        挂载 + 校验
dsh-panel-bridge disable [--profile web]        移除挂载
dsh-panel-bridge status  [--port 3080]          打印 loopback diag
dsh-panel-bridge qr      [--url …] [--svg f]    配对深链 / 二维码
```

---

## 配置项（`cordis.patch.yml` 的 `config`）

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `approvalTimeoutMs` | `120000` | 审批超时自动拒绝 |
| `takeOverApprovals` | `true` | 接管宿主审批队列（否则只旁听） |
| `injectBridge` | `false` | 是否向 DSH 网页注入桥接脚本 |
| `publicUrl` | 空 | 「配对页」展示的公网地址；空则由请求的 Host 推导 |

---

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `dsh: failed to parse overlay … cordis.patch.yml` | YAML 写错。最常见：`name` 未加引号却以 `@` 开头（`@` 是 YAML 保留字符）。用 `dsh-panel-bridge enable` 重写，别手改 |
| `failed to import: Cannot find package 'dsh-panel-bridge'` | 包没装进 profile `node_modules`，重跑 `dsh plugin … add`；或 `name` 写成了包名但实际是本地目录（此时应写绝对路径） |
| `Cannot find module '…/plugins/xxx/index.js'` | 手工方案把入口放进了 `lib/`。loader 只认平铺的 `index.js`，用 `enable` 重新挂载 |
| `dsh-panel-bridge: command not found` | pnpm 的 bin 没进 PATH：用 `npx dsh-panel-bridge enable` 或直接 `node node_modules/dsh-panel-bridge/bin/dsh-panel-bridge.mjs enable` |
| `enable` 后 status 里没有 `/api/panel/*` 路由 | 没重启，或 `name` 指向了不存在的包 |
| 二维码接口返回 401 | 该接口只接受 127.0.0.1 直连；从容器内 `curl` |
| 手机扫码后立即失效 | 启动 token 一次性，正常现象；需要再扫就重启 DSH |
| Termux 上重启后端口仍被旧进程占用 | 见「重启」，必须杀 `exec /usr/bin/dsh web` 那个 proot |

---

## 卸载

```bash
dsh-panel-bridge disable
dsh plugin --profile web remove dsh-panel-bridge
# 手工安装过的，再删掉 ~/.dsh/profiles/web/plugins/panel-bridge-*
```

---

## 目录结构

```
bin/dsh-panel-bridge.mjs   CLI（enable / disable / status / qr）
lib/index.js               插件入口（事件总览、审批、二维码、路由注册）
lib/events.js              SSE 事件总线（seq / Last-Event-ID / 心跳）
lib/approvals.js           审批队列（超时 / 接管 / 结算）
lib/devices.js             device token 存储（配对 / 吊销 / 审计）
lib/inject.js              网页桥接脚本
tools/enable.py            早期 python 版挂载脚本（保留兼容）
install.sh                 离线手工安装（无 npm/git 时用）
pair-qr.sh                 早期二维码脚本（等价于 CLI 的 qr）
```

---

## License

MIT
