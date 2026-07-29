# 02 — Gateway WebSocket 协议(客户端接入)

> 读完本章你将理解:浏览器、CLI、原生 App 等客户端在 HTTP upgrade 完成后,如何通过一套握手 + RPC + 事件的双向协议与 Gateway 通信。

## 一句话定位

Gateway WS 协议是大多数客户端的"应用层"接入方式:在 WS upgrade 完成后,通过 ConnectParams 握手协商身份与版本,通过 HelloOk 返回 server 能力,然后承载所有双向 RPC(methods)与事件(events)。

## 全局协作图

下图展示一次 WS 接入从握手到双向通信的完整心智模型。**先看这张图建立心智模型,再读细节**。

```
                  客户端
          (UI / CLI / 原生 App)
                    │
                    │ 1. HTTP upgrade(含 ConnectParams)
                    ▼
   ┌───────────────────────────────────────┐
   │      Gateway HTTP/WS Server(根)      │
   │      (见 01 章)                      │
   └───────────────────┬───────────────────┘
                       │ 2. WS 升级分流
                       ▼
   ┌───────────────────────────────────────┐
   │      Gateway WS 协议                  │
   │                                       │
   │  握手阶段(固定顺序):                │
   │  • tcp_accepted                       │
   │  • ws_upgrade_started                 │
   │  • auth_credentials_received          │
   │  • auth_validated                     │
   │  • session_attached                   │
   │  • hello_payload_prepared             │
   │  • ready                              │
   └───────────────────┬───────────────────┘
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
   ┌──────────┐                ┌──────────────┐
   │ 统一认证面│                │ ClientId 校验│
   │ (见 12)  │                │ + 协议版本校验│
   └──────────┘                └──────────────┘
        │                             │
        └──────────────┬──────────────┘
                       │ 3. HelloOk 返回
                       ▼
   ┌───────────────────────────────────────┐
   │      HelloOk 帧                       │
   │  • protocol(协商版本)               │
   │  • server(版本信息)                 │
   │  • features(methods/events/caps)      │
   │  • snapshot(初始状态快照)           │
   └───────────────────┬───────────────────┘
                       │ 4. ready 状态
                       ▼
   ┌───────────────────────────────────────┐
   │      双向 RPC + Event 通信            │
   │                                       │
   │   客户端 ──Method 请求──► Gateway     │
   │   客户端 ◄──Event 推送───  Gateway     │
   └───────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **ConnectParams 握手帧** | 客户端在 upgrade 时携带身份、认证、版本信息 | ClientId 必须在注册表内 |
| **握手状态机** | 7 阶段固定顺序推进到 ready | 顺序固定,任一阶段失败即关闭 |
| **HelloOk 响应帧** | 返回协商版本、server 信息、能力清单、初始快照 | 协商失败用 close 帧而非 HelloOk |
| **Method 注册表** | 客户端可调用的 RPC 方法集合 | 新增方法属于协议演进 |
| **Event 注册表** | server 推送给客户端的事件集合 | 新增事件属于协议演进 |
| **ClientId 注册表** | 16 类客户端身份的中央登记(见 12 章) | 新增客户端类型必须登记 |
| **协议版本协商** | 通用协议当前为 4,Node/Probe 允许 ≥3 | bump 需 owner 显式确认 |

## 关联关系

### 握手状态机的 7 阶段

```
   tcp_accepted
       │
       ▼
   ws_upgrade_started
       │
       ▼
   auth_credentials_received ◄── 客户端提交认证字段
       │
       ▼
   auth_validated ◄── 统一认证面校验
       │                  (失败 → close 4401/4403)
       ▼
   session_attached ◄── 绑定到 agent/session
       │
       ▼
   hello_payload_prepared ◄── 准备能力清单 + 快照
       │
       ▼
   ready ◄── 进入双向通信
```

### ConnectParams 携带的认证字段与统一认证面的关系

```
   ConnectParams(客户端提交)          统一认证面(归一)
   ┌──────────────────────┐           ┌──────────────────┐
   │ token                │           │                  │
   │ password             │ ────────► │  按优先级匹配:    │
   │ deviceToken          │           │  归一为单一结果   │
   │ bootstrapToken       │           │                  │
   │ approvalRuntimeToken │           │  method: ...     │
   │ agentRuntimeIdentity │           │  identity: {...} │
   │   Token              │           │  capabilities:.. │
   └──────────────────────┘           └──────────────────┘

   ⚠ 后续业务逻辑只读归一结果,不区分具体字段
```

### HelloOk 能力协商与双向通信

```
   Gateway                          客户端
      │                               │
      │  HelloOk                      │
      │  {                            │
      │    protocol: 4,               │
      │    server: {...},             │
      │    features: {                │
      │      methods: [...],          │
      │      events: [...],           │
      │      capabilities: [...]      │
      │    },                         │
      │    snapshot: {...}            │
      │  }                            │
      │ ─────────────────────────────►│
      │                               │
      │                               │ 据此知道可调用哪些
      │                               │ Method、可订阅哪些 Event
      │                               │
      │  Method Request ◄─────────────│
      │  (session.attach / agent.run │
      │   / channel.send / ...)       │
      │                               │
      │  Event ──────────────────────►│
      │  (agent.message /             │
      │   channel.event / ...)        │
```

## 协作流程

### 一次 WS 接入握手到 ready 的完整旅程

下面追踪一个 iOS App 通过 WS 接入到 ready 的全过程,标注每步由哪个组件负责。

```
iOS App 发起 WS upgrade
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Gateway HTTP/WS Server 接收 upgrade(由 01 章根负责)      │
│    • WS 升级分流器路由到 Gateway 客户端 upgrade              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 握手状态机:ws_upgrade_started                             │
│    • 解析 ConnectParams                                      │
│    • clientId: openclaw-ios                                  │
│    • mode: ui                                                │
│    • protocolVersion: 4                                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. ClientId 校验 + 协议版本校验                              │
│    • ClientId 必须在注册表内(见 12 章)                    │
│    • 协议版本必须 ≥ 通用下限(4)                            │
│    • 失败 → close(protocol-mismatch)                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. auth_credentials_received → auth_validated                │
│    • 统一认证面校验认证字段(deviceToken)                    │
│    • 失败 → close 4401/4403(invalid-credentials)            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. session_attached                                           │
│    • 绑定到 agent / session                                   │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. hello_payload_prepared → ready                            │
│    • Gateway 发送 HelloOk(能力清单 + 初始快照)              │
│    • 客户端进入 ready 状态                                    │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. 双向 RPC + Event 通信                                      │
│    • App 发 Method(agent.run 等)                            │
│    • Gateway 推 Event(agent.message 等)                     │
└──────────────────────────────────────────────────────────────┘
```

### 关闭场景与关闭原因

| 关闭原因 | 触发场景 |
|---|---|
| invalid-credentials | 认证失败 |
| protocol-mismatch | 协议版本不兼容 |
| session-mismatch | session 不匹配 |
| slow-consumer | 客户端消费过慢(背压保护) |
| gateway-shutdown | server 关闭 |

## 关键设计约束

### 1. 握手阶段顺序固定

- **为什么**:认证、绑定 session、准备能力清单有严格依赖
- **怎么做**:7 阶段状态机线性推进,不允许跳过或乱序
- **影响**:任一阶段失败立即关闭,不会进入 ready

### 2. ClientId 必须在注册表登记

- **为什么**:可观测性、协议版本协商、客户端能力识别都需要中央登记
- **怎么做**:upgrade 时校验 ClientId 是否在注册表内(见 12 章)
- **影响**:新增客户端类型必须先登记,否则接入被拒

### 3. 协议版本 bump 是重大决策

- **为什么**:协议版本影响所有客户端兼容性
- **怎么做**:通用版本当前为 4,Node/Probe 允许 ≥3;bump 不能自动生成,需 owner 显式确认;兼容性变更必须 additive first
- **影响**:协议演进成本高,需谨慎

### 4. 认证字段归一为单一结果

- **为什么**:6 种认证字段不应让业务代码逐个判断
- **怎么做**:握手时经统一认证面归一为单一结果,后续只读结果
- **影响**:认证失败排查需对照优先级表,但业务逻辑解耦

### 5. 背压保护

- **为什么**:慢客户端会拖垮 server
- **怎么做**:slow-consumer 关闭原因,消费过慢时主动断开
- **影响**:客户端必须及时消费事件,否则被断开

## 设计观察

### 为什么握手要返回 snapshot 初始快照

```
错误设计:
   ready 后客户端需逐个发 RPC 拉取当前状态
   (会话列表 / agent 状态 / 配置 ...)
   → 冷启动多轮往返,延迟高

正确设计:
   HelloOk 内嵌 snapshot,客户端 ready 即有完整初始状态
   → 一次握手拿到全部上下文,零额外往返
```

### 为什么 Method/Event 通过 features 协商而非硬编码

```
错误设计:
   客户端假设 server 支持所有 Method/Event
   → 不同版本 server 能力不同时调用失败

正确设计:
   HelloOk 返回 features(methods/events/capabilities)
   客户端据 capabilities 决定可调用范围
   → 版本兼容、能力降级优雅
```

### 为什么 Node/Probe 允许旧协议版本而 UI/Worker 必须 4

```
错误设计:
   所有客户端统一强制最新协议版本
   → Node/Probe 是功能子集(健康检查/远程调用),
     强制升级成本高且无收益

正确设计:
   UI/CLI/Worker 必须 4(需要最新能力)
   Node Host / Probe 允许 ≥3(功能子集,旧版可用)
   → 差异化下限,降低升级成本
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | 本文件 — Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 协议帧定义(ConnectParams/HelloOk) | [packages/gateway-protocol/src/schema/frames.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/frames.ts) |
| 协议版本管理 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
| 传输层关闭原因 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-transport.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-transport.ts) |
| 握手状态机与 WS 客户端类型 | [src/gateway/server/ws-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server/ws-types.ts) |
| Method/Event 清单 | [src/gateway/server-methods-list.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-methods-list.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
