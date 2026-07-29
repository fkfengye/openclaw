# 01 — 共享状态库

> 读完本章你将理解:共享状态库承担什么职责、它的契约由哪些组件协作完成、为什么所有全局状态都汇聚到这里。

## 一句话定位

共享状态库是 OpenClaw 的"全局真相源":
- 单文件 SQLite,所有 Agent 共享
- 存全局运行时状态、插件 KV、Agent 注册表、跨 Agent 租约
- 是 Agent 库的"目录页",维护路径与版本索引

## 全局协作图

下图展示共享状态库与各组件的协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          上层调用方                                   │
│                                                                      │
│   Gateway 启动    Agent Runner    插件系统     Doctor / CLI         │
│   (初始化库)      (读注册表)      (KV 读写)   (维护/迁移)          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 通过共享库契约访问
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          共享库契约面                                │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│   │  打开 / 只读 │  │  写事务      │  │  维护断言 / 迁移       │   │
│   │  句柄         │  │  管理器      │  │  入口                  │   │
│   └──────┬───────┘  └──────┬───────┘  └───────────┬────────────┘   │
└──────────┼─────────────────┼──────────────────────┼────────────────┘
           │                 │                      │
           ▼                 ▼                      ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          共享库内核                                   │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│   │  Schema      │  │  Permissions │  │  Schema Helpers        │   │
│   │  版本管理    │  │  权限硬化    │  │  (表/列探测)           │   │
│   └──────┬───────┘  └──────┬───────┘  └───────────┬────────────┘   │
│          │                 │                      │                 │
│          └─────────────────┼──────────────────────┘                 │
│                            │                                         │
│                            ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  SQLite 文件(WAL 模式)                                    │  │
│   │  路径:state/openclaw.sqlite                                │  │
│   └──────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          共享库内容                                  │
│                                                                      │
│   • 全局运行时状态(配置/绑定/调度)                                │
│   • 插件 KV 数据(每个插件命名空间)                               │
│   • agent_databases 注册表(Agent 库目录页)                        │
│   • agent_database_leases(跨 Agent 租约)                          │
│   • agent_deletion_journal(删除防篡改)                            │
│   • operator_approvals(运维审批)                                  │
│   • audit_events(审计日志)                                        │
│   • cron_jobs / commitments / diagnostic_events / ...              │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

共享库由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **共享库契约** | 定义 schema 版本、文档 URL、句柄类型、迁移类型 | 版本号是单一权威,所有上层引用此处的常量 |
| **打开 / 只读句柄** | 提供 db / path / WAL 维护的统一句柄;支持只读模式 | 只读模式用于诊断/备份,不影响主进程 |
| **写事务管理器** | 在 BEGIN IMMEDIATE 内执行同步回调 | 回调内禁止 await/Promise;先做异步规划再进事务 |
| **Schema 版本管理** | 维护 user_version、严格版本断言、新版本错误 | 当前版本超出支持 → fail closed 拒绝启动 |
| **权限硬化** | 0o700 目录 + 0o600 文件,失败时 best-effort 警告 | 不让 chmod 失败拖垮 Gateway(Azure Files/NFS/Docker) |
| **Schema Helpers** | 探测表存在 / 列存在 / 主键列;供迁移代码使用 | 迁移代码先探测再改,避免重复 DDL |

## 关联关系

### 共享库与 Agent 库的索引关系

```
   ┌─────────────────────────────────────────┐
   │  共享库                                 │
   │                                         │
   │  agent_databases 表                     │
   │  ┌───────────────────────────────────┐  │
   │  │ agentId | path | schema | lastSeen│  │
   │  ├─────────┼──────────┼───────┼───────┤  │
   │  │ agentA  | .../A.sqlite │ 16  │  ts  │  │
   │  │ agentB  | .../B.sqlite │ 16  │  ts  │  │
   │  │ agentC  | .../C.sqlite │ 15  │  ts  │  │
   │  └───────────────────────────────────┘  │
   └────────────────────┬────────────────────┘
                        │
                        │ 列出所有 Agent = 一次查询
                        │ 不需要扫盘 agents/ 目录
                        │
            ┌───────────┼───────────┐
            ▼           ▼           ▼
        ┌────────┐  ┌────────┐  ┌────────┐
        │ AgentA │  │ AgentB │  │ AgentC │
        │  库    │  │  库    │  │  库    │
        │ (v16)  │  │ (v16)  │  │ (v15)  │
        └────────┘  └────────┘  └────────┘

   注:Agent 库的 schema 版本可独立演进,
       共享库注册表只是"目录页",不强制版本一致
```

### 共享库与租约体系

```
   ┌─────────────────────────────────────────────┐
   │  共享库                                      │
   │                                             │
   │  agent_database_leases 表                   │
   │  ┌─────────────────────────────────────┐    │
   │  │ leaseId | agentId | path | pid | ts │    │
   │  └─────────────────────────────────────┘    │
   │                                             │
   │  agent_deletion_journal 表                  │
   │  ┌─────────────────────────────────────┐    │
   │  │ agentId | ...(防删除冲突)          │    │
   │  └─────────────────────────────────────┘    │
   └──────────────────┬──────────────────────────┘
                      │
                      │ 跨进程串行化信任工作
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ 进程 A   │  │ 进程 B   │  │ 进程 C   │
   │ 持有     │  │ 等待     │  │ 查询     │
   │ A 库租约 │  │ B 库租约 │  │ 谁持有?  │
   └──────────┘  └──────────┘  └──────────┘
```

### 正确设计 vs 错误设计

```
错误设计(运行时读旧 shape):
   运行时 ──► 读旧版 audit_events 列
            ──► 走 fallback 分支处理缺失列
            ──► 累积 shims → 难维护

正确设计(运行时只读 canonical):
   Doctor 迁移 ──► 把旧 audit_events 改成 canonical shape
                       │
                       ▼
   运行时 ──► 只读 canonical shape,无 fallback
```

## 协作流程

### 一次共享库写事务的完整旅程

下面追踪一次 Gateway 写入 operator_approval 的全过程。

```
Gateway 收到一个需要运维审批的操作
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 异步规划阶段(事务外)                                     │
│    由上层调用方                                                │
│    → 计算 approvalId / kind / payload                         │
│    → 检查环境变量 / 配置                                       │
│    → 完成所有异步 I/O / 文件访问 / Hook                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 进入写事务(BEGIN IMMEDIATE)                              │
│    由写事务管理器                                              │
│    → 获取独占写锁(同步,带 busy timeout)                     │
│    → 进入事务回调                                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 事务内:重新校验权威行                                     │
│    由写事务管理器                                              │
│    → 重新读 operator_approvals 表(防 TOCTOU)                 │
│    → 检查冲突(同 approvalId 是否已存在)                     │
│    → 检查 schema 版本仍支持                                   │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 事务内:执行写入(同步)                                   │
│    由 Kysely helpers                                           │
│    → INSERT 到 operator_approvals                              │
│    → 同步执行,无 await                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 同步 commit                                                │
│    由写事务管理器                                              │
│    → COMMIT(同步)                                            │
│    → 释放写锁                                                  │
│    → 失败则 ROLLBACK 并抛出                                   │
└──────────────────────────────────────────────────────────────┘
```

### 一次只读诊断的旅程

```
运维人员想诊断共享库状态
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 只读打开                                                   │
│    由只读句柄管理器                                            │
│    → 准备只读 SQLite 路径(可能复制到临时位置)               │
│    → 以只读模式打开                                            │
│    → 不影响主进程的写句柄                                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Schema 版本断言                                            │
│    由 Schema 版本管理                                          │
│    → 读 user_version                                          │
│    → 若版本超出支持 → 报错(避免老工具读坏新库)              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 只读查询                                                   │
│    由上层调用方                                                │
│    → SELECT 不需要事务                                        │
│    → 不修改任何状态                                            │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 版本号是单一权威

- **为什么**:版本号散落多处会导致判断不一致;运行时与 Doctor 必须看到同一版本
- **怎么做**:版本常量只在契约文件定义一次;所有上层引用此处的常量;`user_version` 是文件级真相
- **影响**:升级版本只需改一处;新版本工具拒绝读老版本库时,错误信息一致

### 2. 写事务回调必须同步

- **为什么**:事务回调内 `await`/Promise 会让事务边界与锁持有时间失控
- **怎么做**:回调内只做同步读 + 校验 + 写 + commit;所有异步工作在 `BEGIN` 之前完成
- **影响**:事务持锁时间短;并发性能可预测

### 3. 事务内必须重读权威行

- **为什么**:从规划到 `BEGIN` 之间,其他进程可能已修改数据(TOCTOU)
- **怎么做**:进入事务后重新读取并校验关键行,再决定是否写入
- **影响**:防止重复审批、重复 lease、覆盖他人修改

### 4. 权限硬化是 best-effort

- **为什么**:某些文件系统(Azure Files/NFS/Docker volume)无法 chmod;若硬性要求会让 Gateway 无法启动
- **怎么做**:目录 0o700 / 文件 0o600;失败时每个路径警告一次,继续运行;但凭据相关硬化失败仍抛出
- **影响**:大多数系统有强权限;少数系统降级运行但不阻塞

### 5. 维护断言 fail closed

- **为什么**:运行时若接受超出当前版本的库,会读到未知 shape 导致数据损坏
- **怎么做**:维护断言器检查 user_version,超出当前版本 → 报错并指向文档 URL;路径解析失败 → 报错
- **影响**:升级时新版本工具明确拒绝老库;Doctor 负责把老库升到 canonical

### 6. Additive 加表不 bump 版本

- **为什么**:加表对老版本是 graceful degrade(老版本只是看不到新表);bump 应保留给"老版本无法容忍"的变更
- **怎么做**:新表在 canonical schema SQL 声明 + 列入"lazy additive tables"清单 + 一次性 lazy ensure;下次自然 bump 时合并
- **影响**:小步演进不需要用户显式确认;升级路径平滑

## 设计观察

### 为什么权限硬化要 best-effort

```
错误设计(硬性要求 chmod):
   启动时 chmod 失败 ──► 抛错 ──► Gateway 不启动
   → Azure Files / NFS / Docker volume 用户无法使用
   → 真实凭据安全风险反而更高(用户关掉硬化)

正确设计(best-effort):
   chmod 失败 ──► 警告一次 ──► 继续运行
   → 大多数系统获得强权限
   → 少数系统降级但可用
   → 凭据相关硬化失败仍抛出(不会静默)
```

### 为什么 Schema Helpers 只供迁移代码用

```
错误设计(运行时用 Helpers 探测列):
   运行时 ──► if (tableHasColumn(...)) { 走新路径 } else { 走旧路径 }
   → 累积 fallback 栈
   → 测试需要覆盖两种路径
   → 难维护

正确设计(迁移代码用 Helpers):
   Doctor 迁移 ──► if (!tableHasColumn(...)) { ALTER TABLE 加列 }
                       │
                       ▼
   运行时 ──► 假设列存在,直接读
   → 运行时无分支
   → 测试只需覆盖 canonical shape
```

### 为什么当前版本超出支持要 fail closed

```
错误设计(允许读):
   老版本工具 ──► 读新版本库 ──► 看到未知表/列 ──► 静默忽略
   → 数据被错误解释
   → 诊断困难

正确设计(fail closed):
   老版本工具 ──► 读新版本库 ──► 报错 + 文档 URL
   → 用户知道需要升级工具
   → 数据不会被错误解释
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) | 总览:SQLite 双层结构 + 状态层组件全景 |
| [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) | 本文件 — 共享状态库 |
| [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) | Per-Agent 状态库:契约、lease、registry |
| [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) | Schema 演进:版本管理、additive 变更、migration 策略 |
| [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) | 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 共享状态库主模块 | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
| 共享库契约 | [src/state/openclaw-state-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-contract.ts) |
| 共享库只读句柄 | [src/state/openclaw-state-db-readonly.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-readonly.ts) |
| 共享库权限硬化 | [src/state/openclaw-state-db-permissions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-permissions.ts) |
| 共享库 Schema Helpers | [src/state/openclaw-state-db-schema-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-helpers.ts) |
| 共享库 Additive Schema | [src/state/openclaw-state-db-schema-additive.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-additive.ts) |
| 共享库 Schema 修复 | [src/state/openclaw-state-db-schema-repair.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-repair.ts) |
| 共享库维护断言 | [src/state/openclaw-state-db-maintenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-maintenance.ts) |
| 共享库路径解析 | [src/state/openclaw-state-db.paths.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.paths.ts) |
| 共享库 canonical schema SQL | [src/state/openclaw-state-schema.sql](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-schema.sql) |
| 启动迁移 checkpoint | [src/state/openclaw-state-db-startup-checkpoint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-startup-checkpoint.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Storage" 段 |
