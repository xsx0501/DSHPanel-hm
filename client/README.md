# client · HarmonyOS NEXT 面板

DSH 的鸿蒙客户端：ArkTS / Stage 模型，目标 `HarmonyOS NEXT`，API 20+。

---

## 构建

前置：DevEco Studio（含 HarmonyOS SDK）。仓库里**没有** `hvigorw` 包装脚本，用它自带的：

| 系统 | hvigor 路径 |
| --- | --- |
| Windows | `"C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat"` |
| macOS | `/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw` |
| Linux | `~/DevEco-Studio/tools/hvigor/bin/hvigorw` |

```bash
export DEVECO_SDK_HOME="/path/to/DevEco-Studio/sdk"   # Windows: 用 setx 或 $env:
cd client
"<hvigor>" --mode module -p product=default -p module=panel@default \
  -p buildMode=debug assembleHap --no-daemon
```

产物：`panel/build/default/outputs/default/panel-default-signed.hap`

> 未配置签名时 hvigor 仍能编译，只是产物叫 `panel-default-unsigned.hap`，**装不上设备**。
> 实测：从本仓库干净拷贝出来构建，产出 `panel-default-unsigned.hap` 668,597 字节。

安装到设备：

```bash
hdc list targets                     # 拿到设备 id
hdc -t <deviceId> install -r panel/build/default/outputs/default/panel-default-signed.hap
```

> **必须签名**。未签名的 HAP 装不上，且下面这些 ACL 权限只有在签名 profile 里声明才会生效。

---

## 签名与权限（重要）

`build-profile.json5` 里的 `signingConfigs` 是**空的**——签名材料因人而异，不入库。请在 DevEco Studio 里：

`File → Project Structure → Signing Configs → 勾选 Automatically generate signature`

然后在你的 ACL 申请材料（profile）里加上这几条：

```json
{ "name": "ohos.permission.USE_FLOAT_BALL",
  "reason": "$string:reason_float_ball",
  "usedScene": { "abilities": ["DSHPanelAbility"], "when": "inuse" } },
{ "name": "ohos.permission.FLOAT_VIEW",
  "reason": "$string:reason_float_view",
  "usedScene": { "abilities": ["DSHPanelAbility"], "when": "inuse" } },
{ "name": "ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM",
  "reason": "$string:reason_bg_system",
  "usedScene": { "abilities": ["DSHPanelAbility"], "when": "inuse" } }
```

`START_ABILITIES_FROM_BACKGROUND` **一般申不下来**（后台拉起 Ability）。没有它时：

- 点悬浮球 → 推送一条可点通知，点通知由系统拉起面板
- 悬浮卡片上的「打开」按钮已移除

---

## 首次使用

1. 宿主机装好插件并在同一网络/公网可达
2. 宿主机执行 `dsh-panel-bridge qr --url https://<域名>` 出二维码
3. 手机 App：底部「更多」→「节点」→「扫码」
4. 连接成功：概览页出现 turn/step，桌面出现悬浮球

---

## 界面结构

| 区域 | 内容 |
| --- | --- |
| 顶部 | 只读信息：标题、会话数、状态胶囊、节点名 |
| 主体 | 可左右滑动的三页：概览 / 会话 / 日志 |
| 底部 | 概览 / 会话 / 日志 / **更多**（工具箱：重连、节点、网页、悬浮球、闪控窗、保活、停止任务） |

---

## 承载形态（L0/L1/L2）

| 层级 | 实现 | 说明 |
| --- | --- | --- |
| L0 | 通知栏 | 进度通知；审批通知带「允许 / 拒绝」ActionButton |
| L1 | 悬浮球 | 两行文本（大字进度 + 小字会话），前台创建、后台常驻 |
| L2 | 闪控窗 | 与球 bind 后由系统展开；卡片显示会话、`T·S`、会话数、待审批、最近 3 条事件 |

平台限制与踩坑记录见仓库根 README 的「已知平台限制」。

---

## 目录

```
client/
├── AppScope/            应用级配置与图标
├── panel/
│   └── src/main/
│       ├── ets/
│       │   ├── pages/           Index / FloatCard / Nodes / Browse
│       │   ├── presenter/       悬浮球、闪控窗、保活、通知
│       │   ├── domain/          SSE 事件流、遥测
│       │   ├── net/             API 客户端、SSE 解析
│       │   ├── store/           节点与卡片状态
│       │   └── probe/           能力探测
│       ├── resources/
│       └── module.json5
├── build-profile.json5   签名配置留空，需自行生成
└── hvigorfile.ts
```
