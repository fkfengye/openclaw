# 05 — 其他工具

> 读完本章你将理解:除内置 / Web / 会话 / 媒体之外的"其他工具"由哪些组件构成、它们如何按"桌面终端 / 通信问询 / 子代理委派 / 任务计划 / 节点转录 / 技能工坊 / 网关状态 / 投票定时 / 仪表板语音"九组协作,以及为何所有工具都坚持单一职责、各自独立注册。

## 一句话定位

其他工具是 Agent 的**长尾能力补全层**:
- 提供 25+ 类单一职责工具,覆盖桌面控制、终端、TTS、仪表板、目标管理、节点操作、消息、移动 UI、问询、子代理、系统代理、任务建议、转录、结构化输出、技能工坊、委派、心跳、投票、计划更新、网关、会话状态、代理列表、代理等待、对话、定时
- 每类工具独立注册,互不耦合
- 共享的网关调用上下文与节点辅助逻辑集中维护

## 全局协作图

下图展示其他工具在 Agent 工具集中的位置,以及九组工具如何协作。

```
                    Agent Runner
                        │
                        │ 请求工具表
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              其他工具(本章范围)                                 │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  共享上下文                                              │  │
│   │  (网关调用上下文 / 节点辅助 / 嵌入网关 stub /            │  │
│   │   进程内网关 / 网关 schema)                              │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 按九组分发                          │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │                                                            │  │
│   ▼                                                            ▼  │
│   ┌──────────────────────┐              ┌────────────────────┐  │
│   │  桌面与终端组        │              │  通信与问询组      │  │
│   │ (computer /          │              │ (message /         │  │
│   │  terminal /          │              │  ask-user /        │  │
│   │  mobile-ui /         │              │  conversation)     │  │
│   │  screen)             │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│   ┌──────────▼───────────┐              ┌──────────▼──────────┐  │
│   │  子代理与委派组      │              │  任务与计划组       │  │
│   │ (subagents /         │              │ (goal /             │  │
│   │  system-agent /      │              │  task-suggestion /  │  │
│   │  openclaw-delegate / │              │  update-plan /      │  │
│   │  agents-list /       │              │  structured-output) │  │
│   │  agents-wait)        │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│   ┌──────────▼───────────┐              ┌──────────▼──────────┐  │
│   │  节点与转录组        │              │  技能工坊组         │  │
│   │ (nodes /             │              │ (skill-workshop)    │  │
│   │  transcripts)        │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│   ┌──────────▼───────────┐              ┌──────────▼──────────┐  │
│   │  网关与状态组        │              │  投票与定时组       │  │
│   │ (gateway /           │              │ (poll-vote-echo /   │  │
│   │  session-status /    │              │  cron)              │  │
│   │  heartbeat-response) │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│              └──────────────┬──────────────────────┘             │
│                             ▼                                    │
│              ┌──────────────────────────────────┐                │
│              │  仪表板与语音组                  │                │
│              │ (dashboard / tts)                │                │
│              └──────────────────────────────────┘                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  状态层 + 外部环境     │
                  │  (SQLite / 桌面 /      │
                  │   网关 / 渠道)         │
                  └────────────────────────┘
```

## 组件清单

其他工具按九组划分,共 25+ 类工具 + 5 类共享设施:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **桌面控制工具** | 控制桌面应用(鼠标 / 键盘 / 截图) | 平台相关,node 解析 |
| **终端工具** | 终端交互能力 | 与 bash 工具职责区分 |
| **移动 UI 工具** | 移动端 UI 自动化 | 平台相关 |
| **屏幕工具** | 屏幕捕获与查询 | 与桌面控制协作 |
| **消息工具** | 跨渠道消息发送 | 走插件 Hook,不直接调渠道 |
| **问询工具** | 向用户提问并等待回复 | 异步等待,可超时 |
| **对话工具** | 对话元能力 | 与会话工具职责区分 |
| **子代理工具** | 派生子代理执行任务 | 受资源约束 |
| **系统代理工具** | 系统级代理能力 | 权限受控 |
| **委派工具** | 委派任务到 OpenClaw | 跨代理边界 |
| **代理列表工具** | 列出可用代理 | 受权限过滤 |
| **代理等待工具** | 等待代理完成 | 协作式,非抢占 |
| **目标工具** | 目标管理与追踪 | 与计划工具协作 |
| **任务建议工具** | 任务建议生成 | 受上下文约束 |
| **计划更新工具** | 计划的更新与维护 | 与目标工具协作 |
| **结构化输出工具** | 强制结构化输出 | schema 驱动 |
| **节点工具** | 节点操作(命令 / 媒体) | 节点辅助集中 |
| **转录工具** | 会话转录查询 | 受访问边界约束 |
| **技能工坊工具** | 技能创建与管理 | 工厂模式,可组合 |
| **网关工具** | 网关操作 | 走共享调用上下文 |
| **会话状态工具** | 会话状态查询 | 与会话工具协作 |
| **心跳响应工具** | 心跳保活响应 | 周期性 |
| **投票回显工具** | 投票与回显 | 受配额约束 |
| **定时工具** | 定时任务管理 | cron 规范化,创作者能力约束 |
| **仪表板工具** | 仪表板操作 | 与会话状态协作 |
| **TTS 工具** | 文本转语音 | provider 驱动 |
| **网关调用上下文** | 网关调用的共享上下文 | 跨网关工具复用 |
| **节点辅助** | 节点工具共享逻辑 | 跨节点工具复用 |
| **嵌入网关 stub** | 嵌入式网关 stub | 测试与隔离用 |
| **进程内网关** | 进程内网关调用 | 与外部网关边界清晰 |
| **网关 schema** | 网关操作的 schema 定义 | 跨网关工具一致 |

## 关联关系

### 九组工具与共享上下文

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   每个网关相关工具各自维护调用上下文        │
   │   → 上下文不一致 → 行为漂移                │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   网关工具 ─┐                              │
   │   会话状态 ─┼──► 网关调用上下文(共享)     │
   │   心跳响应 ─┤    网关 schema(共享)        │
   │   委派工具 ─┘                              │
   │   → 上下文一致 → 行为统一                   │
   └─────────────────────────────────────────────┘
```

### 子代理与委派的边界

```
   子代理工具
        │
        │ 派生本代理内的子代理
        ▼
   子代理(同代理,资源受限)

   委派工具
        │
        │ 跨代理委派任务
        ▼
   OpenClaw 委派(跨代理边界,走网关调用上下文)

   系统代理工具
        │
        │ 系统级代理能力
        ▼
   系统代理(权限受控)

   三者职责区分:
   • 子代理:本代理内并发
   • 委派:跨代理协作
   • 系统代理:系统级能力
```

### 任务与计划组协作

```
   目标工具 ──► 设定目标
        │
        ▼
   计划更新工具 ──► 维护实现计划
        │
        ▼
   任务建议工具 ──► 生成任务建议
        │
        ▼
   结构化输出工具 ──► 强制结构化产出
   (schema 驱动,保证可解析)
```

## 协作流程

### 一次子代理派生的旅程

下面追踪 LLM 调用子代理工具派生一个子代理执行任务的全过程。

```
LLM 调用子代理工具,传入任务描述
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 资源约束校验                                               │
│    → 检查当前代理的子代理配额                                │
│    → 通过:继续                                              │
│    → 超限:返回错误                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 派生子代理                                                 │
│    → 创建子代理执行环境                                      │
│    → 注入任务描述                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 子代理执行                                                 │
│    → 子代理独立运行                                          │
│    → 父代理可继续其他工作                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果回收                                                   │
│    → 子代理完成,结果回送父代理                              │
│    → 父代理通过代理等待工具或主动查询获取                    │
└──────────────────────────────────────────────────────────────┘
```

### 一次问询工具调用的旅程

```
LLM 调用问询工具,传入问题
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 问题派发                                                  │
│    → 通过消息工具或渠道插件派发问题给用户                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 异步等待                                                   │
│    → agent run 挂起,等待用户回复                            │
│    → 应用超时控制                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 用户回复                                                   │
│    → 用户通过渠道回复                                        │
│    → 回复作为问询结果                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果回送 LLM                                               │
│    → 用户回复作为工具结果                                    │
│    → LLM 继续推理                                            │
└──────────────────────────────────────────────────────────────┘
```

### 一次定时工具调用的旅程

```
LLM 调用定时工具,传入 cron 表达式与任务
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 创作者能力校验                                             │
│    → 校验调用方是否有创建定时任务的权限                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. cron 规范化                                                │
│    → 规范化 cron 表达式                                      │
│    → 校验节奏约束(最小间隔)                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 注册定时任务                                               │
│    → 写入状态库                                              │
│    → 调度器接管                                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 返回任务标识                                               │
│    → LLM 可通过标识管理(查询 / 暂停 / 删除)                │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 每类工具单一职责

- **为什么**:25+ 类工具若职责重叠,会导致调用方困惑、维护负担重
- **怎么做**:每类工具坚持单一职责,边界清晰,独立注册
- **影响**:新增工具不影响既有工具,调用方选择明确

### 2. 网关调用上下文共享

- **为什么**:多个工具(网关 / 会话状态 / 心跳 / 委派)都需调用网关,各自维护上下文会不一致
- **怎么做**:网关调用上下文模块统一承载,网关 schema 跨工具一致
- **影响**:网关调用行为统一,新增网关工具复用上下文

### 3. 子代理受资源约束

- **为什么**:无限制派生子代理会耗尽系统资源
- **怎么做**:子代理工具调用前校验配额,超限拒绝
- **影响**:资源使用可控,防止单代理失控

### 4. 问询工具异步等待

- **为什么**:用户回复可能耗时较长,同步等待会阻塞
- **怎么做**:问询工具异步等待,带超时控制,agent run 挂起但不占资源
- **影响**:用户体验好,资源利用率高

### 5. 定时工具受创作者能力约束

- **为什么**:定时任务可被滥用(资源耗尽、骚扰)
- **怎么做**:定时工具调用前校验创作者能力,cron 表达式规范化,最小间隔约束
- **影响**:定时任务可控,异常调度可被识别与限制

### 6. 节点辅助集中

- **为什么**:节点工具的命令与媒体操作有共享逻辑,散落会不一致
- **怎么做**:节点辅助模块统一承载共享逻辑,节点工具的命令与媒体分离
- **影响**:节点工具行为一致,新增节点操作复用辅助

## 设计观察

### 为什么子代理 / 委派 / 系统代理三者分离

```
单一代理工具:
   所有"派生 / 委派 / 系统级"都走同一入口
   → 职责混淆 → 权限边界不清 → 难以管控

三者分离:
   子代理工具:本代理内并发,资源受限
   委派工具:跨代理协作,走网关调用上下文
   系统代理工具:系统级能力,权限受控
   → 职责清晰 → 权限边界明确 → 各自可控
```

### 为什么结构化输出需要 schema 驱动

```
无 schema:
   LLM 自由输出
   → 调用方需猜测格式 → 解析失败频发

schema 驱动:
   LLM 调用结构化输出工具
       │
       ▼
   schema 校验 ──► 强制结构化产出
       │
       ├─ 符合 schema → 返回
       └─ 不符合 → 要求重试
   → 调用方拿到的是可解析的结构化数据
```

### 为什么节点工具的命令与媒体分离

```
单一节点工具:
   命令操作 + 媒体操作 混在一起
   → 工具表臃肿 → 调用方选择困难

分离设计:
   节点命令工具 ──► 命令操作
   节点媒体工具 ──► 媒体操作
   共享节点辅助 ──► 复用逻辑
   → 职责清晰,共享逻辑集中
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 内置工具:bash / edit / find / grep / ls / read / write 及共享设施 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | Web 工具:fetch / search / guarded-fetch / shared |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 会话工具:list / history / search / send / spawn / yield / access |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 媒体生成工具:image / music / video / pdf |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 本文件 — 其他工具 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 桌面控制工具 | [src/agents/tools/computer-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/computer-tool.ts) |
| 终端工具 | [src/agents/tools/terminal-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/terminal-tool.ts) |
| 移动 UI 工具 | [src/agents/tools/mobile-ui-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/mobile-ui-tool.ts) |
| 屏幕工具 | [src/agents/tools/screen-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/screen-tool.ts) |
| 消息工具 | [src/agents/tools/message-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/message-tool.ts) |
| 消息工具描述 | [src/agents/tools/message-tool-description.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/message-tool-description.ts) |
| 消息工具 schema 作用域 | [src/agents/tools/message-tool-schema-scoping.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/message-tool-schema-scoping.ts) |
| 问询工具 | [src/agents/tools/ask-user-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/ask-user-tool.ts) |
| 对话工具 | [src/agents/tools/conversation-tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/conversation-tools.ts) |
| 子代理工具 | [src/agents/tools/subagents-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/subagents-tool.ts) |
| 系统代理工具 | [src/agents/tools/system-agent-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/system-agent-tool.ts) |
| 委派工具 | [src/agents/tools/openclaw-delegate-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/openclaw-delegate-tool.ts) |
| 代理列表工具 | [src/agents/tools/agents-list-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/agents-list-tool.ts) |
| 代理等待工具 | [src/agents/tools/agents-wait-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/agents-wait-tool.ts) |
| 目标工具 | [src/agents/tools/goal-tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/goal-tools.ts) |
| 任务建议工具 | [src/agents/tools/task-suggestion-tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/task-suggestion-tools.ts) |
| 计划更新工具 | [src/agents/tools/update-plan-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/update-plan-tool.ts) |
| 结构化输出工具 | [src/agents/tools/structured-output-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/structured-output-tool.ts) |
| 节点工具主入口 | [src/agents/tools/nodes-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/nodes-tool.ts) |
| 节点工具命令 | [src/agents/tools/nodes-tool-commands.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/nodes-tool-commands.ts) |
| 节点工具媒体 | [src/agents/tools/nodes-tool-media.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/nodes-tool-media.ts) |
| 节点辅助 | [src/agents/tools/nodes-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/nodes-utils.ts) |
| 转录工具 | [src/agents/tools/transcripts-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/transcripts-tool.ts) |
| 转录工具运行时 | [src/agents/tools/transcripts-tool-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/transcripts-tool-runtime.ts) |
| 技能工坊工具 | [src/agents/tools/skill-workshop-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/skill-workshop-tool.ts) |
| 技能工坊工厂 | [src/agents/tools/skill-workshop-tool-factory.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/skill-workshop-tool-factory.ts) |
| 技能工坊辅助 | [src/agents/tools/skill-workshop-tool-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/skill-workshop-tool-helpers.ts) |
| 技能工坊展示 | [src/agents/tools/skill-workshop-tool-presentation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/skill-workshop-tool-presentation.ts) |
| 网关工具 | [src/agents/tools/gateway-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/gateway-tool.ts) |
| 网关调用上下文 | [src/agents/tools/gateway-caller-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/gateway-caller-context.ts) |
| 网关 schema | [src/agents/tools/gateway-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/gateway-schema.ts) |
| 网关主入口 | [src/agents/tools/gateway.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/gateway.ts) |
| 嵌入网关 stub | [src/agents/tools/embedded-gateway-stub.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/embedded-gateway-stub.ts) |
| 进程内网关 | [src/agents/tools/in-process-gateway.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/in-process-gateway.ts) |
| 会话状态工具 | [src/agents/tools/session-status-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/session-status-tool.ts) |
| 会话状态运行时 | [src/agents/tools/session-status.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/session-status.runtime.ts) |
| 心跳响应工具 | [src/agents/tools/heartbeat-response-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/heartbeat-response-tool.ts) |
| 投票回显工具 | [src/agents/tools/poll-vote-echo.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/poll-vote-echo.ts) |
| 定时工具主入口 | [src/agents/tools/cron-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool.ts) |
| 定时工具规范化 | [src/agents/tools/cron-tool-canonicalize.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool-canonicalize.ts) |
| 定时工具上下文 | [src/agents/tools/cron-tool-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool-context.ts) |
| 定时工具创作者能力 | [src/agents/tools/cron-tool-creator-cap.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool-creator-cap.ts) |
| 定时工具 schema | [src/agents/tools/cron-tool-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool-schema.ts) |
| 定时工具写入 | [src/agents/tools/cron-tool-write.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool-write.ts) |
| 定时工具类型 | [src/agents/tools/cron-tool.types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/cron-tool.types.ts) |
| 仪表板工具 | [src/agents/tools/dashboard-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/dashboard-tool.ts) |
| TTS 工具 | [src/agents/tools/tts-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/tts-tool.ts) |
| 模型配置辅助 | [src/agents/tools/model-config.helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/model-config.helpers.ts) |
| 公共工具辅助 | [src/agents/tools/common.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/common.ts) |
| 代理步骤 | [src/agents/tools/agent-step.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/agent-step.ts) |
| 聊天历史文本 | [src/agents/tools/chat-history-text.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/chat-history-text.ts) |
