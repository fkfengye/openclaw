# 01 — Gateway HTTP/WS Server(核心根)

> 读完本章你将理解:为什么所有接入方式最终汇聚到同一个 HTTP server,以及这个根如何用一次端口同时承载 HTTP 路由与两类 WebSocket 协议。

## 一句话定位

Gateway HTTP/WS Server 是 OpenClaw 与外部世界的**唯一汇聚根**:一个 HTTP server 同时承载 HTTP 路由(REST/静态资源/插件路由)与 WebSocket upgrade(Gateway 客户端 + Worker 子协议),通过 bind 模式控制可达性,通过统一认证面控制访问。

## 全局协作图

下图展示根 server 如何把所有外部接入分流到各子系统。**先看这张图建立心智模型,再读细节**。

```
                  所有外部接入
                       │
   ┌───────────────────┼───────────────────┐
   │                   │                   │
   ▼                   ▼                   ▼
 HTTP 请求          WS upgrade          插件 HTTP/WS
 (REST/UI/资源)    (客户端/Worker)     (插件自定义路由)
   │                   │                   │
   └───────────────────┼───────────────────┘
                       │
                       ▼
   ┌───────────────────────────────────────┐
   │      Gateway HTTP/WS Server(根)      │
   │                                       │
   │  职责:                                │
   │  • 统一监听端口(HTTP + WS 共端口)    │
   │  • 路径分类器分流 HTTP 路由           │
   │  • 双路 WS upgrade(Gateway/Worker)   │
   │  • 统一认证面拦截所有接入             │
   │  • Bind 模式控制可达范围              │
   └───────┬───────────────────┬───────────┘
           │                   │
   ┌───────┴───────┐   ┌───────┴───────┐
   │  HTTP 路由表   │   │  WS 升级分流   │
   │  (路径分类器)  │   │               │
   │               │   │   ┌─────────┐ │
   │ • OpenAI REST │   │   │ Gateway │ │
   │ • OpenResp    │   │   │ 客户端  │ │
   │ • Models API  │   │   │ upgrade │ │
   │ • Control UI  │   │   └─────────┘ │
   │ • MCP App     │   │   ┌─────────┐ │
   │ • Plugin 路由 │   │   │ Worker  │ │
   │ • Node Watch  │   │   │ upgrade │ │
   └───────────────┘   │   └─────────┘ │
                       └───────────────┘
           │
           ▼
   ┌───────────────────────┐
   │     统一认证面         │
   │  (7 种方式归一)       │
   └───────────────────────┘
           │
           ▼
   ┌───────────────────────┐
   │   业务内核(Lane/     │
   │   Agent/Turn)         │
   └───────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **HTTP/WS Server 主体** | 监听端口,接收所有 HTTP 请求与 WS upgrade | HTTP 与 WS 共享同一端口 |
| **HTTP 路径分类器** | 一次扫描把请求分流到 OpenAI/UI/MCP/插件等路由 | 单一分类入口,顺序明确 |
| **WS 升级分流器** | 区分 Gateway 客户端 upgrade 与 Worker upgrade | 两类 WS 协议逻辑分离,共享端口 |
| **Bind 模式控制器** | 决定绑定地址(loopback/lan/tailnet/auto) | 决定默认认证策略 |
| **统一认证面** | 7 种认证方式归一为单一结果 | 所有接入必经,无认证旁路 |
| **启动阶段编排器** | 分 5 阶段把 server 从 bootstrap 到 plugins 装配完成 | 阶段顺序固定 |

## 关联关系

### 根 server 与外部接入的关系

```
   ┌──────────────┐  HTTP  ┌──────────────────────┐
   │ OpenAI 客户端│ ──────►│                      │
   │ (Continue等) │        │                      │
   └──────────────┘        │                      │
                           │                      │
   ┌──────────────┐  HTTP  │                      │
   │ MCP 客户端   │ ──────►│  Gateway HTTP/WS     │
   │ (Claude Dtk) │        │  Server(根)         │
   └──────────────┘        │                      │
                           │                      │
   ┌──────────────┐  WS    │                      │
   │ Control UI   │ ──────►│                      │
   └──────────────┘        │                      │
                           │                      │
   ┌──────────────┐  WS    │                      │
   │ 原生 App     │ ──────►│                      │
   └──────────────┘        │                      │
                           │                      │
   ┌──────────────┐  WS    │                      │
   │ Worker 进程  │ ──────►│                      │
   └──────────────┘        └──────────┬───────────┘
                                     │
                                     ▼
                          ┌──────────────────┐
                          │   统一认证面     │
                          └──────────────────┘
```

### Bind 模式与默认认证的绑定

```
   Bind 模式决定可达范围 → 决定默认认证策略

   ┌─────────────┐         ┌──────────────────┐
   │ loopback    │ ───────►│ 默认 none        │
   │ 127.0.0.1   │         │ (本机无需认证)   │
   └─────────────┘         └──────────────────┘

   ┌─────────────┐         ┌──────────────────┐
   │ lan         │ ───────►│ token / password │
   │ 0.0.0.0     │         │ (局域网需凭证)   │
   └─────────────┘         └──────────────────┘

   ┌─────────────┐         ┌──────────────────┐
   │ tailnet     │ ───────►│ tailscale Whois  │
   │ Tailscale   │         │ (网络身份认证)   │
   └─────────────┘         └──────────────────┘

   ┌─────────────┐         ┌──────────────────┐
   │ auto        │ ───────►│ 视环境自动判断   │
   └─────────────┘         └──────────────────┘
```

### 启动阶段的 5 阶段装配

```
   1. bootstrap ─► 2. early ─► 3. post-attach ─► 4. finish ─► 5. plugins
      (引导)        (早期服务)   (HTTP attach)     (完成)      (调度服务)

   每阶段职责:
   • bootstrap   — 解析配置、准备 server 骨架
   • early       — 启动早期必需服务
   • post-attach — HTTP server attach 到端口
   • finish      — 完成基础装配
   • plugins     — 激活定时与调度服务

   ⚠ 阶段顺序固定,跨阶段依赖只能向后
```

## 协作流程

### 一次 HTTP 请求被分流的完整旅程

下面追踪一个外部 OpenAI 兼容客户端发来的 HTTP 请求,看根 server 如何分流。

```
外部客户端 POST /v1/chat/completions
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. HTTP/WS Server 主体接收                                   │
│    • 单端口监听,HTTP 与 WS 共享                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 插件路由优先判断                                          │
│    • 检查是否有插件认领该路径                                │
│    • 认领 → 交给插件 handler 处理(返回)                    │
│    • 未认领 → 进入主路径分类器                               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 统一认证面拦截                                            │
│    • 提取 Bearer token                                       │
│    • 归一为单一认证结果                                      │
│    • 失败 → 401/403                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 路径分类器分流                                            │
│    • /v1/*        → OpenAI / OpenResponses / Models REST     │
│    • /__openclaw__/* → MCP App / 助手媒体                    │
│    • /api/nodes/* → 节点 watch                               │
│    • 其他         → Control UI 静态资源 / SPA fallback       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 子系统处理 → HTTP Response 返回                           │
└──────────────────────────────────────────────────────────────┘
```

### 一次 WS upgrade 被分流的完整旅程

```
客户端发起 WS upgrade
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. HTTP/WS Server 主体接收 upgrade 请求                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 插件 upgrade 优先判断                                     │
│    • 插件认领 → 插件 WS handler                              │
│    • 未认领 → 进入主升级分流                                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. WS 升级分流器区分两类协议                                 │
│    • Gateway 客户端 upgrade → 走 Gateway WS 协议(见 02)    │
│    • Worker upgrade        → 走 Worker 子协议(见 03)       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 各自握手 + 认证 + 业务交互                                │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 单一根 server

- **为什么**:统一认证、统一并发控制、统一可观测性、统一状态库
- **怎么做**:所有接入汇聚到同一个 HTTP/WS server,不允许多 server 分散接入
- **影响**:新增接入方式 = 在根上注册新路由/upgrade,不另起 server

### 2. HTTP 与 WS 共享端口

- **为什么**:用户只需开放一个端口,降低部署复杂度
- **怎么做**:WS upgrade 复用 HTTP server 的 upgrade 事件
- **影响**:HTTP 路由与 WS 协议在同一端口分流,需明确分类优先级

### 3. 两类 WS 协议逻辑分离

- **为什么**:Gateway 客户端协议(双向 RPC)与 Worker 协议(流式提交)用途完全不同
- **怎么做**:使用独立的 upgrade handler,共享端口但逻辑隔离
- **影响**:排查 WS 问题时需先判断属于哪类协议

### 4. 各接入层可独立开关

- **为什么**:不同部署场景只需部分接入能力(如纯 headless 不需 UI)
- **怎么做**:配置项控制 OpenAI / OpenResponses / Control UI 等是否启用
- **影响**:配置面变大,新增接入层需同步配置开关

### 5. Bind 模式绑定默认认证

- **为什么**:可达范围决定威胁模型,loopback 默认无需认证而 lan/tailnet 必须
- **怎么做**:bind 模式 → 默认认证策略的固定映射
- **影响**:切换 bind 模式会改变认证默认行为,operator 需理解

## 设计观察

### 为什么所有接入汇聚到一个根 server

```
错误设计:
   OpenAI 客户端 ──► 独立 HTTP server A
   Control UI    ──► 独立 HTTP server B
   Worker        ──► 独立 WS server C
   → 认证、并发、日志、状态各做一遍 → 不一致且难维护

正确设计:
   所有客户端 ──► Gateway HTTP/WS Server(根)
                  ↑
            统一认证面
            统一并发控制
            统一可观测性
            统一状态库
   → 一致性 + 可维护性
```

### 为什么 WS upgrade 要分两路而非统一处理

```
错误设计:
   所有 WS upgrade ──► 单一 handler ──► 内部 if/else 分流
   → Gateway 客户端逻辑与 Worker 逻辑耦合,一处故障影响全部

正确设计:
   WS upgrade ──► 分流器 ──┬─► Gateway 客户端 upgrade handler
                            └─► Worker upgrade handler
   → 两类协议独立演进、独立故障隔离
```

### 为什么插件路由优先于主路由

```
错误设计:
   主路由分类器先跑 → 插件路由只能用主路由未覆盖的路径
   → 路径冲突时插件无法扩展被主路由占用的前缀

正确设计:
   插件路由优先 → 插件可认领任意路径
   未认领的才走主路由分类器
   → 插件扩展能力强,主路由只兜底
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | 本文件 — Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
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
| Gateway HTTP/WS Server 主体 | [src/gateway/server-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-http.ts) |
| Bind 模式与 server 选项 | [src/gateway/server-public.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-public.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| 启动阶段引导 | [src/gateway/server-startup-bootstrap.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-startup-bootstrap.ts) |
| 调度服务装配 | [src/gateway/server-runtime-services.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-runtime-services.ts) |
| Models REST | [src/gateway/models-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/models-http.ts) |
| Embeddings REST | [src/gateway/embeddings-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/embeddings-http.ts) |
