# 00 — Agent 会话管理总览

> 读完本章你将理解:Agent 会话管理在 OpenClaw 运行时中处于什么位置、由哪些子组件构成、如何与 Agent Runner 协作,以及会话状态如何在 per-agent SQLite 之上流动。

## 一句话定位

Agent 会话管理是 Agent Runner 的**实现细节层**:
- 在 per-agent SQLite 之上提供会话生命周期、分支树、上下文压缩、扩展加载与执行能力
- 模型解析由 Provider 插件提供,Agent 会话不绑定特定厂商
- 认证档案、会话历史、运行记录全部落库,无内存态泄漏

## 全局协作图

下图展示 Agent 会话管理在 OpenClaw 运行时中的位置,以及它内部 5 类子组件如何协作。**先看这张图建立心智模型,再读细节**。

```
                    用户消息(来自 Channel 接入层)
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Agent Runner                               │
        │  (一次 agent run 的总编排)                  │
        │  ① trace 追踪   ② 配置加载   ③ Lane 分配    │
        └──────────────────────┬──────────────────────┘
                               │
                               │ 把消息与上下文交给
                               │ "Agent 会话管理"层处理
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│              Agent 会话管理(本章范围)                           │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  会话生命周期层                                          │  │
│   │  (创建 / 执行 / 检视 / 提示 / 树导航)                    │  │
│   │  按"基类→特化"分层继承,共享同一会话状态                  │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │ 持有                                │
│                            ▼                                     │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  会话管理器                                              │  │
│   │  (分支 / 编解码 / 条目 / 持久化)                         │  │
│   │  会话树以 SQLite transcript 身份为根                      │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │ 调用                                │
│   ┌────────────────────────┴─────────────────────────────────┐  │
│   │                                                            │  │
│   ▼                                                            ▼  │
│   ┌──────────────────────┐              ┌────────────────────┐  │
│   │  提示词与模型        │              │  认证与执行        │  │
│   │  (系统提示 / 模板 /  │              │ (凭据存储 / OAuth /│  │
│   │   模型解析 / 注册表) │              │  bash 执行)        │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│              │   ┌─────────────────────────────────┘             │
│              │   │                                               │
│              ▼   ▼                                               │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  压缩与扩展                                              │  │
│   │  (上下文压缩 / 分支摘要 / 扩展加载与执行)                │  │
│   └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               │ 读写
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│  状态层(上游依赖)                                              │
│                                                                  │
│   ┌──────────────────────┐    ┌──────────────────────────────┐  │
│   │  共享状态库           │    │  Per-Agent 状态库            │  │
│   │  (全局运行时)        │    │  • 会话历史(transcript)     │  │
│   │                      │    │  • 认证档案(auth-profiles)  │  │
│   │                      │    │  • 运行记录 / 缓存           │  │
│   └──────────────────────┘    └──────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## 组件清单

Agent 会话管理由 5 类子组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **会话生命周期层** | 一次会话的创建、执行、检视、提示构建、树导航 | 分层继承共享同一状态,模式特定 I/O 留在调用方 |
| **会话管理器** | 会话树的分支、编解码、条目操作、持久化 | 以 SQLite transcript 身份为根,只支持最新会话版本 |
| **提示词与模型** | 系统提示构建、模板、模型解析与作用域、模型注册表 | 模型解析由 Provider 插件提供,会话层不绑定厂商 |
| **认证与执行** | 凭据存储、OAuth 注册表、bash 与通用命令执行 | 认证档案落 per-agent SQLite,失败 fail-closed |
| **压缩与扩展** | 上下文压缩、分支摘要、扩展加载与生命周期执行 | 压缩委托共享 agent-core,扩展用 jiti 加载 TS 模块 |

## 关联关系

### 会话管理与 Agent Runner 的边界

```
   ┌──────────────┐
   │ Agent Runner │ ──编排 8 阶段──► 把"会话级工作"委托给
   │ (总编排)     │                  Agent 会话管理
   └──────┬───────┘
          │
          ▼
   ┌──────────────────────────────────┐
   │  Agent 会话管理                  │
   │                                  │
   │  • 维护会话历史与分支树          │
   │  • 构建 prompt 并解析模型        │
   │  • 取认证档案调 LLM             │
   │  • 压缩长上下文                  │
   │  • 执行扩展与工具                │
   └──────────────────────────────────┘
          │
          ▼
   ┌──────────────┐
   │  状态库      │
   │ (per-agent)  │
   └──────────────┘
```

### 与上游依赖的关系

```
   ┌─────────────────────────────┐
   │  状态层(02.1)              │
   │  • per-agent SQLite         │
   │  • 写事务同步 commit        │
   └──────────────┬──────────────┘
                  │ 会话历史 / 认证档案落库
                  ▼
   ┌─────────────────────────────┐
   │  Agent 会话管理(本章)      │
   └──────────────┬──────────────┘
                  │ 调 LLM / 解析模型
                  ▼
   ┌─────────────────────────────┐
   │  AI Provider 层(02.4)      │
   │  • Provider 插件提供模型    │
   │  • 流式返回 / 工具调用      │
   └─────────────────────────────┘
```

### 反例:会话层不应直接耦合厂商

```
错误设计:
   会话生命周期 ──直接 import──► OpenAI SDK
   → 切换厂商要改会话层代码
   → 会话层绑定特定厂商的 prompt 格式

正确设计:
   会话生命周期 ──► 模型解析层 ──► Provider 插件 ──► LLM
                    (只认 Model 抽象)
   → 切换厂商只换 Provider 插件,会话层不变
```

## 协作流程

### 一次会话从创建到压缩的完整旅程

下面追踪一次 agent run 中,会话管理各子组件如何接力。

```
用户消息到达 Agent Runner
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 会话生命周期层                                             │
│    → 创建会话对象,绑定 per-agent SQLite                     │
│    → 安装工具 Hook,构建运行时能力表                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 会话管理器                                                 │
│    → 加载会话树(transcript 身份)                            │
│    → 解析父链条目,准备上下文                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 提示词与模型                                               │
│    → 构建系统提示(工具/指南/项目上下文/技能)                │
│    → 模型解析:作用域匹配 + 初始选择                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 认证与执行                                                 │
│    → 从 per-agent SQLite 取认证档案                          │
│    → 无可用凭据时 fail-closed 并给出引导文案                 │
│    → bash / 通用命令执行(沙箱策略)                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 压缩与扩展(按需触发)                                     │
│    → 上下文超阈值 → 压缩:生成摘要 + 裁剪历史                │
│    → 分支切换 → 分支摘要:总结被放弃的分支                   │
│    → 扩展加载器(jiti)加载会话级 TS 扩展                    │
│    → 扩展运行器管理扩展生命周期与事件分发                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  会话状态写入 per-agent SQLite
                  回复送回 Agent Runner → 分发
```

## 关键设计约束

### 1. 会话管理是 Agent Runner 的实现细节

- **为什么**:Agent Runner 负责总编排(trace/Lane/终态归一化),会话级细节不应污染编排层
- **怎么做**:把会话历史、prompt 构建、压缩等下沉到独立的会话管理子组件
- **影响**:Agent Runner 可独立测试,会话层可独立演进

### 2. 会话状态存 per-agent SQLite

- **为什么**:进程重启后状态可恢复,无内存态泄漏
- **怎么做**:会话历史(transcript)、认证档案、运行记录全部落 per-agent 库
- **影响**:禁止 JSON/sidecar 文件存运行时会话状态

### 3. 模型解析由 Provider 插件提供

- **为什么**:Agent 会话层不绑定特定厂商,切换 LLM 只换 Provider 插件
- **怎么做**:会话层只认 Model 抽象,模型解析通过模型注册表与 Provider 路由
- **影响**:同一 Agent 可配置不同 Provider(OpenAI/Anthropic/本地)

### 4. 认证档案 fail-closed

- **为什么**:禁止隐式凭据 fallback,防止用错账号或泄漏
- **为什么**:SecretRef 失败要隔离到最小已知拥有面
- **怎么做**:无可用凭据时给出引导文案并停步,不静默降级
- **影响**:Doctor 与 status 必须列出每个降级的 owner

### 5. 压缩委托共享 agent-core

- **为什么**:避免在会话层重写上下文裁剪与摘要算法
- **怎么做**:压缩与分支摘要桥接共享 agent-core 实现,本地保留历史抛错式 API
- **影响**:agent-core 返回 Result,会话层负责拆包转换

## 设计观察

### 为什么会话生命周期用分层继承而非单一大类

```
单一大类:
   • 所有能力塞进一个对象 → 文件膨胀,难维护
   • 测试要构造完整对象 → 启动整个运行时

分层继承:
   基类(配置/依赖)
     ↑ 特化(模型处理)
       ↑ 特化(会话检视/统计)
         ↑ 特化(压缩)
           ↑ 特化(扩展集成)
             ↑ 特化(执行/重试)
               ↑ 特化(树导航/分支摘要)
                 ↑ 顶层会话(组装)
   • 每层职责单一,可独立阅读
   • 共享同一会话状态,无跨对象同步问题
```

### 为什么扩展用独立加载器而非直接 import

```
错误设计:
   会话层 ──直接 import──► 扩展模块
   → 扩展必须随核心一起编译
   → 用户无法在运行时加载自定义扩展

正确设计:
   会话层 ──► 扩展加载器(jiti) ──► 动态加载 TS 扩展
   → 扩展可在运行时加载,无需重编译
   → 沙箱化虚拟模块,隔离核心内部
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/00-overview.md) | 本文件 — 总览与索引 |
| [01-session-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/01-session-lifecycle.md) | 会话生命周期层 |
| [02-session-manager.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/02-session-manager.md) | 会话管理器 |
| [03-prompt-model.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/03-prompt-model.md) | 提示词与模型 |
| [04-auth-execution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/04-auth-execution.md) | 认证与执行 |
| [05-compaction-extensions.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/05-compaction-extensions.md) | 压缩与扩展 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 会话生命周期顶层 | [src/agents/sessions/agent-session.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session.ts) |
| 会话管理器门面 | [src/agents/sessions/session-manager.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/session-manager.ts) |
| 系统提示构建 | [src/agents/sessions/system-prompt.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/system-prompt.ts) |
| 认证存储门面 | [src/agents/sessions/auth-storage.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/auth-storage.ts) |
| 上下文压缩桥接 | [src/agents/sessions/compaction/compaction.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/compaction/compaction.ts) |
| 扩展加载器 | [src/agents/sessions/extensions/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/extensions/loader.ts) |
| 会话目录桶导出 | [src/agents/sessions/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/index.ts) |
| Per-Agent 状态库(上游) | [src/state/openclaw-agent-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.ts) |
| 认证档案目录(上游) | [src/agents/auth-profiles/](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/auth-profiles/) |
| Agent Runner 主流程(上游) | [src/agents/agent-command.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-command.ts) |
