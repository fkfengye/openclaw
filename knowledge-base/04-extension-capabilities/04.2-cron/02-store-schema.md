# 02 — 存储与 Schema

> 读完本章你将理解:任务表如何落 SQLite、Schema 与类型如何对齐、Key 如何做分区隔离、运行 ID 如何生成、临时数据如何用单调修订号防覆盖、工具白名单与 Webhook URL 如何规整。

## 一句话定位

存储层是定时任务的"持久记忆":
- 任务表、运行记录、临时数据全部落共享状态库 SQLite,禁止 JSON / sidecar
- Schema 与类型集中定义,行编解码负责 DB 行与领域对象互转
- 临时数据(per-job scratch)用单调修订号 + 内容哈希做乐观并发控制
- 运行 ID、运行日志类型、工具白名单、Webhook URL 各有独立规整入口

## 全局协作图

下图展示存储层内部各组件如何协作,以及与调度层、投递层的边界。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       存储层(Storage Layer)                         │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 任务表      │  │ Schema      │  │ 类型定义    │  │ Key 分区   │ │
│   │ (任务持久化)│  │ (Kysely 表) │  │ (领域模型)  │  │ (路径规范化)│ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 行编解码    │  │ 标量编解码  │  │ 触发编解码  │  │ 载荷编解码│ │
│   │ (DB行↔领域) │  │ (基本类型) │  │ (trigger)   │  │ (payload) │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 临时数据    │  │ 投递计划    │  │ 运行 ID     │  │ 运行日志  │ │
│   │ (per-job    │  │ (路由解析)  │  │ (生成器)    │  │ 类型      │ │
│   │  scratch)   │  │             │  │             │  │           │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   规则:SQLite 唯一 | 共享状态库 | 写事务同步 commit | 禁止 sidecar  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 上游:调度层读写
                               │ 下游:投递层读计划
                               ▼
                  ┌────────────────────────┐
                  │  调度层 + 投递层       │
                  │  (上游依赖)            │
                  └────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **任务表** | 持久化任务记录(身份、调度、状态、配置) | 共享状态库的 cron 表,SQLite 唯一 |
| **Schema** | Kysely 表 facade,定义行类型与插入 / 选择 shape | 与共享状态库生成的类型对齐 |
| **类型定义** | 领域模型:CronJob / CronJobCreate / CronJobPatch 等 | 与 DB 行 shape 分离,经编解码互转 |
| **Key 分区** | 为存储行生成规范化分区键(路径解析) | 用绝对路径作为键,防相对路径歧义 |
| **行编解码** | DB 行与领域对象互转,处理可空字段、JSON 序列化 | 双向无损,字段变更需同步编解码 |
| **标量编解码** | 基本类型(字符串、数字、布尔)的边界规整 | 拒绝畸形输入,空值语义明确 |
| **触发编解码** | trigger 字段的序列化 / 反序列化 | 支持 cron 与间隔两种触发语法 |
| **载荷编解码** | payload 字段的序列化 / 反序列化 | 支持 Agent 回合、脚本、触发脚本等载荷类型 |
| **临时数据** | per-job 临时内容存储,带修订号 + 内容哈希 | 单调修订号防旧写覆盖新值,unset 保留墓碑行 |
| **投递计划** | 解析任务配置,产出路由计划(模式、渠道、收件人、线程) | 纯函数,可被校验 / 预览 / dry-run 复用 |
| **运行 ID** | 为每次运行生成唯一标识 | 单调递增,跨任务唯一 |
| **运行日志类型** | 定义运行日志条目的类型与编解码 | 与运行记录表对齐 |
| **工具白名单** | 决定任务能否使用 Agent 工具,默认值规整 | 仅在需要工具运行时的载荷才设默认白名单 |
| **Webhook URL** | 规整与校验 Webhook URL,拒绝非 HTTP(S) | 空 / 畸形 / 非 HTTP(S) 一律返回 null |

## 关联关系

### 任务表与编解码的分层

```
   调度层(领域对象)
        │
        ▼
   ┌─────────────┐
   │ 行编解码    │ ◄──► 触发编解码 + 载荷编解码 + 标量编解码
   │ (DB行↔领域) │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐
   │ Schema      │ ──► Kysely 表 facade
   │ (表定义)    │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐
   │ 任务表      │ ──► 共享状态库 SQLite
   │ (实际行)    │
   └─────────────┘

   反例:领域对象直接当 DB 行
   → 可空字段、JSON 序列化、触发 / 载荷多态无统一处理 → 数据腐败
```

### 临时数据的乐观并发控制

```
   写入方 A:读到修订号 = 5
   写入方 B:读到修订号 = 5
   写入方 A:提交内容 + 修订号 6 ──► 成功
   写入方 B:提交内容 + 修订号 6 ──► 冲突(期望 5,实际 6)→ 拒绝

   反例:无修订号
   写入方 A:读到内容 X
   写入方 B:读到内容 X
   写入方 A:写入 Y
   写入方 B:写入 Z ──► 覆盖 Y → A 的写入丢失

   墓碑行机制:
   写入方 unset(删除内容)→ 保留墓碑行(修订号继续递增)
   → 后续 compare-and-swap 写入看到墓碑 → 不能复活旧内容
```

### 投递计划与投递执行的边界

```
   任务配置
       │
       ▼
   ┌─────────────┐
   │ 投递计划    │ ──纯函数──► 路由计划
   │ (路由解析)  │             (模式 + 渠道 + 收件人 + 线程)
   └─────────────┘                       │
                                         ▼
   ┌─────────────┐               ┌─────────────┐
   │ 配置校验    │ ◄──复用────────│ 投递执行    │
   │ dry-run     │ ◄──复用────────│ (按计划发送)│
   │ 预览        │ ◄──复用────────└─────────────┘
   └─────────────┘

   反例:投递执行内嵌路由解析
   → 校验 / dry-run / 预览各复制一份路由逻辑 → 三处不一致
```

## 协作流程

### 一次任务写入的存储流程

```
调度层调用任务表写入(任务对象)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 行编解码                                                  │
│    领域对象 → DB 行                                          │
│    • 触发字段经触发编解码序列化                              │
│    • 载荷字段经载荷编解码序列化                              │
│    • 标量字段经标量编解码规整                                │
│    • 可空字段处理为 DB 可空 shape                            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Key 分区                                                  │
│    存储路径 → 规范化绝对路径 → 分区键                        │
│    → 防止相对路径 / 符号链接造成重复键                       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 写事务(同步 commit)                                     │
│    BEGIN                                                     │
│    • 重读权威行校验前置条件                                  │
│    • 写入任务表                                              │
│    COMMIT(同步)                                            │
│    → 事务内禁止 await / 异步操作                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 读回校验                                                  │
│    从 DB 读回行 → 经行编解码还原为领域对象                   │
│    → 确认写入无误                                            │
└──────────────────────────────────────────────────────────────┘
```

### 临时数据的写入流程

```
Agent 在执行中需要保存临时内容
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 读当前状态                                                │
│    → 内容 + 修订号(若已 unset,看到墓碑行)                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 计算新内容哈希                                            │
│    → 与已存 source_sha256 对比,相同则跳过写入               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. compare-and-swap 写入                                     │
│    期望修订号 = 当前修订号                                  │
│    • 成功 → 返回新修订号                                    │
│    • 冲突 → 返回冲突原因 + 最新修订号(调用方自行重试)      │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. SQLite 唯一,禁止 sidecar 文件

- **为什么**:状态层规则要求所有运行时状态落 SQLite,避免文件系统散落、跨进程不一致
- **怎么做**:任务表、运行记录、临时数据均存共享状态库;禁止 JSON / JSONL / TXT / sidecar 文件
- **影响**:旧文件格式只在 doctor 迁移代码中出现,运行时不读

### 2. 写事务同步 commit,事务内禁止 await

- **为什么**:SQLite 写事务是临界区,事务内 await 会延长锁持有时间,造成并发性能崩塌
- **怎么做**:BEGIN 前完成所有异步规划、文件系统访问、插件钩子、谓词;事务内只做重读校验 + 写入;COMMIT 同步
- **影响**:写入路径必须先准备好所有数据,不能边算边写

### 3. 临时数据用单调修订号防覆盖

- **为什么**:多个写入方(主任务、子代理、外部触发)可能并发写同一任务的临时内容,无修订号会丢失更新
- **怎么做**:每次写入递增修订号;compare-and-swap 期望旧修订号;unset 保留墓碑行,修订号继续递增
- **影响**:旧写入方无法用陈旧修订号复活已 unset 的内容

### 4. Key 分区用绝对路径规范化

- **为什么**:相对路径、符号链接、`.` / `..` 会让同一存储位置产生不同键,造成重复行
- **怎么做**:存储路径经路径解析为绝对路径,作为分区键
- **影响**:跨平台路径差异(大小写、分隔符)需在解析时统一

### 5. 投递计划是纯函数,与投递执行分离

- **为什么**:配置校验、dry-run、预览都需要在不真正发送时知道路由计划;若计划内嵌在执行中,三者都得复制一份逻辑
- **怎么做**:投递计划组件接收任务配置,纯函数返回路由计划;投递执行器只按计划发送
- **影响**:计划解析可独立测试,执行器只关心发送

### 6. 工具白名单默认值只在需要时设

- **为什么**:不是所有任务都使用 Agent 工具(如纯脚本任务),无差别设默认白名单会模糊任务能力边界
- **怎么做**:仅当任务载荷需要工具运行时(Agent 回合、脚本、触发脚本)且未显式指定白名单时,才设默认不限制
- **影响**:任务能力声明清晰,审计时能看出哪些任务真正用工具

## 设计观察

### 为什么领域对象与 DB 行分离

```
耦合设计:
   领域对象 = DB 行
   → 可空字段、JSON 序列化、触发 / 载荷多态直接暴露给上层
   → 上层每处用都得处理这些边界 → 重复且易错

分离设计:
   领域对象 ◄──行编解码──► DB 行
   → 上层只看干净领域模型
   → 编解码集中处理可空、JSON、多态
   → 字段变更只改编解码,上层无感
```

### 为什么 unset 临时数据要保留墓碑行

```
无墓碑:
   写入方 A:读到内容 X,修订号 5
   写入方 B:unset → 行被删除
   写入方 A:compare-and-swap 期望 5 → 行不存在 → 视为新建 → 写入 X → 旧内容复活

有墓碑:
   写入方 A:读到内容 X,修订号 5
   写入方 B:unset → 墓碑行,修订号 6
   写入方 A:compare-and-swap 期望 5 → 实际 6 → 冲突 → 拒绝 → 旧内容不复活
```

### 为什么 Webhook URL 校验拒绝非 HTTP(S)

```
宽松校验:
   接受任意 URL scheme(file://、ftp://、data://)
   → 攻击者构造 file:// URL 让服务端读取本地文件 → SSRF / 信息泄露

严格校验:
   只接受 HTTP(S)
   → 收窄攻击面,与 OpenClaw 网络策略一致
   → 空 / 畸形 / 非 HTTP(S) 一律返回 null,调用方按"未配置"处理
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/00-overview.md) | 定时任务组件全景 |
| [01-schedule-service.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/01-schedule-service.md) | 调度与服务 |
| [02-store-schema.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/02-store-schema.md) | 本文件 — 存储与 Schema |
| [03-delivery-retry.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/03-delivery-retry.md) | 投递与重试 |
| [04-cron-exit-watchers.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/04-cron-exit-watchers.md) | 退出监控 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 任务存储入口 | [src/cron/store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store.ts) |
| Schema 与 Kysely facade | [src/cron/store/schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/schema.ts) |
| 类型定义 | [src/cron/store/types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/types.ts) |
| Key 分区 | [src/cron/store/key.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/key.ts) |
| 行编解码 | [src/cron/store/row-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/row-codec.ts) |
| 标量编解码 | [src/cron/store/scalar-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/scalar-codec.ts) |
| 触发编解码 | [src/cron/store/trigger-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/trigger-codec.ts) |
| 载荷编解码 | [src/cron/store/payload-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/payload-codec.ts) |
| 投递编解码 | [src/cron/store/delivery-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/delivery-codec.ts) |
| 状态编解码 | [src/cron/store/state-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/state-codec.ts) |
| 失败告警编解码 | [src/cron/store/failure-alert-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/failure-alert-codec.ts) |
| 配置状态 | [src/cron/store/config-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/store/config-state.ts) |
| 临时数据存储 | [src/cron/scratch-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/scratch-store.ts) |
| 临时数据契约 | [src/cron/scratch-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/scratch-contract.ts) |
| 投递计划 | [src/cron/delivery-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-plan.ts) |
| 运行 ID | [src/cron/run-id.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/run-id.ts) |
| 运行日志类型 | [src/cron/run-log-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/run-log-types.ts) |
| 任务运行事件编解码 | [src/cron/task-run-event-codec.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/task-run-event-codec.ts) |
| 工具白名单 | [src/cron/tools-allow.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/tools-allow.ts) |
| 工具策略 | [src/cron/scheduled-tool-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/scheduled-tool-policy.ts) |
| Webhook URL | [src/cron/webhook-url.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/webhook-url.ts) |
| 持久化 shape | [src/cron/persisted-shape.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/persisted-shape.ts) |
| 共享类型 | [src/cron/types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/types.ts) |
| 共享类型(补充) | [src/cron/types-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/types-shared.ts) |
| 上游依赖:共享状态库 | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
