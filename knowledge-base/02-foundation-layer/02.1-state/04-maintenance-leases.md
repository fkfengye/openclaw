# 04 — 维护与租约

> 读完本章你将理解:OpenClaw 如何保证双层库的完整性、租约如何串行化跨进程工作、Doctor 如何修复历史 shape、Gateway 重启时如何平滑交接。

## 一句话定位

维护与租约是状态层的"可靠性支柱":
- 租约(lease)串行化跨进程信任工作,防并发覆盖
- 完整性校验(verify)定期巡检双层库,损坏即隔离
- Doctor 迁移面修复历史 shape:operator-approval / restart-handoff / audit / session-watch
- Gateway 重启时通过 restart-handoff 平滑交接未完成工作

## 全局协作图

下图展示维护与租约体系与各组件的协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          触发源                                       │
│                                                                      │
│   Gateway 启动      Doctor 命令     定时巡检      进程崩溃恢复       │
│   (restart-handoff) (用户主动修复)  (verify)      (lease 检测)       │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 触发维护或租约操作
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       租约体系(Lease)                               │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │  共享库租约      │  │  Agent 库租约    │  │  通用 Lease      │ │
│   │                  │  │                  │  │                  │ │
│   │  • scope=shared  │  │  • claim Agent   │  │  • 任意 scope+key│ │
│   │  • 任意 scope+key│  │    库前 claim    │  │  • 跨库支持      │ │
│   │  • 写共享库串行  │  │  • 配合 deletion │  │  • 带超时/退避   │ │
│   │                  │  │    journal       │  │                  │ │
│   └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘ │
│            │                     │                      │           │
│            └─────────────────────┼──────────────────────┘           │
│                                  │                                   │
│                                  ▼                                   │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  Lease 上下文(所有权断言)                                 │  │
│   │  • 持有者随时断言自己仍持有 lease                          │  │
│   │  • 事务内断言(防 TOCTOU)                                  │  │
│   │  • lease 丢失 → fail closed                                │  │
│   └──────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       完整性校验(Verify)                            │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │  定时调度器      │  │  Worker 子进程   │  │  结果应用器      │ │
│   │                  │  │                  │  │                  │ │
│   │  • Gateway 启动  │  │  • 隔离执行      │  │  • 损坏→隔离     │ │
│   │    后启动        │  │  • 不阻塞主进程  │  │    (quarantine)  │ │
│   │  • unref 定时    │  │  • 输出结果      │  │  • 健康→继续     │ │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Doctor 迁移面                                  │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │  Operator-       │  │  Restart-        │  │  Audit           │ │
│   │  Approval 迁移   │  │  Handoff 迁移    │  │  Migration       │ │
│   │                  │  │                  │  │                  │ │
│   │  • kind 约束修复 │  │  • 旧表 strict 化│  │  • 旧列重写      │ │
│   │  • Doctor-only   │  │  • Gateway 重启  │  │  • v2 shape 升级 │ │
│   │                  │  │    平滑交接      │  │                  │ │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘ │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │  Session-Watch   │  │  Startup         │  │  Agent 库        │ │
│   │  Migration       │  │  Checkpoint      │  │  Session 迁移    │ │
│   │                  │  │                  │  │                  │ │
│   │  • cursor v4 化  │  │  • schema_meta   │  │  • session 节点  │ │
│   │  • provenance    │  │  • 启动时记录    │  │    迁移          │ │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

维护与租约由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **通用 Lease** | 跨库的 scope+key 租约,带超时/退避/abort | 同步事务获取;所有权断言防止 lease 丢失后继续操作 |
| **Agent 库 Lease** | claim Agent 库前的串行化,配合 deletion journal | lease + deletion journal 在共享库写事务内原子完成 |
| **完整性校验** | 定期巡检双层库,worker 子进程隔离执行 | 损坏结果上报 quarantine;主进程不阻塞 |
| **Doctor 迁移模块群** | operator-approval / restart-handoff / audit / session-watch / startup-checkpoint | Doctor-only;运行时不调用;在事务内执行+标记版本 |
| **Quarantine 隔离** | 把损坏库标记为隔离,运行时拒绝读写 | 隔离状态可清除(Doctor 修复后) |
| **启动 Checkpoint** | schema_meta 表记录启动信息,辅助诊断 | 启动时记录,不阻塞 |

## 关联关系

### 租约体系的层次

```
   ┌─────────────────────────────────────────────────────────┐
   │  通用 Lease(最底层)                                   │
   │                                                         │
   │  • scope + key + database(shared 或 agent)             │
   │  • claim(timeout, backoff, abort)                      │
   │  • 所有权断言 / 事务内所有权断言                       │
   │  • release                                             │
   │                                                         │
   │  适用:any 需要串行化的跨进程工作                       │
   └────────────────────┬────────────────────────────────────┘
                        │
                        │ 特化
                        ▼
   ┌─────────────────────────────────────────────────────────┐
   │  Agent 库 Lease(特化层)                               │
   │                                                         │
   │  • claim 前:检查 agent_deletion_journal                │
   │  • claim 时:写 agent_database_leases(共享库)          │
   │  • claim 后:才能打开 Agent 库                          │
   │  • release 时:删除 lease 行                            │
   │                                                         │
   │  适用:打开 / 写 Agent 库前的串行化                     │
   └─────────────────────────────────────────────────────────┘

   关键不变量:
   • 通用 Lease 提供所有权断言,Agent 库 Lease 复用
   • Agent 库 Lease 额外约束 deletion journal
   • 两者都在共享库写事务内完成
```

### Verify 与 Quarantine 的协作

```
   ┌─────────────────────────────────────────────────────────┐
   │  定时调度器(Gateway 启动后)                          │
   │  • 每天 / 固定间隔触发                                  │
   │  • unref,不阻塞 Gateway                                │
   └────────────────────┬────────────────────────────────────┘
                        │
                        ▼
   ┌─────────────────────────────────────────────────────────┐
   │  Worker 子进程                                          │
   │  • 收集所有双层库目标                                   │
   │  • 隔离执行完整性校验                                   │
   │  • 输出每个库的结果(healthy / corrupted)              │
   └────────────────────┬────────────────────────────────────┘
                        │
                        ▼
   ┌─────────────────────────────────────────────────────────┐
   │  结果应用器                                             │
   │  • healthy → 继续正常运行                               │
   │  • corrupted → 写入 quarantine                          │
   │                ↓                                        │
   │  ┌──────────────────────────────────────────────────┐  │
   │  │  Quarantine 隔离                                 │  │
   │  │  • 运行时拒绝读写隔离库                          │  │
   │  │  • Doctor 可清除隔离(修复后)                   │  │
   │  │  • 隔离状态可查询                                │  │
   │  └──────────────────────────────────────────────────┘  │
   └─────────────────────────────────────────────────────────┘
```

### Doctor 迁移面的关系

```
   openclaw doctor --fix
         │
         ▼
   ┌─────────────────────────────────────────────────────────┐
   │  Doctor 主流程                                           │
   │  • 维护断言(schema 版本 / 路径 / 完整性)              │
   │  • 依次检查各迁移模块                                    │
   └────────────────────┬────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
   ┌─────────┐    ┌─────────┐    ┌─────────┐
   │operator │    │restart  │    │audit    │
   │approval │    │handoff  │    │migration│
   │         │    │         │    │         │
   │• kind   │    │• 旧表   │    │• 旧列   │
   │  约束   │    │  strict │    │  重写   │
   │  修复   │    │  化     │    │• v2     │
   │         │    │• 重启   │    │  shape  │
   │         │    │  交接   │    │  升级   │
   └─────────┘    └─────────┘    └─────────┘
        │               │               │
        └───────────────┼───────────────┘
                        │
                        ▼
   ┌─────────────────────────────────────────────────────────┐
   │  共同规则                                               │
   │  • 在共享库写事务内执行                                 │
   │  • 用 Schema Helpers 探测旧 shape                       │
   │  • 改写后断言 canonical shape                           │
   │  • 标记 user_version(若需要)                          │
   │  • 同步 commit                                          │
   └─────────────────────────────────────────────────────────┘
```

### 正确设计 vs 错误设计

```
错误设计(verify 在主进程执行):
   Gateway 主进程 ──► 直接校验 SQLite 文件
   → 校验期间 Gateway 阻塞
   → 校验本身可能崩溃主进程
   → 影响所有用户

正确设计(worker 子进程):
   Gateway 主进程 ──► 启动 worker ──► 隔离校验
                                       │
                                       ▼
   worker 输出结果 ──► 主进程应用(quarantine 或继续)
   → 主进程不阻塞
   → worker 崩溃不影响主进程
   → 结果可审计
```

## 协作流程

### 一次 lease claim 的完整旅程

下面追踪一次通用 lease claim 的全过程。

```
进程 A 要执行需要 lease 的操作(scope=global-state-migration, key=v6)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 准备 lease 参数                                           │
│    → scope / key / database(shared 或 agent)                 │
│    → leaseMs(租约时长)/ waitMs(等待时长)                   │
│    → signal(AbortSignal)                                     │
│    → leaseLabel / operationLabel(诊断用)                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 尝试 claim(带退避)                                       │
│    → 在写事务内:                                            │
│      ① 检查 state_leases 表(scope+key 是否已被持有)         │
│      ② 若已被持有且未过期 → 等待 + 退避                      │
│      ③ 若空闲或已过期 → INSERT lease 行                      │
│         (leaseId / scope / key / pid / start_time / now)     │
│    → 同步 commit                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 返回 lease 上下文                                         │
│    → signal(AbortSignal,租约到期自动 abort)                 │
│    → 所有权断言(随时断言自己仍持有)                       │
│    → 事务内所有权断言(写事务内断言)                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 执行受保护的工作                                          │
│    → 进程 A 执行迁移 / 写入 / 长任务                         │
│    → 关键节点调用所有权断言确认未被抢                       │
│    → 进入写事务时调用事务内所有权断言                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 释放 lease                                               │
│    → 工作完成 → DELETE lease 行                              │
│    → 其他进程可立即 claim                                    │
│    → 若进程崩溃:lease 行残留,下个 claimer 检测 pid 死亡    │
│      后可强制 claim                                          │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Gateway 重启 + restart-handoff 的旅程

```
Gateway 进程崩溃,有未完成的运维操作
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 新 Gateway 启动                                           │
│    → 启动编排阶段 2:运行时状态准备                          │
│    → 打开共享库                                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 检测 restart-handoff 需求                                 │
│    由 restart-handoff 迁移模块                                │
│    → 检查共享库是否有旧 gateway_restart_handoffs 表          │
│    → 若有且未 strict 化 → 需要迁移                           │
│    → 若有 pending handoff 记录 → 接管未完成工作              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 在事务内执行迁移                                          │
│    → 在共享库写事务内:                                      │
│      ① 把旧表 strict 化(若需要)                            │
│      ② 重写 handoff 记录为新 shape                          │
│      ③ 断言 canonical shape                                 │
│    → 同步 commit                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 接管未完成工作                                            │
│    → 读取 handoff 记录,识别崩溃前进度                       │
│    → 决定哪些操作需要重试 / 回滚 / 继续                      │
│    → 在新 lease 保护下继续执行                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 标记完成                                                  │
│    → 在事务内删除/更新 handoff 记录                          │
│    → 释放 lease                                              │
│    → Gateway 进入正常运行                                    │
└──────────────────────────────────────────────────────────────┘
```

### 一次 verify 巡检的旅程

```
Gateway 运行中,定时调度器触发 verify
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 收集目标                                                  │
│    → 收集所有双层库路径(共享库 + 所有注册的 Agent 库)      │
│    → 跳过已隔离的库                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 启动 worker 子进程                                       │
│    → 主进程 fork worker                                      │
│    → worker 接管所有目标路径                                 │
│    → 主进程继续服务(不阻塞)                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. worker 执行校验                                           │
│    → 对每个目标:                                            │
│      ① 以只读模式打开                                        │
│      ② 调用 SQLite integrity check                           │
│      ③ 记录结果(healthy / corrupted / error)               │
│    → worker 输出结果集合                                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 主进程应用结果                                            │
│    → healthy → 继续正常运行                                  │
│    → corrupted → 写入 quarantine                             │
│      ① 在共享库写事务内 INSERT quarantine 记录               │
│      ② 标记该库为隔离                                        │
│      ③ 运行时拒绝读写隔离库                                  │
│    → error → 记录日志,下次重试                              │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. lease 必须可检测进程死亡

- **为什么**:进程崩溃后 lease 行残留,若不检测会让资源永久锁定
- **怎么做**:lease 记录 owner_pid + owner_start_time;claimer 检测 pid 是否死亡 + start_time 是否变化;死亡或重启后可强制 claim
- **影响**:崩溃后资源可被接管;不会永久死锁

### 2. lease 丢失必须 fail closed

- **为什么**:lease 丢失(被他人抢走或过期)后继续操作会导致并发覆盖
- **怎么做**:lease 上下文提供所有权断言 / 事务内所有权断言;调用方在关键节点断言;丢失 → 抛错,停止操作
- **影响**:调用方必须处理 lease 丢失;不能假设"拿到 lease 永远持有"

### 3. verify 在 worker 子进程执行

- **为什么**:verify 涉及打开多个 SQLite 文件 + integrity check;在主进程执行会阻塞 Gateway + 可能崩溃主进程
- **怎么做**:fork worker 子进程;worker 隔离执行;主进程只应用结果
- **影响**:Gateway 不被 verify 阻塞;worker 崩溃不影响主进程

### 4. quarantine 让运行时拒绝读写

- **为什么**:损坏库继续读写会导致数据进一步损坏或不可预测行为
- **怎么做**:verify 发现损坏 → 写 quarantine 记录;运行时打开库前检查 quarantine;隔离 → 拒绝
- **影响**:损坏被隔离;Doctor 修复后可清除隔离

### 5. Doctor 迁移是 Doctor-only

- **为什么**:迁移代码处理旧 shape,逻辑复杂;运行时调用会引入 fallback 栈
- **怎么做**:迁移模块只由 Doctor 调用;运行时不 import 迁移模块;迁移完成后运行时只读 canonical
- **影响**:运行时代码简洁;迁移逻辑隔离在 Doctor

### 6. operator-approval 迁移修复 kind 约束

- **为什么**:operator_approvals 表的 kind 列曾有约束问题;旧数据可能违反新约束
- **怎么做**:Doctor 检测旧 kind 值;在事务内重写为合法值;断言 canonical shape
- **影响**:升级后审批数据合规;运行时无需处理旧 kind

## 设计观察

### 为什么 lease 用 owner_pid + owner_start_time

```
错误设计(只用 pid):
   lease 行记录 pid=12345
   → 进程崩溃,pid 被新进程复用
   → 新进程不持有 lease,但 pid 仍"存活"
   → lease 永远无法被强制 claim

正确设计(pid + start_time):
   lease 行记录 pid=12345 + start_time=...
   → claimer 检测:pid 是否死亡?start_time 是否变化?
   → 进程崩溃后 pid 复用,start_time 必然不同
   → claimer 可安全强制 claim
```

### 为什么 verify 用 worker 而非定时同步校验

```
错误设计(主进程定时同步校验):
   每 24 小时,主进程:
     for each db: open + integrity check
   → 校验期间 Gateway 阻塞
   → 一个库损坏可能让校验循环崩溃
   → 影响所有用户

正确设计(worker 子进程):
   每 24 小时,主进程:
     fork worker
     worker: for each db: open + integrity check
     worker 输出结果
     主进程: 应用结果(quarantine 或继续)
   → 主进程不阻塞
   → worker 崩溃不影响主进程
   → 结果可审计
```

### 为什么 Doctor 迁移要 assert canonical shape

```
错误设计(迁移后不 assert):
   Doctor 迁移 ──► 改写部分数据 ──► 标记版本
   → 可能漏改某些行
   → 可能 shape 不完整
   → 运行时读到"半改"状态

正确设计(迁移后 assert):
   Doctor 迁移 ──► 改写 ──► assert canonical shape ──► 标记版本
   → assert 失败 → ROLLBACK,不标记版本
   → 下次 Doctor 会重新尝试
   → 运行时只读完整 canonical shape
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/00-overview.md) | 总览:SQLite 双层结构 + 状态层组件全景 |
| [01-shared-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/01-shared-state-db.md) | 共享状态库:契约、schema-helpers、permissions、readonly |
| [02-agent-state-db.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/02-agent-state-db.md) | Per-Agent 状态库:契约、lease、registry |
| [03-schema-evolution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/03-schema-evolution.md) | Schema 演进:版本管理、additive 变更、migration 策略 |
| [04-maintenance-leases.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.1-state/04-maintenance-leases.md) | 本文件 — 维护与租约 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 通用 Lease | [src/state/openclaw-state-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-lease.ts) |
| Agent 库 Lease | [src/state/openclaw-agent-db-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-lease.ts) |
| Agent 删除 journal | [src/state/agent-deletion-journal.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/agent-deletion-journal.ts) |
| 完整性校验入口 | [src/state/openclaw-database-verify.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-verify.ts) |
| 完整性校验实现 | [src/state/openclaw-database-verify.impl.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-verify.impl.ts) |
| 完整性校验 worker | [src/state/openclaw-database-verify.worker.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-database-verify.worker.ts) |
| Quarantine 隔离存储 | [src/state/openclaw-quarantine-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-quarantine-store.ts) |
| Operator-Approval 迁移 | [src/state/openclaw-state-db-operator-approval-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-operator-approval-migration.ts) |
| Session-Watch 迁移 | [src/state/openclaw-state-db-session-watch-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-session-watch-migration.ts) |
| Audit 迁移 | [src/state/openclaw-state-db-audit-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-audit-migration.ts) |
| 启动 Checkpoint | [src/state/openclaw-state-db-startup-checkpoint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-startup-checkpoint.ts) |
| 共享库维护断言 | [src/state/openclaw-state-db-maintenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-maintenance.ts) |
| Per-Agent 库维护 | [src/state/openclaw-agent-db-maintenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-maintenance.ts) |
| Per-Agent Session 迁移 | [src/state/openclaw-agent-db-session-migrations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-agent-db-session-migrations.ts) |
| 共享库 Schema 修复 | [src/state/openclaw-state-db-schema-repair.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-schema-repair.ts) |
| 共享库 Legacy backfills | [src/state/openclaw-state-db-legacy-backfills.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db-legacy-backfills.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Storage" / "Validation" 段 |
