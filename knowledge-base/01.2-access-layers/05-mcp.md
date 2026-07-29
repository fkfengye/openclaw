# 05 — MCP 接入(三个接入面)

> 读完本章你将理解:OpenClaw 与 MCP 协议交互存在哪三个完全独立的接入面,它们的方向、协议、认证为何不能合并。

## 一句话定位

OpenClaw 与 MCP(Model Context Protocol)的交互分三个**完全独立**的接入面:Loopback HTTP(本地 MCP 客户端接入 OpenClaw,仅 127.0.0.1)、App Standalone(浏览器渲染 MCP app UI,HMAC 短时 ticket)、Connection(反向,OpenClaw 作为 MCP 客户端连接外部 MCP server);三者协议、认证、用途完全不同。

## 全局协作图

下图展示三个 MCP 接入面的方向与定位差异。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────┐
│                  MCP 三个接入面                                  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 5.1 MCP Loopback HTTP(外部 → OpenClaw)                  │  │
│  │                                                            │  │
│  │   本地 MCP 客户端         OpenClaw Gateway                │  │
│  │   (Claude Desktop,  ──► HTTP + JSON-RPC ──► Loopback     │  │
│  │    VSCode, Cursor)     (仅 127.0.0.1)       HTTP Server  │  │
│  │                          Bearer + Grant       │          │  │
│  │                                                ▼          │  │
│  │                                        Gateway 工具调用   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 5.2 MCP App Standalone(浏览器 → OpenClaw)               │  │
│  │                                                            │  │
│  │   浏览器          OpenClaw Gateway                         │  │
│  │   ──► HTTP GET ──► App Standalone 处理器                   │  │
│  │       /__openclaw__   HMAC ticket(TTL 2 分钟)            │  │
│  │       /mcp-app                                            │  │
│  │                          │                                  │  │
│  │                          ▼                                  │  │
│  │                   渲染 MCP app UI(嵌入 Control UI)       │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 5.3 MCP Connection(反向:OpenClaw → 外部)               │  │
│  │                                                            │  │
│  │   OpenClaw agent          外部 MCP Server                 │  │
│  │   ──► MCP client ──► (filesystem / github /              │  │
│  │                        postgres / ...)                    │  │
│  │                                                            │  │
│  │   注:不属于"接入 OpenClaw",列出仅为完整                │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **MCP Loopback HTTP Server** | 把本地 MCP 客户端的 JSON-RPC 翻译为 Gateway 工具调用 | 仅绑定 127.0.0.1,杜绝远程调用 |
| **MCP Grant Store** | 为每次 MCP 调用绑定 agent session + run + 工具白名单 | per-run 最小权限,工具白名单强约束 |
| **MCP App Standalone 处理器** | 在浏览器渲染 MCP app UI,嵌入 Control UI | HMAC 签名 ticket,TTL 仅 2 分钟 |
| **MCP Connection(反向)** | OpenClaw agent 作为 MCP 客户端连接外部 MCP server | 反向接入,不属于"外部接入 OpenClaw" |

## 关联关系

### 三个接入面的方向对比

```
   5.1 Loopback HTTP            5.2 App Standalone          5.3 Connection
   外部 ──► OpenClaw             浏览器 ──► OpenClaw         OpenClaw ──► 外部
   (本地 MCP 客户端)            (渲染 MCP app UI)          (反向,作为 MCP 客户端)
        │                            │                            │
        ▼                            ▼                            ▼
   ┌──────────────┐           ┌──────────────┐           ┌──────────────┐
   │ HTTP+JSON-RPC│           │ HTTP GET     │           │ MCP client   │
   │ 127.0.0.1    │           │ HMAC ticket  │           │ 连外部 server│
   │ Bearer+Grant │           │ TTL 2min     │           │              │
   └──────────────┘           └──────────────┘           └──────────────┘
        │                            │                            │
        ▼                            ▼                            ▼
   Gateway 工具调用            渲染 MCP app UI              调用外部工具
   (绑定到特定 run)           (嵌入 Control UI)           (filesystem/github/...)

   ⚠ 三者协议、认证、用途完全不同,不能合并
```

### Loopback 的 per-run 工具白名单与 Grant 的关系

```
   MCP 客户端调用 tools/call
        │
        ▼
   ┌──────────────────────────────────┐
   │ MCP Grant Store                  │
   │ 解析调用上下文:                  │
   │ • sessionKey                    │
   │ • agentId / sessionId / runId   │
   │ • workspaceDir                  │
   │ • toolsAllow(工具白名单)       │
   └──────────────┬───────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────┐
   │ 工具白名单检查                    │
   │  tool ∈ toolsAllow → 允许调用    │
   │  tool ∉ toolsAllow → 拒绝(error)│
   └──────────────┬───────────────────┘
                  │ 允许
                  ▼
   ┌──────────────────────────────────┐
   │ Gateway 工具调用                  │
   │ (共享 Gateway 状态)              │
   └──────────────────────────────────┘
```

### App Standalone 的 ticket 生命周期

```
   插件请求渲染 MCP app view
        │
        ▼
   ┌──────────────────────────────────┐
   │ 1. 签发 ticket                    │
   │    • nonce(随机)               │
   │    • expiresAtMs(2 分钟后)      │
   │    • HMAC 签名                   │
   │    • 格式:v1.<nonce>.<exp>.<sig>│
   └──────────────┬───────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────┐
   │ 2. 浏览器持 ticket 请求           │
   │    GET /__openclaw__/mcp-app      │
   │    ?ticket=v1.<nonce>.<exp>.<sig>│
   └──────────────┬───────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────┐
   │ 3. App Standalone 处理器校验      │
   │    • HMAC 签名有效               │
   │    • 未过期(< 2 分钟)          │
   │    • 通过 → 渲染 MCP app UI      │
   └──────────────────────────────────┘
```

## 协作流程

### 一次 MCP Loopback 调用的完整旅程

下面追踪一个 Claude Desktop 通过 MCP 调用 OpenClaw 工具的全过程。

```
Claude Desktop 发起 MCP 调用(tools/call)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Loopback HTTP Server 接收                                 │
│    • 仅监听 127.0.0.1(杜绝远程)                            │
│    • Bearer token 验证                                       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. MCP Grant Store 解析调用上下文                            │
│    • 绑定到特定 agent session + run                          │
│    • 取出 toolsAllow(工具白名单)                           │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 工具白名单检查                                             │
│    • 调用的 tool ∈ toolsAllow → 允许                         │
│    • 调用的 tool ∉ toolsAllow → 拒绝(JSON-RPC error)        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Gateway 工具调用(共享 Gateway 状态)                     │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. JSON-RPC Response 返回给 Claude Desktop                   │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. Loopback 仅绑定 127.0.0.1

- **为什么**:MCP 客户端通常本地运行,远程调用会绕过 Gateway 网络层防护
- **怎么做**:Loopback HTTP Server 强制绑定 127.0.0.1
- **影响**:仅本机 MCP 客户端可接入,远程需走其他接入面

### 2. per-run 工具白名单

- **为什么**:最小权限原则,一次 MCP 调用只应访问该 run 允许的工具
- **怎么做**:Grant Store 为每次调用绑定 agent session + run + toolsAllow
- **影响**:工具白名单的来源与更新需明确

### 3. App Standalone ticket 短时有效

- **为什么**:浏览器环境 ticket 易泄漏,短 TTL 降低风险
- **怎么做**:HMAC 签名 ticket,TTL 仅 2 分钟
- **影响**:ticket 复用窗口短,客户端需即时使用

### 4. 三个接入面完全独立

- **为什么**:本地工具客户端、浏览器 app、反向 MCP client 用途完全不同,合并会混淆安全模型
- **怎么做**:三个接入面各自独立的协议、认证、处理器
- **影响**:文档与实现需明确区分,不能跨面复用

## 设计观察

### 为什么 Loopback 强制 127.0.0.1 而非用认证保护

```
错误设计:
   Loopback 监听 0.0.0.0,仅靠 Bearer token 保护
   → token 泄漏后远程可直接调用工具,绕过网络层防护

正确设计:
   Loopback 强制 127.0.0.1 + Bearer token + Grant 白名单
   → 三层防护:网络层(本机)+ 认证层(token)+ 授权层(白名单)
```

### 为什么三个接入面不能合并为一个

```
错误设计:
   合并成一个"MCP 接入面",内部 if/else 分流
   → 本地客户端、浏览器 app、反向连接的安全模型完全不同,
     合并导致认证逻辑混乱、攻击面扩大

正确设计:
   三个独立接入面,各自协议、认证、处理器
   → 安全边界清晰,各自演进互不影响
```

### 为什么 App Standalone 用 HMAC ticket 而非长期 token

```
错误设计:
   浏览器持长期 token 访问 MCP app
   → token 存浏览器易被 XSS 窃取,长期有效风险高

正确设计:
   短时 HMAC ticket(TTL 2 分钟)
   → 即使泄漏,2 分钟后失效;签名防伪造
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | 本文件 — MCP 接入(三个接入面) |
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
| MCP Loopback HTTP Server | [src/gateway/mcp-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-http.ts) |
| MCP Loopback JSON-RPC 协议 | [src/gateway/mcp-http.protocol.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-http.protocol.ts) |
| MCP Grant Store(per-run 白名单) | [src/gateway/mcp-grant-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-grant-store.ts) |
| MCP App Standalone 处理器 | [src/gateway/mcp-app-standalone.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/mcp-app-standalone.ts) |
| MCP Connection(反向)类型 | [src/plugins/types.mcp-connection.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/types.mcp-connection.ts) |
| MCP 客户端实现 | [src/mcp/](file:///d:/DevSpace/person/ai_space/openclaw/src/mcp/) |
