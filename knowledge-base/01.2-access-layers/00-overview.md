# 00 — 接入层(Access Layers)总览

> 用户、客户端、外部工具、渠道平台如何接入 OpenClaw?本章用组件视角讲清楚所有接入方式如何汇聚到 Gateway,以及彼此的协议差异与认证关系。

## 一句话定位

接入层是 OpenClaw 与外部世界的**全部入口集合**:
- 所有接入最终汇聚到一个根:Gateway HTTP/WS Server
- 14 类接入方式覆盖 CLI、浏览器、原生 App、外部工具、渠道平台
- 统一认证面 + 统一 ClientId 注册表 + 统一协议版本管理
- 渠道插件(25+)与原生 App 都通过 Gateway WS 协议接入

## 全局协作图

下图展示所有外部客户端如何汇聚到 Gateway,以及 Gateway 内部如何分流到各子系统。**先看这张图建立心智模型**。

```
                          用户/客户端
                              │
        ┌─────────────┬───────┼───────┬─────────────┐
        │             │       │       │             │
        ▼             ▼       ▼       ▼             ▼
   CLI 入口      浏览器     原生App  外部工具       渠道平台
   (终端)       Control UI iOS/Mac/ OpenAI/MCP  Telegram/
                (HTTP+WS)  Linux/   Compat/     Slack/
                           Android  OpenResp/   Discord/
                                    MCP Loop    WhatsApp...
        │             │       │       │             │
        │             └───────┴───────┘             │
        │                     │                     │
        │                     ▼                     │
        │           ┌──────────────────────┐         │
        │           │ Gateway HTTP/WS      │         │
        │           │ Server (根)         │         │
        │           │                      │         │
        │           │ 同时承载:           │         │
        │           │ • HTTP 路由          │         │
        │           │   (UI/OpenAI/MCP/   │         │
        │           │    插件/hooks)      │         │
        │           │ • WS upgrade        │         │
        │           │   (Gateway/Worker) │         │
        │           └────┬─────────┬────┘         │
        │                │         │               │
        │         ┌──────┘         └──────┐         │
        │         │                       │         │
        │         ▼                       ▼         │
        │  ┌──────────────┐     ┌──────────────┐   │
        │  │ Gateway WS    │     │ Worker WS     │   │
        │  │ 协议          │     │ 子协议        │   │
        │  │               │     │               │   │
        │  │ (RPC + 事件)  │     │ (独立 upgrade)│   │
        │  └──────┬────────┘     └──────┬───────┘   │
        │         │                       │          │
        │         └──────────┬────────────┘          │
        │                    │                       │
        │                    ▼                       │
        │         ┌──────────────────────┐            │
        │         │   统一认证面         │            │
        │         │                      │            │
        │         │ • Bearer token       │            │
        │         │ • Password          │            │
        │         │ • Tailscale          │            │
        │         │ • Device token       │            │
        │         │ • Bootstrap token    │            │
        │         │ • Trusted proxy     │            │
        │         │ • None              │            │
        │         └──────────────────────┘            │
        │                    │                       │
        │         ┌──────────┴────────────┐         │
        │         │                       │         │
        │         ▼                       ▼         │
        │  ┌──────────────┐     ┌──────────────┐   │
        │  │ Lane 调度    │     │ Channel Turn │◄──┘
        │  │ → Agent Run  │     │ 内核         │
        │  └──────────────┘     └──────────────┘
        │
        ▼
   Commander 分发
   (进入业务逻辑)
```

## 组件清单

接入层由 5 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Gateway HTTP/WS Server** | 所有接入的统一汇聚点,承载 HTTP 路由与 WS upgrade | 同时支持两类 WS 协议:Gateway 协议与 Worker 子协议 |
| **统一认证面** | 7 种认证方式归一为单一结果对象 | 所有接入必须经过认证,无认证旁路 |
| **ClientId 注册表** | 16 类客户端身份的中央登记 | 新增客户端类型必须在此注册 |
| **协议版本管理** | Gateway/Worker/Node/Probe 各有协议版本下限 | 版本 bump 需 owner 显式确认 |
| **Channel 转接器** | 渠道插件把各平台消息转成 OpenClaw 内部格式 | 插件只能 transport-only,不做业务 |

## 关联关系

### 3 类接入方式的协作

```
   ┌──────────────────────────────────────────────────────┐
   │ 类型 A:直接 HTTP/WS 接入                            │
   │                                                      │
   │ • CLI(通过 Layer 1-7 启动链路)                     │
   │ • Control UI(浏览器,HTTP + WS)                    │
   │ • OpenAI Compatible REST(HTTP /v1/*)                │
   │ • OpenResponses REST(HTTP /v1/responses)            │
   │ • MCP Loopback(HTTP + JSON-RPC,仅 127.0.0.1)        │
   │ • MCP App Standalone(HTTP,HMAC ticket)              │
   │ • Plugin HTTP/Upgrade(插件自定义路由)             │
   │ • Node Host(WS + node.invoke.* RPC)                │
   │ • Probe(WS,轻量健康探测)                          │
   │                                                      │
   │   → 全部直接打到 Gateway HTTP/WS Server              │
   └──────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────┐
   │ 类型 B:通过渠道插件接入                            │
   │                                                      │
   │ • Telegram / WhatsApp / LINE / Slack / Discord       │
   │ • SMS / IRC / Google Chat / Synology Chat            │
   │ • Matrix / iMessage / Email / ...                    │
   │                                                      │
   │   → 渠道插件转成内部格式 → 提交 Turn 内核           │
   │   → 渠道插件只做 transport-only,不持业务逻辑        │
   └──────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────┐
   │ 类型 C:通过 SDK 接入(插件作者)                   │
   │                                                      │
   │ • 插件作者通过 openclaw/plugin-sdk/* 访问核心        │
   │ • 数百个 *-runtime.ts 懒加载接缝                    │
   │ • 注册 Provider / Tool / Channel / Hook              │
   │                                                      │
   │   → 插件通过 SDK 边界注册能力,运行时由核心调度      │
   └──────────────────────────────────────────────────────┘
```

### 协议版本与客户端身份的层级

```
                PROTOCOL_VERSION = 4
                        │
        ┌───────────────┼───────────────────────┐
        │               │                       │
        ▼               ▼                       ▼
  Gateway 客户端    Worker 子协议          Node Host
  (协议 ≥4)        (协议 ≥4)              (协议 ≥3)
        │               │                       │
        │               │                       │
        ▼               │                       ▼
  ┌──────────────────┐ │                ┌──────────────┐
  │ ClientId 注册表  │ │                │ Probe         │
  │ (16 类客户端)    │ │                │ (协议 ≥3)     │
  │                  │ │                └──────────────┘
  │ • webchat-ui     │ │
  │ • control-ui     │ │
  │ • browser-ext    │ │
  │ • tui            │ │
  │ • cli            │ │
  │ • gateway-client │ │
  │ • macos/linux    │ │
  │ • ios/watchos    │ │
  │ • android        │ │
  │ • node-host      │ │
  │ • worker         │ │
  │ • probe          │ │
  │ • test/fingerprint│ │
  └──────────────────┘ │
                       │
                       ▼
                   Worker 接入
                   (openclaw-worker)
```

### 认证面的 7 种方式

```
   所有接入 ──► 统一认证面 ──► 归一结果(GatewayAuthResult)

   ┌──────────────────────────────────────────────────┐
   │ 7 种认证方式                                     │
   │                                                  │
   │ 1. none           无需认证(loopback)             │
   │ 2. token          Bearer token(用户长期凭证)    │
   │ 3. password       密码(基础认证)                │
   │ 4. tailscale      Tailscale 网络身份             │
   │ 5. device-token   设备长期凭证(原生 App)        │
   │ 6. bootstrap-token 一次性引导 token              │
   │ 7. trusted-proxy  信任的反向代理                 │
   │                                                  │
   │ → 所有方式归一为单一 result,后续逻辑无需区分    │
   └──────────────────────────────────────────────────┘
```

## 协作流程

### 一次 WebSocket 接入的完整旅程

下面追踪一个原生 App(如 iOS App)通过 WS 接入 Gateway 的全过程。

```
iOS App 启动,连接 Gateway
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. WebSocket 握手                                            │
│    • 发起 WS upgrade 请求                                    │
│    • 携带 ClientId: openclaw-ios                             │
│    • 携带 Protocol-Version: 4                                │
│    • 携带 Auth: Bearer <device-token>                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Gateway HTTP/WS Server 接收                              │
│    • 路由到 WS upgrade handler                               │
│    • 检查 ClientId 是否在注册表中(openclaw-ios ✓)           │
│    • 检查协议版本(>= 4 ✓)                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 统一认证面                                                │
│    • 解析 Authorization header                              │
│    • 走 device-token 认证                                    │
│    • 校验 token 有效性                                       │
│    • 产出 GatewayAuthResult(method=device-token, ...)       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. WS 连接建立                                               │
│    • 升级为 WebSocket 连接                                   │
│    • 绑定到 Gateway WS 协议                                  │
│    • 注册到客户端连接表                                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 业务交互                                                  │
│    • App 发送 RPC 请求(如 agent.run)                       │
│    • Gateway 通过 Lane 调度到 Agent Runner                  │
│    • 流式返回事件给 App                                      │
│    • App 渲染 UI                                            │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Channel 接入的完整旅程

下面追踪一条 Telegram 消息从 Bot 平台到 Agent 的全过程。

```
用户在 Telegram 发消息 "帮我写代码"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Telegram Bot 平台推送                                    │
│    • 通过 webhook 推送到 Telegram 插件                       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Telegram 插件(extensions/telegram/)                     │
│    • 收到 Bot 平台原始消息                                  │
│    • 转成 OpenClaw 内部消息格式                             │
│    • 提交给 Channel Turn 内核                               │
│    (插件只做 transport-only 转换,不做业务)                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Channel Turn 内核                                         │
│    • 接收消息                                                │
│    • 判断 Admission 策略:                                   │
│      ├─ dispatch      → 走 Agent                            │
│      ├─ observeOnly   → 仅观察                              │
│      ├─ handled       → 插件已处理                          │
│      └─ drop          → 丢弃                               │
│    • 持久化投递(防丢失)                                    │
│    • 防死循环(bot-loop-protection)                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Gateway → Agent Runner                                  │
│    • Lane 调度器分配 lane                                   │
│    • Agent Runner 处理消息                                  │
│    • 调用 LLM + 工具                                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 回复分发                                                  │
│    • 回复派发 Hook 触发                                      │
│    • Telegram 插件收到回复                                  │
│    • 转成 Telegram 格式发回用户                             │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 所有接入汇聚到一个根

- **根**:Gateway HTTP/WS Server
- **作用**:统一认证、统一并发控制、统一可观测性、统一状态库
- **反例**:每个渠道插件各自调用 Agent Runner,会重复实现认证、并发、可观测

### 2. 渠道插件只能 transport-only

- 渠道插件只做:渲染展示、动作映射、传输限制、回调映射
- **禁止**:渠道插件持有产品命令树、provider policy、feature-specific 菜单
- **目的**:核心保持渠道无关,新增渠道不改核心

### 3. 认证面归一为单一结果

- 7 种认证方式归一为 GatewayAuthResult
- 后续逻辑无需区分 token/password/tailscale
- **禁止**:在业务代码里判断具体认证方式

### 4. ClientId 必须在注册表登记

- 16 类客户端身份有中央注册表
- 新增客户端类型必须在此注册
- **目的**:可观测性、协议版本协商、客户端能力识别

### 5. 协议版本 bump 是重大决策

- PROTOCOL_VERSION = 4
- Worker/Node/Probe 各有协议版本下限
- 版本 bump 不能自动生成,需 owner 显式确认
- 兼容性变更必须 additive first

### 6. MCP 三个接入面完全独立

| 接入面 | 协议 | 用途 |
|---|---|---|
| Loopback HTTP | HTTP + JSON-RPC(仅 127.0.0.1) | 本地 MCP 客户端 |
| App Standalone | HTTP(/__openclaw__/mcp-app) | 浏览器 App |
| Connection | 反向 | OpenClaw 作为 MCP 客户端 |

## 设计观察

### 为什么所有接入都汇聚到 Gateway

```
错误设计:
   Telegram ──► Agent Runner
   Slack    ──► Agent Runner
   iOS App ──► Agent Runner
   UI       ──► Agent Runner
   → 认证、并发、状态、可观测性各做一遍 → 不一致

正确设计:
   所有客户端 ──► Gateway HTTP/WS Server ──► Agent Runner
                  ↑
            统一认证面
            统一并发控制(Lane)
            统一可观测性
            统一状态库
```

### 为什么渠道插件只能 transport-only

```
错误设计:
   Telegram 插件:
   • transport(收发消息)
   • 自己实现 /help 命令
   • 自己管理 agent 路由
   • 自己处理 provider 选择
   → 核心逻辑散落在各渠道 → 不一致

正确设计:
   Telegram 插件:
   • transport(收发消息)
   • 渲染展示(把 markdown 转成 Telegram 格式)
   • 动作映射(把按钮回调转成统一 action)
   • 不做任何业务决策
   → 核心逻辑集中在 Gateway → 一致
```

### 为什么 MCP 三个接入面完全独立

- Loopback HTTP 只服务本地客户端(安全限制)
- App Standalone 服务浏览器 App(需要 HMAC ticket)
- Connection 是反向(OpenClaw 作为 MCP 客户端连接外部 MCP server)
- 三者协议、认证、用途完全不同,不能合并

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 本文件 — 概览与索引 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入(iOS/macOS/Linux/Android/watchOS) |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Gateway HTTP/WS Server | [src/gateway/server-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-http.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
| 协议版本 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| Gateway WS 协议 | [packages/gateway-protocol/src/schema/frames.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/frames.ts) |
| Worker 子协议 | [packages/gateway-protocol/src/schema/worker-admission.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/worker-admission.ts) |
| OpenAI REST | [src/gateway/openai-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/openai-http.ts) |
| OpenResponses REST | [src/gateway/openresponses-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/openresponses-http.ts) |
| MCP Loopback | [src/gateway/mcp-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-http.ts) |
| MCP App Standalone | [src/gateway/mcp-app-standalone.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-app-standalone.ts) |
| Control UI | [src/gateway/control-ui.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui.ts) |
| Plugin HTTP | [src/gateway/server/plugins-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server/plugins-http.ts) |
| Node Host | [src/gateway/node-agent-cli-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/node-agent-cli-runtime.ts) |
| Probe | [src/gateway/probe.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/probe.ts) |
| Plugin SDK 入口 | [src/plugin-sdk/entrypoints.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/entrypoints.ts) |
| Telegram 插件示例 | [extensions/telegram/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/extensions/telegram/index.ts) |
