# OpenClaw 知识库导航

本知识库基于 OpenClaw 源码直读分析,采用**层级编号**组织(`01` 父级 → `01.1`/`01.2` 子级;`02`/`03`/`04` 为按架构分层平铺的大组,其下 `02.1`/`03.1`/`04.1` 为子目录)。

### 第 0 层:整体架构与接入面(已完成)

- **[01-openclaw-architecture/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture)** — 整体架构分析(顶层,11 章)
  - **[01.1-external-entry-layer/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer)** — 外部入口层深入分析(子层 1,7 章,CLI 启动链路细化)
  - **[01.2-access-layers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers)** — 接入层深入分析(子层 2,12 章,Gateway 接入面细化)

### 第 1 层:基础设施层(被所有上层依赖,已完成)

- **[02-foundation-layer/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer)** — 基础设施层(4 子目录 16 章,提供数据/配置/工具/LLM 基础)
  - **[02.1-state/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state)** — 状态层(SQLite 双层结构 + Schema 演进,4 章)
  - **[02.2-config/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config)** — 配置层(三步加载 + 类型系统 + Schema 变更,3 章)
  - **[02.3-infra/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra)** — 基础设施原语(FS/路径/网络/TLS/进程/平台,4 章)
  - **[02.4-ai-providers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers)** — LLM Provider 抽象层(契约/实现/传输/工具,4 章)

### 第 2 层:运行时核心(依赖第 1 层,已完成)

- **[03-runtime-core/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core)** — 运行时核心(3 子目录 17 章)
  - **[03.1-agent-sessions/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions)** — Agent 会话管理(生命周期/管理器/提示词/认证/压缩,5 章)
  - **[03.2-gateway-internal/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal)** — Gateway 内部编排(启动/认证/客户端/对话/凭据监控,6 章)
  - **[03.3-plugin-registry/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry)** — 插件注册表(注册/Provider/Plugin/加载器/会话目录,5 章)

### 第 3 层:扩展能力(依赖第 2 层,已完成)

- **[04-extension-capabilities/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities)** — 扩展能力(3 子目录 15 章)
  - **[04.1-hooks/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks)** — Hook 系统(配置策略/加载安装/Gmail 平台集成,3 章)
  - **[04.2-cron/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron)** — 定时任务系统(调度服务/存储/Delivery 重试/退出监控,4 章)
  - **[04.3-agent-tools/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools)** — Agent 工具集(内置/Web/会话/媒体/其他,5 章)

### 层级关系

**01.x 内部(接入面细化):**
- `01.1-external-entry-layer` 是 `01-openclaw-architecture/03-startup-flow.md` 的细化展开(CLI 启动链路,Layer 1-7)
- `01.2-access-layers` 是 `01-openclaw-architecture/03-startup-flow.md` 在 Gateway 接入面的细化展开(Gateway HTTP/WS Server 之后的所有接入协议)
- `01.1` 与 `01.2` 互补:前者覆盖 Layer 1-7(CLI → Commander),后者覆盖 Layer 7 之后的接入协议(Gateway HTTP/WS → 各类客户端)

**02 / 03 / 04 之间(自下而上依赖):**
- `02-foundation-layer` 是最底层,被 03/04 所有组件依赖,提供数据/配置/工具/LLM 基础
- `03-runtime-core` 依赖 02,是 Agent/Gateway/插件注册表的运行时编排核心
- `04-extension-capabilities` 依赖 03,是核心运行时的事件驱动延伸与工具能力扩展
- 三层与 `01-openclaw-architecture` 的对应:02 细化 `08-state`/`09-config`;03 细化 `04-agent-runtime`;04 细化 `05-plugin-system`

## 全局架构图

下图展示 OpenClaw 从用户敲下命令到子命令分发的完整链路,并标注每个环节由哪个知识库的哪个文件覆盖。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          用户敲下命令                                    │
│                          openclaw <args>                                │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
╔═════════════════════════════════════════════════════════════════════════╗
║  外部入口层 (External Entry Layer)                                       ║
║  知识库:01.1-external-entry-layer/                                          ║
║                                                                         ║
║  Layer 1: npm bin ─────────── package.json "bin"                        ║
║       │                                                                 ║
║       ▼                                                                 ║
║  Layer 2: Runtime 守卫 + Respawn ─── openclaw.mjs L50-L304              ║
║       │   (Node 22.22.3+/24.15+/25.9+ 或 Bun with node:sqlite)         ║
║       ▼                                                                 ║
║  Layer 3: Launcher Fast-path ─────── 读 dist/cli-startup-metadata.json  ║
║       │   (--version / --help / <cmd> --help)                           ║
║       │   命中 → exit(0)                                                ║
║       ▼                                                                 ║
║  Layer 4: 动态 import TS bundle ──── dist/entry.js | dist/entry.mjs     ║
║       │                                                                 ║
║       ▼                                                                 ║
║  Layer 5: entry.ts 进程入口 ──────── 环境规范化(env/argv/profile)        ║
║       │   + 第二次 runtime 守卫 + 第二次 respawn 评估                    ║
║       ▼                                                                 ║
║  Layer 6: entry.ts Fast-path ─────── 第二次拦截(含 live config 检查)    ║
║       │   命中 → exit(0)                                                ║
║       ▼                                                                 ║
║  Layer 7: runCli / Commander ──────── 命令树分发                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                                   │
                                   ▼
╔═════════════════════════════════════════════════════════════════════════╗
║  Gateway 启动 (5 阶段)                                                   ║
║  知识库:01-openclaw-architecture/03-startup-flow.md                       ║
║                                                                         ║
║  ① bootstrap → ② early → ③ post-attach → ④ finish → ⑤ plugins          ║
╚═════════════════════════════════════════════════════════════════════════╝
                                   │
                                   ▼
                   ┌───────────────┴───────────────┐
                   │                               │
                   ▼                               ▼
        ┌─────────────────────┐         ┌─────────────────────┐
        │  Agent 运行时        │         │  Channel 通道系统    │
        │  04-agent-runtime  │         │  06-channels        │
        │  • lane 调度        │         │  • Turn 内核         │
        │  • terminal outcome │         │  • 入站消息流程       │
        └──────────┬──────────┘         └──────────┬──────────┘
                   │                               │
                   └───────────────┬───────────────┘
                                   │
                                   ▼
                       ┌───────────────────────┐
                       │  插件系统 (Plugin)     │
                       │  05-plugin-system     │
                       │  • 加载链路             │
                       │  • Hook 体系            │
                       │  • Provider / Tool     │
                       └───────────┬────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
              ▼                    ▼                    ▼
    ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │  协议契约         │  │  状态管理         │  │  配置管理         │
    │  07-protocol     │  │  08-state        │  │  09-config      │
    │  • TypeBox       │  │  • SQLite 双层   │  │  • 三步加载       │
    │  • 13 fragment   │  │  • 22 代 schema  │  │  • 热重载         │
    └──────────────────┘  └──────────────────┘  └──────────────────┘
                                   │
                                   ▼
                       ┌───────────────────────┐
                       │  设计原则 + 评估       │
                       │  10-design-principles│
                       │  11-assessment       │
                       └───────────────────────┘
```

### 接入层关系图

下图展示 OpenClaw 接入层全景:所有用户/客户端如何汇聚到 Gateway HTTP/WS Server,以及各接入方式的协议与覆盖文件。

```
                          用户/客户端
                              │
        ┌─────────────┬───────┼───────┬─────────────┐
        │             │       │       │             │
        ▼             ▼       ▼       ▼             ▼
   CLI 入口      浏览器     原生App  外部工具       渠道平台
   (Layer 1-7)  Control UI iOS/Mac/ OpenAI/MCP  Telegram/
                (HTTP+WS)  Linux/   Compat/     Slack/
                           Android  OpenResp/   Discord/
                                    MCP Loop    WhatsApp...
        │             │       │       │             │
        │             └───────┴───────┘             │
        │                     │                     │
        │                     ▼                     │
        │           ┌──────────────────┐            │
        │           │ Gateway HTTP/WS  │            │
        │           │ Server (根)       │            │
        │           │ server-http.ts    │            │
        │           │ :477              │            │
        │           └────┬─────────┬────┘            │
        │                │         │                 │
        │         ┌──────┘         └──────┐          │
        │         │ WS upgrade            │ WS upgrade│
        │         │ (Gateway)             │ (Worker)  │
        │         ▼                       ▼          │
        │  ┌──────────────┐        ┌──────────────┐  │
        │  │ Gateway WS    │        │ Worker WS     │  │
        │  │ Protocol      │        │ Sub-protocol │  │
        │  │ (frames.ts)   │        │ (worker-     │  │
        │  │                │        │  admission)  │  │
        │  └──────┬────────┘        └──────┬───────┘  │
        │         │                        │          │
        │  ┌──────┴────────────────────────┴─────┐    │
        │  │   Channel 接入(transport-only)   │◄───┘
        │  │   extensions/<id>/ + plugin-sdk    │
        │  └────────────────────────────────────┘
        │                     │
        ▼                     ▼
   Commander 分发     Plugin SDK 接入
   (run-main.ts)      src/plugin-sdk/*
```

### 知识库分层全景图

下图把全部 6 大目录组按**架构分层**对齐,展示从用户到状态层的完整依赖链,以及每组目录覆盖哪一层。

```
┌──────────────────────────────────────────────────────────────────────────┐
│  第 0 层:整体架构与接入面                                                │
│                                                                          │
│  01-openclaw-architecture (顶层 11 章)                                   │
│   ├─ 01.1-external-entry-layer (CLI 启动 7 章)                          │
│   └─ 01.2-access-layers    (接入协议 12 章)                              │
│                                                                          │
│  覆盖:定位 / 模块边界 / 启动流程 / Agent / 插件 / 通道 / 协议 / 状态 / 配置│
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ 依赖
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  第 1 层:基础设施层  02-foundation-layer                                │
│                                                                          │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────────┐ │
│  │ 02.1-state   │ │ 02.2-config  │ │ 02.3-infra  │ │ 02.4-ai-prov   │ │
│  │ SQLite 双层  │ │ 三步加载     │ │ FS/网络/TLS │ │ LLM Provider   │ │
│  │ Schema 演进  │ │ 类型系统     │ │ 进程/平台    │ │ 抽象层         │ │
│  └──────────────┘ └──────────────┘ └──────────────┘ └────────────────┘ │
│                                                                          │
│  职责:被所有上层依赖,提供数据 / 配置 / 工具 / LLM 基础                  │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ 依赖
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  第 2 层:运行时核心  03-runtime-core                                     │
│                                                                          │
│  ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐  │
│  │ 03.1-agent-sessions│ │ 03.2-gateway-      │ │ 03.3-plugin-       │  │
│  │ 会话生命周期       │ │ internal           │ │ registry           │  │
│  │ 分支树 / 压缩      │ │ 启动 / 认证 / 对话 │ │ 注册 / Provider    │  │
│  │ 认证 / 扩展        │ │ 凭据监控           │ │ 加载器 / 目录      │  │
│  └────────────────────┘ └────────────────────┘ └────────────────────┘  │
│                                                                          │
│  职责:Agent / Gateway / 插件注册表的运行时编排                           │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ 依赖
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  第 3 层:扩展能力  04-extension-capabilities                            │
│                                                                          │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐              │
│  │ 04.1-hooks   │ │ 04.2-cron    │ │ 04.3-agent-tools   │              │
│  │ 事件驱动延伸 │ │ 定时任务系统 │ │ Agent 工具集       │              │
│  │ 配置/加载/   │ │ 调度/存储/   │ │ 内置/Web/会话/     │              │
│  │ 平台集成     │ │ 重试/监控    │ │ 媒体/其他          │              │
│  └──────────────┘ └──────────────┘ └────────────────────┘              │
│                                                                          │
│  职责:核心运行时的事件驱动延伸与工具能力扩展                             │
└──────────────────────────────────────────────────────────────────────────┘
```

#### 与 `01-openclaw-architecture` 的对应关系

| 01 顶层章节 | 对应细化目录 | 说明 |
|---|---|---|
| `03-startup-flow.md` | 01.1 + 01.2 | CLI 启动链路 + Gateway 接入面 |
| `04-agent-runtime.md` | 03.1-agent-sessions | Agent 会话生命周期细化 |
| `05-plugin-system.md` | 03.3 + 04.1 + 04.3 | 插件注册表 + Hook + 工具集 |
| `06-channels.md` | (已在 01.2-access-layers/08 覆盖) | 渠道接入 |
| `08-state.md` | 02.1-state | SQLite 双层 + Schema 演进细化 |
| `09-config.md` | 02.2-config | 配置三步加载细化 |
| Gateway 内部 | 03.2-gateway-internal | 启动/认证/对话/凭据监控 |
| 基础设施原语 | 02.3-infra | FS/网络/TLS/进程/平台 |
| LLM 抽象 | 02.4-ai-providers | Provider 契约/实现/传输 |
| 定时任务 | 04.2-cron | 调度/存储/重试/监控 |

接入层详细分析见 [01.2-access-layers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers) 目录。

#### 接入层 ↔ 知识库文件映射

| 接入层 | 协议 | 覆盖文件 |
|---|---|---|
| Gateway HTTP/WS Server(核心根) | HTTP + WS upgrade | [01.2-access-layers/01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) |
| Gateway WebSocket 协议 | WS(RPC + 事件) | [01.2-access-layers/02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) |
| Worker 接入 | WS(独立子协议) | [01.2-access-layers/03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) |
| OpenAI / OpenResponses REST | HTTP(`/v1/*`) | [01.2-access-layers/04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) |
| MCP 接入(3 个接入面) | HTTP + JSON-RPC | [01.2-access-layers/05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) |
| Control UI | HTTP + WS | [01.2-access-layers/06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) |
| Plugin HTTP/Upgrade | HTTP + WS(插件自定义) | [01.2-access-layers/07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) |
| Channel 渠道接入 | 因渠道而异 | [01.2-access-layers/08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) |
| Plugin SDK 接入 | ESM 包导入 | [01.2-access-layers/09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) |
| 原生 App(iOS/macOS/Linux/Android/watchOS) | WS | [01.2-access-layers/10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) |
| Node Host + Probe | WS(轻量) | [01.2-access-layers/11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) |
| 认证统一面 + ClientId 注册表 | - | [01.2-access-layers/12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) |

## 目录结构导航

每条目录后附主题说明,点击文件名即可跳转打开。

### 📁 [01-openclaw-architecture/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture) — 整体架构分析(顶层)

覆盖 OpenClaw 全部核心子系统:定位、模块边界、启动流程、Agent、插件、通道、协议、状态、配置、设计原则、风险评估。作为顶层概览,下属两个细化目录(01.1-external-entry-layer、01.2-access-layers)分别展开 CLI 启动链路与 Gateway 接入协议细节。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) — 总览与索引,含静态分层视图、动态流程视图、入站消息流程图
- [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) — 顶层定位与技术栈(Node 22+/24+/25+,TS ESM strict,SQLite-only,TypeBox 协议)
- [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) — 模块地图与目录职责(src/gateway / src/agents / src/channels / src/plugins / src/plugin-sdk / packages/gateway-protocol / extensions)
- [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) — CLI → Gateway 启动流程(5 阶段:bootstrap / early / post-attach / finish / plugins)
- [04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/04-agent-runtime.md) — Agent 运行时流程(lane 并发控制、terminal outcome 归一化)
- [05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/05-plugin-system.md) — 插件系统(加载链路 loader → registry、Hook 体系、Provider/Tool 系统)
- [06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/06-channels.md) — 通道系统(Turn 内核、`ChannelTurnAdmission` 4 种 kind、入站消息流程)
- [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) — Gateway 协议与 Schema(PROTOCOL_VERSION=4、13 fragment 分片、TypeBox 校验)
- [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) — SQLite 状态管理(双层结构:共享 state DB + per-agent DB、22 代 schema 演进)
- [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) — 配置加载与迁移(三步:read → migrate → validate、热重载机制)
- [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) — 关键设计原则(Owner 边界、兼容性策略、Lean Code、Hot Path 优化、TS 严格)
- [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) — 评估与风险点(5 优点 + 8 风险 + 待精读项清单)

### 📁 [01.1-external-entry-layer/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer) — 外部入口层深入分析(01 的子层 1)

聚焦 `openclaw.mjs` + `src/entry.ts` + `src/cli/run-main.ts` 三层 launcher 链路的细节,涵盖 fast-path、respawn、信号转发、runtime 守卫等。是 01-openclaw-architecture/03-startup-flow.md 在 CLI 启动链路方向的细化展开。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) — 概览与索引,含 7 层静态分层视图与启动决策树
- [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) — 7 层层次结构与职责(npm bin → runtime 守卫 → fast-path → import TS → entry.ts → Commander)
- [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) — 三层 fast-path 体系 + 预计算 metadata(`dist/cli-startup-metadata.json`)
- [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) — Respawn 体系(源码 checkout / 打包安装 / NODE_OPTIONS 三场景)+ 信号转发三层 grace
- [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) — 双重 runtime 守卫 + Node/Bun 版本兼容矩阵
- [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) — 完整调用流程图(从 `openclaw <args>` 到 Commander 分发的全链路)
- [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) — 设计评估(6 优点 + 7 风险,含矩阵图)
- [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) — 关键源码索引(Launcher / Entry / CLI / Infra / Process / 构建脚本)

### 📁 [01.2-access-layers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers) — 接入层深入分析(01 的子层 2)

聚焦 Gateway HTTP/WS Server 之后的所有接入协议:14 类接入方式、3 类接入方式(直接 HTTP/WS、通过渠道插件、通过 SDK)、统一认证面、ClientId 注册表。是 01-openclaw-architecture/03-startup-flow.md 在 Gateway 接入面方向的细化展开。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) — 概览与索引,含接入层清单、关系图、协议版本层级
- [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) — Gateway HTTP/WS Server(核心根,所有接入的统一汇聚点)
- [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) — Gateway WebSocket 协议(客户端接入,含握手时序、HelloOk 协商)
- [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) — Worker 接入(独立子协议,WS upgrade 分离,16 种关闭原因)
- [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) — OpenAI / OpenResponses REST API 接入(`/v1/*` 路由,Bearer token)
- [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) — MCP 接入(三个接入面:Loopback HTTP / App Standalone / Connection 反向)
- [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) — Control UI 接入(浏览器 UI,HTTP 静态资源 + WS + CSP + device auth migration)
- [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) — Plugin HTTP/Upgrade 接入(插件自定义 HTTP 路由与 WS upgrade,webhook 场景)
- [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) — Channel 渠道接入(25+ 渠道:Telegram/WhatsApp/LINE/Slack/Discord/SMS/IRC 等,transport-only)
- [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) — Plugin SDK 接入(插件作者,`openclaw/plugin-sdk/*` ESM 包导入,数百个 `*-runtime.ts` 接缝)
- [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) — 原生 App 接入(iOS/macOS/Linux Tauri/Android/Wear OS/watchOS,统一 WS 协议)
- [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) — Node Host + Probe 接入(配对节点提供远程计算 + 健康探测,协议 ≥3)
- [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) — 认证统一面(7 种 method)+ ClientId 注册表(16 类客户端)+ 协议版本管理

---

## 📁 第 1 层:02-foundation-layer/ — 基础设施层(4 子目录 16 章)

被所有上层依赖,提供数据 / 配置 / 工具 / LLM 基础。是 `01-openclaw-architecture/08-state.md` 与 `09-config.md` 的细化展开。

### 📂 [02.1-state/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state) — 状态层(SQLite 双层结构,4 章)

按上下游递进:契约 → 实现 → 演进 → 维护。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) — 总览:SQLite 双层结构 + 状态层组件全景
- [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) — 共享状态库(`state/openclaw.sqlite`):契约、schema-helpers、permissions、readonly
- [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) — Per-agent 状态库(`agents/<id>/agent/openclaw-agent.sqlite`):契约、lease、registry
- [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) — Schema 演进:22 代版本管理、additive 变更、migration 策略
- [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) — 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration

### 📂 [02.2-config/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config) — 配置层(三步加载,3 章)

把磁盘配置文件 + 环境变量转化为运行时可消费的规范形态。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config/00-overview.md) — 总览:IO 操作 + 类型系统 + Schema 变更三层组件协作
- [01-io-operations.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config/01-io-operations.md) — IO 操作层:快照读取(含恢复)、安全写入(原子+备份)、审计日志
- [02-type-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config/02-type-system.md) — 类型系统:TypeBox schema、LoadedConfig 形态、环境变量合并
- [03-schema-mutation.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.2-config/03-schema-mutation.md) — Schema 变更:migration 规则、doctor --fix 修平、兼容性策略

### 📂 [02.3-infra/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra) — 基础设施原语(4 章)

最底层工具集,不含任何业务语义,不知道 Agent / 插件 / 渠道为何物。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) — 总览:FS/路径/环境 → 网络/TLS → 执行/进程 → 平台适配 四层结构
- [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) — 文件系统 / 路径 / 环境:realpath 规范、tmp 根、env 合并
- [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) — 网络 / TLS:端口分配、证书校验、代理策略
- [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) — 执行 / 进程:子进程 spawn、信号转发、超时控制
- [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) — 平台特定:macOS / Linux / Windows 差异处理

### 📂 [02.4-ai-providers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers) — LLM Provider 抽象层(4 章)

把 LLM 厂商抽象成可替换的 Provider,核心运行时不绑定特定厂商。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers/00-overview.md) — 总览:Provider 核心契约 + 实现 + 传输 + 工具 四层结构
- [01-provider-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers/01-provider-core.md) — Provider 核心契约:共享类型、校验器、事件流契约
- [02-provider-implementations.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers/02-provider-implementations.md) — Provider 实现:OpenAI / Anthropic / 本地模型 等适配器
- [03-transports.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers/03-transports.md) — 传输层:流式返回、代理 / TLS 策略
- [04-utils-internal.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.4-ai-providers/04-utils-internal.md) — 工具层:token 计数、重试、错误归一化

---

## 📁 第 2 层:03-runtime-core/ — 运行时核心(3 子目录 17 章)

依赖第 1 层,是 Agent / Gateway / 插件注册表的运行时编排核心。

### 📂 [03.1-agent-sessions/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions) — Agent 会话管理(5 章)

Agent Runner 的实现细节层,在 per-agent SQLite 之上提供会话生命周期。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/00-overview.md) — 总览:会话生命周期 + 管理器 + 提示词 + 认证 + 压缩 五类组件
- [01-session-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/01-session-lifecycle.md) — 会话生命周期:创建、执行、压缩、终态归一化
- [02-session-manager.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/02-session-manager.md) — 会话管理器:分支树管理、持久化、编解码
- [03-prompt-model.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/03-prompt-model.md) — 提示词模型:系统提示、模板、变量绑定
- [04-auth-execution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/04-auth-execution.md) — 认证与执行:凭据存储、OAuth 注册表、Bash 执行器
- [05-compaction-extensions.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/05-compaction-extensions.md) — 压缩与扩展:分支摘要、上下文压缩、扩展加载器

### 📂 [03.2-gateway-internal/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal) — Gateway 内部编排(6 章)

接入面与 Agent 运行时之间的"操作系统"。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/00-overview.md) — 总览:启动编排 + 认证内部 + 客户端对话 + 凭据监控 六类组件
- [01-boot-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/01-boot-lifecycle.md) — 启动与生命周期:5 阶段启动编排
- [02-auth-internal.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/02-auth-internal.md) — 认证内部:7 种认证方式归一为单一结果
- [03-client-conversation.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/03-client-conversation.md) — 客户端与对话:连接生命周期、对话投影
- [04-chat-display.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/04-chat-display.md) — 聊天显示:投影而非状态机管理
- [05-control-ui-backend.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/05-control-ui-backend.md) — Control UI 后端:HTTP 子面提供 UI 能力
- [06-credentials-monitoring.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/06-credentials-monitoring.md) — 凭据规划、渠道健康、定时流、执行审批

### 📂 [03.3-plugin-registry/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry) — 插件注册表(5 章)

运行时核心的"能力中枢",把外部插件能力按类别登记到进程内。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) — 总览:注册表分层结构 + 外部上下文
- [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) — 注册表核心:Provider / Tool / Hook / Channel / Web 能力登记
- [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) — Provider 运行时:模型路由、auth 处理
- [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) — Plugin 运行时:生命周期、Hook 执行
- [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) — 加载器与发现:已安装插件发现、manifest 加载
- [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) — Web 会话目录:能力来源与公开产物

---

## 📁 第 3 层:04-extension-capabilities/ — 扩展能力(3 子目录 15 章)

依赖第 2 层,是核心运行时的事件驱动延伸与工具能力扩展。

### 📂 [04.1-hooks/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks) — Hook 系统(3 章)

运行时的"事件驱动延伸层",监听 Agent / Gateway / 会话事件执行自定义逻辑。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks/00-overview.md) — 总览:四类 Hook 来源(打包内置 / 插件 / 托管 / 工作区)+ 配置/加载/执行三层
- [01-config-policy.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks/01-config-policy.md) — 配置与策略层:Hook 配置 schema、信任策略、优先级
- [02-loader-install.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks/02-loader-install.md) — 加载与安装:发现、加载、安装流程
- [03-gmail-platform.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.1-hooks/03-gmail-platform.md) — Gmail 平台集成:作为 Hook 来源的完整示例

### 📂 [04.2-cron/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron) — 定时任务系统(4 章)

调度服务、存储层、投递重试、退出监控。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/00-overview.md) — 总览:调度 + 存储 + 投递 + 监控 四层
- [01-schedule-service.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/01-schedule-service.md) — 调度服务:cron 表达式解析、触发
- [02-store-schema.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/02-store-schema.md) — 存储与 Schema:SQLite 持久化、数据结构
- [03-delivery-retry.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/03-delivery-retry.md) — Delivery 与重试:投递机制、重试策略
- [04-cron-exit-watchers.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/04-cron-exit-watchers.md) — 退出监控:进程退出时的清理与持久化

### 📂 [04.3-agent-tools/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools) — Agent 工具集(5 章)

Agent 可调用的工具集合,按层次组织(内置 / Web / 会话 / 媒体 / 其他)。

- [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) — 总览:工具层次结构 + 确定性排序 + 安全沙箱
- [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) — 内置工具:bash / edit / find / grep
- [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) — Web 工具:fetch / search / guarded / shared
- [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) — 会话工具:list / history / send / spawn
- [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) — 媒体工具:image / music / video / pdf
- [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) — 其他工具:computer / terminal / tts / dashboard

## 阅读建议

### 按学习目标选择入口

| 学习目标 | 推荐阅读顺序 |
|---|---|
| **理解全局架构** | 01-openclaw-architecture/01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 |
| **深入启动链路** | 01-openclaw-architecture/03(高层)→ 01.1-external-entry-layer/01 → 02 → 03 → 04 → 05(细节) |
| **理解接入层** | 01.2-access-layers/00 → 01(根)→ 02(WS 协议)→ 03-11(各类接入)→ 12(认证与 ClientId) |
| **理解状态层** | 01-openclaw-architecture/08(高层)→ 02.1-state/00 → 01(共享库)→ 02(Agent 库)→ 03(Schema 演进)→ 04(租约) |
| **理解配置层** | 01-openclaw-architecture/09(高层)→ 02.2-config/00 → 01(IO)→ 02(类型系统)→ 03(Schema 变更) |
| **理解 LLM 抽象** | 02.4-ai-providers/00 → 01(核心契约)→ 02(实现)→ 03(传输)→ 04(工具) |
| **理解 Agent 会话** | 01-openclaw-architecture/04(高层)→ 03.1-agent-sessions/00 → 01(生命周期)→ 02(管理器)→ 05(压缩) |
| **理解 Gateway 内部** | 03.2-gateway-internal/00 → 01(启动)→ 02(认证)→ 03(客户端对话)→ 06(凭据监控) |
| **理解插件注册表** | 03.3-plugin-registry/00 → 01(注册核心)→ 04(加载器)→ 02(Provider 运行时) |
| **理解 Hook 系统** | 04.1-hooks/00 → 01(配置策略)→ 02(加载安装)→ 03(Gmail 示例) |
| **理解定时任务** | 04.2-cron/00 → 01(调度)→ 02(存储)→ 03(投递重试)→ 04(退出监控) |
| **理解 Agent 工具集** | 04.3-agent-tools/00 → 01(内置)→ 02(Web)→ 03(会话)→ 04(媒体)→ 05(其他) |
| **快速上手开发插件** | 01-openclaw-architecture/02(模块边界)→ 05(插件系统)→ 01.2-access-layers/09(Plugin SDK)→ 10(设计原则) |
| **理解 Agent 运行时** | 01-openclaw-architecture/04 → 06(通道)→ 05(插件 Hook)→ 01.2-access-layers/08(Channel 接入) |
| **排查启动问题** | 01.1-external-entry-layer/05(调用流程)→ 03(respawn)→ 04(runtime 守卫) |
| **排查接入认证问题** | 01.2-access-layers/12(认证面 + ClientId)→ 01(Gateway HTTP/WS)→ 02(WS 协议握手) |
| **排查状态/Schema 问题** | 02.1-state/03(Schema 演进)→ 04(租约维护)→ 02.2-config/03(doctor --fix) |
| **评估技术选型** | 01-openclaw-architecture/11(评估)→ 10(设计原则)→ 01(技术栈)→ 01.2-access-layers/00(接入层全景) |
| **接入外部消息平台** | 01.2-access-layers/08(渠道接入)→ 07(Plugin HTTP)→ 09(Plugin SDK) |
| **自下而上读全栈** | 02-foundation-layer(全部)→ 03-runtime-core(全部)→ 04-extension-capabilities(全部) |

### 知识库关系图

下图展示全部 6 大目录组的依赖与细化关系。**先看这张图建立全局心智模型**。

```
┌──────────────────────────────────────────────────────────────────────────┐
│  第 0 层:01-openclaw-architecture/(整体架构,11 章)                      │
│                                                                          │
│  01-positioning ──► 02-module-map ──► 03-startup-flow ──┐               │
│                                              │           │               │
│  04-agent-runtime ◄── 05-plugin ◄── 06-channels          │               │
│       │                  │                  │            │               │
│       ▼                  ▼                  ▼            │               │
│  07-protocol ──► 08-state ──► 09-config ──► 10-principles               │
│                                              │           │               │
│                                              ▼           │               │
│                                         11-assessment    │               │
└──────────────────────────────────────────────┼────────────┘               │
                                               │                            │
                ┌──────────────────────────────┼────────────┐               │
                │                              │            │               │
                │ 细化展开                     │            │ 细化展开      │
                ▼ (CLI 启动)                  │            ▼ (Gateway 接入) │
   ┌─────────────────────────────┐            │   ┌─────────────────────────┴──┐
   │ 01.1-external-entry-layer/   │            │   │ 01.2-access-layers/        │
   │ (外部入口层,7 章)          │            │   │ (接入层,12 章)            │
   └─────────────────────────────┘            │   └────────────────────────────┘
                                               │
                       ┌───────────────────────┼───────────────────────┐
                       │                       │                       │
                       ▼ (状态/配置细化)       ▼ (Agent 细化)          ▼ (插件细化)
┌──────────────────────────────┐  ┌──────────────────────────┐  ┌────────────────────────┐
│  第 1 层:02-foundation-layer │  │  第 2 层:03-runtime-core│  │  第 3 层:04-extension │
│  (基础设施,4 子目录 16 章)  │  │  (运行时核心,3 子目录   │  │  (扩展能力,3 子目录   │
│                              │  │   17 章)                │  │   15 章)              │
│  02.1-state ◄── 02.2-config │  │                          │  │                       │
│       │              │        │  │  03.1-agent-sessions     │  │  04.1-hooks           │
│       ▼              ▼        │  │       ▲                  │  │       ▲               │
│  02.3-infra ◄── 02.4-ai-prov │  │  03.2-gateway-internal   │  │  04.2-cron            │
│                              │  │       ▲                  │  │       ▲               │
│  (被 03/04 所有组件依赖)    │  │  03.3-plugin-registry     │  │  04.3-agent-tools     │
└──────────────┬───────────────┘  │                          │  │                       │
               │                  │  (依赖 02,被 04 依赖)  │  │  (依赖 03)            │
               └──────────────────►└────────────┬─────────────┘  └───────────▲───────────┘
                                   │            │                            │
                                   └────────────┴────────────────────────────┘
                                                依赖链:02 → 03 → 04
```

#### 01.x 内部详细关系图

```
┌─────────────────────────────────────────────────────────────────┐
│                  01-openclaw-architecture/                          │
│                  (整体架构,11 章覆盖全栈)                         │
│                                                                  │
│  01-positioning ──► 02-module-map ──► 03-startup-flow ──┐       │
│                                              │           │       │
│  04-agent-runtime ◄── 05-plugin ◄── 06-channels          │       │
│       │                  │                  │            │       │
│       ▼                  ▼                  ▼            │       │
│  07-protocol ──► 08-state ──► 09-config ──► 10-principles │       │
│                                              │           │       │
│                                              ▼           │       │
│                                         11-assessment    │       │
└──────────────────────────────────────────────────────────┼────────┘
                                                           │
                       ┌───────────────────────────────────┼───┐
                       │                                   │   │
                       │ 细化展开                          │   │
                       ▼ (CLI 启动链路)                    │   │ 细化展开
┌──────────────────────────────────────────────┐           │   │ (Gateway 接入面)
│                  01.1-external-entry-layer/       │           │   │
│                  (外部入口层,7 章)            │           │   ▼
│                                              │           │   ┌──────────────────────────────────────┐
│  00-overview ──► 01-layer-arch ──► 02-fast   │           │   │                  01.2-access-layers/        │
│                                  │            │           │   │                  (接入层,12 章)        │
│  06-design ◄── 05-call ◄── 03-respawn       │           │   │                                      │
│       │              │            │           │           │   │  00-overview(清单 + 关系图)         │
│       ▼              ▼            ▼           │           │   │   │                                  │
│  07-source    04-runtime-guard    │           │           │   │   ▼                                  │
│                                  │           │           │   │  01-gateway-http-ws(根)            │
│  (Layer 1-7:CLI → Commander)    │           │           │   │   │                                  │
└──────────────────────────────────┘           │           │   │   ▼                                  │
                                               │           │   │  02-gateway-ws-protocol              │
                       Layer 1-7 (CLI)         │           │   │   ├─► 03-11(各类接入)                │
                       ─────────────────────────┘           │   │   ▼                                  │
                                                             │   │  12-auth-clients(认证 + ClientId)   │
                                                             │   └──────────────────────────────────────┘
```

## 文件统计

| 知识库 | 文件数 | 章节数 | ASCII 架构图/流程图数 |
|---|---|---|---|
| 01-openclaw-architecture | 12 | 11(00 为索引) | 40 |
| 01.1-external-entry-layer | 8 | 7(00 为索引) | 12 |
| 01.2-access-layers | 13 | 12(00 为索引) | 26 |
| 02.1-state | 5 | 4(00 为索引) | 12 |
| 02.2-config | 4 | 3(00 为索引) | 9 |
| 02.3-infra | 5 | 4(00 为索引) | 10 |
| 02.4-ai-providers | 5 | 4(00 为索引) | 11 |
| 03.1-agent-sessions | 6 | 5(00 为索引) | 14 |
| 03.2-gateway-internal | 7 | 6(00 为索引) | 15 |
| 03.3-plugin-registry | 6 | 5(00 为索引) | 12 |
| 04.1-hooks | 4 | 3(00 为索引) | 8 |
| 04.2-cron | 5 | 4(00 为索引) | 10 |
| 04.3-agent-tools | 6 | 5(00 为索引) | 12 |
| **合计** | **86** | **73** | **191** |

## 分析方法说明

- **全部基于源码直读**,引用文件路径 + 行号(如 [openclaw.mjs L147-L148](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs#L147-L148))
- **未深入项明确标注"待精读"**,不臆测
- **ASCII 图用于可视化决策树与时序**,文本用于精确说明
- **每个文件独立可读**,但也按章节序号有依赖关系
- **代码引用使用 `file:///` 协议**,在 VSCode / GitHub 中可直接点击跳转
