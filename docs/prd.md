# DeepSeek Harness 鸿蒙客户端（DS-Harness-HM）详细场景化 PRD

**文档版本**：v2.0（面向架构与方案设计基线版）

**目标平台**：HarmonyOS NEXT（API 12+，手机/折叠屏优先，兼容平板）

**核心架构约束**：`ArkWeb` 容器退后台后 Chromium 渲染线程会被系统挂起；普通全局悬浮窗权限在手机端受限。方案设计必须基于 **「UI 容器（ArkWeb）+ 独立通信工作线程（ArkTS Worker / Native NAPI）+ 闪控窗球联动（`floatView` & `floatingBall`）+ 长时任务（Continuous Task）」** 的解耦架构。

## 一、 全局状态机与数据分布矩阵（方案设计基线）

在进入具体业务场景前，方案设计需确立客户端的 **三维正交状态机** 与 **跨线程数据存储矩阵**，确保前台 Web、后台 Worker 与原生悬浮窗三者状态绝对一致。

### 1.1 三维正交状态机定义

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. 节点连接态 (ConnectionState) - 由后台 Worker 线程维护主状态          │
│    DISCONNECTED ──(导入/激活)──> HANDSHAKING ──(200 OK)──> CONNECTED     │
│         ▲                            │                         │        │
│         └──(401/403 Token失效)───────┴──(网络闪断)──> RECONNECTING      │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. 任务执行态 (TaskState) - 由 SSE/WS 事件流驱动                        │
│    IDLE ──(发起/接管任务)──> RUNNING ──(触发高危Tool)──> WAITING_APPROVAL│
│     ▲                         │  ▲                             │        │
│     └──(确认已读/重置)── COMPLETED/ERROR ◄──(批准/拒绝/超时)───┘        │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. 视图展现态 (PresentationState) - 由 UIAbility 与 WindowManager 驱动  │
│    FOREGROUND_WEB (主界面全屏交互，悬浮窗隐藏)                          │
│         │ (onBackground 且 TaskState != IDLE)                           │
│         ▼                                                               │
│    BACKGROUND_BALL (闪控球贴边吸附，显示简明状态/进度)                  │
│         │ (用户单击闪控球 或 触发 WAITING_APPROVAL 自动弹出)            │
│         ▼                                                               │
│    BACKGROUND_CARD (闪控窗展开卡片，显示流式摘要与快捷审批按钮)         │
│         │ (用户手动关闭悬浮球/窗 且 任务仍在运行)                       │
│         ▼                                                               │
│    BACKGROUND_LIVEVIEW (降级为系统实况窗/灵动胶囊 + 后台长时任务兜底)   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 核心数据存储与跨线程共享矩阵

| **数据类别**         | **关键字段**                                                 | **存储介质**                                                | **读写线程与同步机制**                                       | **安全与生命周期要求**                                       |
| -------------------- | ------------------------------------------------------------ | ----------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **高敏凭据**         | `authToken`, `clientCertPassword`                            | `@ohos.security.asset` (TEE 关键资产存储)                   | 主线程读写；通过 `Worker.postMessage` 按需下发内存态给 Worker | 严禁明文落盘至 Preferences 或日志；支持硬件级加密与卸载保留配置 |
| **节点与同步配置**   | `nodeId`, `endpoint`, `wsEndpoint`, `workspaceId`, `modelProfile`, `approvalRules`, `customHeaders` | `@ohos.data.preferences` (用户首选项)                       | 主线程读写，变更时广播通知 Worker 与 ArkWeb                  | 导入链接握手成功后立即持久化；按 `nodeId` 隔离多套环境       |
| **实时任务遥测状态** | `taskId`, `taskState`, `stepCurrent`, `stepTotal`, `currentTool`, `confirmPayload`, `tokenSpeed` | `AppStorage` (全局响应式状态中心)                           | Worker 解析流后上报主线程更新 `AppStorage`；主界面与 `floatView` 悬浮窗通过 `@StorageProp` 自动响应式刷新 | 内存态维护，无需每次变动落盘                                 |
| **后台流式增量缓存** | `RingBuffer` (后台期间收到的 SSE Chunk 队列)                 | Native / Worker 内存环形缓冲区 + `RelationalStore` (SQLite) | Worker 写入；当 `PresentationState != FOREGROUND_WEB` 时暂停向 Web 推送高频 DOM 更新，切回前台时批量 Flush | 环形缓冲区上限 2MB（超出则丢弃最旧中间态，仅保留关键 Step 事件）；完整事件流异步落盘 SQLite 供离线复盘 |

## 二、 核心业务场景详细需求（端到端设计指导）

### 场景 1：带 Token 的 DSH 网址导入与全链路自动同步

- **场景目标**：用户从 PC 浏览器、终端或聊天软件获取一条带 Token 的链接后，客户端在 1 秒内完成解析、远端配置拉取、本地安全存储与 `ArkWeb` 免登注入，直接进入可用工作区。
- **触发入口**：
  1. **系统级 DeepLink 唤起**：点击 `dsh://connect?...` 或 `dsh://import/...` 链接触发 `EntryAbility.onCreate` / `onNewWant`。
  2. **前台剪贴板智能嗅探**：`EntryAbility.onForeground` 触发剪贴板正则检测，匹配成功弹出半模态导入确认卡片。
  3. **地址栏直接粘贴 / 扫码导入**：在节点管理页粘贴 `https://host/path?token=xxx` 或扫描终端二维码。

#### 1.1 主流程与系统行为（Main Flow）

```
[外部输入 URI]
   │
   ├─► 1. URI 规范化解析 (DshUriParser)
   │      • 提取: endpoint, rawToken, workspaceId, customHeaders, ignoreSslError
   │      • 生成干净 Web URL (剥离 query/hash 中的 token 参数，防止泄露至浏览历史)
   │
   ├─► 2. 原生层预握手与配置拉取 (Native Bootstrap)
   │      • 由原生 HTTP 模块携带 Authorization: Bearer {rawToken} 请求远端配置探针
   │      • 拉取项: 远端工作区列表、默认模型参数、高危 Tool 审批正则、当前活跃 Task 快照
   │
   ├─► 3. 凭据加密与配置落盘
   │      • rawToken 写入 ASSET (Key: "dsh_token_{nodeId}")
   │      • 节点元数据与远端同步配置写入 Preferences
   │
   ├─► 4. ArkWeb 免登环境预置 (严格按生命周期时序执行)
   │      • Step 4.1 [loadUrl 前]: WebCookieManager.configCookieSync 写入鉴权 Cookie
   │      • Step 4.2 [onPageBegin]: runJavaScript 注入 localStorage (Token + Workspace + 配置快照)
   │      • Step 4.3 [onInterceptRequest]: 拦截同源 API 请求，自动补齐 Authorization 与自定义穿透 Header
   │
   └─► 5. 后台 Worker 监听通道初始化
          • 主线程向 Worker 发送 INIT_NODE 指令，建立常驻状态监听
```

#### 1.2 方案设计约束与边界条件（Design Constraints & Edge Cases）

| **编号**  | **异常/边界场景**                                        | **系统处理策略与设计要求**                                   |
| --------- | -------------------------------------------------------- | ------------------------------------------------------------ |
| **E-1.1** | **前端框架路由守卫早于 JS 注入执行（闪现登录页）**       | **设计强约束**：严禁等到 `onPageEnd` 才注入 Token。必须同时使用：① `loadUrl` 前预置 Cookie；② 在 `Web` 组件挂载时通过 `javaScriptOnDocumentStart`（文档开始解析但未执行前端脚本前）注入 `localStorage.setItem` 脚本，保证前端 React/Vue 初始化读取时 Token 100% 存在。 |
| **E-1.2** | **导入重复节点（Host + Workspace 相同，但 Token 更新）** | 按 `sha256(endpoint + workspaceId)` 生成唯一 `nodeId`。若已存在相同 `nodeId`，判定为 **“凭据热更新”**：直接覆盖 `ASSET` 中的 Token，刷新远端配置，不新建冗余节点卡片，并弹出 Toast *“已更新节点 [别名] 的访问凭据与配置”*。 |
| **E-1.3** | **内网自签名 HTTPS 证书报错**                            | 若导入链接带 `insecure=1` 或用户在弹窗中点击“信任此内网证书”，在 `ArkWeb` 的 `onSslErrorEventReceive` 中匹配当前 `host` 并调用 `event.handler.handleConfirm()`；同时在 Worker 原生网络请求中关闭针对该 Host 的 SSL 证书链强校验。 |
| **E-1.4** | **Web 端内部主动修改了配置或切换了工作区**               | 通过 `javaScriptOnDocumentStart` 注入 `Storage.prototype.setItem` 代理拦截器。当监听到 Web 前端修改了工作区 ID、模型配置或 Token 时，立即通过 `HarmonyHarnessBridge.onWebConfigMutated(key, val)` 反向同步至原生 `Preferences` 与 Worker 线程，防止双向状态分裂。 |

### 场景 2：PC/云端存量长任务的无缝跨端接管

- **场景目标**：用户在电脑端启动了一个耗时 20 分钟的 DeepSeek Harness 任务（如大规模代码重构或自动化测试），随后复制带 Token 的网址到鸿蒙手机端打开（或直接打开已配对的客户端），手机端无需重新发起任务，自动发现并接管正在运行的任务流。
- **前置条件**：节点握手成功（`ConnectionState == CONNECTED`）。

#### 2.1 主流程与系统行为

1. **活跃任务探测**：节点握手接口（或紧随其后的 `GET /api/v1/tasks?status=active`）返回当前正在运行的 `activeTaskId`、当前步骤 `stepCurrent/stepTotal`、最后一条事件游标 `lastEventId` 以及任务所属会话 URL。
2. **Web 容器自动深链跳转**：若当前 `ArkWeb` 停留在首页，原生层自动拼接任务详情路由（如 `${endpoint}/tasks/${activeTaskId}`）控制 `ArkWeb` 跳转至对应会话页面。
3. **Worker 独立挂载事件流**：后台 Worker 携带 `Last-Event-ID: ${lastEventId}` 与 `Authorization` Header，独立连接至该任务的 SSE/WebSocket 状态流，更新全局 `AppStorage` 中的 `TaskState = RUNNING`。
4. **顶部接管提示条**：界面顶部浮现轻量化胶囊提示：*“已无缝接管云端运行中任务（Step 4/12），切至后台将自动开启悬浮窗监控”*。

### 场景 3：切后台自动保活与“闪控球/闪控窗”双态联动

- **场景目标**：当存在活跃任务时，用户将应用切至后台（回桌面、切微信、刷视频），客户端网络流零中断，并通过鸿蒙原生 `floatView`（闪控窗）与 `floatingBall`（闪控球）实时展示任务进度；当没有活跃任务时切后台，不打扰用户、不空耗电量。

#### 3.1 前后台切换时序设计（方案核心）

```
[用户手势返回桌面 / 切换应用]
       │
       ▼
[EntryAbility.onBackground() 触发]
       │
       ├─► 判断 TaskState 是否为 RUNNING 或 WAITING_APPROVAL？
       │     ├─► [否 (IDLE / COMPLETED)]: 不申请保活，不弹悬浮窗，允许系统正常挂起进程。
       │     └─► [是 (存在活跃任务)]: 执行以下 4 步保活与流转动作 ──┐
       │                                                            ▼
       ├─► 1. 启动长时任务兜底 (ContinuousTaskManager)
       │      • 调用 backgroundTaskManager.startBackgroundRunning(DATA_TRANSFER)
       │
       ├─► 2. 切换流式数据路由 (降频保护 ArkWeb)
       │      • 向 Worker 发送 ENTER_BACKGROUND 指令
       │      • Worker 停止通过 JSBridge 向 ArkWeb 高频推送 Token 增量 (防止后台 Web 高 CPU 被系统强杀)
       │      • Worker 改为将流式数据写入原生 RingBuffer，仅按 2Hz (每500ms最多1次) 更新 AppStorage 驱动悬浮窗 UI
       │
       └─► 3. 拉起闪控球与绑定闪控窗 (FloatWindowController)
              • 初始化 floatingBall 与 floatView 控制器并执行 bind() 联动
              • 默认以【闪控球态】贴边展示：旋转进度环 + "Step 4/10"
```

#### 3.2 闪控球（`floatingBall`）与闪控窗（`floatView`）五态交互规格

| **任务状态 (TaskState)**            | **闪控球态（贴边小胶囊/球）视觉表现**                        | **闪控窗态（点击展开卡片）内容与操作项**                     | **触觉与系统通知配合**                          |
| ----------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ----------------------------------------------- |
| **RUNNING** (思考/执行中)           | 蓝色呼吸流光边框 + 当前步骤号（如 `4/10`）或旋转动效         | • **标题栏**：节点别名 + 已耗时计时器 `03:42` • **动作区**：当前 Tool 图标 + 摘要（如 `[Bash] npm run build`） • **日志窗**：最近 2 行输出（单行截断，等宽字体） • **底部操作**：`[中断任务]`、`[回到主界面]` | 静默更新，无震动                                |
| **WAITING_APPROVAL** (等待人工审批) | **琥珀色高频闪烁** + 盾牌感叹号图标；**支持配置自动展开为闪控窗态** | • **高亮告警栏**：*“Agent 请求执行敏感操作”* • **指令详情框**：滚动展示待执行的完整命令或修改文件路径（如 `rm -rf ./dist`） • **核心操作按钮**：**[允许执行 (Approve)]**（绿色主按钮）、**[拒绝 (Reject)]**（红色次按钮）、**[允许本会话同类操作]** | 触发 `@ohos.vibrator` 双次强提醒震动 + 锁屏提醒 |
| **COMPLETED** (执行完成)            | 绿色实心勾选图标，保持 5 秒后自动收缩半透明隐入边缘（或按配置自动关闭） | • **完成摘要**：总耗时 `05:12` + 消耗 Token 统计 • **产物预览**：修改文件数 / 测试通过率摘要 • **底部操作**：`[查看完整报告]`（点击直接拉起主 App 并销毁悬浮窗） | 触发清脆短促单次成功震动                        |
| **ERROR / INTERRUPTED** (异常中止)  | 红色常亮感叹号图标                                           | • **错误原因**：如 `Tool Execution Timeout` 或 `SSH 节点断开` • **底部操作**：`[重试当前 Step]`、`[回到主界面排查]` | 触发长震动告警 + 系统通知栏持久化卡片           |

#### 3.3 切回前台恢复时序（`onForeground` 补偿同步）

1. 用户点击悬浮窗上的“回到主界面”或从桌面图标切回 App，触发 `EntryAbility.onForeground()`。
2. **销毁/隐藏悬浮窗与停止长时任务**：调用 `stopFloatingBall()` 并释放 `ContinuousTask`。
3. **RingBuffer 批量补偿同步**：
   - 若 Worker 与服务端直接通信：Worker 将后台期间暂存在 `RingBuffer` 中的增量事件一次性打包，通过 `HarmonyHarnessBridge.flushBackgroundEvents(batchJson)` 注入 `ArkWeb`，前端一次性合并状态并滚动到底部，避免逐个 Token 补发造成主界面卡顿。
   - 若前端自身依赖服务端状态同步：触发前端轻量级 `syncSessionState()` 接口拉取最新快照。

### 场景 4：高危动作拦截与悬浮窗快捷审批闭环（Out-of-App HITL）

- **场景目标**：用户在其他 App（如微信聊天或阅读文档）时，DeepSeek Harness Agent 触发了需要人工确认的操作（Human-in-the-Loop），用户无需切换应用，直接在悬浮窗点击“批准”或“拒绝”，1 秒内完成指令下发并恢复任务流。

#### 4.1 方案设计关键链路（绕过后台冻结的 ArkWeb）

- **设计红线**：当应用在后台时，用户在闪控窗（`floatView`）点击 **「允许执行 (Approve)」**，**绝对不能依赖调用 `ArkWeb.runJavaScript()` 让网页去发请求**（因为此时 `ArkWeb` 渲染进程可能处于系统冻结状态，JS 不会立即执行）。
- **正确架构路径**：
  1. 闪控窗 UI 组件点击“批准”按钮后，直接向 **后台 Worker 线程** 发送 `ACTION_APPROVAL_DECISION` 消息（携带 `taskId`, `confirmId`, `decision: 'APPROVE'`）。
  2. **Worker 线程直接通过原生 HTTP/WebSocket**，携带缓存的 `authToken` 向 Harness 服务端发送审批确认请求（`POST /api/v1/tasks/${taskId}/confirm`）。
  3. 服务端收到确认后继续推送后续 SSE 事件流，闪控窗状态在 200ms 内无缝切回 `RUNNING` 并自动收起为闪控球，全程零应用切换、零 Web 唤醒延迟。
  4. 同时将审批记录压入 `RingBuffer`，待用户稍后切回前台时，同步更新 `ArkWeb` 界面上的按钮状态为“已批准”。

### 场景 5：被动嗅探模式（针对不修改 Harness 原网页源码的兼容方案）

- **场景背景**：若连接的 DeepSeek Harness 服务端是标准开源版或第三方部署版，并未专门开发 `/api/v1/harness/bootstrap` 原生探针接口，也未在前端源码中主动调用 `window.HarmonyHarnessBridge`。

- **方案设计要求（零侵入 Proxy 注入引擎）**：

  通过在 `ArkWeb` 的 `javaScriptOnDocumentStart` 阶段注入 **「无侵入式 Fetch / EventSource / WebSocket 劫持与转发脚本」**，实现全自动状态提取：

```
┌────────────────────────────────────────────────────────────────────────┐
│ ArkWeb 页面内部 (注入 HarmonyMonkeyPatch.js)                           │
│                                                                        │
│ 1. 劫持 window.fetch & window.EventSource & window.WebSocket           │
│ 2. 当识别到请求匹配 SSE 流特征 (Content-Type: text/event-stream) 时：  │
│    • 若处于前台 (FOREGROUND)：正常放行给前端渲染，同时将每个 chunk     │
│      旁路镜像 (Tee Stream) 发送给 HarmonyHarnessBridge.onRawChunk()    │
│    • 若即将退后台：将请求的 URL、Headers、Body 序列化移交给原生 Worker │
│      由 Worker 在后台维持连接或轮询任务状态 API                        │
│ 3. DOM 兜底嗅探 (MutationObserver)：                                   │
│    • 监听页面中的关键状态 DOM 节点（如 Stop 按钮、Confirm 弹窗容器）   │
│    • 实时映射为 RUNNING / WAITING_APPROVAL / IDLE 状态上报原生层       │
└────────────────────────────────────────────────────────────────────────┘
```

### 场景 6：异常自愈与降级兜底场景

| **场景编号** | **触发场景描述**                                             | **系统自愈与降级行为设计**                                   |
| ------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **R-01**     | **看视频/打游戏时用户嫌悬浮球遮挡，手动点击了悬浮窗的「×」关闭按钮，但任务仍在运行** | **自动降级为实况窗（Live View）**：捕获 `floatingBall` 关闭回调，若 `TaskState == RUNNING`，不终止后台保活，而是立即调用 `@ohos.liveViewManager` 创建系统级 **实况窗（状态栏灵动胶囊 + 通知栏实况卡片）**，并在胶囊内显示进度百分比；同时弹出 Toast *“已为您切换至状态栏实况胶囊监控”*。 |
| **R-02**     | **进出电梯、Wi-Fi 切蜂窝网络导致后台 SSE/WS 断开**           | **原生网络监听与指数退避重连**：Worker 订阅 `@ohos.net.connection` 网络状态变化。断网时闪控球显示“黄色断连重试”角标（不立即置为 `ERROR` 打扰用户）；网络恢复或按 `1s → 2s → 4s → 8s` 退避周期重连成功后，携带 `Last-Event-ID` 续接流，闪控球自动恢复为蓝色运行态。 |
| **R-03**     | **任务执行中途 Token 过期（收到 401/403）**                  | 闪控球切换为 **橙色钥匙闪烁图标**。用户点击展开闪控窗，直接展示 **「粘贴并更新 Token」** 安全控件按钮（`<PasteButton>`）。点击后直接读取剪贴板中的新 Token 或新 DSH 链接，热更新 `ASSET` 与 Worker 内存并原地恢复连接，无需重新打开主界面。 |
| **R-04**     | **系统内存极度紧张，后台进程被鸿蒙管控强杀**                 | **状态恢复自检（Crash / Kill Recovery）**：每次 Worker 收到任务状态变更时，将 `activeTaskId` 与 `nodeId` 写入轻量级 `Preferences`。当用户再次点击桌面图标冷启动 App 时，`EntryAbility.onCreate` 检测到上次存在未闭环的 `activeTaskId`，立即触发【场景 2】自动重连远端查询该任务的最终结果（已完成或仍在运行），并在顶部提示恢复结果。 |

## 三、 核心接口与跨模块通信契约（指导详细编码设计）

### 3.1 主线程 ↔ Worker 线程通信协议（`WorkerMessageProtocol.ts`）

方案设计必须严格通过强类型消息枚举隔离 UI 主线程与网络保活 Worker 线程：

TypeScript

```
// 主线程 -> Worker 的控制指令
export type MainToWorkerCmd =
  | { type: 'INIT_NODE'; payload: { nodeId: string; endpoint: string; token: string; headers?: Record<string, string>; ignoreSsl?: boolean } }
  | { type: 'ATTACH_TASK_STREAM'; payload: { taskId: string; streamUrl: string; lastEventId?: string } }
  | { type: 'SET_APP_LIFECYCLE'; payload: { isBackground: boolean } }
  | { type: 'SUBMIT_APPROVAL'; payload: { taskId: string; confirmId: string; decision: 'APPROVE' | 'REJECT'; rememberRule?: boolean } }
  | { type: 'ABORT_TASK'; payload: { taskId: string } }
  | { type: 'DISCONNECT_NODE' };

// Worker -> 主线程的状态与事件上报
export type WorkerToMainEvent =
  | { type: 'NODE_HANDSHAKE_RESULT'; payload: { success: boolean; syncedConfig?: RemoteHarnessConfig; activeTaskId?: string; errorMsg?: string } }
  | { type: 'TASK_TELEMETRY_UPDATE'; payload: TaskTelemetrySnapshot } // 驱动 AppStorage 与悬浮窗刷新
  | { type: 'FLUSH_RING_BUFFER'; payload: { taskId: string; chunks: string[] } } // 切回前台时批量回放给 ArkWeb
  | { type: 'AUTH_TOKEN_EXPIRED'; payload: { nodeId: string; httpStatus: number } };
```

### 3.2 任务遥测快照数据结构（`TaskTelemetrySnapshot`）

该结构直接绑定至鸿蒙 `AppStorage`，供主界面状态栏、闪控球、闪控窗以及系统实况窗（Live View）共享订阅：

TypeScript

```
export interface TaskTelemetrySnapshot {
  nodeId: string;
  nodeName: string;
  taskId: string;
  status: 'IDLE' | 'RUNNING' | 'WAITING_APPROVAL' | 'COMPLETED' | 'ERROR';
  stepCurrent: number;
  stepTotal: number;
  elapsedSeconds: number;
  tokenSpeed: number;           // tokens/s
  currentToolName?: string;     // 如 "bash", "write_file", "search_code"
  currentActionSummary: string; // 如 "Executing: hvigorw assembleHap --mode module"
  latestLogLines: string[];     // 固定保留最近 2~3 行脱敏后的流式输出摘要
  pendingConfirmation?: {
    confirmId: string;
    toolName: string;
    riskLevel: 'MEDIUM' | 'HIGH' | 'CRITICAL';
    commandOrDiffPreview: string; // 闪控窗内展示的待审批命令详情
    timeoutSeconds?: number;
  };
  errorMessage?: string;
  updatedAt: number;
}
```

## 四、 非功能性指标与鸿蒙系统红线（NFR & Guardrails）

在进场编写架构设计与代码前，技术方案必须满足以下系统级约束：

1. **后台 CPU 与功耗防杀红线**：
   - 鸿蒙 NEXT 的后台资源管控模块会监控申请了 `DATA_TRANSFER` 长时任务的应用。若应用在后台期间持续产生高 CPU 占用（例如 `ArkWeb` 持续重绘 Markdown DOM 树），会被系统判定为异常耗电并强杀。
   - **架构强约束**：进入 `onBackground()` 后，必须切断高频 Token 增量向 `ArkWeb` 的实时桥接（或向 Web 注入 `window.__DSH_PAUSE_RENDER__ = true` 挂起前端虚拟列表渲染），后台阶段仅允许 Worker 线程解析流并以 **不超过 2Hz（每 500ms 一次）** 的频率节流（Throttle）更新 `floatView` 悬浮窗 UI。
2. **后台保活真伪校验（防系统回收）**：
   - `DATA_TRANSFER` 类型的长时任务要求应用在后台期间确实存在活跃的网络 Socket 流量或通知栏进度更新。Worker 线程需维持与 DeepSeek Harness 服务端的 SSE 心跳包（如每 15 秒一次 `: ping\n\n`），同时联动更新通知栏/实况窗进度，确保符合系统保活审计策略。
3. **闪控窗（`floatView`）尺寸与交互合规**：
   - 遵循鸿蒙系统对闪控窗的模板规范，闪控窗展开态仅放置高密度核心信息与最多 3 个高优操作按钮（批准、拒绝、回主端），避免在闪控窗内嵌套复杂滚动列表或二次弹窗（手势冲突）。

## 五、 研发交付物拆分清单（指导下一步方案设计）

基于本场景化 PRD，后续技术方案设计与编码可拆分为以下 **4 个高内聚模块（Sub-Specs）**：

1. **`Mod-UriSync`（链接解析与配置同步模块）**：负责 `DshUriParser`、`ASSET` 硬件加密存取、`Preferences` 多节点管理，以及 `ArkWeb` 的 Cookie / `javaScriptOnDocumentStart` 免登预注入。
2. **`Mod-StreamWorker`（独立流式保活与代理 Worker）**：负责运行在独立线程的 SSE/WebSocket 客户端、后台 `RingBuffer` 节流缓冲、断网指数退避重连，以及绕过 Web 直接发送 HITL 审批请求。
3. **`Mod-FloatKeepAlive`（窗球联动与长时任务模块）**：负责 `EntryAbility` 前后台生命周期拦截、`floatingBall` 与 `floatView` 的绑定与五态 UI 渲染、`ContinuousTask` 启停，以及悬浮窗关闭后向 `LiveView`（实况窗）的无缝降级。
4. **`Mod-WebBridge`（ArkWeb 容器与无侵入嗅探脚本）**：负责双向 `JSBridge` 注册、前端 `fetch/EventSource` 旁路劫持注入脚本（兼容未改源码的 Harness 服务端），以及切回前台时的 `RingBuffer` 批量补偿同步。