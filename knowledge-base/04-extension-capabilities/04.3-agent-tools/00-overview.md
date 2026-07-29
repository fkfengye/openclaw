# 00 — Agent 工具集总览

> 读完本章你将理解:Agent 工具集在 OpenClaw 运行时中处于什么位置、由哪几类工具构成、工具如何被注册与调用,以及工具表为何要保持确定性排序。

## 一句话定位

Agent 工具集是 Agent 会话的**能力延伸层**:
- 所有工具由插件注册或由内置工具集提供,Agent Runner 不预知有哪些工具
- 工具按"内置 / Web / 会话 / 媒体 / 其他"五类分层,每类职责独立
- 工具表确定性排序,保证 prompt cache 友好

## 全局协作图

下图展示 Agent 工具集在 OpenClaw 运行时中的位置,以及五类工具如何协作。**先看这张图建立心智模型,再读细节**。

```
                    用户消息(来自 Channel 接入层)
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Agent Runner                               │
        │  (一次 agent run 的总编排)                  │
        └──────────────────────┬──────────────────────┘
                               │
                               │ 从插件 Hook 收集工具表
                               │ 注入 LLM 请求
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│              Agent 工具集(本章范围)                              │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  工具注册与执行边界                                      │  │
│   │  (插件注册 / 工具表排序 / 同步执行 / 结果归一)          │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 按类别分发                          │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │                                                            │  │
│   ▼                                                            ▼  │
│   ┌──────────────────────┐              ┌────────────────────┐  │
│   │  内置工具集          │              │  Web 工具          │  │
│   │  (bash / edit /      │              │ (fetch / search /  │  │
│   │   find / grep / ls / │              │  guarded-fetch)   │  │
│   │   read / write)      │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│   ┌──────────▼───────────┐              ┌──────────▼──────────┐  │
│   │  会话工具            │              │  媒体生成工具       │  │
│   │  (sessions-list /    │              │ (image / music /    │  │
│   │   history / search / │              │  video / pdf)       │  │
│   │   send / spawn /     │              │                     │  │
│   │   yield / ...)       │              │                     │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│              └──────────────┬──────────────────────┘             │
│                             ▼                                    │
│              ┌──────────────────────────────────┐                │
│              │  其他工具                        │                │
│              │ (computer / terminal / tts /     │                │
│              │  dashboard / goal / nodes /      │                │
│              │  message / mobile-ui / ask-user /│                │
│              │  subagents / system-agent / ...) │                │
│              └──────────────────────────────────┘                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  状态层                │
                  │  (per-agent SQLite)    │
                  │  • 工具结果落库        │
                  │  • 媒体产物引用        │
                  └────────────────────────┘
```

## 组件清单

Agent 工具集由 5 类工具 + 1 类注册执行边界构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **工具注册与执行边界** | 收集插件注册的工具,确定性排序,同步执行,结果归一 | 工具表确定性排序(prompt cache 友好) |
| **内置工具集** | 提供代码会话的基础能力:命令执行、文件读写、查找检索 | 分"可变编码"与"只读发现"两套集合 |
| **Web 工具** | 网页抓取、网络搜索,带 SSRF 防护与可读性提取 | guarded-fetch 是统一安全防护入口 |
| **会话工具** | 多会话管理:列表、历史、搜索、发送、派生、让步、访问控制 | 受 session 访问边界约束,防越权 |
| **媒体生成工具** | 图像 / 音乐 / 视频 / PDF 生成,支持后台与状态轮询 | 大产物走后台任务,状态可轮询 |
| **其他工具** | 桌面控制、终端、TTS、仪表板、目标、节点、消息、移动 UI、问询、子代理、系统代理、任务建议、转录、结构化输出、技能工坊、委派、心跳、投票、计划更新、网关、会话状态、代理列表、代理等待、对话、定时 | 单一职责,各自独立注册 |

## 关联关系

### 工具集与上游依赖

```
   ┌─────────────────────┐
   │ Agent 会话管理      │
   │ (会话生命周期 /     │
   │  会话管理器 /       │
   │  提示词与模型)      │
   └──────────┬──────────┘
              │
              │ 提供会话上下文
              │ 与执行环境
              ▼
   ┌─────────────────────┐
   │ Agent 工具集        │
   │ (本章)              │
   └──────────┬──────────┘
              │
              │ 工具表注入
              ▼
   ┌─────────────────────┐
   │ 插件注册表          │
   │ (Provider / Tool /  │
   │  Channel / Hook)    │
   └─────────────────────┘
```

### 工具调用与归一化

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   各类工具各自决定结果格式与错误返回        │
   │   → 调用方需要为每类工具写适配 → 不一致     │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   所有工具 → 共用结果归一入口               │
   │   → 调用方只面对统一形状 → 一致             │
   └─────────────────────────────────────────────┘
```

### 五类工具的依赖链

```
   Agent 会话
        │
        ▼
   内置工具集 ──────► Web 工具
        │                │
        │                ▼
        │           会话工具
        │                │
        │                ▼
        │           媒体生成工具
        │                │
        │                ▼
        └──────────► 其他工具
```

## 协作流程

### 一次工具调用的完整旅程

下面追踪 LLM 产生一次工具调用到结果回送的全过程。

```
LLM 输出 tool call
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 工具表查找                                                │
│    按工具名在已注册工具表中查找                              │
│    → 命中:进入执行                                          │
│    → 未命中:返回错误结果                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 工具执行                                                  │
│    → 内置工具:本地执行(bash / 文件操作)                   │
│    → Web 工具:走 guarded-fetch 安全防护                     │
│    → 会话工具:校验 session 访问边界                         │
│    → 媒体工具:可能派发后台任务,返回任务句柄                │
│    → 其他工具:按各自协议执行                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 结果归一                                                  │
│    → 输出截断(超长输出落临时文件,返回引用)                │
│    → 错误归一为统一形状                                      │
│    → 媒体产物落库或返回引用                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果回送 LLM                                              │
│    → 工具结果作为下一轮输入                                  │
│    → LLM 继续推理或产生下一个 tool call                      │
└──────────────────────────────────────────────────────────────┘
```

### 工具表确定性排序

```
场景:同一 Agent 配置下,两次 run 的工具表顺序必须一致

错误做法:
   每次按插件加载完成时间排序
   → 工具表顺序不稳定 → prompt cache 失效

正确做法:
   按固定规则(注册顺序 + 名称)排序
   → 工具表顺序稳定 → prompt cache 命中率高
```

## 关键设计约束

### 1. 工具表确定性排序

- **为什么**:prompt cache 依赖输入字节稳定;工具表顺序变化会让 cache key 漂移
- **怎么做**:工具表按固定规则排序,不依赖插件加载完成时间或运行时遍历顺序
- **影响**:新增工具不破坏既有 cache,排序规则变更需谨慎评估

### 2. 工具由插件注册而非硬编码

- **为什么**:Agent Runner 必须保持插件无关,不能预知有哪些工具
- **怎么做**:工具表从插件 Hook 收集,内置工具也走同一注册边界
- **影响**:新增工具 = 新增插件或扩展现有插件,不改 Agent Runner

### 3. 工具结果统一形状

- **为什么**:调用方(主要是 LLM 循环)只应面对一种结果形状,避免为每类工具写适配
- **怎么做**:所有工具共用结果归一入口,超长输出截断、错误归一、产物引用统一处理
- **影响**:工具实现方只需专注业务逻辑,基础设施由边界承担

### 4. Web 工具的安全防护集中

- **为什么**:SSRF、可读性提取、provider 切换等是横切关注点,不能散落各处
- **怎么做**:所有 Web 抓取走 guarded-fetch 统一入口,安全策略集中维护
- **影响**:新增 Web provider 不引入新的安全风险面

### 5. 会话工具受访问边界约束

- **为什么**:多会话场景下,Agent 不能越权访问其他会话
- **怎么做**:会话工具调用前先经 session 访问边界校验
- **影响**:防止跨 agent / 跨 session 的越权读写

### 6. 媒体生成走后台任务

- **为什么**:图像 / 音乐 / 视频生成长耗时,不能阻塞 agent run
- **怎么做**:派发后台任务,返回任务句柄,Agent 通过状态轮询工具查询
- **影响**:Agent run 不会因媒体生成而长时间挂起

## 设计观察

### 为什么内置工具分"可变编码"与"只读发现"两套

```
单一工具集:
   受限会话需要禁用 bash / edit / write
   → 每次按名单过滤 → 易遗漏,且排序不稳定

两套工具集:
   可变编码集:read / bash / edit / write
   只读发现集:read / grep / find / ls
   → 受限会话直接挂载只读集 → 边界清晰
```

### 为什么 Web 工具需要 guarded-fetch

```
直接抓取:
   Web 工具 ──直接请求──► 任意 URL
   → SSRF 风险(内网地址 / 元数据端点)
   → 无超时控制
   → 无可读性提取

guarded-fetch 入口:
   Web 工具 ──► guarded-fetch ──► 实际请求
                 │
                 ├─ SSRF 校验
                 ├─ 超时控制
                 ├─ 可读性提取
                 └─ provider fallback
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 本文件 — 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 内置工具:bash / edit / find / grep / ls / read / write 及共享设施 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | Web 工具:fetch / search / guarded-fetch / shared |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 会话工具:list / history / search / send / spawn / yield / access |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 媒体生成工具:image / music / video / pdf |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 其他工具:computer / terminal / tts / dashboard / goal / nodes / message 等 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Agent 工具根目录 | [src/agents/tools/](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/) |
| 内置工具目录 | [src/agents/sessions/tools/](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/) |
| 内置工具公开 barrel | [src/agents/sessions/tools/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/index.ts) |
| 工具结果归一 | [src/agents/tools/tool-results.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/tool-results.ts) |
| 工具运行时辅助 | [src/agents/tools/tool-runtime.helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/tool-runtime.helpers.ts) |
| 工具定义包装 | [src/agents/sessions/tools/tool-definition-wrapper.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/tool-definition-wrapper.ts) |
| 工具能力可用性 | [src/agents/tools/manifest-capability-availability.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/manifest-capability-availability.ts) |
| 工具目录 AGENTS 约束 | [src/agents/tools/AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/AGENTS.md) |
