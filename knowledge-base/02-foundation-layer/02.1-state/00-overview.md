# 00 — 状态层总览

> 这是状态层目录的入口。读完本章你将理解:OpenClaw 为什么用 SQLite 双层结构、状态层由哪些组件构成、它们如何协作保证一致性。

## 一句话定位

状态层是 OpenClaw 的"记忆中枢":
- 全部运行时状态(配置、会话、缓存、注册表、租约)只落在 SQLite
- 双层结构:一个共享库 + 每个 Agent 一个独立库
- 写事务同步 commit,Schema 演进有严格版本契约

## 全局协作图

下图展示状态层的双层结构与组件协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          上层调用方                                   │
│                                                                      │
│   Gateway 核心     Agent Runner     插件系统     Doctor / CLI        │
│   (启动/调度)      (会话/缓存)      (KV 数据)   (迁移/修复)          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 所有状态读写都走状态层契约
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          状态层(State Layer)                       │
│                                                                      │
│   ┌─────────────────────────┐    ┌─────────────────────────────┐    │
│   │  共享状态库              │    │  Per-Agent 状态库            │    │
│   │                         │    │                             │    │
│   │  • 全局运行时状态        │    │  • 单 Agent 会话历史         │    │
│   │  • 插件 KV 数据          │    │  • Agent 范围缓存            │    │
│   │  • Agent 注册表          │    │  • 运行记录                  │    │
│   │  • 跨 Agent 租约         │    │  • Agent 范围租约            │    │
│   └───────────┬─────────────┘    └──────────────┬──────────────┘    │
│               │                                  │                   │
│               │       注册表 + 路径索引          │                   │
│               │◄────────────────────────────────┘                   │
│               │          (Agent 库在共享库登记)                      │
│                                                                      │
│   横向契约(对所有上层):                                            │
│   • SQLite 唯一存储  • Kysely helpers  • 写事务同步 commit          │
│   • Schema 版本管理  • 一次性 lazy ensure  • 禁止 JSON/sidecar     │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      维护面(Maintenance Surface)                    │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│   │  Schema      │  │  Verify      │  │  Operator-Approval /   │   │
│   │  演进管理    │  │  完整性校验   │  │  Restart-Handoff /     │   │
│   │  (版本/迁移) │  │  (定期巡检)  │  │  Audit 迁移            │   │
│   └──────────────┘  └──────────────┘  └────────────────────────┘   │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  Lease(租约体系):跨进程串行化信任工作                        │  │
│   │  • 共享库租约   • Agent 库租约   • Agent 删除 journal        │  │
│   └──────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

状态层由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **共享状态库** | 全局运行时状态、插件 KV、Agent 注册表、跨 Agent 租约 | 单文件,所有 Agent 共享;路径 `state/openclaw.sqlite` |
| **Per-Agent 状态库** | 单个 Agent 的会话历史、缓存、运行记录、Agent 范围租约 | 一个 Agent 一个库;路径 `agents/<agentId>/agent/openclaw-agent.sqlite` |
| **Schema 演进管理** | 双层库各自独立的 schema 版本契约;additive vs bump 区分 | 版本 bump 需用户显式确认,Agent 不能自主推进 |
| **租约体系** | 跨进程串行化信任工作,保证同一资源不会被并发占用 | 同步事务获取/释放;租约丢失需 fail closed |
| **完整性校验** | 定期巡检双层库,把损坏结果上报隔离(quarantine) | 子进程 worker 执行,主进程不被阻塞 |
| **维护迁移面** | Doctor 拥有的修复入口:operator-approval / restart-handoff / audit / 启动 checkpoint | Doctor-only,运行时不读旧 shape |

## 关联关系

### 双层库的注册关系

```
   ┌─────────────────────────────────┐
   │  共享状态库                     │
   │                                 │
   │  ┌───────────────────────────┐  │
   │  │  agent_databases 注册表   │  │
   │  │  (路径/版本/最后可见时间) │  │
   │  └────────────┬──────────────┘  │
   └───────────────┼─────────────────┘
                   │
                   │ 每个 Agent 库在共享库登记一行
                   │ (路径 / schema 版本 / 大小 / 最后可见时间)
                   │
       ┌───────────┼───────────┐
       │           │           │
       ▼           ▼           ▼
   ┌────────┐  ┌────────┐  ┌────────┐
   │ AgentA │  │ AgentB │  │ AgentC │
   │  库    │  │  库    │  │  库    │
   └────────┘  └────────┘  └────────┘

   设计目的:
   • 共享库是"目录页",Agent 库是"分卷"
   • 列出所有 Agent 不需要扫盘
   • Agent 库 schema 版本可独立演进
   • 共享库自身也记录 Agent 库的租约状态
```

### 上层调用方与状态层的边界

```
   ┌──────────────────────────────────────────────┐
   │  上层调用方                                  │
   │  (Gateway / Agent Runner / 插件 / Doctor)   │
   └────────────────────┬─────────────────────────┘
                        │
                        │ 只能通过状态层契约访问
                        │ (不能直接读 SQLite 文件)
                        ▼
   ┌──────────────────────────────────────────────┐
   │  状态层契约                                  │
   │                                              │
   │  • 共享库:打开 / 写事务 / 只读 / 维护       │
   │  • Agent 库:打开 / lease / 注册 / 维护      │
   │  • Schema:版本断言 / 加列 / lazy ensure     │
   │  • 租约:获取 / 释放 / 所有权断言            │
   └────────────────────┬─────────────────────────┘
                        │
                        ▼
   ┌──────────────────────────────────────────────┐
   │  SQLite 文件层                               │
   │  (WAL 模式 / 权限硬化 / 完整性校验)         │
   └──────────────────────────────────────────────┘
```

### 正确设计 vs 错误设计

```
错误设计(多源状态):
   共享库 ──┐
   JSON 文件 ──┼──► 运行时各自判断状态来源 → 不一致
   内存缓存 ──┘

正确设计(单源真相):
   运行时 ──► SQLite(唯一真相源)
                ↑
            旧 JSON 只在 Doctor 迁移代码中出现
            运行时不读旧 shape
```

## 协作流程

### 一次状态写入的完整旅程

下面追踪一次 Agent Runner 写会话历史的全过程,标注每步由哪个组件负责。

```
Agent Runner 准备写入会话历史
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 路径解析                                                   │
│    由 Per-Agent 库路径解析器                                   │
│    → 根据 agentId 解析出 agents/<id>/agent/openclaw-agent.sqlite│
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 租约获取(claim lease)                                    │
│    由 Agent 库租约管理器                                       │
│    → 在共享库的 agent_database_leases 表写一行                │
│    → 校验 agent_deletion_journal 没有 pending 删除            │
│    → 返回 leaseId                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 打开 Agent 库                                              │
│    由 Per-Agent 库 opener                                      │
│    → 配置 WAL pragma / busy timeout                           │
│    → 权限硬化(0o700 目录 / 0o600 文件)                       │
│    → 完整性断言(文件未损坏)                                  │
│    → Schema 版本断言(不能比当前版本更新)                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 写事务(同步 commit)                                      │
│    由共享/Agent 库写事务管理器                                 │
│    → 进入 BEGIN IMMEDIATE                                      │
│    → 重新读取并校验权威行(防 TOCTOU)                          │
│    → 写入会话历史行                                            │
│    → 同步 commit(回调内禁止 await/Promise)                   │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 注册表更新                                                 │
│    由 Agent 库注册表                                           │
│    → 在共享库的 agent_databases 表更新 lastSeenAt / sizeBytes │
│    → 让"列出所有 Agent"无需扫盘                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 租约释放(release lease)                                  │
│    由 Agent 库租约管理器                                       │
│    → 删除 agent_database_leases 行                             │
│    → 让其他进程可获取该 Agent 库的租约                        │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Doctor 迁移的旅程

```
openclaw doctor --fix
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 维护断言                                                   │
│    由共享库维护断言器                                          │
│    → 检查 schema 版本是否在支持范围                            │
│    → 路径解析 + 完整性确认                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 识别需要的迁移                                             │
│    由各迁移模块自检                                            │
│    → operator-approval kind 约束是否需要修复                  │
│    → restart-handoff 旧表是否需要 strict 化                   │
│    → audit-events 旧列是否需要重写                            │
│    → session-watch cursor provenance 是否需要 v4 化           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 在事务内执行迁移                                           │
│    由各迁移模块在写事务内                                      │
│    → 同步 commit                                              │
│    → 迁移后断言 canonical schema shape                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 标记 schema 版本                                           │
│    由 schema 版本管理                                          │
│    → 更新 user_version 到当前 canonical 版本                  │
│    → 后续运行时直接读 canonical shape,无 fallback             │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. SQLite 是唯一状态层

- **为什么**:多源状态(JSON/JSONL/TXT/sidecar)会导致真相分裂、并发冲突、恢复不一致
- **怎么做**:所有运行时状态、缓存、队列、注册表、索引、游标、checkpoint 都落 SQLite;旧文件格式只在 Doctor 迁移代码中读
- **影响**:运行时代码无 fallback 分支,失败必须 fail loud 而非走旁路

### 2. 双层库职责分离

- **为什么**:单库会让全局状态与 Agent 局部状态耦合,一个 Agent 的损坏影响全局;多文件 JSON 又会失控
- **怎么做**:共享库存全局/注册表/跨 Agent 租约;每个 Agent 独库存会话/缓存/运行记录;Agent 库在共享库登记一行
- **影响**:Agent 库可独立备份/删除/迁移;共享库保持小而稳定

### 3. 写事务同步 commit

- **为什么**:SQLite 事务回调内 `await`/Promise 会让事务边界失控,导致锁未释放或部分写入
- **怎么做**:先完成异步规划、文件访问、插件 Hook、谓词判断,再 `BEGIN`;事务回调内只做同步读+校验+写+commit
- **影响**:事务回调必须同步;返回 Promise 会触发硬错误

### 4. Kysely helpers 优先,raw SQL 受限

- **为什么**:raw SQL 字符串易拼接出错、难审计、绕过类型契约
- **怎么做**:运行时读写用 Kysely helpers;raw SQL 仅限 schema DDL、migrations、低层 bootstrap、 narrowly justified 的 SQLite 原语
- **影响**:类型安全 + 可审计;新加 raw SQL 需要说明理由

### 5. Schema 版本 bump 是重大决策

- **为什么**:版本 bump 意味着旧版客户端无法读取新库,会影响升级路径
- **怎么做**:bump 需用户显式讨论确认;Agent 不能自主推进 schema 版本;纯 additive 变更不 bump,在 canonical schema 声明 + 一次性 lazy ensure
- **影响**:升级路径稳定;additive 加表/列对老版本是 graceful degrade

### 6. 旧 shape 只在迁移代码中读

- **为什么**:运行时若兼容旧 shape,会积累 shims/aliases/fallback 栈,最终无法维护
- **怎么做**:运行时只读当前 canonical shape;旧 shape 在 Doctor 迁移代码中规范化后再交给运行时
- **影响**:运行时代码简洁;旧 shape 兼容是迁移债务,不是运行时债务

## 设计观察

### 为什么用双层库而非单库

```
错误设计(单库):
   所有 Agent + 全局状态 ──► 一个 SQLite 文件
   → 一个 Agent 写入阻塞所有 Agent
   → 单 Agent 损坏影响全局
   → 备份/删除 Agent 需要全库操作

正确设计(双层):
   共享库(小而稳):注册表 + 全局状态 + 跨 Agent 租约
       │
       └──► Agent 库(独立):会话 + 缓存 + 运行记录
   → Agent 间写不互相阻塞
   → 单 Agent 损坏只影响自己
   → Agent 可独立备份/删除/迁移
```

### 为什么 Agent 库要在共享库登记

```
错误设计(不登记):
   要列出所有 Agent → 扫盘 agents/ 目录
   → 慢
   → 容易遇到符号链接 / 权限 / 损坏文件
   → 无法知道每个 Agent 的 schema 版本

正确设计(登记):
   共享库的 agent_databases 表 = Agent 目录页
   → 列出所有 Agent = 一次 SQL 查询
   → 包含路径 / schema 版本 / 大小 / 最后可见时间
   → 注册时用 realpath + device/inode 防符号链接陷阱
```

### 为什么租约要写共享库

```
错误设计(文件锁):
   Agent 库文件 ──► OS 文件锁
   → 进程崩溃后锁释放,但状态可能未清理
   → 难以诊断"谁持有锁"
   → 跨平台行为不一致

正确设计(共享库租约):
   agent_database_leases 表(在共享库)
   → 记录 leaseId / agentId / path / owner_pid / owner_start_time / opened_at
   → 可查询、可诊断、可检测进程死亡
   → 配合 agent_deletion_journal 防止已删除 Agent 被重新 claim
```

## 阅读建议

| 学习目标 | 推荐顺序 |
|---|---|
| **理解全局** | 按章节序号 00 → 04 通读 |
| **理解共享库细节** | 直接读 01(共享状态库) |
| **理解 Agent 库细节** | 先读 01 共享库,再读 02(Agent 库) |
| **理解升级路径** | 直接读 03(Schema 演进) |
| **理解运维与可靠性** | 直接读 04(维护与租约) |

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) | 本文件 — 总览与索引 |
| [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) | 共享状态库:契约、schema-helpers、permissions、readonly |
| [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) | Per-Agent 状态库:契约、lease、registry |
| [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) | Schema 演进:版本管理、additive 变更、migration 策略 |
| [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) | 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 共享状态库主模块 | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
| 共享库契约 | [src/state/openclaw-state-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-contract.ts) |
| Per-Agent 状态库主模块 | [src/state/openclaw-agent-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.ts) |
| Per-Agent 库契约 | [src/state/openclaw-agent-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-contract.ts) |
| Schema 版本解析 | [src/state/openclaw-schema-versions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-schema-versions.ts) |
| Agent 库注册表 | [src/state/openclaw-agent-db-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-registry.ts) |
| Agent 库租约 | [src/state/openclaw-agent-db-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-lease.ts) |
| 共享库维护 | [src/state/openclaw-state-db-maintenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-maintenance.ts) |
| 完整性校验 | [src/state/openclaw-database-verify.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-verify.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" / "Storage" 段 |
