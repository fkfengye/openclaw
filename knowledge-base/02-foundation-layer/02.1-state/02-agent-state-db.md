# 02 — Per-Agent 状态库

> 读完本章你将理解:每个 Agent 为什么有独立 SQLite 库、它的契约如何与共享库协作、lease 与 registry 如何防止并发冲突。

## 一句话定位

Per-Agent 状态库是单个 Agent 的"私人记忆":
- 一个 Agent 一个 SQLite 文件,路径 `agents/<agentId>/agent/openclaw-agent.sqlite`
- 存该 Agent 的会话历史、运行记录、缓存、Agent 范围租约
- 通过 lease + registry 与共享库协作,保证跨进程串行化

## 全局协作图

下图展示 Per-Agent 库与共享库、上层调用方的协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          上层调用方                                   │
│                                                                      │
│   Agent Runner     Doctor / CLI     Control UI     插件系统         │
│   (会话读写)       (维护/迁移)      (列出 Agent)   (Agent KV)       │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 通过 Per-Agent 库契约访问
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Per-Agent 库契约面                             │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│   │  打开 / lease │  │  写事务      │  │  注册 / 注销           │   │
│   │  一体化       │  │  管理器      │  │  管理器                │   │
│   └──────┬───────┘  └──────┬───────┘  └───────────┬────────────┘   │
└──────────┼─────────────────┼──────────────────────┼────────────────┘
           │                 │                      │
           ▼                 ▼                      ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Per-Agent 库内核                                │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│   │  Schema      │  │  Permissions │  │  Schema Helpers        │   │
│   │  版本管理    │  │  权限硬化    │  │  (owner / 版本探测)    │   │
│   └──────┬───────┘  └──────┬───────┘  └───────────┬────────────┘   │
│          │                 │                      │                 │
│          └─────────────────┼──────────────────────┘                 │
│                            │                                         │
│                            ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  SQLite 文件(WAL 模式)                                    │  │
│   │  路径:agents/<agentId>/agent/openclaw-agent.sqlite          │  │
│   └──────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
         │                                              │
         │ lease 协作                                   │ registry 协作
         ▼                                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       共享库(目录页)                                │
│                                                                      │
│   • agent_database_leases 表(谁持有哪个 Agent 库)                  │
│   • agent_deletion_journal 表(防删除冲突)                          │
│   • agent_databases 注册表(所有 Agent 库的目录索引)                │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

Per-Agent 库由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Per-Agent 库契约** | 定义 schema 版本、句柄类型、注册表行类型、owner 检视类型 | 一个 Agent 一个 schema 版本;独立于共享库演进 |
| **打开 + lease 一体化** | 获取 lease 后才打开库;释放 lease 时关闭 | 防止未持 lease 的进程读写 Agent 库 |
| **写事务管理器** | 在 BEGIN IMMEDIATE 内执行同步回调 | 与共享库同规则:回调内禁止 await/Promise |
| **注册表管理器** | 在共享库登记/注销 Agent 库;支持列出所有 Agent | 注册时用 realpath + device/inode 防符号链接陷阱 |
| **Schema Helpers** | 探测 owner、版本、media persistence 版本 | 迁移代码先探测再改 |
| **权限硬化** | 0o700 目录 + 0o600 文件 | 与共享库同规则:best-effort,凭据相关失败仍抛出 |

## 关联关系

### Agent 库与共享库的双向协作

```
   ┌─────────────────────────────────────────────────────────┐
   │  共享库(全局真相源)                                   │
   │                                                         │
   │  ┌─────────────────────┐  ┌─────────────────────────┐  │
   │  │ agent_databases     │  │ agent_database_leases   │  │
   │  │ (Agent 库目录页)    │  │ (谁持有哪个 Agent 库)   │  │
   │  └──────────┬──────────┘  └────────────┬────────────┘  │
   │             │                          │                │
   │             │     ┌────────────────────┘                │
   │             │     │                                      │
   └─────────────┼─────┼──────────────────────────────────────┘
                 │     │
                 │     │ lease claim / release
                 │     │
                 │     ▼
   ┌─────────────┼──────────────────────────────────────────┐
   │             │     Per-Agent 库                          │
   │             │                                            │
   │  registry ──┘                                            │
   │  (登记/注销/列表)                                        │
   │                                                          │
   │  ┌──────────────────────────────────────────────────┐   │
   │  │  Agent 范围内容                                  │   │
   │  │  • 会话历史(transcripts / sessions)            │   │
   │  │  • 运行记录(run outcomes)                      │   │
   │  │  • 缓存(prompt cache / lookups)                │   │
   │  │  • Agent 范围租约(state_leases)                │   │
   │  │  • 会话节点 / artifact FK                       │   │
   │  └──────────────────────────────────────────────────┘   │
   └──────────────────────────────────────────────────────────┘

   关键不变量:
   • 持有 lease 才能写 Agent 库
   • 注册表行与 lease 行都在共享库
   • Agent 库 schema 版本独立演进
```

### lease 与 deletion journal 的防冲突协作

```
   场景:进程 A 持有 agentB 的 lease,同时 Doctor 想删除 agentB

   ┌──────────────────────────────────────────────────────────┐
   │  共享库                                                   │
   │                                                          │
   │  agent_database_leases         agent_deletion_journal    │
   │  ┌────────────────────┐        ┌─────────────────────┐   │
   │  │ leaseId | agentB | │        │ agentB | (pending)  │   │
   │  │ pid=A   | ...      │        │ ...                 │   │
   │  └────────────────────┘        └─────────────────────┘   │
   └──────────────────────────────────────────────────────────┘
                  ▲                              ▲
                  │                              │
   ┌──────────────┴──────────┐    ┌──────────────┴────────────┐
   │  进程 A                 │    │  Doctor                    │
   │  持有 agentB lease      │    │  想删除 agentB             │
   │                         │    │                             │
   │  释放 lease 时:         │    │  claim lease 时:           │
   │  → 检查 journal         │    │  → 检查 journal            │
   │  → 如有 pending 删除    │    │  → 若有 pending 删除       │
   │    → 拒绝重新 claim     │    │    → 拒绝 claim            │
   └─────────────────────────┘    └────────────────────────────┘

   设计目的:
   • 防止已删除 Agent 被重新 claim
   • 防止正在使用的 Agent 被删除
   • deletion journal 是"防篡改"的真相源
```

### 正确设计 vs 错误设计

```
错误设计(共享库存所有会话):
   共享库 ──► 存所有 Agent 的所有会话历史
   → 单库膨胀快
   → 一个 Agent 写入阻塞所有 Agent
   → 删除一个 Agent 需要全库扫描

正确设计(共享库只存目录):
   共享库 ──► 只存 agent_databases 注册表 + lease + deletion journal
       │
       └──► 每个 Agent 一个独立库
   → 共享库小而稳定
   → Agent 间写不互相阻塞
   → 删除 Agent = 删一个文件 + 注销一行
```

## 协作流程

### 一次打开 Agent 库的完整旅程

下面追踪 Agent Runner 第一次需要某个 Agent 的库时的全过程。

```
Agent Runner 收到针对 agentB 的请求,需要打开 agentB 的库
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 路径解析                                                   │
│    由 Per-Agent 库路径解析器                                   │
│    → 规范化 agentId                                           │
│    → 解析出 agents/<agentB>/agent/openclaw-agent.sqlite       │
│    → 判断是否为 incognito(隐身)模式路径                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. lease claim                                               │
│    由 Agent 库 lease 管理器                                    │
│    → 在共享库写事务内:                                        │
│      ① 检查 agent_deletion_journal(agentB 是否 pending 删除)│
│      ② 检查 path fence(路径是否已被删除)                    │
│      ③ INSERT 到 agent_database_leases                        │
│         (leaseId / agentB / path / pid / start_time / now)    │
│    → 返回 leaseId                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 打开 SQLite 文件                                          │
│    由 Per-Agent 库 opener                                      │
│    → 配置 WAL pragma / busy timeout                           │
│    → 权限硬化(0o700 目录 / 0o600 文件)                       │
│    → 完整性断言(文件未损坏)                                  │
│    → Schema 版本断言(不能比当前版本更新)                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Schema ensure(若需要)                                    │
│    由 Agent 库 Schema 管理器                                   │
│    → 若文件是新建:执行 canonical schema SQL                   │
│    → 若文件已存在:断言 canonical shape,加 lazy additive 表  │
│    → 标记 user_version 到当前版本                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 注册到共享库                                              │
│    由注册表管理器                                              │
│    → 在共享库写事务内:                                        │
│      ① realpath + device/inode 防符号链接陷阱                 │
│      ② UPSERT 到 agent_databases                              │
│         (agentB / path / schemaVersion / lastSeenAt / size)   │
│    → 让"列出所有 Agent"无需扫盘                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 返回句柄给上层                                            │
│    → Agent Runner 拿到 { agentId, db, path, walMaintenance } │
│    → 可开始读写                                               │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Agent 库写事务的旅程

```
Agent Runner 要写入新的会话历史行
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 异步规划(事务外)                                         │
│    → 准备 transcript 行 / session 行                          │
│    → 完成所有异步 I/O                                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 进入 Agent 库写事务                                       │
│    → BEGIN IMMEDIATE                                          │
│    → 持有 lease 才能进(上层已在打开时 claim)                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 事务内:重读 + 校验                                       │
│    → 重读 session 行(防 TOCTOU)                              │
│    → 校验 media persistence 版本                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 事务内:写入(同步)                                       │
│    → INSERT 到 transcripts / sessions                         │
│    → 同步,无 await                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 同步 commit                                                │
│    → COMMIT                                                   │
│    → 释放写锁                                                  │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. lease 是写 Agent 库的前提

- **为什么**:多个进程同时写同一个 Agent 库会导致 SQLite 锁竞争 + 数据覆盖
- **怎么做**:打开 Agent 库前先在共享库 claim lease;lease 记录 pid + start_time,可检测进程死亡;释放时删除 lease 行
- **影响**:同一时刻只有一个进程能写 Agent 库;其他进程需要等待或失败

### 2. lease 必须配合 deletion journal

- **为什么**:仅靠 lease 不能防止"已删除 Agent 被重新 claim"——lease 可能过期或进程死亡
- **怎么做**:claim lease 时检查 deletion journal;删除 Agent 时先写 journal 再尝试 claim;两者在共享库写事务内原子完成
- **影响**:删除 Agent 是防篡改的;不会被并发 claim 抢救回来

### 3. 注册表用 realpath + device/inode

- **为什么**:agents/ 目录可能有符号链接、相对路径、跨文件系统挂载;只用 lexical path 会被符号链接欺骗
- **怎么做**:注册时解析 realpath + 记录 device/inode;列出时按真实路径去重;探测符号链接陷阱
- **影响**:同一个 Agent 库不会被注册两次;符号链接不会让 Agent "消失"

### 4. Agent 库 schema 版本独立演进

- **为什么**:不同 Agent 可能由不同版本的工具创建/使用;强制版本一致会让升级路径僵化
- **怎么做**:每个 Agent 库有自己的 user_version;共享库注册表记录每个 Agent 的版本;新版本工具拒绝读超出支持的库
- **影响**:可渐进升级;老 Agent 库可被新工具维护(若版本兼容)

### 5. incognito 模式独立路径

- **为什么**:incognito 会话不应污染主 Agent 库;但仍需要 SQLite 一致性保证
- **怎么做**:incognito 路径与主路径分离;路径解析器区分两种模式;incognito 库的生命周期独立
- **影响**:incognito 不会影响主 Agent 的会话历史;关闭后可独立清理

### 6. lease 失败必须 fail closed

- **为什么**:lease 是并发安全的基石;若失败时静默继续,会导致数据竞争
- **怎么做**:lease claim 失败 → 抛错,不开库;lease 丢失(被他人抢走)→ 抛错,停止写;lease 存储失败 → 抛错
- **影响**:调用方必须处理 lease 失败;不能假设"拿到 lease 一定成功"

## 设计观察

### 为什么 lease 写共享库而非 Agent 库

```
错误设计(lease 写 Agent 库):
   要 claim agentB ──► 打开 agentB.sqlite ──► 写 lease 行
   → 打开库本身就需要锁,与 lease 串行化目标冲突
   → 进程崩溃后 lease 行残留,难诊断
   → 跨进程可见性差

正确设计(lease 写共享库):
   要 claim agentB ──► 在共享库写 lease 行 ──► 才能打开 agentB.sqlite
   → lease 与库文件解耦
   → 共享库是"目录页",天然可查询
   → lease 记录 pid + start_time,可检测进程死亡
   → 配合 deletion journal 防篡改
```

### 为什么注册表用 device/inode 而非路径

```
错误设计(只用 lexical path):
   agents/agentB/agent/openclaw-agent.sqlite
   agents/agentB -> /mnt/remote/agents/agentB  (符号链接)
   → 同一个库被注册两次
   → 列出时显示两个 agentB

正确设计(realpath + device/inode):
   注册时:
     realpath(...) → /mnt/remote/agents/agentB/agent/openclaw-agent.sqlite
     stat(...) → device=12345, inode=67890
   → 即使路径不同,device+inode 相同 → 识别为同一个库
   → 去重后只显示一个 agentB
```

### 为什么 Agent 库 schema 独立于共享库

```
错误设计(强制版本一致):
   共享库 v6 + 所有 Agent 库必须 v16
   → 升级共享库需要同时升级所有 Agent 库
   → 老 Agent 库无法被新工具读取
   → 升级路径僵化

正确设计(独立演进):
   共享库 v6,Agent 库 v15/v16 混合
   → 共享库注册表记录每个 Agent 的版本
   → 新工具按 Agent 库自身版本处理
   → 可渐进升级,老 Agent 库不被强制迁移
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) | 总览:SQLite 双层结构 + 状态层组件全景 |
| [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) | 共享状态库:契约、schema-helpers、permissions、readonly |
| [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) | 本文件 — Per-Agent 状态库 |
| [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) | Schema 演进:版本管理、additive 变更、migration 策略 |
| [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) | 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Per-Agent 状态库主模块 | [src/state/openclaw-agent-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.ts) |
| Per-Agent 库契约 | [src/state/openclaw-agent-db-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-contract.ts) |
| Per-Agent 库 lease | [src/state/openclaw-agent-db-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-lease.ts) |
| Per-Agent 库注册表 | [src/state/openclaw-agent-db-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-registry.ts) |
| Per-Agent 库注册表列表 | [src/state/openclaw-agent-db-registry-listing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-registry-listing.ts) |
| Per-Agent 库权限硬化 | [src/state/openclaw-agent-db-permissions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-permissions.ts) |
| Per-Agent 库 Schema Helpers | [src/state/openclaw-agent-db-schema-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-schema-helpers.ts) |
| Per-Agent 库 Schema 管理 | [src/state/openclaw-agent-db-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-schema.ts) |
| Per-Agent 库路径解析 | [src/state/openclaw-agent-db.paths.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db.paths.ts) |
| Per-Agent 库维护 | [src/state/openclaw-agent-db-maintenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-maintenance.ts) |
| Per-Agent 库只读 | [src/state/openclaw-agent-db-readonly.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-readonly.ts) |
| Agent 删除 journal | [src/state/agent-deletion-journal.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/agent-deletion-journal.ts) |
| Per-Agent canonical schema SQL | [src/state/openclaw-agent-schema.sql](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-schema.sql) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Storage" 段 |
