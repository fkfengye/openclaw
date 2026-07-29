# 04 — OpenAI / OpenResponses REST API 接入

> 读完本章你将理解:外部工具如何把 OpenClaw 当作 OpenAI API 后端使用,以及 OpenAI 兼容与 OpenResponses 两条 REST 路径如何共享同一认证面与 Agent run 内核。

## 一句话定位

通过标准 HTTP REST 暴露两类开放协议接入面:OpenAI 兼容 API(让 Continue / Cline / Aider 等零改造接入)与 OpenResponses API(开放响应协议);两者都用 Bearer token 认证,把请求翻译为 OpenClaw Agent run,支持 SSE 流式与 JSON 一次性两种响应格式,可独立开关。

## 全局协作图

下图展示两类 REST 接入如何汇聚到根 server、共享认证面、最终翻译为 Agent run。**先看这张图建立心智模型,再读细节**。

```
              外部工具(OpenAI 兼容客户端)
              (Continue / Cline / Aider / curl / ...)
                        │
                        │ POST /v1/chat/completions
                        │ POST /v1/responses
                        │ POST /v1/models /v1/embeddings
                        │ Authorization: Bearer <token>
                        ▼
   ┌───────────────────────────────────────┐
   │      Gateway HTTP/WS Server(根)      │
   │      (见 01 章)                      │
   └───────────────────┬───────────────────┘
                       │ 路径分类器
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
   ┌──────────────┐           ┌──────────────┐
   │ OpenAI 兼容   │           │ OpenResponses│
   │ REST 处理器   │           │ REST 处理器  │
   │              │           │              │
   │ /v1/chat/    │           │ /v1/responses│
   │  completions │           │              │
   │ /v1/models   │           │              │
   │ /v1/embeddings│          │              │
   └──────┬───────┘           └──────┬───────┘
          │                          │
          └────────────┬─────────────┘
                       │
                       ▼
              ┌──────────────────┐
              │   统一认证面     │
              │ (Bearer token)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  请求翻译器       │
              │  (OpenAI/OpenResp│
              │   → Agent run)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  Agent Run 内核  │
              │  (Lane 调度)     │
              └────────┬─────────┘
                       │
            ┌──────────┴──────────┐
            │                     │
            ▼                     ▼
      stream: true           stream: false
            │                     │
            ▼                     ▼
      ┌──────────┐          ┌──────────┐
      │ SSE 响应  │          │ JSON 响应 │
      └──────────┘          └──────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **OpenAI 兼容 REST 处理器** | 处理 /v1/chat/completions、/v1/models、/v1/embeddings | 兼容 OpenAI API 形状 |
| **OpenResponses REST 处理器** | 处理 /v1/responses(开放响应协议) | 兼容 Open Responses 规范 |
| **请求翻译器** | 把 OpenAI/OpenResponses 请求翻译为 OpenClaw Agent run | 工具调用语义需映射 |
| **响应格式器** | 输出 SSE(流式)或 JSON(一次性) | 兼容 OpenAI stream 字段 |
| **配置开关** | 各接入面可独立 enabled/disabled | 配置面变更影响外部工具 |

## 关联关系

### OpenAI 兼容 vs OpenResponses 对比

```
   ┌────────────────────────────┐    ┌────────────────────────────┐
   │ OpenAI 兼容                 │    │ OpenResponses              │
   │                             │    │                             │
   │ 路径:                       │    │ 路径:                       │
   │  /v1/chat/completions       │    │  /v1/responses              │
   │  /v1/models                 │    │                             │
   │  /v1/embeddings             │    │ 标准:                       │
   │                             │    │  open-responses.com         │
   │ 标准:                       │    │                             │
   │  platform.openai.com        │    │ 客户端:                     │
   │                             │    │  支持 Open Responses 的工具 │
   │ 客户端:                     │    │                             │
   │  Continue / Cline / Aider  │    │                             │
   │  / 任何 OpenAI 兼容客户端   │    │                             │
   └────────────────────────────┘    └────────────────────────────┘
            │                                  │
            │   共享:Bearer token 认证         │
            │   共享:Agent run 内核            │
            │   共享:SSE / JSON 响应格式       │
            └──────────────┬───────────────────┘
                           │
                           ▼
                    统一认证面 + Agent Run
```

### REST 接入与 WS 接入的关系

```
   WS 接入(02 章)                REST 接入(本章)
   ┌──────────────┐               ┌──────────────┐
   │ 长连接        │               │ 短连接        │
   │ 双向 RPC+Event│               │ 请求-响应     │
   │ 用于:        │               │ 用于:        │
   │  UI/CLI/App  │               │  外部工具     │
   │  长会话       │               │  一次性调用   │
   └──────┬───────┘               └──────┬───────┘
          │                              │
          └──────────────┬───────────────┘
                         │
                         ▼
                都汇聚到 Gateway 根 server
                都经统一认证面
                都进入 Agent run 内核(Lane 调度)
```

## 协作流程

### 一次 OpenAI 兼容请求的完整旅程

下面追踪一个 Continue 客户端发来的流式聊天补全请求的全过程。

```
Continue 客户端 POST /v1/chat/completions (stream: true)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Gateway HTTP/WS Server 接收(由 01 章根负责)              │
│    • 路径分类器命中 OpenAI REST 路由                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 统一认证面                                                 │
│    • 提取 Bearer token                                       │
│    • 归一为单一认证结果                                      │
│    • 失败 → 401/403                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. OpenAI 兼容 REST 处理器                                    │
│    • 解析 OpenAI 请求体(messages / model / stream / ...)    │
│    • 请求翻译器:OpenAI 请求 → Agent run 命令                │
│    • 工具调用语义映射(OpenAI function calling → 内部 tool) │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Agent Run 内核(Lane 调度)                               │
│    • 分配 lane,启动 Agent run                               │
│    • 流式输出 chunk                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
                ┌─────────────┴─────────────┐
                │                           │
                ▼                           ▼
          stream: true                 stream: false
                │                           │
                ▼                           ▼
        ┌───────────────┐           ┌───────────────┐
        │ SSE 响应       │           │ JSON 响应      │
        │ (text/event-  │           │ (application/ │
        │  stream)      │           │  json)        │
        │ 分块推送      │           │ 一次性返回    │
        └───────────────┘           └───────────────┘
```

### 典型使用场景

| 场景 | 接入方式 |
|---|---|
| Continue / Cline 配置 OpenClaw 为后端 | 把 apiBase 指向 Gateway /v1,apiKey 填 Gateway token |
| curl 测试 | POST /v1/chat/completions 携带 Bearer token |
| 支持 Open Responses 的客户端 | POST /v1/responses 携带 Bearer token |

## 关键设计约束

### 1. 零成本接入

- **为什么**:让生态内大量 OpenAI 兼容客户端无需改造即可使用 OpenClaw
- **怎么做**:严格兼容 OpenAI API 形状(路径、请求体、响应、SSE chunk)
- **影响**:OpenAI API 演进时需同步,工具调用语义差异需处理

### 2. 两条路径独立开关

- **为什么**:不同部署只需其中一条路径(如纯 OpenResponses 场景)
- **怎么做**:配置项分别控制 OpenAI / OpenResponses 的 enabled
- **影响**:配置面变更属兼容敏感,需谨慎

### 3. 复用 Gateway 认证面

- **为什么**:避免为 REST 接入另建认证体系
- **怎么做**:Bearer token 经统一认证面校验,与 WS 接入共享
- **影响**:外部工具只需一个 Gateway token 即可用所有接入面

### 4. 流式与一次性双格式

- **为什么**:不同客户端对响应格式要求不同(实时 vs 一次性)
- **怎么做**:按 stream 字段分流到 SSE 或 JSON
- **影响**:SSE 兼容性需跟进各客户端解析行为

### 5. 请求翻译为 Agent run

- **为什么**:OpenClaw 内核是 Agent run,不是裸 LLM 调用
- **怎么做**:请求翻译器把 OpenAI 请求映射为 Agent run 命令
- **影响**:model 字段映射、工具调用语义需谨慎处理

## 设计观察

### 为什么 OpenAI 与 OpenResponses 共享内核而非各自独立

```
错误设计:
   OpenAI REST ──► 独立处理链 A ──► 独立 Agent 内核 A
   OpenResp REST ──► 独立处理链 B ──► 独立 Agent 内核 B
   → 两套内核,行为不一致,维护成本翻倍

正确设计:
   OpenAI REST ──┐
                  ├─► 统一认证面 ─► 请求翻译器 ─► Agent Run 内核
   OpenResp REST─┘
   → 一套内核,两条翻译路径,行为一致
```

### 为什么 REST 接入复用 Gateway 认证而非独立 token

```
错误设计:
   REST 接入用独立 API key 体系
   → 用户需管理两套凭证(WS 一套、REST 一套)

正确设计:
   REST 复用 Gateway Bearer token(统一认证面)
   → 一套凭证通吃 WS + REST + 所有接入面
```

### 为什么 model 字段需要映射而非直接透传

```
错误设计:
   直接把 OpenAI model 字段当模型名调用 LLM
   → 丢失 OpenClaw 的 agent 配置、auth profile、工具集

正确设计:
   model 字段映射到 OpenClaw agent run
   → 复用 agent 配置、工具、auth、Lane 调度
   → 外部工具拿到的是完整 agent 能力,而非裸 LLM
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | 本文件 — OpenAI / OpenResponses REST API |
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
| OpenAI 兼容 REST 处理器 | [src/gateway/openai-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/openai-http.ts) |
| OpenResponses REST 处理器 | [src/gateway/openresponses-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/openresponses-http.ts) |
| Models REST | [src/gateway/models-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/models-http.ts) |
| Embeddings REST | [src/gateway/embeddings-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/embeddings-http.ts) |
| Bearer token 提取 | [src/gateway/http-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/http-utils.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| Bind 模式与配置开关 | [src/gateway/server-public.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-public.ts) |
