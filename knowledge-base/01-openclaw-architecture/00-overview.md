# 00 — OpenClaw 整体架构总览

> 这是知识库的入口。读完本章你将理解:OpenClaw 是什么、由哪些组件构成、组件之间如何协作、消息如何流动。

## 一句话定位

OpenClaw 是一个**本地优先的多渠道 AI 助手 Gateway**:
- 自研 WebSocket 协议连接所有客户端
- SQLite 作为唯一状态层
- 所有渠道(25+)与能力(browser/canvas/cron 等)以插件形式接入
- 核心保持插件无关,扩展点全部走 SDK 边界

## 全局架构图

下图展示 OpenClaw 的组件分层与协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       外部世界(用户与客户端)                          │
│                                                                      │
│   CLI 用户    浏览器用户   原生 App 用户   外部工具    渠道平台用户    │
│   (终端)     (Control UI) (iOS/Mac/...)  (OpenAI/MCP) (Telegram/Slack)│
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 各种协议(HTTP/WS/Bot API/REST)
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       接入层(Access Layer)                          │
│                                                                      │
│         所有接入汇聚到 Gateway HTTP/WS Server                         │
│         (统一认证面 + 协议版本管理 + ClientId 注册表)                │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Gateway 核心(Gateway Core)                    │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 启动编排    │  │ 配置管理    │  │ Lane 调度   │  │ 认证面    │ │
│   │ (5 阶段)    │  │ (三步加载)  │  │ (并发控制)  │  │ (7 method)│ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            │                  │                  │
            ▼                  ▼                  ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  Agent 运行时    │ │  插件系统        │ │  通道系统        │
│                  │ │                  │ │                  │
│ • Runner 编排    │ │ • 加载器         │ │ • Turn 内核      │
│ • 终态归一化      │ │ • Hook 体系      │ │ • 持久化投递     │
│ • 依赖注入       │ │ • Provider/Tool  │ │ • 防死循环        │
└────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘
         │                    │                    │
         │     ┌──────────────┴──────────────┐     │
         │     │                             │     │
         │     ▼                             ▼     │
         │  ┌────────────────────────────────────┐ │
         │  │  外部插件仓库(extensions/*)        │ │
         │  │                                    │ │
         │  │  渠道插件:                         │ │
         │  │  WhatsApp/Telegram/Slack/Discord   │ │
         │  │  /Signal/iMessage/SMS/Teams/      │ │
         │  │  Matrix/Feishu/LINE/QQ/WebChat    │◄┘
         │  │                                    │
         │  │  能力插件:                         │
         │  │  browser/canvas/cron/nodes/        │
         │  │  sessions/discord-actions/...       │
         │  └────────────────────────────────────┘
         │                    │
         ▼                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       状态层(State Layer)                           │
│                                                                      │
│   ┌──────────────────────┐    ┌──────────────────────────────────┐  │
│   │  共享状态库           │    │  Per-Agent 状态库                │  │
│   │                      │    │                                  │  │
│   │  • 全局运行时状态     │    │  • 单个 Agent 的会话历史          │  │
│   │  • 插件 KV 数据       │    │  • Agent 范围的缓存                │  │
│   │  • 跨 Agent 共享数据  │    │  • 运行记录                      │  │
│   └──────────────────────┘    └──────────────────────────────────┘  │
│                                                                      │
│   规则:SQLite 唯一 | 写事务同步 commit | 禁止 JSON/sidecar 文件     │
└──────────────────────────────────────────────────────────────────────┘

    横向贯穿层(对上方所有层提供契约):

┌──────────────────────────────────────────────────────────────────────┐
│  协议契约              │  SDK 边界              │  AGENTS.md 约束     │
│  (TypeBox Schema)      │  (插件唯一入口)        │  (硬规则)          │
│                                                                      │
│  • 协议版本管理        │  • 数百个运行时接缝    │  • 边界强约束      │
│  • 版本 bump 需确认   │  • 禁止 import 核心    │  • 兼容性策略       │
│  • 校验器 + 迁移      │  • 禁止 import 其他插件│  • 状态/配置规则   │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

OpenClaw 由 8 类核心组件构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **接入层** | 接收所有外部客户端连接,汇聚到 Gateway HTTP/WS Server | 统一认证面,ClientId 注册表管理 17 类客户端 |
| **Gateway 核心** | 启动编排、配置管理、并发调度、认证 | 启动分 5 阶段,配置只支持最新 shape |
| **Agent 运行时** | 一次 agent run 的总编排,调用 LLM + 工具,产出回复 | 终态归一化是硬约束,依赖注入便于测试 |
| **插件系统** | 加载/注册/Hook 体系,提供 Provider 与 Tool 能力 | 插件只能通过 SDK 边界访问核心 |
| **通道系统** | Turn 内核处理消息流转,持久化投递,防死循环 | 4 种 Admission 策略(dispatch/observeOnly/handled/drop) |
| **状态层** | SQLite 双层结构:共享 DB + per-agent DB | 唯一存储,禁止 JSON/sidecar,写事务同步 |
| **协议契约** | TypeBox Schema 定义所有消息格式 | 版本 bump 需 owner 显式确认 |
| **SDK 边界** | 插件访问核心的唯一通道 | 禁止 import 核心 src,禁止 import 其他插件 |

## 关联关系

### 组件协作总图

```
   ┌─────────────┐
   │  外部客户端  │
   │  (CLI/UI/   │
   │   App/Bot)  │
   └──────┬──────┘
          │ 各种协议
          ▼
   ┌─────────────┐
   │  接入层     │ ──认证──► Gateway 核心
   │             │              │
   └──────┬──────┘              │
          │                     ▼
          │             ┌─────────────┐
          │             │ Lane 调度   │
          │             │ (并发控制)  │
          │             └──────┬──────┘
          │                    │
          │                    ▼
          │             ┌─────────────┐
          │             │ Agent Runner│
          │             │ (消息处理)  │
          │             └──────┬──────┘
          │                    │
          │      ┌─────────────┼─────────────┐
          │      │             │             │
          │      ▼             ▼             ▼
          │ ┌────────┐  ┌────────────┐  ┌────────┐
          │ │Provider│  │ Tool 注册表 │  │ 状态库 │
          │ │ (LLM) │  │ (插件工具)  │  │(SQLite)│
          │ └────┬───┘  └────────────┘  └────────┘
          │      │
          │      ▼
          │ ┌────────┐
          │ │  LLM   │
          │ │(外部) │
          │ └────────┘
          │
          ▼
   ┌─────────────┐
   │  回复分发   │
   │  (回原渠道) │
   └─────────────┘
```

### 插件与核心的边界

```
   ┌──────────────────────────────────────────────────┐
   │  核心运行时(src/)                              │
   │                                                  │
   │  • Gateway 编排     • Agent Runner              │
   │  • Turn 内核        • 状态层                    │
   │                                                  │
   └──────────────────────┬───────────────────────────┘
                          │
                          │ 只能通过 SDK 边界访问
                          │
   ┌──────────────────────▼───────────────────────────┐
   │  SDK 边界(src/plugin-sdk/*)                   │
   │                                                  │
   │  • 数百个 *-runtime.ts 懒加载接缝               │
   │  • Provider 入口 / Tool 入口 / Channel 入口     │
   │                                                  │
   └──────────────────────┬───────────────────────────┘
                          │
                          │ 插件通过 SDK 注册能力
                          │
   ┌──────────────────────▼───────────────────────────┐
   │  外部插件(extensions/*)                       │
   │                                                  │
   │  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
   │  │ Telegram │ │ WhatsApp │ │ Slack    │ ...    │
   │  └──────────┘ └──────────┘ └──────────┘         │
   │  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
   │  │ browser  │ │ canvas   │ │ cron     │ ...    │
   │  └──────────┘ └──────────┘ └──────────┘         │
   └──────────────────────────────────────────────────┘
```

## 协作流程

### 一条用户消息的完整旅程

下面追踪一条 Telegram 用户消息从接入到回复的全过程,标注每步由哪个组件负责。

```
用户在 Telegram 发了 "帮我分析这张图"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 接入层                                                     │
│    Telegram 插件收到 Bot 平台推送的消息                      │
│    → 转成 OpenClaw 内部消息格式                              │
│    → 通过 WS 协议提交给 Gateway                             │
│    → 认证面校验(Bearer token / password / tailscale 等)    │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 通道系统(Turn 内核)                                       │
│    接收入站消息,判断处理策略:                                │
│    ├─ dispatch      → 走 Agent                               │
│    ├─ observeOnly   → 仅观察,不处理                          │
│    ├─ handled       → 插件已自行处理                         │
│    └─ drop          → 丢弃                                   │
│                                                              │
│    同时做:                                                  │
│    • 持久化投递(防消息丢失)                                │
│    • 防死循环(bot-loop-protection)                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Gateway 核心(Lane 调度)                                  │
│    按 agentId + sessionKey 分配并发 lane                     │
│    • 同 session 串行(避免状态竞争)                          │
│    • 跨 session 并发                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Agent 运行时(Runner 编排)                                │
│    ① 启动 trace 追踪                                         │
│    ② 加载 agent 配置(模型、auth profile)                    │
│    ③ 绑定 per-agent SQLite                                   │
│    ④ 从插件收集 Provider + Tool 表                          │
│    ⑤ 调用 LLM,流式接收输出                                  │
│    ⑥ 处理 tool call(插件同步执行工具)                      │
│    ⑦ 终态归一化(单一入口,禁止重推)                        │
│    ⑧ 写状态库                                                │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 回复分发                                                  │
│    → 回复派发 Hook 把回复送回 Telegram 插件                  │
│    → Telegram 插件把回复发到用户                              │
└──────────────────────────────────────────────────────────────┘
```

### Gateway 启动流程

Gateway 启动分 5 个阶段,每个阶段职责独立、可单独排查。

```
openclaw 命令
     │
     ▼
┌──────────────────────────────────────────────────────┐
│  阶段 1: Bootstrap(引导)                           │
│  • 解析参数、环境变量                                │
│  • Fast-path 拦截(--version / --help)               │
│  • 评估是否需要 respawn(源码/打包/container)       │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 2: Runtime State(运行时状态准备)             │
│  • 初始化状态库连接                                  │
│  • 加载配置(三步:读取 → 迁移 → 校验)              │
│  • 准备运行时上下文                                  │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 3: Lifecycle(生命周期)                       │
│  • 绑定信号处理                                     │
│  • 设置进程级配置                                   │
│  • 准备可观测性                                      │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 4: Core Runtime(核心运行时)                  │
│  • 启动 HTTP/WS Server                              │
│  • 注册认证                                          │
│  • 启动 Lane 调度器                                 │
│  • 启动 Control UI                                   │
│  • 启动定时任务                                      │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 5: Plugins(插件加载)                         │
│  • 发现已安装插件                                    │
│  • 加载 manifest                                     │
│  • 按能力注册(Provider/Tool/Channel/Hook)           │
│  • 启动插件运行时                                    │
└──────────────────────────────┬───────────────────────┘
                               ▼
                  Gateway 就绪
                  (等待客户端连接)
```

## 关键设计约束

### 1. 核心保持插件无关

- 核心运行时(`src/`)不依赖任何具体插件
- 切换 Telegram 插件为自定义渠道插件,核心不变
- 切换 OpenAI Provider 为 Anthropic Provider,Agent Runner 不变

### 2. SQLite 是唯一状态层

- 所有运行时状态、缓存、队列、注册表都存 SQLite
- **禁止** JSON / JSONL / TXT / sidecar 文件存运行时状态
- 旧文件格式只在 doctor 迁移代码中出现,运行时不读

### 3. 协议版本 bump 是重大决策

- 协议版本由专门模块管理
- 版本 bump 不能自动生成,需 owner 显式确认
- 兼容性变更必须 additive first(先加新字段,不删旧字段)

### 4. 插件只能通过 SDK 边界

- 插件不能 `import` 核心 `src/**`
- 插件不能 `import` 其他插件的 `src/**`
- 只能通过 `openclaw/plugin-sdk/*` 访问核心能力

### 5. 配置只支持最新 shape

- 核心运行时只读取当前规范的配置格式
- 旧配置通过 `doctor --fix` 迁移到新格式
- 不做运行时兼容(无 shims、aliases、fallback readers)

## 设计观察

### 为什么所有接入都汇聚到 Gateway

```
错误设计:
   Telegram 插件 ──直接调用──► Agent Runner
   Slack 插件   ──直接调用──► Agent Runner
   UI           ──直接调用──► Agent Runner
   → 认证、并发、状态、可观测性各做一遍 → 不一致

正确设计:
   所有客户端 ──► Gateway HTTP/WS Server ──► Agent Runner
                  ↑
            统一认证面
            统一并发控制
            统一可观测性
            统一状态库
```

### 为什么用 Lane 而非线程池

```
线程池:
   • 难以保证同 session 串行
   • 难以隔离不同 agent 的资源
   • 难以做 lane 级别可观测

Lane 调度:
   • 按 agentId + sessionKey 分配 → 天然串行保证
   • 跨 agent 独立 lane → 资源隔离
   • Lane 数有上限 → 防资源耗尽
   • 每个 lane 可独立追踪 → 可观测
```

## 阅读建议

| 学习目标 | 推荐顺序 |
|---|---|
| **理解全局** | 按章节序号 01 → 11 通读 |
| **理解启动链路** | 先读 03(启动流程)再读 04(Agent 运行时) |
| **理解扩展点** | 先读 05(插件系统)再读 06(通道) |
| **理解数据层** | 直接读 08(状态)+ 09(配置) |
| **做架构决策参考** | 直接读 11(评估与风险) |

## 子目录导航

本章是整体架构概览。需要更深入的内容,见下属两个细化目录:

- **[01.1-external-entry-layer/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer)** — 外部入口层深入分析(7 章,CLI 启动链路细化)
- **[01.2-access-layers/](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers)** — 接入层深入分析(12 章,Gateway 接入面细化)

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 本文件 — 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 模块地图与目录职责 |
| [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) | CLI → Gateway 启动流程 |
| [04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/04-agent-runtime.md) | Agent 运行时流程 |
| [05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/05-plugin-system.md) | 插件系统 |
| [06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/06-channels.md) | 通道系统 |
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 进程入口 | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| CLI 主编排 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| Gateway 启动 | [src/gateway/server-start.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts) |
| Agent Runner | [src/agents/agent-command.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-command.ts) |
| 终态归一化器 | [src/agents/agent-run-terminal-outcome.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-run-terminal-outcome.ts) |
| Lane 调度器 | [src/gateway/server-lanes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-lanes.ts) |
| Turn 内核 | [src/channels/turn/kernel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/kernel.ts) |
| 状态库 | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
| 配置加载 | [src/config/io.load.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/config/io.load.ts) |
| 协议契约 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| SDK 边界 | [src/plugin-sdk/entrypoints.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/entrypoints.ts) |
| AGENTS.md 硬约束 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
