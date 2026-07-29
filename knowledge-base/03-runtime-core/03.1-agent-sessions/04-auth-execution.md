# 04 — 认证与执行

> 读完本章你将理解:凭据如何以 per-agent SQLite 认证档案库为唯一权威存储,OAuth 注册表如何隔离各 provider,以及 bash 与通用命令执行如何接入沙箱策略。

## 一句话定位

认证与执行层是会话与外部资源(凭据/命令)之间的**安全边界**:
- 凭据存储门面以 per-agent SQLite 认证档案库为权威,把 provider 默认档案投射进上游 SDK 形状
- OAuth 注册表为各 provider 隔离回调与刷新逻辑,刷新加文件锁防并发
- bash 执行器与通用执行器接入沙箱策略,认证失败 fail-closed 并给出引导文案

## 全局协作图

下图展示认证与执行层的内部协作。**框里是组件名+职责**。

```
        会话生命周期层(调用方)
            │
            │ 请求凭据 / 执行命令
            ▼
   ┌──────────────────────────────────────────────────────┐
   │  认证与执行层                                        │
   │                                                      │
   │   ┌──────────────────────┐  ┌─────────────────────┐ │
   │   │  凭据存储门面        │  │  认证引导文案       │ │
   │   │                      │  │                     │ │
   │   │ • API key 凭据       │  │ • 无 key 文案       │ │
   │   │ • OAuth 凭据         │  │ • 无模型文案        │ │
   │   │ • 环境变量查找       │  │ • 失败原因格式化    │ │
   │   │ • 写事务同步 commit  │  │                     │ │
   │   └──────────┬───────────┘  └─────────────────────┘ │
   │              │                                       │
   │              │ 查询 OAuth provider                   │
   │              ▼                                       │
   │   ┌──────────────────────┐  ┌─────────────────────┐ │
   │   │  OAuth 注册表        │  │  bash 执行器        │ │
   │   │                      │  │                     │ │
   │   │ • provider 注册      │  │ • 命令执行          │ │
   │   │ • 回调路由           │  │ • 操作接入          │ │
   │   │ • 刷新锁             │  │ • 输出处理          │ │
   │   └──────────────────────┘  └──────────┬──────────┘ │
   │                                         │            │
   │                              ┌──────────▼──────────┐ │
   │                              │  通用执行器         │ │
   │                              │                     │ │
   │                              │ • 命令执行抽象      │ │
   │                              │ • 进程管理          │ │
   │                              └─────────────────────┘ │
   └──────────────────────────────────────────────────────┘
            │
            │ 读写凭据 / 执行命令
            ▼
   ┌──────────────────────────────────────────────────────┐
   │  Per-Agent SQLite 认证档案库(权威存储)            │
   │                                                      │
   │  • API key 档案                                      │
   │  • OAuth 令牌(加密)                                │
   │  • 档案版本与元数据                                  │
   └──────────────────────────────────────────────────────┘
```

## 组件清单

认证与执行层由 5 个组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **凭据存储门面** | API key/OAuth 凭据读写,环境变量查找,写事务同步 | per-agent SQLite 为唯一权威,无隐式 fallback |
| **认证引导文案** | 无 key/无模型/失败原因格式化 | fail-closed 时给出引导而非静默降级 |
| **OAuth 注册表** | provider 注册,回调路由,刷新锁 | 刷新加文件锁,防并发刷新冲突 |
| **bash 执行器** | bash 命令执行,操作接入,输出处理 | 接入沙箱策略,输出截断 |
| **通用执行器** | 命令执行抽象,进程管理 | 与具体 shell 解耦 |

## 关联关系

### 凭据存储的权威与投射

```
   ┌─────────────────────────────────────────────┐
   │  Per-Agent SQLite 认证档案库(权威)        │
   │                                             │
   │  • API key 档案(加密)                     │
   │  • OAuth 令牌(加密)                       │
   │  • 档案版本 / 元数据                        │
   └────────────────────┬────────────────────────┘
                        │ 读写(写事务同步 commit)
                        ▼
   ┌─────────────────────────────────────────────┐
   │  凭据存储门面                               │
   │                                             │
   │  ① 读:从档案库加载持久化状态               │
   │  ② 投射:把 provider 默认档案投射进上游     │
   │     SDK 形状(保持上游契约)                │
   │  ③ 环境变量:作为补充查找源(非权威)       │
   │  ④ 写:写事务同步 commit 到档案库           │
   └────────────────────┬────────────────────────┘
                        │
                        ▼
   ┌─────────────────────────────────────────────┐
   │  上游会话 SDK(契约形状)                  │
   │                                             │
   │  • 接收投射后的档案形状                     │
   │  • 不感知 OpenClaw 内部存储                 │
   └─────────────────────────────────────────────┘

   反例:环境变量作为权威源
        → 多 agent 共享环境变量 → 凭据串号
        → 环境变量变更不落库 → 状态不一致
```

### OAuth 刷新的并发保护

```
   场景:同一 agent 多个会话同时触发 OAuth 令牌刷新

   无锁(错误):
   会话 A ──刷新──► provider ──返回新令牌──► 写库
   会话 B ──刷新──► provider ──返回新令牌──► 写库
   → 两次刷新,后写覆盖前写
   → 可能拿到已失效的旧令牌

   有文件锁(正确):
   会话 A ──获取锁──► 刷新──► 写库──► 释放锁
   会话 B ──等锁──► 获取锁──► 读库(已是新令牌)
                              → 若仍需刷新则刷新,否则直接用
   → 单一刷新路径,无重复刷新
   → 符合"写事务同步 commit"约束
```

## 协作流程

### 一次凭据获取的完整过程

下面追踪会话请求 API key 凭据到可用的全过程。

```
会话生命周期层请求凭据(provider + 模型)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 凭据存储门面接收请求                                      │
│    → 校验档案库迁移就绪(未就绪抛迁移错误)                  │
│    → 从 per-agent SQLite 加载持久化档案状态                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 查找匹配档案                                              │
│    → 按 provider 与模型匹配档案                             │
│    → 找到?进入步骤 3                                       │
│    → 未找到?查环境变量作为补充源                           │
│       → 环境变量有?投射为档案形状                          │
│       → 都没有?fail-closed                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 投射为上游 SDK 形状                                       │
│    → 把 OpenClaw 内部档案投射进上游会话 SDK 契约形状        │
│    → 保持上游契约,不暴露内部存储                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 返回凭据给会话                                            │
│    → 会话用凭据调 Provider → LLM                            │
└──────────────────────────────────────────────────────────────┘

失败路径(fail-closed):
   无可用凭据 → 认证引导文案格式化原因 → 返回给会话 → 停步
```

### bash 命令执行的接入

下面追踪一次 bash 工具调用的执行过程。

```
LLM 发出 bash 工具调用
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 会话执行层接管                                            │
│    → 调用 bash 执行器                                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. bash 执行器                                              │
│    → 创建本地 bash 操作集(沙箱策略接入)                   │
│    → 执行命令(操作集抽象)                                 │
│    → 处理输出(截断/累积)                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 返回结果                                                  │
│    → 输出送回会话 → 送回 LLM                                │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. per-agent SQLite 为唯一权威存储

- **为什么**:多 agent 隔离,进程重启可恢复,无内存态泄漏
- **怎么做**:凭据读写都走 per-agent SQLite 认证档案库;环境变量只是补充查找源,非权威
- **影响**:禁止 JSON/sidecar 文件存凭据;旧文件格式只在 doctor 迁移代码出现

### 2. 认证失败 fail-closed

- **为什么**:禁止隐式凭据 fallback,防止用错账号或泄漏
- **怎么做**:无可用凭据时给出引导文案并停步,不静默降级到其他凭据
- **影响**:Doctor 与 status 必须列出每个降级的 owner;失败隔离到最小已知拥有面

### 3. OAuth 刷新加文件锁

- **为什么**:多会话并发刷新会重复刷新并互相覆盖
- **怎么做**:刷新前获取文件锁,持有锁期间刷新并写库,释放后其他会话读新令牌
- **影响**:单一刷新路径,符合写事务同步 commit 约束

### 4. 投射保持上游 SDK 契约

- **为什么**:上游会话 SDK 有固定的档案形状契约,不能直接塞 OpenClaw 内部形状
- **怎么做**:凭据存储门面把 OpenClaw 内部档案投射进上游 SDK 契约形状
- **影响**:上游 SDK 不感知 OpenClaw 内部存储,契约稳定

### 5. 档案库迁移就绪校验

- **为什么**:旧档案库未迁移到当前版本时,读写会损坏数据
- **怎么做**:加载前校验档案库迁移就绪,未就绪抛迁移错误
- **影响**:强制先迁移再使用,符合"运行时只读当前规范形状"约束

## 设计观察

### 为什么环境变量不是权威源

```
环境变量为权威(错误):
   • 多 agent 共享同一进程环境变量 → 凭据串号
   • 环境变量变更不落库 → 状态不一致
   • 不同 agent 无法隔离凭据
   • 进程重启后环境变量可能丢失

per-agent SQLite 为权威(正确):
   • 每个 agent 独立档案库 → 天然隔离
   • 写库同步 commit → 状态一致
   • 进程重启可恢复
   • 环境变量仅作补充查找源(无档案时尝试)
```

### 为什么 bash 执行器与通用执行器分开

```
合一(错误):
   一个执行器处理所有命令
   → bash 特有逻辑(PTY/操作集/输出累积)与通用逻辑混淆
   → 难以单独测试 bash 行为

分开(正确):
   bash 执行器:专注 bash 命令(操作集/PTY/输出处理)
   通用执行器:命令执行抽象与进程管理
   → 各自职责清晰
   → bash 执行器可接入沙箱策略,通用执行器保持抽象
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/00-overview.md) | 总览与索引 |
| [01-session-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/01-session-lifecycle.md) | 会话生命周期层 |
| [02-session-manager.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/02-session-manager.md) | 会话管理器 |
| [03-prompt-model.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/03-prompt-model.md) | 提示词与模型 |
| [04-auth-execution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/04-auth-execution.md) | 本文件 — 认证与执行 |
| [05-compaction-extensions.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/05-compaction-extensions.md) | 压缩与扩展 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 凭据存储门面 | [src/agents/sessions/auth-storage.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/auth-storage.ts) |
| 认证引导文案 | [src/agents/sessions/auth-guidance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/auth-guidance.ts) |
| OAuth 注册表 | [src/agents/sessions/auth-storage-oauth-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/auth-storage-oauth-registry.ts) |
| bash 执行器 | [src/agents/sessions/bash-executor.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/bash-executor.ts) |
| 通用执行器 | [src/agents/sessions/exec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/exec.ts) |
| 认证档案目录(上游) | [src/agents/auth-profiles/](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/auth-profiles/) |
| 认证档案持久化(上游) | [src/agents/auth-profiles/persisted.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/auth-profiles/persisted.ts) |
| 认证档案 SQLite 访问(上游) | [src/agents/auth-profiles/sqlite.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/auth-profiles/sqlite.ts) |
| bash 操作集 | [src/agents/sessions/tools/bash.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/bash.ts) |
| bash 操作抽象 | [src/agents/sessions/tools/bash-operations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/bash-operations.ts) |
