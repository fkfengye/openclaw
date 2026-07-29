# OpenClaw 知识库导航

本知识库基于 OpenClaw 源码直读分析,采用**层级编号**组织(`01` 父级 → `01.1`/`01.2` 子级):
- **[01-openclaw-architecture/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture)** — 整体架构分析(顶层,11 章)
  - **[01.1-external-entry-layer/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer)** — 外部入口层深入分析(子层 1,7 章,CLI 启动链路细化)
  - **[01.2-access-layers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers)** — 接入层深入分析(子层 2,12 章,Gateway 接入面细化)

层级关系:
- `01.1-external-entry-layer` 是 `01-openclaw-architecture/03-startup-flow.md` 的细化展开(CLI 启动链路,Layer 1-7)
- `01.2-access-layers` 是 `01-openclaw-architecture/03-startup-flow.md` 在 Gateway 接入面的细化展开(Gateway HTTP/WS Server 之后的所有接入协议)
- `01.1` 与 `01.2` 互补:前者覆盖 Layer 1-7(CLI → Commander),后者覆盖 Layer 7 之后的接入协议(Gateway HTTP/WS → 各类客户端)

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

## 阅读建议

### 按学习目标选择入口

| 学习目标 | 推荐阅读顺序 |
|---|---|
| **理解全局架构** | 01-openclaw-architecture/01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11 |
| **深入启动链路** | 01-openclaw-architecture/03(高层)→ 01.1-external-entry-layer/01 → 02 → 03 → 04 → 05(细节) |
| **理解接入层** | 01.2-access-layers/00 → 01(根)→ 02(WS 协议)→ 03-11(各类接入)→ 12(认证与 ClientId) |
| **快速上手开发插件** | 01-openclaw-architecture/02(模块边界)→ 05(插件系统)→ 01.2-access-layers/09(Plugin SDK)→ 10(设计原则) |
| **理解 Agent 运行时** | 01-openclaw-architecture/04 → 06(通道)→ 05(插件 Hook)→ 01.2-access-layers/08(Channel 接入) |
| **排查启动问题** | 01.1-external-entry-layer/05(调用流程)→ 03(respawn)→ 04(runtime 守卫) |
| **排查接入认证问题** | 01.2-access-layers/12(认证面 + ClientId)→ 01(Gateway HTTP/WS)→ 02(WS 协议握手) |
| **评估技术选型** | 01-openclaw-architecture/11(评估)→ 10(设计原则)→ 01(技术栈)→ 01.2-access-layers/00(接入层全景) |
| **接入外部消息平台** | 01.2-access-layers/08(渠道接入)→ 07(Plugin HTTP)→ 09(Plugin SDK) |

### 知识库关系图

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
│                  (外部入口层,7 章)            │           │   │
│                                              │           │   ▼
│  00-overview ──► 01-layer-arch ──► 02-fast   │           │   ┌──────────────────────────────────────┐
│                                  │            │           │   │                  01.2-access-layers/        │
│  06-design ◄── 05-call ◄── 03-respawn       │           │   │                  (接入层,12 章)        │
│       │              │            │           │           │   │                                      │
│       ▼              ▼            ▼           │           │   │  00-overview(清单 + 关系图)         │
│  07-source    04-runtime-guard    │           │           │   │   │                                  │
│                                  │           │           │   │   ▼                                  │
│  (Layer 1-7:CLI → Commander)    │           │           │   │  01-gateway-http-ws(根)            │
│                                  │           │           │   │   │                                  │
│                                  │           │           │   │   ▼                                  │
│                                  │           │           │   │  02-gateway-ws-protocol              │
│                                  │           │           │   │   │                                  │
│                                  │           │           │   │   ├─► 03-worker-admission           │
│                                  │           │           │   │   ├─► 04-openai-openresponses       │
│                                  │           │           │   │   ├─► 05-mcp                        │
│                                  │           │           │   │   ├─► 06-control-ui                │
│                                  │           │           │   │   ├─► 07-plugin-http               │
│                                  │           │           │   │   ├─► 08-channels                   │
│                                  │           │           │   │   ├─► 09-plugin-sdk                 │
│                                  │           │           │   │   ├─► 10-native-apps               │
│                                  │           │           │   │   └─► 11-node-host-probe           │
│                                  │           │           │   │   │                                  │
│                                  │           │           │   │   ▼                                  │
│                                  │           │           │   │  12-auth-clients(认证 + ClientId)   │
│                                  │           │           │   │                                      │
│                                  │           │           │   │  (Gateway HTTP/WS → 各类客户端)       │
└──────────────────────────────────┘           │           │   └──────────────────────────────────────┘
                                               │           │
                       Layer 1-7 (CLI)         │           │   Layer 7 之后(Gateway 接入)
                       ─────────────────────────┘           └───────────────────────────
```

## 文件统计

| 知识库 | 文件数 | 章节数 | ASCII 架构图/流程图数 |
|---|---|---|---|
| 01.1-external-entry-layer | 8 | 7(00 为索引) | 12 |
| 01-openclaw-architecture | 12 | 11(00 为索引) | 40 |
| 01.2-access-layers | 13 | 12(00 为索引) | 26 |
| **合计** | **33** | **30** | **78** |

## 分析方法说明

- **全部基于源码直读**,引用文件路径 + 行号(如 [openclaw.mjs L147-L148](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs#L147-L148))
- **未深入项明确标注"待精读"**,不臆测
- **ASCII 图用于可视化决策树与时序**,文本用于精确说明
- **每个文件独立可读**,但也按章节序号有依赖关系
- **代码引用使用 `file:///` 协议**,在 VSCode / GitHub 中可直接点击跳转
