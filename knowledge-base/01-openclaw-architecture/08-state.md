# 08 — SQLite 状态管理

> 状态层是 OpenClaw 的"记忆":所有运行时状态、缓存、队列、注册表都存在 SQLite。读完本章你将理解为什么禁止 JSON 文件、双层结构如何划分、写事务为什么必须同步 commit、schema 演进如何管控。

## 一句话定位

SQLite 是 OpenClaw 的**唯一状态层**:
- 禁止 JSON / JSONL / TXT / sidecar 文件存运行时状态、缓存、队列、注册表、游标、检查点
- 双层结构:共享状态库(全局运行时 + 插件 KV)+ Per-Agent 状态库(会话历史 + 缓存)
- 写事务是同步 commit 段:BEGIN 前完成所有异步工作,写入前重读校验,禁止 await in callback
- Schema 演进严控:纯 additive 不 bump,破坏性变更需 owner 显式确认,agent 不可自主 bump

## 全局协作图

下图展示状态层如何被所有核心组件共享,以及双层结构如何划分。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      核心运行时(所有层)                            │
│                                                                      │
│   Gateway 编排    Agent Runner    Turn 内核    插件系统              │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 读写状态(只通过 Kysely helpers)
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      状态访问层(Kysely)                           │
│                                                                      │
│   约束:禁止 raw SQL(除 schema DDL / 迁移 / 底层 bootstrap)       │
│   约束:写事务同步 commit,禁止 await in callback                   │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  共享状态库      │ │  Per-Agent 状态库│ │  Doctor 迁移器   │
│                  │ │                  │ │                  │
│  state/          │ │  agents/<id>/    │ │  openclaw doctor │
│  openclaw.sqlite │ │  agent/          │ │  --fix           │
│                  │ │  openclaw-agent  │ │                  │
│  schema v6       │ │  .sqlite         │ │  单一迁移 owner  │
│                  │ │                  │ │  迁移→校验→      │
│ • 全局运行时状态 │ │  schema v16      │ │  runtime 假定    │
│ • 插件 KV 数据   │ │                  │ │  新 shape        │
│ • 跨 Agent 共享  │ │ • 会话历史       │ │                  │
│                  │ │ • 运行记录       │ │  禁止:          │
│                  │ │ • Agent 缓存     │ │  • dual-write    │
│                  │ │                  │ │  • read-through  │
│                  │ │                  │ │  • lazy import   │
│                  │ │                  │ │  • SQLite 失败   │
│                  │ │                  │ │    用 JSON       │
└──────────────────┘ └──────────────────┘ └──────────────────┘

禁止的存储方式:
┌──────────────────────────────────────────────────────────────────────┐
│  • JSON 文件(运行时状态)                                           │
│  • JSONL 文件(队列 / 游标 / 检查点)                               │
│  • TXT 文件                                                          │
│  • sidecar 文件                                                      │
│  • 任何 OpenClaw 拥有的运行时状态用非 SQLite 存储                    │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

状态层由 5 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **共享状态库** | 存全局运行时状态、插件 KV 数据、跨 Agent 共享数据 | schema v6,所有层共享读写 |
| **Per-Agent 状态库** | 存单个 Agent 的会话历史、运行记录、缓存 | schema v16,Agent 范围隔离 |
| **状态访问层** | 用 Kysely helpers 访问 SQLite,非 raw SQL | 写事务同步 commit,禁止 await in callback |
| **Doctor 迁移器** | 单一迁移 owner,迁移旧 shape 到新 shape | 迁移后 runtime 假定新 shape,无 dual-write |
| **Schema 演进管理器** | 管控 schema 版本 bump | 纯 additive 不 bump,破坏性需 owner 显式确认 |

## 关联关系

### 双层 SQLite 结构

```
    OpenClaw 状态层(SQLite only)
    ════════════════════════════

    ┌──────────────────────────────────────────────────────────────┐
    │                    共享状态库                                │
    │                state/openclaw.sqlite                         │
    │                    schema v6                                 │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ 全局运行时状态                                       │   │
    │  │  • Gateway 配置缓存                                 │   │
    │  │  • 通道状态                                         │   │
    │  │  • 插件注册表                                       │   │
    │  │  • 会话监视游标                                      │   │
    │  │  • 定时任务状态                                     │   │
    │  └──────────────────────────────────────────────────────┘   │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ 插件 KV 数据                                         │   │
    │  │  • 各插件的键值存储                                  │   │
    │  │  • 跨 Agent 共享的插件数据                           │   │
    │  └──────────────────────────────────────────────────────┘   │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ 其他共享状态                                         │   │
    │  │  • 用户档案                                         │   │
    │  │  • 配置机器状态                                      │   │
    │  │  • onboarding 推荐                                  │   │
    │  │  • 包生命周期租约                                    │   │
    │  │  • Agent 删除日志                                    │   │
    │  └──────────────────────────────────────────────────────┘   │
    └──────────────────────────────────────────────────────────────┘

                            ▲
                            │ 所有层读写
                            │

    ┌──────────────────────────────────────────────────────────────┐
    │                    Per-Agent 状态库                          │
    │        agents/<agentId>/agent/openclaw-agent.sqlite          │
    │                    schema v16                                │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ Agent 范围状态                                       │   │
    │  │  • 会话历史                                         │   │
    │  │  • 对话回合                                         │   │
    │  │  • 工具调用记录                                      │   │
    │  └──────────────────────────────────────────────────────┘   │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ Agent 范围缓存                                       │   │
    │  │  • prompt 缓存                                      │   │
    │  │  • 工具描述符缓存                                    │   │
    │  │  • 模型目录缓存                                      │   │
    │  └──────────────────────────────────────────────────────┘   │
    │                                                              │
    │  ┌──────────────────────────────────────────────────────┐   │
    │  │ 看板与会话共享                                       │   │
    │  │  • 会话共享                                          │   │
    │  │  • 会话来源                                          │   │
    │  └──────────────────────────────────────────────────────┘   │
    └──────────────────────────────────────────────────────────────┘
```

### 写事务同步 commit 流程

```
    SQLite 写事务流程(硬约束)
    ═══════════════════════════

    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 1:异步规划(BEGIN 之前)                           │
    │                                                          │
    │  允许:                                                   │
    │  ├─ 异步规划                                            │
    │  ├─ 文件系统访问                                        │
    │  ├─ 插件钩子                                            │
    │  └─ 谓词判断                                            │
    │                                                          │
    │  必须:所有异步工作在 BEGIN 之前完成                    │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 2:BEGIN 事务                                      │
    │                                                          │
    │  开始同步 commit 段                                      │
    │                                                          │
    │  从这里开始:                                            │
    │     禁止返回 Promise                                    │
    │     禁止执行 await                                      │
    │     禁止任何异步操作                                    │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 3:重读 + 校验权威行                               │
    │                                                          │
    │  必须:                                                   │
    │  ├─ 重读要修改的行                                      │
    │  └─ 校验行未被其他事务修改                              │
    │                                                          │
    │  原因:                                                   │
    │  ├─ 防止丢失更新                                        │
    │  └─ 确保写入基于最新数据                                │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 4:写入(同步)                                     │
    │                                                          │
    │  用 Kysely helpers(非 raw SQL)                         │
    │                                                          │
    │  例外(允许 raw SQL):                                   │
    │  ├─ schema DDL                                          │
    │  ├─ 迁移                                                │
    │  ├─ 底层数据库 bootstrap                                │
    │  └─ 窄场景 SQLite 原语                                  │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 5:COMMIT(同步)                                   │
    │                                                          │
    │  同步 commit,事务完成                                   │
    └──────────────────────────────────────────────────────────┘
```

### Schema 变更决策

```
   想变更 SQLite schema?
        │
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 纯 additive?(新表,旧版本 build 仍能工作)             │
   │                                                          │
   │  ├─ Yes → 不 bump schema version                        │
   │  │   ├─ 在 canonical schema 文件声明                    │
   │  │   ├─ 首次使用时 lazy ensure(幂等)                 │
   │  │   └─ 下一次自然 bump 时合并到迁移路径              │
   │  │                                                      │
   │  └─ No  → 继续...                                       │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 破坏性?(旧 reader 无法容忍)                           │
   │                                                          │
   │  └─ Yes → 必须 bump schema version                     │
   │      ├─ 需 owner 显式讨论与接受                        │
   │      └─ Agent 不可自主 bump                            │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Cache / 瞬态状态?                                       │
   │                                                          │
   │  └─ 无兼容迁移(除非有 shipped 契约)                  │
   │      ├─ 优先删除 / 丢弃 / 重建 而非导入               │
   │      └─ 如果旧状态可丢失,删除旧路径                  │
   └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 一次状态迁移的完整旅程

下面追踪一个用户从旧版本升级到新版本时,状态如何被迁移。

```
用户从旧版本升级
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Runtime 阶段(正常运行时)                                 │
│    Runtime 只读 canonical store(最新 shape)                │
│    → 不读旧 file stores                                     │
│    → 不读 sidecars                                          │
│    → 不读 aliases                                           │
│    → 不做 fallback readers                                  │
│    → 如果 shape 不匹配,启动失败,提示运行 doctor          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 用户运行 doctor --fix                                      │
│    Doctor 是单一迁移 owner                                   │
│    → 核心配置修复在核心 doctor                              │
│    → 插件配置修复在插件 doctor contract                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Doctor 迁移流程                                            │
│    ① 读取旧 shape 数据                                       │
│    ② 迁移到新 shape                                          │
│    ③ 校验新 shape 正确                                       │
│    ④ 标记迁移完成                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 迁移后 Runtime 行为                                       │
│    Runtime 假定新 shape                                      │
│    → 不再回头看旧数据                                        │
│    → 无 dual-write                                          │
│    → 无 read-through fallback                               │
│    → 无 lazy import                                          │
│    → 无 "if SQLite fails use JSON"                          │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. SQLite 是唯一状态层

- **为什么**:散落的 JSON / JSONL / TXT / sidecar 文件会导致状态不一致、难备份、难迁移、难排查;集中到 SQLite 让状态可管理、可事务、可查询。
- **怎么做**:所有 OpenClaw 拥有的运行时状态、缓存、队列、注册表、游标、检查点、插件临时数据都存 SQLite;禁止任何非 SQLite 文件存这些数据。
- **影响**:状态集中管理,一致性强;但所有状态访问都经过 SQLite,要求合理的访问模式与索引。

### 2. 写事务同步 commit

- **为什么**:SQLite 写事务中如果 await,可能导致事务超时、锁竞争、数据一致性破坏;同步 commit 段保证事务原子性。
- **怎么做**:BEGIN 前完成所有异步工作(规划、文件系统访问、插件钩子、谓词);BEGIN 后只做重读校验 + 同步写入 + 同步 commit;禁止从事务回调返回 Promise 或执行 await。
- **影响**:数据一致性强;但要求把异步逻辑与同步写入分离,增加代码组织约束。

### 3. 用 Kysely helpers 而非 raw SQL

- **为什么**:raw SQL 字符串容易拼写错误、无法类型检查、难维护;Kysely helpers 提供类型安全的查询构建。
- **怎么做**:运行时访问用 Kysely helpers;例外只限 schema DDL、迁移、底层 bootstrap、窄场景 SQLite 原语。
- **影响**:查询类型安全;但要求所有访问都走 helpers,不能临时拼 SQL。

### 4. Schema 版本 bump 需 owner 显式确认

- **为什么**:schema bump 意味着旧版本无法读取新数据,影响所有已部署用户;agent 自主 bump 会导致版本失控。
- **怎么做**:纯 additive(新表)不 bump,只声明 + lazy ensure + 下次自然 bump 合并;破坏性变更(旧 reader 无法容忍)必须 bump,需 owner 显式讨论与接受,agent 不可自主 bump。
- **影响**:schema 稳定性高;但演进决策慢,需人工把关。

### 5. Doctor 是单一迁移 owner

- **为什么**:如果 runtime 也做迁移,会导致 dual-write、read-through fallback、lazy import 等复杂分支,状态不一致;单一 owner 让迁移逻辑集中。
- **怎么做**:Doctor 迁移 → 校验 → runtime 假定新 shape;禁止 dual-write、read-through fallback、lazy import、"if SQLite fails use JSON"。
- **影响**:迁移逻辑集中,易维护;但要求用户升级时必须先运行 doctor。

### 6. Cache 无兼容迁移

- **为什么**:Cache 是瞬态数据,丢失可重建;为 cache 做迁移得不偿失。
- **怎么做**:除非有 shipped 用户契约,cache / 瞬态状态无兼容迁移;优先删除 / 丢弃 / 重建而非导入;如果旧状态可丢失且无用户可见数据丢失,删除旧路径。
- **影响**:cache 逻辑简单;但要求 cache 可重建,不能存不可恢复的数据。

## 设计观察

### 为什么禁止 JSON 文件存运行时状态

```
错误设计:状态散落在多个 JSON 文件
   state/
   ├─ config.json          (配置缓存)
   ├─ sessions.jsonl       (会话队列)
   ├─ cursor.txt           (游标)
   ├─ plugin-kv/           (插件 KV)
   │   ├─ plugin-a.json
   │   └─ plugin-b.json
   └─ checkpoint.json      (检查点)
   → 状态不一致(部分文件更新部分没更新)
   → 难备份(要备份多个文件)
   → 难迁移(每个文件格式不同)
   → 难排查(状态散落)
   → 无事务保证

正确设计:状态集中到 SQLite
   state/openclaw.sqlite    (共享状态)
   agents/<id>/...sqlite    (per-agent 状态)
   → 事务保证(ACID)
   → 单文件备份
   → 统一迁移路径
   → 可查询(SQL)
   → 一致性强
```

### 为什么写事务禁止 await

```
错误设计:事务回调中 await
   db.transaction(async (trx) => {
     await trx.insert(...);       // await 1
     const data = await fetchData(); // await 2(外部 IO)
     await trx.update(...);       // await 3
   });
   → SQLite 锁定时间不可控
   → 外部 IO 期间事务挂起
   → 可能超时回滚
   → 数据一致性风险

正确设计:同步 commit 段
   // BEGIN 前完成所有异步
   const data = await fetchData();
   const plan = await computePlan(data);

   // 同步事务段
   db.transaction((trx) => {
     const current = trx.select(...);  // 重读校验
     trx.insert(...);                  // 同步写入
     trx.update(...);                  // 同步写入
   });                                 // 同步 commit
   → 锁定时间短
   → 无外部 IO 在事务内
   → 数据一致
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 模块地图与目录职责 |
| [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) | CLI → Gateway 启动流程 |
| [04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/04-agent-runtime.md) | Agent 运行时流程 |
| [05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/05-plugin-system.md) | 插件系统 |
| [06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/06-channels.md) | 通道系统 |
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | 本文件 — SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 共享状态库主实现 | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
| 共享状态库路径 | [src/state/openclaw-state-db.paths.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.paths.ts) |
| 共享状态库 schema 修复 | [src/state/openclaw-state-db-schema-repair.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-repair.ts) |
| 共享状态库 additive schema | [src/state/openclaw-state-db-schema-additive.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-additive.ts) |
| 共享状态库 legacy 回填 | [src/state/openclaw-state-db-legacy-backfills.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-legacy-backfills.ts) |
| 共享状态库 operator 审批迁移 | [src/state/openclaw-state-db-operator-approval-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-operator-approval-migration.ts) |
| 共享状态库 audit 迁移 | [src/state/openclaw-state-db-audit-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-audit-migration.ts) |
| 共享状态库启动检查点 | [src/state/openclaw-state-db-startup-checkpoint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-startup-checkpoint.ts) |
| 共享状态库只读访问 | [src/state/openclaw-state-db-readonly.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-readonly.ts) |
| 共享状态库权限 | [src/state/openclaw-state-db-permissions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-permissions.ts) |
| 共享状态库租约 | [src/state/openclaw-state-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-lease.ts) |
| Per-Agent 状态库主实现 | [src/state/openclaw-agent-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.ts) |
| Per-Agent 状态库路径 | [src/state/openclaw-agent-db.paths.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.paths.ts) |
| Per-Agent 状态库 schema | [src/state/openclaw-agent-db-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-schema.ts) |
| Per-Agent 状态库会话迁移 | [src/state/openclaw-agent-db-session-migrations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-session-migrations.ts) |
| Per-Agent 状态库会话来源 | [src/state/openclaw-agent-db-session-provenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-session-provenance.ts) |
| Schema 版本常量 | [src/state/openclaw-schema-versions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-schema-versions.ts) |
| 数据库校验 | [src/state/openclaw-database-verify.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-verify.ts) |
| 数据库预检 | [src/state/openclaw-database-preflight.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-preflight.ts) |
| 隔离存储 | [src/state/openclaw-quarantine-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-quarantine-store.ts) |
| 用户档案 | [src/state/user-profiles.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/user-profiles.ts) |
| 包生命周期租约 | [src/state/claw-package-lifecycle-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/claw-package-lifecycle-lease.ts) |
| Agent 删除日志 | [src/state/agent-deletion-journal.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/agent-deletion-journal.ts) |
| Normalization Core 工具包 | [packages/normalization-core/](file:///d:/DevSpace/person/ai_space/openclaw/packages/normalization-core) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
