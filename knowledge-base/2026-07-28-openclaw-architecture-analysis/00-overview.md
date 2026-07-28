# OpenClaw 整体架构与流程分析 — 总览

- 生成日期:2026-07-28
- 数据来源:OpenClaw 仓库 `d:\DevSpace\person\ai_space\openclaw` 源码精读
- 仓库版本:`2026.7.2`([package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json#L3))
- Schema 版本:`state=6, agent=16`([package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json#L4-L9))

## 一句话定位

OpenClaw 是一个**本地优先的多渠道 AI 助手 Gateway**:自研 WebSocket 协议、SQLite 状态层、可插拔扩展运行时,核心保持插件无关,所有渠道(25+)与能力(browser/canvas/cron/nodes 等)以插件形式接入。

## 核心结论(速查)

1. **四层分离**:核心运行时 `src/` / 插件实现 `extensions/` / SDK 边界 `src/plugin-sdk/` / 协议契约 `packages/gateway-protocol/`,边界由 AGENTS.md 强约束。
2. **启动双层**:`src/entry.ts` 是进程入口(fast-path 拦截 --version/--help);`src/gateway/server-start.ts` 是 Gateway 启动(bootstrap → runtime state → lifecycle → core runtime → finish)。
3. **懒加载贯穿**:从 entry 到 gateway 启动到插件加载,处处 `createLazyRuntimeModule`,降低冷启动成本。
4. **状态统一为 SQLite**:`state/openclaw.sqlite`(共享)+ `agents/<agentId>/agent/openclaw-agent.sqlite`(per-agent),禁止 JSON/sidecar 文件存运行时状态。
5. **协议版本**:`PROTOCOL_VERSION=4`,版本 bump 不可自动生成,需 owner 显式确认。
6. **插件边界硬约束**:插件只能通过 `openclaw/plugin-sdk/*` 进入核心,不能 import `src/**` 或其他插件 `src/**`。
7. **Agent 运行时**:走 `agentCommandInternal`,终态归一化必须经 `agent-run-terminal-outcome.ts`,不允许在 projections 中重新推导 timeout/cancel 优先级。
8. **Channel Turn 内核**:`src/channels/turn/kernel.ts` 用 discriminated union(`dispatch`/`observeOnly`/`handled`/`drop`)表达消息处理策略。

## 整体架构图

### 静态分层视图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          外部入口层(External Entry)                         │
│                                                                              │
│   openclaw CLI ──── openclaw.mjs wrapper ──── src/entry.ts (进程入口)         │
│   (用户/脚本)        (npm bin)              (fast-path 拦截 --version/--help) │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          配置层(Configuration)                              │
│                                                                              │
│   ~/.openclaw/openclaw.json  +  env vars                                     │
│         │                                                                    │
│         ▼                                                                    │
│   src/config/io.load.ts                                                      │
│   readConfigFile → migrateConfig → validateConfig  (核心只支持最新 shape)    │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Gateway 控制面(Gateway Control Plane)                │
│                                                                              │
│   src/gateway/server-start.ts                                                │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │ bootstrap → runtime-state → lifecycle → core-runtime → finish       │  │
│   │ (server-startup-*.ts 15+ 文件,各阶段独立拆分)                       │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│   关键服务:                                                                   │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│   │   auth-*.ts  │  │ config-reload│  │  server-cron │  │ control-ui   │  │
│   │ (token/scope)│  │   (热重载)   │  │ (定时任务)   │  │  (Web UI)    │  │
│   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
       ┌─────────────────────────────┼─────────────────────────────┐
       │                             │                             │
       ▼                             ▼                             ▼
┌──────────────┐  ┌─────────────────────────────────┐  ┌──────────────────┐
│              │  │                                 │  │                  │
│ Agent 运行时 │  │     插件系统(Plugin System)     │  │  通道系统        │
│              │  │                                 │  │  (Channels)      │
│ src/agents/  │  │ src/plugins/                    │  │ src/channels/    │
│              │  │                                 │  │                  │
│ agent-       │  │ ┌─────────────────────────────┐ │  │ turn/kernel.ts   │
│  command.ts  │◄─┼─│ loader-*.ts (发现/加载)     │ │◄─┤ (dispatch/       │
│              │  │ │ registry-*.ts (按能力注册)  │ │  │  observeOnly/    │
│ agent-run-   │  │ │ wired-hooks-*.ts (Hook)     │ │  │  handled/drop)   │
│  terminal-   │  │ │ provider-*.ts (LLM provider)│ │  │                  │
│  outcome.ts  │  │ │ tools.ts (tool 注册)        │ │  │ turn/lifecycle.ts│
│ (终态归一化) │  │ │ tool-descriptor-cache.ts    │ │  │ turn/durable-    │
│              │  │ │   (prompt cache 友好)       │ │  │  delivery.ts    │
│ Lane 并发控制│  │ └─────────────────────────────┘ │  │                  │
│              │  │                                 │  │ transport/        │
└──────┬───────┘  └──────────────┬──────────────────┘  │ stall-watchdog   │
       │                         │                     └────────┬─────────┘
       │                         │                              │
       │   ┌─────────────────────┘                              │
       │   │                                                    │
       │   │            ┌──────────────────────────────────────┘
       │   │            │
       │   │            │  ┌─────────────────────────────────────────────┐
       │   │            │  │  外部通道与能力插件(extensions/*)           │
       │   │            │  │                                              │
       │   │            │  │ 渠道:WhatsApp/Telegram/Slack/Discord/Signal │
       │   │            │  │       /iMessage/SMS/Teams/Matrix/Feishu/    │
       │   │            └──┤       /LINE/QQ/WebChat 等 (25+)            │
       │   │               │                                              │
       │   │               │ 工具:browser/canvas/cron/nodes/sessions     │
       │   │               │       /discord-actions/slack-actions 等     │
       │   │               └──────────────────────────────────────────────┘
       │   │
       ▼   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            状态层(State Layer)                             │
│                                                                              │
│   ┌─────────────────────────┐    ┌──────────────────────────────────────┐  │
│   │  共享 state DB           │    │  Per-agent DB                          │  │
│   │  state/openclaw.sqlite   │    │  agents/<agentId>/agent/               │  │
│   │                          │    │    openclaw-agent.sqlite              │  │
│   │  • 全局运行时状态         │    │  • Agent-scoped 状态/cache            │  │
│   │  • 插件 KV 数据          │    │  • session history                     │  │
│   │  • schema v6             │    │  • schema v16                          │  │
│   └─────────────────────────┘    └──────────────────────────────────────┘  │
│                                                                              │
│   规则:Kysely helpers(非 raw SQL)| 写事务同步 commit | 禁止 await in tx │
│         禁止 JSON/sidecar | Doctor 单一迁移 owner | 无 dual-write          │
└─────────────────────────────────────────────────────────────────────────────┘

    横向贯穿层(对所有上方层提供契约):

┌─────────────────────────────────────────────────────────────────────────────┐
│  协议契约(packages/gateway-protocol/)   │  SDK 边界(src/plugin-sdk/)     │
│                                              │                              │
│  • TypeBox schemas(13 fragment)            │  • 数百个 *-runtime.ts        │
│  • PROTOCOL_VERSION = 4                     │  • 插件唯一入口               │
│  • 版本 bump 需 owner 显式确认              │  • 禁止 import 核心 src/**     │
│  • 校验器 + 迁移 API                        │  • 禁止 import 其他插件 src/** │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 动态流程视图(CLI 启动 + 消息处理)

```
[用户] openclaw agent --message "xxx"
   │
   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 1. 进程入口(src/entry.ts)                                           │
│    ├─ isMainModule 守卫                                              │
│    ├─ assertSupportedRuntime                                        │
│    ├─ tryHandleRootVersionFastPath (--version 快速返回)             │
│    ├─ tryHandleRootHelpFastPath (--help 快速返回)                    │
│    └─ tryHandlePrecomputedCommandHelpFastPath (子命令 --help)        │
└─────────────────────────────┬────────────────────────────────────────┘
                              │ (未命中 fast path)
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 2. Gateway 启动(src/gateway/server-start.ts)                        │
│    prepareBootstrap → prepareRuntimeState → prepareLifecycle        │
│    → startCoreRuntime → finishStartup                                │
│    (懒加载:createLazyRuntimeModule 贯穿全程)                       │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. Agent 命令(src/agents/agent-command.ts)                          │
│    ├─ createAgentCommandTrace (mark 各阶段)                          │
│    ├─ resolveAgentCommandDeps (依赖注入)                             │
│    ├─ 加载 agent 配置 + 模型选择 + auth profile                      │
│    ├─ 准备 session (绑定 agents/<agentId>/agent/openclaw-agent.sqlite)│
│    ├─ 构造 LLM 请求(走 provider-runtime.ts)                        │
│    ├─ 注入工具表(来自 plugins/tools.ts)                             │
│    ├─ 流式接收 LLM 输出                                              │
│    ├─ 处理 tool calls(同步执行 plugin tool hook)                    │
│    ├─ 终态归一化(agent-run-terminal-outcome.ts)                     │
│    │    (硬约束:不允许在 projections 重新推导 timeout/cancel)       │
│    └─ 落库 + 回复分发                                                │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 4. Channel 回复派发(src/channels/turn/kernel.ts)                    │
│    dispatchAssembledChannelTurn                                      │
│    ├─ ChannelTurnAdmission 判别:                                    │
│    │    dispatch | observeOnly | handled | drop                     │
│    ├─ durable-delivery.ts (持久化投递,防丢失)                        │
│    ├─ bot-loop-protection.ts (防 bot 死循环)                         │
│    └─ transport/stall-watchdog.ts (传输层 stall 检测)               │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
                  [外部通道:Telegram/Discord/Slack/...]
```

### 消息入站流程(从通道到 Agent)

```
[外部渠道:Telegram/Discord/Slack/...]
   │
   │ (消息入站)
   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Channel 插件(extensions/<id>/)                                     │
│ ├─ transport-only:渲染展示/动作映射/传输限制                          │
│ ├─ dm-access.ts (DM pairing 默认)                                   │
│ └─ pairing-adapters.ts (未知发送者触发 pairing code)                │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ wired-hooks-inbound-claim.ts                                        │
│ (插件认领消息,决定是否走 agent)                                     │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ turn/kernel.ts                                                       │
│ dispatchChannelInboundTurn                                           │
│ ChannelTurnAdmission: dispatch | observeOnly | handled | drop       │
└─────────────────────────────┬────────────────────────────────────────┘
                              │ (dispatch)
                              ▼
                    [Agent 运行时 → LLM → 工具调用 → 回复]
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ wired-hooks-reply-dispatch.ts                                        │
│ wired-hooks-reply-payload-sending.ts                                 │
│ (回复派发与 payload 发送 hook)                                       │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
                    [Channel 插件 → 外部渠道回复用户]
```

## 文件索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/00-overview.md) | 本文件 — 总览与索引 |
| [2026-07-28-01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-01-positioning.md) | 顶层定位与技术栈 |
| [2026-07-28-02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-02-module-map.md) | 模块地图与目录职责 |
| [2026-07-28-03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-03-startup-flow.md) | CLI → Gateway 启动流程 |
| [2026-07-28-04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-04-agent-runtime.md) | Agent 运行时流程 |
| [2026-07-28-05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-05-plugin-system.md) | 插件系统(加载/注册/Hook) |
| [2026-07-28-06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-06-channels.md) | 通道系统(Turn 内核) |
| [2026-07-28-07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-07-protocol.md) | Gateway 协议与 Schema |
| [2026-07-28-08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-08-state.md) | SQLite 状态管理 |
| [2026-07-28-09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-09-config.md) | 配置加载与迁移 |
| [2026-07-28-10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-10-design-principles.md) | 关键设计原则 |
| [2026-07-28-11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/2026-07-28-openclaw-architecture-analysis/2026-07-28-11-assessment.md) | 评估与风险点 |

## 阅读建议

- 想了解全局:按 01 → 11 顺序读
- 想理解启动:先 03(启动流程)再 04(Agent 运行时)
- 想理解扩展点:先 05(插件系统)再 06(通道)
- 想理解数据层:直接 08(状态)+ 09(配置)
- 想做架构决策参考:直接 11(评估与风险)

## 证据原则

每节结论均附源码引用(文件路径 + 行号)。源码引用使用 `file:///` 绝对路径,可直接在 IDE 中点击跳转。所有路径基于仓库根 `d:\DevSpace\person\ai_space\openclaw\`。
