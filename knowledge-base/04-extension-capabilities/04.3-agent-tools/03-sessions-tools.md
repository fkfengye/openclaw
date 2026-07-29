# 03 — 会话工具

> 读完本章你将理解:会话工具由哪些组件构成、多会话管理如何通过列表 / 历史 / 搜索 / 发送 / 派生 / 让步 / 访问控制协作,以及为何所有会话工具调用必须先经 session 访问边界校验。

## 一句话定位

会话工具是 Agent 的**多会话管理层**:
- 提供 9 类会话操作:列表、历史、搜索、发送、派生、让步、访问控制、自归档、会话工具自身
- 所有调用先经 session 访问边界校验,防越权
- a2a(代理间通信)发送走独立扩展,token 受控

## 全局协作图

下图展示会话工具在 Agent 工具集中的位置,以及 9 类工具与访问边界如何协作。

```
                    Agent Runner
                        │
                        │ 请求工具表
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              会话工具(本章范围)                                 │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  Session 访问边界                                       │  │
│   │  (校验调用方对目标 session 的权限)                      │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 校验通过才放行                      │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  会话工具集合                                            │  │
│   │                                                          │  │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐    │  │
│   │  │ 列表     │ │ 历史     │ │ 搜索     │ │ 发送     │    │  │
│   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘    │  │
│   │                                                          │  │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐    │  │
│   │  │ 派生     │ │ 让步     │ │ 工具自身 │ │ 自归档   │    │  │
│   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘    │  │
│   │                                                          │  │
│   │  ┌──────────┐ ┌──────────┐                               │  │
│   │  │ 公告目标 │ │ 发送令牌 │                               │  │
│   │  └──────────┘ └──────────┘                               │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 共享辅助                            │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  会话辅助  │  发送辅助  │  会话解析  │  派生可见接纳       │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  Per-agent SQLite      │
                  │  (会话历史 / 运行记录) │
                  └────────────────────────┘
```

## 组件清单

会话工具由 9 类工具 + 4 类共享辅助构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **会话列表工具** | 列出当前可见的会话 | 受访问边界约束,只返回有权访问的会话 |
| **会话历史工具** | 查询指定会话的历史记录 | 经访问边界校验,防越权读取 |
| **会话搜索工具** | 在会话历史中搜索内容 | 经访问边界校验 |
| **会话发送工具** | 向指定会话发送消息 | 受发送令牌约束,防滥用 |
| **会话派生工具** | 从当前会话派生子会话 | 派生可见接纳策略控制 |
| **会话让步工具** | 让步当前会话执行权 | 协作式调度,非抢占 |
| **会话工具自身** | 会话工具的元能力 | 自归档支持 |
| **会话访问控制** | 校验调用方对目标 session 的权限 | 硬约束,所有会话工具必经 |
| **会话自归档** | 会话工具自身的归档能力 | 受 creator 能力约束 |
| **会话辅助** | 会话工具共享辅助逻辑 | 跨工具复用 |
| **发送辅助** | 发送工具共享辅助逻辑 | 含 a2a 扩展 |
| **会话解析** | 会话标识解析与归一 | 跨工具一致 |
| **派生可见接纳** | 派生会话的可见性与接纳策略 | 控制派生会话是否对原会话可见 |
| **公告目标** | 会话公告的目标解析 | 跨工具一致 |
| **发送令牌** | 发送工具的令牌管理 | 限流与配额 |

## 关联关系

### 会话工具与访问边界

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   各会话工具各自校验权限                    │
   │   → 校验逻辑散落 → 易遗漏 → 越权风险       │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   所有会话工具                              │
   │       │                                     │
   │       ▼                                     │
   │   Session 访问边界(统一校验)              │
   │       │                                     │
   │       ├─ 通过 → 放行执行                    │
   │       └─ 拒绝 → 返回越权错误                │
   └─────────────────────────────────────────────┘
```

### 发送工具与 a2a 扩展

```
   会话发送工具
        │
        │ 普通发送
        ▼
   发送辅助 ──► 目标会话

   会话发送工具
        │
        │ 代理间通信(a2a)
        ▼
   a2a 扩展 ──► 发送令牌校验 ──► 跨代理发送
   (独立扩展,token 受控)
```

### 派生与让步的协作

```
   父会话
     │
     │ 调用派生工具
     ▼
   派生工具 ──► 派生可见接纳策略
     │           │
     │           ├─ 可见 → 父会话能感知子会话
     │           └─ 不可见 → 父会话不感知
     ▼
   子会话(独立执行)

   父会话
     │
     │ 调用让步工具
     ▼
   让步当前执行权 → 其他会话可接管资源
   (协作式,非抢占)
```

## 协作流程

### 一次会话历史查询的旅程

下面追踪 LLM 调用会话历史工具查询另一会话历史的全过程。

```
LLM 调用会话历史工具,传入目标会话标识
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 会话标识解析                                               │
│    → 解析目标会话标识为规范形式                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 访问边界校验                                               │
│    → 校验调用方对目标会话的读取权限                          │
│    → 通过:继续                                              │
│    → 拒绝:返回越权错误                                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 历史查询                                                   │
│    → 从 per-agent SQLite 读取目标会话历史                    │
│    → 应用分页与过滤                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果返回                                                   │
│    → 历史记录列表回送 LLM                                    │
└──────────────────────────────────────────────────────────────┘
```

### 一次会话派生的旅程

```
LLM 调用会话派生工具,传入派生参数
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 访问边界校验                                               │
│    → 校验调用方是否有派生权限                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 派生可见接纳策略评估                                      │
│    → 决定子会话是否对父会话可见                              │
│    → 决定子会话是否需要显式接纳                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 创建子会话                                                 │
│    → 继承父会话上下文(按策略)                              │
│    → 注册到 per-agent SQLite                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 返回子会话标识                                             │
│    → LLM 可继续操作父会话或与子会话交互                      │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 访问边界是硬约束

- **为什么**:多会话场景下,Agent 不能越权访问其他会话的历史或发送消息
- **怎么做**:所有会话工具调用前先经 session 访问边界统一校验
- **影响**:校验逻辑单点维护,新增会话工具自动获得保护

### 2. 发送令牌防滥用

- **为什么**:会话发送可能被滥用( spam 、资源耗尽)
- **怎么做**:发送工具走令牌管理,限流与配额集中控制
- **影响**:发送行为可控,异常调用可被识别与限制

### 3. a2a 发送走独立扩展

- **为什么**:代理间通信涉及跨代理信任边界,需独立管控
- **怎么做**:a2a 发送作为独立扩展,token 受控,与普通会话发送分离
- **影响**:跨代理通信有独立安全边界,不影响普通会话发送

### 4. 派生可见接纳策略

- **为什么**:派生会话是否对父会话可见、是否需要接纳,影响会话树结构与协作模型
- **怎么做**:派生可见接纳模块统一策略,派生工具调用时评估
- **影响**:会话树结构可控,父子会话协作关系明确

### 5. 让步是协作式而非抢占式

- **为什么**:抢占式让步会打断正在执行的工作,导致状态不一致
- **怎么做**:让步工具由 Agent 主动调用,协作式释放执行权
- **影响**:会话切换可控,不会出现中途打断的脏状态

### 6. 会话标识统一解析

- **为什么**:不同工具可能接受不同形式的会话标识,需统一为规范形式
- **怎么做**:会话解析模块统一处理标识解析与归一
- **影响**:工具实现不关心标识差异,跨工具行为一致

## 设计观察

### 为什么会话工具需要"自归档"

```
无自归档:
   会话工具创建的子会话
   → 完成后无法清理 → 会话树膨胀

有自归档:
   会话工具支持自归档
   → 子会话完成可自动归档
   → 受 creator 能力约束(只有创建者能归档)
   → 会话树保持精简
```

### 为什么派生需要可见接纳策略

```
无策略:
   父会话派生子会话
   → 子会话总是对父会话可见
   → 父会话可能被大量子会话打扰

有策略:
   父会话派生子会话
       │
       ├─ 可见策略 → 父会话感知子会话状态
       └─ 不可见策略 → 父会话不感知,子会话独立运行
   → 协作模式灵活,避免干扰
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 内置工具:bash / edit / find / grep / ls / read / write 及共享设施 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | Web 工具:fetch / search / guarded-fetch / shared |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 本文件 — 会话工具 |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 媒体生成工具:image / music / video / pdf |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 其他工具:computer / terminal / tts / dashboard / goal / nodes / message 等 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 会话访问控制 | [src/agents/tools/sessions-access.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-access.ts) |
| 会话列表工具 | [src/agents/tools/sessions-list-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-list-tool.ts) |
| 会话历史工具 | [src/agents/tools/sessions-history-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-history-tool.ts) |
| 会话搜索工具 | [src/agents/tools/sessions-search-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-search-tool.ts) |
| 会话发送工具 | [src/agents/tools/sessions-send-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-send-tool.ts) |
| 会话发送 a2a 扩展 | [src/agents/tools/sessions-send-tool.a2a.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-send-tool.a2a.ts) |
| 会话派生工具 | [src/agents/tools/sessions-spawn-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-spawn-tool.ts) |
| 会话派生可见 | [src/agents/tools/sessions-spawn-visible.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-spawn-visible.ts) |
| 会话派生可见接纳 | [src/agents/tools/sessions-spawn-visible-admission.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-spawn-visible-admission.ts) |
| 会话让步工具 | [src/agents/tools/sessions-yield-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-yield-tool.ts) |
| 会话工具自身 | [src/agents/tools/sessions-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-tool.ts) |
| 会话解析 | [src/agents/tools/sessions-resolution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-resolution.ts) |
| 会话辅助 | [src/agents/tools/sessions-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-helpers.ts) |
| 会话发送辅助 | [src/agents/tools/sessions-send-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-send-helpers.ts) |
| 会话发送令牌 | [src/agents/tools/sessions-send-tokens.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-send-tokens.ts) |
| 会话公告目标 | [src/agents/tools/sessions-announce-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/sessions-announce-target.ts) |
| 会话状态解析 | [src/agents/tools/session-status-session-resolve.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/session-status-session-resolve.ts) |
| 会话状态工具 | [src/agents/tools/session-status-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/session-status-tool.ts) |
| 会话状态运行时 | [src/agents/tools/session-status.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/session-status.runtime.ts) |
| 作用域会话访问 | [src/agents/tools/scoped-session-access.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/scoped-session-access.ts) |
