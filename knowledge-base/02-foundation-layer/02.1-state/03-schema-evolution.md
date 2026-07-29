# 03 — Schema 演进

> 读完本章你将理解:OpenClaw 如何管理双层库的 schema 版本、additive 变更与 bump 的区别、迁移策略如何保证升级路径稳定。

## 一句话定位

Schema 演进是状态层的"版本契约":
- 共享库与 Agent 库各自独立的版本号(user_version)
- 22 代历史版本管理(共享库 v1-v6,Agent 库 v1-v16,合计 22 代)
- 严格区分"additive 变更"与"version bump",前者不 bump,后者需用户显式确认

## 全局协作图

下图展示 Schema 演进体系与各组件的协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          演进触发源                                   │
│                                                                      │
│   新功能开发       Doctor 修复       版本发布       用户审批          │
│   (加表/列)        (修旧 shape)     (bump 版本)    (确认 bump)       │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 决策:additive 还是 bump?
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Schema 演进决策面                               │
│                                                                      │
│   ┌────────────────────────┐    ┌────────────────────────────┐      │
│   │  Additive 路径          │    │  Version Bump 路径         │      │
│   │  (老版本可容忍)         │    │  (老版本不可容忍)          │      │
│   │                         │    │                            │      │
│   │  • 新表 / 新列          │    │  • 删列 / 改列类型         │      │
│   │  • 默认值兼容           │    │  • 改主键 / 改约束         │      │
│   │  • 老版本 graceful      │    │  • 老版本 fail closed      │      │
│   │    degrade              │    │                            │      │
│   └───────────┬────────────┘    └─────────────┬──────────────┘      │
│               │                                │                      │
│               │ 不 bump 版本                   │ bump 版本            │
│               ▼                                ▼                      │
│   ┌────────────────────────┐    ┌────────────────────────────┐      │
│   │  Canonical Schema 声明 │    │  用户显式确认              │      │
│   │  + lazy additive 清单  │    │  + 文档更新                │      │
│   │  + 一次性 lazy ensure  │    │  + 迁移代码                │      │
│   └───────────┬────────────┘    └─────────────┬──────────────┘      │
│               │                                │                      │
│               └────────────────┬───────────────┘                      │
│                                ▼                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  Schema 版本管理器                                         │    │
│   │                                                            │    │
│   │  • 共享库 user_version(当前 v6)                          │    │
│   │  • Agent 库 user_version(当前 v16)                       │    │
│   │  • 严格版本断言(超出 → fail closed)                     │    │
│   │  • 标记版本(markCurrent)                                │    │
│   └────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       运行时与 Doctor 协作                            │
│                                                                      │
│   ┌──────────────────┐                ┌──────────────────────────┐  │
│   │  运行时           │                │  Doctor                  │  │
│   │  • 只读 canonical │◄────迁移后─────│  • 检测旧 shape          │  │
│   │  • 无 fallback    │                │  • 在事务内改写          │  │
│   │  • 无 shim        │                │  • 标记 canonical 版本   │  │
│   └──────────────────┘                └──────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

Schema 演进由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Schema 版本管理器** | 维护 user_version、严格版本断言、新版本错误 | 当前版本超出支持 → fail closed,带文档 URL |
| **Canonical Schema 声明** | canonical SQL 文件,定义当前 shape 应有的表/列 | 单一权威,运行时与 Doctor 共同引用 |
| **Lazy Additive 清单** | 列出"加表但未 bump"的表名,允许老版本缺失 | 下次自然 bump 时合并入 canonical |
| **Schema Helpers** | 探测表存在 / 列存在 / 主键列;供迁移用 | 迁移代码先探测再改,避免重复 DDL |
| **迁移模块群** | operator-approval / restart-handoff / audit / session-watch / strict | 每个 migration 自检 + 在事务内改写 + 标记版本 |
| **Schema 修复器** | 删旧表、断言 canonical shape、修复合主键 | Doctor-only,运行时不调用 |

## 关联关系

### 双层库的版本独立性

```
   ┌─────────────────────────────────────────────────────────┐
   │  共享库 schema 演进                                     │
   │                                                         │
   │  v1 ──► v2 ──► v3 ──► v4 ──► v5 ──► v6 (当前)          │
   │                                                 │       │
   │                                                 │       │
   │   严格版本 v3 (STRICT_SCHEMA_VERSION)          │       │
   │   ↑ 所有表必须 STRICT,否则 Doctor 修复         │       │
   │                                                 │       │
   │   lazy additive tables:                         │       │
   │   • model_catalog_remote                        │       │
   │   • sidebar_sections                            │       │
   │   (未 bump,等下次自然 bump 合并)              │       │
   └─────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────┐
   │  Agent 库 schema 演进(独立)                          │
   │                                                         │
   │  v1 ──► v2 ──► ... ──► v15 ──► v16 (当前)              │
   │                                            │            │
   │                                            │            │
   │  v9: SQLite STRICT tables                              │
   │  v10: materialized active transcript paths             │
   │  v11: agent-scoped leases + durable delivery           │
   │  v12: session-owned ACP parent-stream events           │
   │  v13: one durable rewrite watermark per transcript     │
   │  v14: logical session nodes + generation windows       │
   │  v15: board + session-sharing tables canonical         │
   │  v16: retire legacy Media* transcript fields           │
   │      (downgrade guard only,Doctor owns data rewrite)   │
   └─────────────────────────────────────────────────────────┘

   关键不变量:
   • 共享库与 Agent 库版本独立
   • 不同 Agent 库可有不同版本
   • 新版本工具拒绝读超出支持的库(fail closed)
```

### additive 与 bump 的决策路径

```
   要加一个新表 / 新列
         │
         ▼
   ┌─────────────────────────────────────┐
   │  决策:additive 还是 bump?         │
   │                                     │
   │  老版本能否容忍?                   │
   │  • 是 → additive                    │
   │  • 否 → bump                        │
   └─────────────┬───────────────────────┘
                 │
       ┌─────────┴─────────┐
       │                   │
       ▼ additive           ▼ bump
   ┌──────────────┐    ┌──────────────────────┐
   │ 1. 加表到    │    │ 1. 用户显式确认      │
   │    canonical │    │ 2. 更新 canonical    │
   │    schema SQL│    │    schema SQL        │
   │ 2. 加入 lazy │    │ 3. 写迁移代码        │
   │    additive  │    │    (Doctor 调用)     │
   │    清单      │    │ 4. bump user_version │
   │ 3. 一次性    │    │ 5. 更新文档          │
   │    lazy      │    │ 6. 升级测试          │
   │    ensure    │    │                      │
   │ 4. 不 bump   │    │                      │
   │    user_ver  │    │                      │
   └──────────────┘    └──────────────────────┘
```

### 正确设计 vs 错误设计

```
错误设计(运行时兼容旧 shape):
   运行时 ──► 读 audit_events
            ──► if (旧列存在) { 走旧路径 } else { 走新路径 }
            ──► 累积 shims → 难维护
            ──► 测试覆盖两种路径

正确设计(Doctor 迁移 + 运行时只读 canonical):
   Doctor 迁移 ──► 把旧 audit_events 改成 canonical shape
                       │
                       ▼
   运行时 ──► 只读 canonical shape,无分支
   → 运行时代码简洁
   → 测试只覆盖 canonical
   → 旧 shape 是迁移债务,不是运行时债务
```

## 协作流程

### 一次 additive 加表的旅程

下面追踪一次"新增 model_catalog_remote 表"的全过程。

```
开发者要加一个新表 model_catalog_remote(模型目录远程缓存)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 决策:additive 还是 bump                                   │
│    → 老版本看不到这表只是少一个功能,不影响其他读写           │
│    → 老版本可容忍 → additive                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 更新 canonical schema SQL                                 │
│    → 在共享库 canonical schema SQL 加 CREATE TABLE 语句       │
│    → 这是"应有 shape"的单一权威                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 加入 lazy additive 清单                                   │
│    → 表名加入 lazy additive tables 清单                      │
│    → 维护断言器允许该表缺失                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 一次性 lazy ensure                                       │
│    → 运行时第一次用到该表时,在写事务内 CREATE TABLE IF NOT  │
│    → 标记 schema_meta 表(若有)记录此次加表                  │
│    → 后续访问直接读,无 ensure 开销                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 不 bump user_version                                     │
│    → user_version 保持当前值                                │
│    → 老版本工具仍能打开库(只是看不到新表)                  │
│    → 下次自然 bump 时,该表合并入 canonical shape            │
└──────────────────────────────────────────────────────────────┘
```

### 一次 version bump 的旅程

下面追踪一次"Agent 库 v15 → v16"的发布全过程。

```
开发者要把 Agent 库从 v15 升到 v16(退役 legacy Media* 字段)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 用户显式确认                                              │
│    → 与用户讨论:bump 影响、升级路径、是否真有必要           │
│    → 用户同意后才继续                                        │
│    → Agent 不能自主推进 schema 版本                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 更新 canonical schema SQL                                 │
│    → 在 Agent 库 canonical schema SQL 中移除 legacy 字段     │
│    → 这是新的 canonical shape                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 写 Doctor 迁移代码                                        │
│    → 迁移代码检测旧 shape(legacy 字段存在)                 │
│    → 在事务内重写数据(把 legacy 字段数据迁移到新位置)     │
│    → 删除 legacy 字段                                        │
│    → 断言 canonical shape                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. bump user_version                                        │
│    → Agent 库契约常量从 15 改为 16                           │
│    → 严格版本断言:旧版本工具拒绝读 v16 库                   │
│    → 错误信息带文档 URL                                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 更新文档                                                  │
│    → 更新数据库 schema 文档                                  │
│    → 记录 v16 的变更说明(退役 legacy 字段)                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 升级测试                                                  │
│    → 测试 Doctor 从 v15 库迁移到 v16                         │
│    → 测试新版本工具能读 v16 库                               │
│    → 测试老版本工具拒绝读 v16 库(fail closed)              │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. bump 需用户显式确认

- **为什么**:bump 意味着老版本工具无法读新库,影响所有用户的升级路径;Agent 自主推进会破坏升级契约
- **怎么做**:Agent 不能自主 bump;必须与用户讨论后由用户确认;bump 时同步更新文档与迁移代码
- **影响**:升级路径稳定可预测;用户对版本变更知情同意

### 2. additive 不 bump

- **为什么**:加表/加列对老版本是 graceful degrade(看不到新表只是少功能,不影响其他读写);bump 应保留给"老版本无法容忍"的变更
- **怎么做**:新表/新列加到 canonical schema SQL + 加入 lazy additive 清单 + 一次性 lazy ensure;不 bump user_version
- **影响**:小步演进不需要用户确认;升级路径平滑;下次自然 bump 时合并

### 3. 严格版本断言 fail closed

- **为什么**:运行时若接受超出当前版本的库,会读到未知 shape 导致数据损坏;静默忽略比报错更危险
- **怎么做**:维护断言器读 user_version;超出当前版本 → 报错 + 文档 URL;不尝试"尽力读"
- **影响**:升级时新版本工具明确拒绝老库;Doctor 负责把老库升到 canonical

### 4. 迁移代码用 Schema Helpers 探测

- **为什么**:迁移代码需要在"已知 shape"和"未知 shape"之间判断;直接 SELECT 可能因表不存在而抛错
- **怎么做**:用 Helpers 探测表存在/列存在/主键列;探测结果决定迁移路径;探测本身不抛错
- **影响**:迁移代码可处理多种历史 shape;不依赖 try/catch 区分

### 5. 迁移在事务内执行 + 标记版本

- **为什么**:迁移与版本标记必须原子;若迁移成功但版本未标记,下次启动会重复迁移
- **怎么做**:在 BEGIN IMMEDIATE 内执行迁移 + 标记 user_version;同步 commit;失败 ROLLBACK 不标记
- **影响**:迁移是幂等的;失败后可重试

### 6. canonical schema SQL 是单一权威

- **为什么**:多处定义"应有的 shape"会分歧;运行时与 Doctor 必须看到同一份 canonical
- **怎么做**:canonical schema SQL 文件是单一权威;运行时用它初始化新库;Doctor 用它断言 canonical shape
- **影响**:新增 shape 只改一处;运行时与 Doctor 一致

## 设计观察

### 为什么区分 additive 与 bump

```
错误设计(所有变更都 bump):
   加一个新表 ──► bump user_version
   → 老版本工具无法读新库
   → 用户被迫升级
   → 升级路径僵化

正确设计(区分):
   加表(老版本可容忍)─ additive,不 bump
   改列类型(老版本不可容忍)─ bump,需用户确认
   → 小步演进平滑
   → 真正破坏性变更才 bump
   → 用户对破坏性变更知情同意
```

### 为什么迁移代码用 Helpers 而非 try/catch

```
错误设计(try/catch 探测):
   try { SELECT old_column FROM table } catch { /* 列不存在,迁移 */ }
   → 错误处理混入业务逻辑
   → 不同 SQLite 错误难区分(列不存在 vs 表不存在 vs 锁)
   → 难审计

正确设计(Helpers 探测):
   if (!tableHasColumn(db, "table", "old_column")) {
     ALTER TABLE ... ADD COLUMN old_column ...
   }
   → 探测与改写分离
   → 探测本身不抛错
   → 迁移路径明确可审计
```

### 为什么 strict 版本独立于主版本

```
   共享库主版本:    v1 ──► v2 ──► v3 ──► v4 ──► v5 ──► v6
   共享库 strict 版本:                  v3 (固定)

   设计目的:
   • 主版本跟踪 schema 演进(加表/列/约束)
   • strict 版本跟踪"所有表必须 STRICT"的硬约束
   • 主版本 ≥ strict 版本的所有表必须是 STRICT
   • Doctor 修复器把非 STRICT 表改成 STRICT

   为什么不合并:
   • 主版本 bump 频繁(每次破坏性变更)
   • strict 版本只 bump 一次(STRICT 化完成后固定)
   • 独立追踪避免混淆
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) | 总览:SQLite 双层结构 + 状态层组件全景 |
| [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) | 共享状态库:契约、schema-helpers、permissions、readonly |
| [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) | Per-Agent 状态库:契约、lease、registry |
| [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) | 本文件 — Schema 演进 |
| [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) | 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Schema 版本解析 | [src/state/openclaw-schema-versions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-schema-versions.ts) |
| 共享库契约(版本常量) | [src/state/openclaw-state-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-contract.ts) |
| Per-Agent 库契约(版本常量) | [src/state/openclaw-agent-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-contract.ts) |
| 共享库 Schema Helpers | [src/state/openclaw-state-db-schema-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-helpers.ts) |
| 共享库 Additive Schema | [src/state/openclaw-state-db-schema-additive.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-additive.ts) |
| 共享库 Schema 修复 | [src/state/openclaw-state-db-schema-repair.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-repair.ts) |
| Per-Agent 库 Schema Helpers | [src/state/openclaw-agent-db-schema-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-schema-helpers.ts) |
| Per-Agent 库 Schema 管理 | [src/state/openclaw-agent-db-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-schema.ts) |
| 共享库 canonical schema SQL | [src/state/openclaw-state-schema.sql](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-schema.sql) |
| Per-Agent canonical schema SQL | [src/state/openclaw-agent-schema.sql](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-schema.sql) |
| Operator-Approval 迁移 | [src/state/openclaw-state-db-operator-approval-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-operator-approval-migration.ts) |
| Session-Watch 迁移 | [src/state/openclaw-state-db-session-watch-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-session-watch-migration.ts) |
| Audit 迁移 | [src/state/openclaw-state-db-audit-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-audit-migration.ts) |
| Per-Agent Session 迁移 | [src/state/openclaw-agent-db-session-migrations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-session-migrations.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Storage" / "SQLite" 段 |
