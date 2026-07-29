# 01 — 调度与服务

> 读完本章你将理解:调度服务如何编排任务生命周期、调度策略如何决定下一次触发时间、活跃任务表如何防重复触发、手动唤醒如何接入心跳循环。

## 一句话定位

调度服务是定时任务的"中枢神经":
- 持有可变调度器状态,所有任务变更走单一 facade
- 通过锁内操作助手实现读 / 写 / 运行三类操作的串行化
- 调度策略(解析、规范化、节奏、错峰、活跃任务)决定任务何时真正触发
- 主动唤醒支持手动立即触发或顺延到下一次心跳

## 全局协作图

下图展示调度服务内部各组件如何协作,以及与外部层的边界。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       调度服务(Scheduling Service)                  │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ Facade      │  │ 服务状态    │  │ 锁内操作    │  │ 生命周期  │ │
│   │ (公共入口)  │ ─►│ (可变状态)  │ ─►│ 助手       │ ─►│ 编排      │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 时间表组件  │  │ 计时器      │  │ 启动追赶    │  │ 失败告警  │ │
│   │ (触发检测)  │  │ (执行调度)  │  │ (历史补跑)  │  │ (账号路由)│ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 调用策略组件决定触发时机
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       调度策略(Scheduling Policy)                   │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 时间表解析  │  │ 规范化      │  │ 节奏钳制    │  │ 错峰偏移  │ │
│   │ (cron 表达  │  │ (任务身份  │  │ (min/max   │  │ (整点对齐 │ │
│   │  式 + 间隔) │  │  + 字段)   │  │  边界)      │  │  偏移)    │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐                                  │
│   │ 活跃任务表  │  │ 运行准备    │                                  │
│   │ (防重复触发)│  │ (admission) │                                  │
│   └─────────────┘  └─────────────┘                                  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 手动入口
                               ▼
                  ┌────────────────────────┐
                  │  主动唤醒              │
                  │  (now / next-heartbeat)│
                  │  → 入队系统事件        │
                  │  → 顺带 poke 心跳      │
                  └────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Facade(公共入口)** | 暴露加 / 改 / 删 / 列 / 触发 / 唤醒等公共 API | 单一入口,所有变更经此进入 |
| **服务状态** | 持有可变调度器状态:启停标志、生命周期代际、调度器是否已启动 | 通过代际号防止启停竞态 |
| **锁内操作助手** | 把读 / 写 / 运行三类操作串行化在锁内 | 所有变更走单一锁,避免状态竞争 |
| **生命周期编排** | 启动 / 停止 / 排空,处理启停并发 | 同代启动幂等,跨代启动互斥 |
| **时间表组件** | 检测任务是否到期,计算下一次触发点 | 整点对齐任务受错峰策略约束 |
| **计时器** | 实际执行调度回调,管理执行超时 | 单任务单计时器,禁止重复装填 |
| **启动追赶** | 启动时扫描过期任务,按策略补跑或跳过 | 必须在调度器就绪前完成 |
| **失败告警** | 任务失败时按账号路由发送通知 | 账号隔离,防止单账号失败淹没其他 |
| **时间表解析** | 解析 cron 表达式 + 间隔式描述 | 同时支持 cron 与间隔两种语法 |
| **规范化** | 任务身份 / 字段 / 载荷的统一规整 | 配置只支持最新 shape,旧格式走 doctor |
| **节奏钳制** | 对成功运行的下一次提议做最小 / 最大边界 | 最小不超最大,二者均为正时长 |
| **错峰偏移** | 对整点对齐任务做小幅随机偏移 | 防止集体撞车,偏移量有上限 |
| **活跃任务表** | 登记正在运行的任务,防重复触发 | 同任务串行,完成或失败后移除 |
| **运行准备** | 决定任务是否被接纳执行(admission) | 禁用 / 已在运行 / 配置非法均拒绝 |
| **主动唤醒** | 手动触发任务或顺延到下一次心跳 | 立即模式入队系统事件,心跳模式 poke 心跳 |

## 关联关系

### Facade 与锁内操作助手

```
   外部调用方
        │
        ▼
   ┌─────────────┐
   │  Facade     │ ──委托──► 锁内操作助手
   │  (公共入口) │              │
   └─────────────┘              ▼
                          ┌─────────────┐
                          │  服务状态   │
                          │  (可变状态) │
                          └──────┬──────┘
                                 │
                                 ▼
                          ┌─────────────┐
                          │  存储层     │
                          │  (SQLite)   │
                          └─────────────┘
```

### 调度策略组件之间的关系

```
   任务配置
       │
       ▼
   ┌─────────────┐
   │ 时间表解析  │ ──► 下一次运行时间提议
   └─────────────┘            │
                              ▼
   ┌─────────────┐     ┌─────────────┐
   │ 错峰偏移    │ ◄──► │ 节奏钳制    │
   │ (整点偏移)  │     │ (min/max)   │
   └─────────────┘     └──────┬──────┘
                              │
                              ▼
                       最终下一次运行时间
                              │
                              ▼
                       ┌─────────────┐
                       │ 活跃任务表  │
                       │ (执行时登记)│
                       └─────────────┘

   反例:三者各自独立应用
   ┌─────────────┐
   │ 解析提议    │ ──► 直接写入存储
   └─────────────┘
   → 错峰 / 节奏被绕过 → 整点拥塞、过快连发
```

### 主动唤醒的两种模式

```
立即模式:
   调用方 ──► 主动唤醒 ──入队系统事件──► Agent 会话
                    │
                    └──poke 心跳循环──► 心跳立即检查

心跳模式:
   调用方 ──► 主动唤醒 ──poke 心跳循环──► 下一次心跳检查时触发
                                          (不入队系统事件)

   反例:立即模式不 poke 心跳
   → 系统事件入队但心跳循环未醒 → 事件积压 → 触发延迟
```

## 协作流程

### 一次任务到期触发的调度细节

```
系统时钟到达下一次运行时间
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 时间表组件                                                │
│    检测到任务到期                                            │
│    → 提交给计时器回调                                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 运行准备(admission)                                      │
│    锁内检查:                                                │
│    ├─ 任务是否被禁用? ──是──► 拒绝执行                      │
│    ├─ 任务是否已在活跃任务表? ──是──► 拒绝(防重复)         │
│    └─ 配置是否合法? ──否──► 拒绝 + 标记任务异常              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 调度策略应用                                              │
│    • 节奏钳制:对提议的下一次运行时间做边界检查              │
│    • 错峰偏移:整点对齐任务加小幅偏移                        │
│    • 写入存储层:更新下一次运行时间                          │
│    • 活跃任务表:登记本任务为活跃                            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 计时器执行                                                │
│    → 调用 Agent 会话 或 执行外部脚本                         │
│    → 执行超时由执行超时组件兜底                              │
│    → 终态信号经单一归一化入口                                │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 终态落库                                                  │
│    • 从活跃任务表移除                                        │
│    • 写入运行记录、终态、投递状态                            │
│    • 失败时按账号路由发送告警                                │
│    • 重新装填时间表                                          │
└──────────────────────────────────────────────────────────────┘
```

### 启动时的生命周期编排

```
Gateway 启动
     │
     ▼
┌──────────────────────────────────────────────────────┐
│  阶段 1:生命周期代际检查                             │
│  • 若已有同代启动在进行 → 等待其完成                 │
│  • 若跨代启动 → 互斥,新代优先                       │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 2:从存储层加载任务表                          │
│  • 校验每个任务的配置合法性                          │
│  • 非法任务进入隔离区,不参与调度                    │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 3:启动追赶扫描                                │
│  • 检测"启动前已过期"的任务                          │
│  • 按配置策略:跳过 / 立即补跑                        │
│  • 修复"启动前溢出"的运行记录                        │
└──────────────────────────────┬───────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────┐
│  阶段 4:装填时间表                                  │
│  • 为每个有效任务设下一触发点                        │
│  • 启动计时器                                        │
│  • 标记调度器已启动                                  │
└──────────────────────────────┬───────────────────────┘
                               ▼
                  调度服务就绪
                  (等待下一次触发)
```

## 关键设计约束

### 1. 单一 facade + 锁内操作助手

- **为什么**:防止并发调用方绕过锁直接修改状态,造成任务表 / 活跃表 / 时间表不一致
- **怎么做**:facade 不直接改状态,委托给锁内操作助手;所有变更操作串行化在锁内
- **影响**:读操作可以非阻塞并发,但写 / 运行操作必须排队

### 2. 生命周期代际号防启停竞态

- **为什么**:启动 / 停止可能并发触发(如热重载),没有代际号会互相踩踏
- **怎么做**:每次停止递增代际号;启动时记录代际号,跨代启动互斥
- **影响**:旧代启动的 Promise 不会污染新代状态

### 3. 节奏与错峰是强制策略而非建议

- **为什么**:LLM 配额、Agent 会话并发、整点对齐的 cron 表达式天然容易撞车
- **怎么做**:节奏策略对成功运行的下一次提议做边界钳制;错峰策略对整点对齐任务做小幅偏移
- **影响**:任务的实际触发时间可能略晚于纯 cron 表达式计算结果,这是有意为之

### 4. 活跃任务表是同任务串行的硬保证

- **为什么**:同一任务在 LLM 慢响应期间可能再次到期,无活跃表会重复触发造成状态竞争
- **怎么做**:任务开始执行时登记到活跃表,完成或失败后移除;admission 检查活跃表拒绝重复
- **影响**:同任务串行,跨任务并发,资源可控

### 5. 配置非法任务进隔离区,不阻塞调度

- **为什么**:单个任务配置非法不应让整个调度服务停摆
- **怎么做**:启动加载时校验,非法任务进入隔离区,不参与调度但仍可列出 / 修复
- **影响**:用户能看到非法任务并修复,其他任务正常调度

### 6. 启动追赶必须在就绪前完成

- **为什么**:若就绪后才发现过期任务,可能与正常触发叠加造成重复执行
- **怎么做**:启动时扫描过期任务,按配置策略补跑或跳过,完成后才标记调度器就绪
- **影响**:调度服务启动有短暂"不可触发"窗口,这是预期行为

## 设计观察

### 为什么时间表解析同时支持 cron 表达式与间隔式

```
单一语法:
   只支持 cron 表达式
   → 用户想"每 90 秒"得写复杂表达式 → 易错
   → 短间隔场景表达式笨重

双语法:
   cron 表达式:适合"每天 9 点" / "每周一"等日历式
   间隔式:    适合"每 90 秒" / "每 45 分钟"等固定间隔
   → 各取所长,规范化统一为内部表示
```

### 为什么失败告警要按账号路由

```
单账号告警:
   任务 A(账号 1)失败 ──► 告警发到账号 1
   任务 B(账号 2)失败 ──► 告警发到账号 1
   → 账号 2 用户收不到自己的失败通知
   → 账号 1 被无关告警淹没

按账号路由:
   任务 A(账号 1)失败 ──► 告警发到账号 1
   任务 B(账号 2)失败 ──► 告警发到账号 2
   → 各账号收自己的失败通知,职责清晰
```

### 为什么运行准备(admission)放在锁内

```
锁外 admission:
   检查活跃表 ──不在──► 写入活跃表 ──► 触发执行
   → 检查与写入之间存在窗口,另一并发调用方可能同时通过检查 → 重复触发

锁内 admission:
   锁内 { 检查活跃表 ──不在──► 写入活跃表 } ──► 触发执行
   → 检查与写入原子,并发调用方串行通过 → 无重复触发
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/00-overview.md) | 定时任务组件全景 |
| [01-schedule-service.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/01-schedule-service.md) | 本文件 — 调度与服务 |
| [02-store-schema.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/02-store-schema.md) | 存储与 Schema |
| [03-delivery-retry.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/03-delivery-retry.md) | 投递与重试 |
| [04-cron-exit-watchers.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/04-cron-exit-watchers.md) | 退出监控 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 调度服务 facade | [src/cron/service.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service.ts) |
| 服务状态 | [src/cron/service/state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/state.ts) |
| 锁内操作助手 | [src/cron/service/locked.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/locked.ts) |
| 生命周期编排 | [src/cron/service/ops-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/ops-lifecycle.ts) |
| 读操作 | [src/cron/service/ops-read.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/ops-read.ts) |
| 写操作 | [src/cron/service/ops-mutations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/ops-mutations.ts) |
| 运行操作 | [src/cron/service/ops-run.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/ops-run.ts) |
| 运行准备 | [src/cron/service/run-admission.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/run-admission.ts) |
| 任务调度 | [src/cron/service/jobs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/jobs.ts) |
| 任务调度计算 | [src/cron/service/jobs-scheduling.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/jobs-scheduling.ts) |
| 启动追赶 | [src/cron/service/timer-catchup.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/timer-catchup.ts) |
| 启动运行修复 | [src/cron/service/startup-run-repair.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/startup-run-repair.ts) |
| 计时器调度 | [src/cron/service/timer-scheduler.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/timer-scheduler.ts) |
| 计时器执行 | [src/cron/service/timer-execution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/timer-execution.ts) |
| 执行超时 | [src/cron/service/timer-execution-timeout.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/timer-execution-timeout.ts) |
| 失败告警 | [src/cron/service/failure-alerts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/failure-alerts.ts) |
| 时间表解析 | [src/cron/parse.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/parse.ts) |
| 时间表 | [src/cron/schedule.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/schedule.ts) |
| 规范化 | [src/cron/normalize.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/normalize.ts) |
| 节奏钳制 | [src/cron/pacing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/pacing.ts) |
| 错峰偏移 | [src/cron/stagger.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/stagger.ts) |
| 活跃任务 | [src/cron/active-jobs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/active-jobs.ts) |
| 主动唤醒 | [src/cron/service/wake.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/wake.ts) |
| 任务账本 | [src/cron/service/task-ledger.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/task-ledger.ts) |
| 任务运行 | [src/cron/service/task-runs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/task-runs.ts) |
| 主动运行取消 | [src/cron/service/active-run-cancellation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/active-run-cancellation.ts) |
| Agent 看门狗 | [src/cron/service/agent-watchdog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/service/agent-watchdog.ts) |
