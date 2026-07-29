# 03 — 投递与重试

> 读完本章你将理解:任务执行结果如何投递到渠道、投递计划如何解析路由、失败通知如何按账号路由、重试分类如何区分执行前后、为什么 5xx 匹配必须带 HTTP 上下文。

## 一句话定位

投递层是定时任务的"输出通道":
- 投递计划组件纯函数解析任务配置,产出路由计划(模式、渠道、收件人、线程)
- 投递执行器按计划调用渠道系统发送消息,失败时按账号路由发通知
- 重试分类器把失败错误归类为可重试 / 不可重试,严格区分执行前后
- 默认投递策略按载荷类型 + 会话目标决定是否走播报模式

## 全局协作图

下图展示投递层内部各组件如何协作,以及与调度层、渠道系统的边界。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       投递层(Delivery Layer)                        │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 投递计划    │  │ 投递执行    │  │ 失败通知    │  │ 默认策略  │ │
│   │ (路由解析)  │ ─►│ (消息发送)  │ ─►│ (账号路由)  │  │ (播报判断)│ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 重试分类    │  │ 投递目标    │  │ 投递上下文  │  │ 渠道校验  │ │
│   │ (失败归类)  │  │ (目标解析)  │  │ (会话绑定)  │  │ (合法性)  │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 上游:调度层提供任务 + 执行结果
                               │ 下游:渠道系统发送消息
                               ▼
                  ┌────────────────────────┐
                  │  渠道系统              │
                  │  (Telegram / Slack /   │
                  │   Discord / ...)       │
                  └────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **投递计划** | 纯函数解析任务配置,产出路由计划 | 与投递执行分离,可被校验 / 预览 / dry-run 复用 |
| **投递执行** | 按计划调用渠道系统发送消息 | 失败不阻塞调度,失败结果回传调度层 |
| **失败通知** | 任务失败时按账号路由发送告警 | 账号隔离,防止单账号失败淹没其他 |
| **默认策略** | 按载荷类型 + 会话目标决定是否默认走播报 | 创建时、持久化时、运行时三处共用同一策略 |
| **重试分类** | 把失败错误归类为可重试 / 不可重试 + 类别 | 区分执行前后,执行后默认不重试 |
| **投递目标** | 解析目标渠道、收件人、线程、账号 | 处理继承会话线程的开关 |
| **投递上下文** | 绑定会话身份,构建出站会话上下文 | 与 Agent 出站身份解析对齐 |
| **渠道校验** | 校验投递配置的渠道合法性 | 拒绝未知渠道,与已注册渠道对齐 |

## 关联关系

### 投递计划 → 投递执行 → 失败通知

```
   任务配置 + 执行结果
        │
        ▼
   ┌─────────────┐
   │ 投递计划    │ ──纯函数──► 路由计划
   │             │             (模式 + 渠道 + 收件人 + 线程 + 账号)
   └─────────────┘                       │
                                         ▼
                                  ┌─────────────┐
                                  │ 投递执行    │
                                  │ (按计划发送)│
                                  └──────┬──────┘
                                         │
                          ┌──────────────┴──────────────┐
                          │                             │
                          ▼                             ▼
                   成功:回传调度层         失败:走失败通知
                                              │
                                              ▼
                                       ┌─────────────┐
                                       │ 失败通知    │
                                       │ (按账号路由)│
                                       └─────────────┘

   反例:投递执行内嵌路由解析 + 失败通知
   → 三者耦合 → 校验 / 预览无法复用 → 失败通知路由不一致
```

### 默认策略的三处共用

```
   任务创建时:默认策略 ──► 决定初始投递模式
   任务持久化时:默认策略 ──► 校验直接写入的投递模式
   任务运行时:默认策略 ──► 解析最终投递模式

   反例:三处各自判断
   → 创建时设为播报,持久化时判为静默,运行时判为不投递
   → 同一任务在不同阶段行为不一致 → 结果静默丢失
```

### 重试分类的执行前后边界

```
   执行未开始:
   错误 = "会话被删除 / 切换" → 可重试(无副作用产生)
   错误 = "速率限制 / 网络错误" → 可重试

   执行已开始:
   错误 = "会话被删除 / 切换" → 不重试(工具可能已产生副作用)
   错误 = "速率限制 / 网络错误" → 不重试(默认)

   反例:不区分执行前后
   执行已开始 + 会话切换 → 重试 → 工具副作用重复执行
   → 非幂等操作(发消息、写库)产生重复效果
```

## 协作流程

### 一次成功投递的完整流程

```
任务执行完成,产出结果
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 投递计划解析                                              │
│    输入:任务配置(载荷类型 + 会话目标 + 投递配置)          │
│    → 默认策略判断是否走播报模式                              │
│    → 解析渠道、收件人、线程、账号                            │
│    → 产出路由计划                                            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 投递目标解析                                              │
│    → 解析目标渠道是否合法                                    │
│    → 处理继承会话线程的开关                                  │
│    → 失败时返回错误(配置错误,非发送错误)                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 投递上下文构建                                            │
│    → 绑定会话身份                                            │
│    → 解析 Agent 出站身份                                     │
│    → 构建出站会话上下文                                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 投递执行                                                  │
│    → 调用渠道系统发送消息                                    │
│    → 等待发送结果(有超时兜底)                              │
│    → 成功:回传调度层                                        │
│    → 失败:进入失败通知路径                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 终态归一化 + 落库                                         │
│    → 投递状态写入存储层                                      │
│    → 调度层重新装填时间表                                    │
└──────────────────────────────────────────────────────────────┘
```

### 失败通知的发送流程

```
任务执行失败 或 投递失败
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 解析失败目的地                                            │
│    → 从任务配置读失败通知配置                                │
│    → 解析失败通知渠道、收件人、线程、账号                    │
│    → 若未配置,按任务原投递目标回退                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 按账号路由                                                │
│    → 任务 A(账号 1)失败 → 告警发到账号 1                   │
│    → 任务 B(账号 2)失败 → 告警发到账号 2                   │
│    → 各账号收自己的失败通知                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 失败通知发送                                              │
│    → 调用渠道系统发送                                        │
│    → 有超时兜底(默认 30 秒)                                │
│    → 发送失败本身不再重试(避免递归)                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 重试分类                                                  │
│    → 错误信息经重试分类器归类                                │
│    → 判断是否可重试 + 类别                                   │
│    → 调度层根据分类决定下一次是否重跑                        │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 投递计划是纯函数,与执行分离

- **为什么**:配置校验、dry-run、预览都需要在不真正发送时知道路由计划;若计划内嵌在执行中,三者都得复制一份逻辑
- **怎么做**:投递计划组件接收任务配置,纯函数返回路由计划;投递执行器只按计划发送
- **影响**:计划解析可独立测试,执行器只关心发送

### 2. 默认策略三处共用同一判断

- **为什么**:创建时、持久化时、运行时如果各自判断默认投递模式,会产生不一致,导致结果静默丢失
- **怎么做**:默认策略组件被三处调用,判断条件统一(载荷类型 + 会话目标)
- **影响**:同任务在全生命周期投递行为一致

### 3. 重试分类必须区分执行前后

- **为什么**:执行开始后工具可能产生非幂等副作用(发消息、写库),盲目重试会重复执行副作用
- **怎么做**:重试分类器接收执行是否已开始的标志;会话生命周期错误只在执行未开始时标记可重试
- **影响**:执行开始后的失败默认不重试,除非显式配置覆盖

### 4. 5xx 匹配必须带 HTTP 上下文

- **为什么**:cron 失败消息正文里常含数字(如"context limit 512 exceeded"、"exited with 503 lines"、".sock" 路径),裸 5xx 正则会误匹配,把永久失败错判为可重试
- **怎么做**:5xx 匹配必须出现 HTTP / status / response 等关键字,或匹配 canonical 5xx 短语,或是消息全文本身
- **影响**:真正的"500 Internal Server Error" / "502 Bad Gateway" 仍能正确分类,而正文里的数字不会误判

### 5. 失败通知按账号路由

- **为什么**:单账号告警会让账号 2 用户收不到自己的失败通知,账号 1 被无关告警淹没
- **怎么做**:失败通知组件从任务配置读账号,按账号路由发送
- **影响**:各账号收自己的失败通知,职责清晰

### 6. 失败通知本身不再重试

- **为什么**:失败通知发送失败若再触发失败通知,会形成递归;若重试会放大故障
- **怎么做**:失败通知发送有超时兜底(默认 30 秒),发送失败本身不再重试,只记录日志
- **影响**:失败通知是 best-effort,不保证送达

## 设计观察

### 为什么结构化分类优先于正则匹配

```
纯正则匹配:
   错误信息 → 一堆正则 → 分类
   → 错误信息措辞变化 → 正则失配 → 分类错误
   → 不同 Provider 措辞不同 → 维护一堆特殊正则

结构化优先:
   Provider 提供结构化分类原因 → 直接采用
   Provider 未提供 → 回退到正则
   → 结构化分类稳定,正则只是兜底
```

### 为什么投递目标解析要处理继承会话线程

```
不处理继承:
   任务配置:渠道 = Telegram,收件人 = 群组 A
   → 直接发到群组 A 的新消息
   → 与原会话上下文断开,用户看不到关联

处理继承:
   任务配置:渠道 = Telegram,收件人 = 群组 A,继承会话线程
   → 解析时带上原会话的线程 ID
   → 消息发到群组 A 的原线程,上下文连贯

   开关可控:
   继承 = true(默认):带原线程
   继承 = false:不带原线程,发新消息
```

### 为什么投递失败不阻塞调度

```
阻塞设计:
   投递失败 ──► 调度层等待重试 ──► 阻塞下一次触发
   → 渠道抖动会让整个调度停摆 → 任务积压

非阻塞设计:
   投递失败 ──► 失败结果回传调度层 ──► 调度层继续装填下一次触发
   → 渠道抖动只影响本次投递,不影响调度
   → 失败通知按账号路由,重试由调度层根据重试分类决定
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/00-overview.md) | 定时任务组件全景 |
| [01-schedule-service.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/01-schedule-service.md) | 调度与服务 |
| [02-store-schema.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/02-store-schema.md) | 存储与 Schema |
| [03-delivery-retry.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/03-delivery-retry.md) | 本文件 — 投递与重试 |
| [04-cron-exit-watchers.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.2-cron/04-cron-exit-watchers.md) | 退出监控 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 投递执行 | [src/cron/delivery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery.ts) |
| 投递计划 | [src/cron/delivery-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-plan.ts) |
| 投递默认值 | [src/cron/delivery-defaults.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-defaults.ts) |
| 投递字段 Schema | [src/cron/delivery-field-schemas.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-field-schemas.ts) |
| 投递渠道校验 | [src/cron/delivery-channel-validation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-channel-validation.ts) |
| 投递目标校验 | [src/cron/delivery-target-validation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-target-validation.ts) |
| 投递预览 | [src/cron/delivery-preview.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-preview.ts) |
| 投递上下文 | [src/cron/delivery-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery-context.ts) |
| 重试分类 | [src/cron/retry-hint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/retry-hint.ts) |
| 失败通知测试 | [src/cron/delivery.failure-notify.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/delivery.failure-notify.test.ts) |
| 隔离 Agent 投递目标 | [src/cron/isolated-agent/delivery-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/isolated-agent/delivery-target.ts) |
| 隔离 Agent 投递感知 | [src/cron/isolated-agent/delivery-dispatch-awareness.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/isolated-agent/delivery-dispatch-awareness.ts) |
| 隔离 Agent 投递策略 | [src/cron/isolated-agent/delivery-dispatch-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/isolated-agent/delivery-dispatch-policy.ts) |
| 隔离 Agent 投递分发 | [src/cron/isolated-agent/delivery-dispatch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/isolated-agent/delivery-dispatch.ts) |
| 会话目标 | [src/cron/session-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/session-target.ts) |
| 任务运行详情 | [src/cron/task-run-detail.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/task-run-detail.ts) |
| 运行诊断 | [src/cron/run-diagnostics.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/run-diagnostics.ts) |
| 运行诊断归一化 | [src/cron/run-diagnostics-normalize.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/run-diagnostics-normalize.ts) |
| 运行错误原因 | [src/cron/run-error-reason.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/run-error-reason.ts) |
| 执行错误常量 | [src/cron/execution-error-constants.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cron/execution-error-constants.ts) |
