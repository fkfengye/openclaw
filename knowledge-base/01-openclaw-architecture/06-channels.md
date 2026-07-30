# 06 — 通道系统

> 通道系统是 OpenClaw 与外部世界对话的"收发室":所有渠道消息在这里被判定、路由、持久化、防死循环。读完本章你将理解一条消息如何从 Telegram 进入、如何被决定处理策略、如何避免 bot 互相触发死循环。

## 一句话定位

通道系统是核心实现,负责消息回合(Turn)的完整生命周期:
- 入站消息先经"入站认领"决定处理策略(4 种 Admission:派发 / 仅观察 / 已处理 / 丢弃)
- 被派发的消息走 Turn 内核:组装 → 调度 → 执行,全程持久化投递防丢失
- 通道插件保持 transport-only:只做渲染 / 传输限制 / 回调映射,不拥有产品命令树
- DM 安全默认为 pairing 模式,未知发送者必须先完成配对码审批

## 全局协作图

下图展示一条入站消息从外部渠道到回复发出的完整协作链路。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      外部渠道平台                                   │
│                                                                      │
│   Telegram    Slack    Discord    WhatsApp    iMessage    25+ 渠道   │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 消息入站
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      通道插件(transport-only)                     │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ DM 配对门   │  │ 展示渲染器  │  │ 传输限制器  │  │ 回调映射器│ │
│   │ (默认       │  │ (通用动作 → │  │ (渠道长度 / │  │ (渠道回调 │ │
│   │  pairing)   │  │  渠道格式)  │  │  字段限制)  │  │  → 通用)  │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   约束:不拥有产品命令树 / 插件策略 / 功能菜单                     │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ① 入站认领
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      Turn 内核(消息回合核心)                      │
│                                                                      │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  Admission 判别器(discriminated union)                    │  │
│   │                                                             │  │
│   │   ┌──────────┐  ┌────────────┐  ┌─────────┐  ┌────────┐  │  │
│   │   │ dispatch │  │observeOnly │  │ handled │  │  drop  │  │  │
│   │   │ (派发    │  │ (仅观察,   │  │ (已处理,│  │ (丢弃, │  │  │
│   │   │  给 agent)│  │  不触发)   │  │  如配对)│  │  如死环)│  │  │
│   │   └──────────┘  └────────────┘  └─────────┘  └────────┘  │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 回合生命    │  │ 持久化投递器│  │ Bot 循环    │  │ 传输 stall │ │
│   │ 周期编排    │  │ (防消息    │  │ 保护器      │  │ 检测器     │ │
│   │ (组装→调度 │  │  丢失)     │  │ (防互相    │  │ (防传输    │ │
│   │  →执行)    │  │             │  │  触发死循环)│  │  卡死)     │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ② 派发给 Agent 运行时
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      Agent 运行时(见第 04 章)                    │
│                                                                      │
│   Runner 编排 → Provider 调 LLM → Tool 调用 → 终态归一化 → 回复     │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ③ 回复派发
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      回复分发链路                                   │
│                                                                      │
│   回复派发 Hook → 回复发送 Hook → 传输层 → 通道插件 → 外部渠道       │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

通道系统由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Turn 内核** | 消息回合的核心编排,判别 Admission、组装 / 调度 / 执行回合 | 用 discriminated union 表达 4 种 Admission,让 impossible states 不可表示 |
| **入站认领器** | 插件认领消息,决定走哪种 Admission 策略 | 是 dispatch / observeOnly / handled / drop 的决策点 |
| **持久化投递器** | 消息持久化后再投递,投递失败可重试 | 防消息丢失,先落库再发 |
| **Bot 循环保护器** | 检测 agent 回复是否触发另一 agent 形成循环 | 命中循环则丢弃(drop) |
| **传输 stall 检测器** | 检测传输层发送是否超时卡死 | 超时则中断并标记失败 |
| **DM 配对门** | 未知发送者默认触发 pairing code,需审批后加入 allowlist | 默认 pairing 模式,公开 DM 需显式 opt-in |

## 关联关系

### 4 种 Admission 策略(核心决策点)

```
                  入站消息到达
                       │
                       ▼
            ┌─────────────────────┐
            │  入站认领器         │
            │  (插件认领消息)    │
            └──────────┬──────────┘
                       │
                       ▼
            ┌─────────────────────┐
            │  Admission 判别器   │
            │  (discriminated    │
            │   union)           │
            └──────────┬──────────┘
                       │
      ┌────────────────┼────────────────┐
      │                │                │
      ▼                ▼                ▼
 ┌─────────┐    ┌─────────────┐   ┌─────────┐
 │ dispatch│    │ observeOnly │   │ handled │
 └────┬────┘    └──────┬──────┘   └────┬────┘
      │                │               │
      ▼                ▼               ▼
 ┌──────────┐   ┌────────────┐   ┌────────────┐
 │ 派发给   │   │ 仅观察     │   │ 已处理     │
 │ agent    │   │ (不触发    │   │ (如配对码  │
 │ 走运行时 │   │  agent     │   │  命中)     │
 │          │   │  turn)     │   │ 不再走     │
 │          │   │            │   │ agent      │
 └──────────┘   └────────────┘   └────────────┘

      第 4 种:drop(丢弃)
      ┌─────────────────────────────────────┐
      │  drop                               │
      │  触发场景:                         │
      │   • Bot 循环保护命中(防死循环)    │
      │   • 被禁止的内容                   │
      │   • 其他丢弃规则                   │
      └─────────────────────────────────────┘
```

### 为什么用 discriminated union 而非 freeform string

```
错误设计:用字符串标识策略
   if (admission === "dispatch") { ... }
   else if (admission === "observe") { ... }
   → 拼写错误运行时才暴露
   → 漏掉分支不会报错
   → 新增策略容易遗漏某处处理

正确设计:discriminated union
   admission.kind === "dispatch"  → 编译期检查完备性
   admission.kind === "observeOnly"
   admission.kind === "handled"
   admission.kind === "drop"
   → 漏掉分支编译失败
   → 让 impossible states 不可表示
   → 新增策略强制处理所有分支
```

### 通道插件边界(transport-only)

```
   ┌──────────────────────────────────────────────────────────┐
   │  通道插件能做(transport-only):                        │
   │                                                        │
   │   • 渲染 portable presentation/actions                 │
   │     (把通用动作渲染为渠道特定格式)                    │
   │   • 强制 transport limits                              │
   │     (如 Telegram 消息长度、Discord embed 字段)         │
   │   • 映射 native callback envelopes                     │
   │     (把渠道回调转为通用格式)                          │
   │   • DM pairing 流程(channel 特定实现)                │
   └──────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │  通道插件不能做:                                       │
   │                                                        │
   │   • 拥有产品命令树(由 core/owner 插件声明)           │
   │   • 决定 plugin/provider policy(由 core 决定)        │
   │   • 拥有 feature-specific menus                        │
   │   • 通过 raw string inference 判断命令                 │
   │     (不允许"如果 value 以 / 开头就是命令")            │
   │   • 特殊处理产品字符串                                 │
   │     (approval/command/URL/web-app/select action        │
   │      必须在 channel encoding 前就可区分)              │
   └──────────────────────────────────────────────────────────┘

   正确的命令动作流转:
   ┌──────────────────────────────────────────────────────────┐
   │  core/owner 插件                                       │
   │     声明 command actions(typed presentation actions)  │
   │              │                                         │
   │              ▼                                         │
   │     [通用动作类型]                                     │
   │              │                                         │
   │              ▼                                         │
   │  channel 插件                                          │
   │     把通用动作映射为渠道特定格式(when supported)     │
   └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 一条入站消息的完整旅程

下面追踪一条 Telegram 用户消息从入站到回复发出的全过程。

```
用户在 Telegram 发了 "帮我分析这张图"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 通道插件(transport-only)                                 │
│    Telegram 插件收到 Bot 平台推送                           │
│    → 转成 OpenClaw 内部消息格式                             │
│    → DM 配对门检查发送者:                                  │
│      ├─ 已在 allowlist → 放行                              │
│      ├─ 未知发送者 → 触发 pairing code,不处理              │
│      └─ pairing 模式默认,公开需显式 opt-in                │
│    → 传输限制器检查消息长度等                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 入站认领器                                                │
│    插件认领消息,返回 Admission 策略:                       │
│    ├─ dispatch      → 走 Agent(本例)                      │
│    ├─ observeOnly   → 仅观察,不触发 agent turn             │
│    ├─ handled       → 插件已自行处理(如配对码命中)        │
│    └─ drop          → 丢弃                                 │
└────────────────────────────┬─────────────────────────────────┘
                             │ (dispatch)
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Turn 内核                                                 │
│    生命周期间守卫检查:                                      │
│    → prepared turn 必须声明生命周期                         │
│    → 生命周期必须拥有 top-level turn adoption 生命周期      │
│    → 防止生命周期错配                                       │
│                                                              │
│    回合编排:组装 → 调度 → 执行                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 持久化投递器                                              │
│    消息持久化后再投递(防丢失)                             │
│    → 先写状态库,再派发给 Agent                            │
│    → 投递失败可重试                                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Agent 运行时(见第 04 章)                                │
│    Runner 编排 → Provider 调 LLM → Tool 调用 → 终态归一化   │
│    → 产出回复                                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. Bot 循环保护器                                            │
│    检测回复是否触发另一 agent:                              │
│    ├─ agent 回复 → 另一 bot 收到 → 另一 agent 触发?        │
│    ├─ 若形成循环 → 丢弃(drop)                             │
│    └─ 不形成循环 → 放行                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. 回复分发链路                                              │
│    回复派发 Hook → 回复发送 Hook                            │
│    → 传输 stall 检测器监控发送是否卡死                      │
│    → 通道插件把回复渲染为 Telegram 格式                     │
│    → Telegram 插件把回复发到用户                            │
└──────────────────────────────────────────────────────────────┘
                             │
                             ▼
                  用户看到回复
```

### DM 配对的安全流程

```
未知发送者首次发消息
         │
         ▼
┌──────────────────────────────────────────────┐
│  DM 配对门(默认 pairing 模式)              │
│                                              │
│  检查发送者是否在 allowlist:                │
│   ├─ 不在 → 触发 pairing code               │
│   │         bot 不处理消息                  │
│   │         发送者收到配对码                 │
│   │                                         │
│   └─ 在 → 放行,走正常流程                  │
└──────────────────┬───────────────────────────┘
                   │ (不在 allowlist)
                   ▼
┌──────────────────────────────────────────────┐
│  管理员审批                                  │
│  openclaw pairing approve <channel> <code>   │
│  → 加入本地 allowlist                        │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│  后续消息                                    │
│  发送者已在 allowlist → 直接放行             │
└──────────────────────────────────────────────┘

安全默认:
 • pairing 模式是默认,防止未知发送者触发 agent
 • 公开 DM 需显式 opt-in:dmPolicy: "open" + "*" 在 allowFrom
 • openclaw doctor 可检测危险的 DM 配置
```

## 关键设计约束

### 1. 通道插件保持 transport-only

- **为什么**:通道插件只负责把通用动作映射到渠道特定格式,不应拥有产品逻辑。否则每个渠道都会重复实现命令树 / 策略 / 菜单,且渠道间行为不一致。
- **怎么做**:通道插件只做渲染 portable presentation/actions、强制 transport limits、映射 native callback envelopes;产品命令树、插件 / Provider 策略、功能菜单由 core / owner 插件声明。
- **影响**:新增渠道只需实现传输映射,不用重写产品逻辑;但要求 core 用 typed presentation actions 声明命令,不能用 raw string inference 让通道猜。

### 2. Admission 用 discriminated union

- **为什么**:消息处理策略有 4 种明确互斥的状态(dispatch / observeOnly / handled / drop),用 freeform string 表达容易拼写错误、漏掉分支、运行时才暴露。
- **怎么做**:用 discriminated union,kind 字段区分 4 种策略;TypeScript 编译期检查完备性,漏掉分支编译失败。
- **影响**:新增策略强制处理所有分支;让 impossible states 不可表示;但要求所有调用方都用类型守卫而非字符串比较。

### 3. 持久化投递防消息丢失

- **为什么**:消息先派发再持久化会导致进程崩溃时消息丢失;先持久化再派发可保证可重试。
- **怎么做**:消息先写状态库,再派发给 Agent;投递失败可从状态库重试。
- **影响**:消息不丢失,但增加了写库开销;需要重试机制处理投递失败。

### 4. Bot 循环保护防死循环

- **为什么**:多个 bot 互相触发会形成死循环(bot A 回复触发 bot B,bot B 回复触发 bot A),耗尽资源。
- **怎么做**:Bot 循环保护器检测 agent 回复是否触发另一 agent,命中循环则丢弃(drop)。
- **影响**:防止资源耗尽;但可能误判正常的多 agent 协作,需要精确的循环检测算法。

### 5. 传输 stall 检测防卡死

- **为什么**:传输层可能因网络问题或渠道平台故障卡死,导致回复永远发不出去。
- **怎么做**:传输 stall 检测器监控发送是否超时,超时则中断并标记失败。
- **影响**:避免无限等待;但需要合理的超时阈值,过短会误杀慢请求。

### 6. DM 安全默认 pairing

- **为什么**:如果默认允许任何发送者触发 agent,bot 会被滥用(垃圾消息、未授权访问)。
- **怎么做**:默认 pairing 模式,未知发送者收到配对码,管理员审批后加入 allowlist;公开 DM 需显式 opt-in。
- **影响**:默认安全;但新用户需要审批才能使用,增加了运维门槛。

## 设计观察

### 为什么命令动作用 typed presentation 而非字符串推断

```
错误设计:通道插件用字符串推断命令
   if (value.startsWith("/")) {
     // 当作命令处理
   }
   → 通道插件特殊处理产品字符串
   → approval / command / URL / web-app / select 混在一起
   → 渠道间行为不一致
   → 新增渠道要重复实现推断逻辑

正确设计:core 声明 typed presentation actions
   core/owner 插件
     声明 command actions(typed)
              │
              ▼
     [通用动作类型]
     • approval action
     • command action
     • URL action
     • web-app action
     • select action
              │
              ▼
   channel 插件
     把通用动作映射为渠道特定格式(when supported)
   → 动作类型在 channel encoding 前就可区分
   → 通道插件不特殊处理产品字符串
   → 新增渠道只需实现映射,不用推断
```

### 为什么 Turn 内核要生命周期守卫

```
错误设计:prepared turn 不声明生命周期
   Turn 内核
   └─ 执行 prepared turn
      → 生命周期可能错配
      → top-level turn adoption 生命周期与 turn 内部不一致
      → 运行时才暴露问题,难排查

正确设计:守卫强制声明生命周期
   Turn 内核
   ├─ 守卫:prepared turn 必须声明 runDispatchLifecycle
   ├─ 守卫:必须拥有 top-level turnAdoptionLifecycle
   └─ 错配则立即抛错
   → 生命周期错配在启动期就暴露
   → 防止运行时状态不一致
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
| [06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/06-channels.md) | 本文件 — 通道系统 |
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Turn 内核(回合核心) | [src/channels/turn/kernel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/kernel.ts) |
| 回合生命周期编排 | [src/channels/turn/lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/lifecycle.ts) |
| 回合执行 | [src/channels/turn/execution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/execution.ts) |
| 持久化投递器 | [src/channels/turn/durable-delivery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/durable-delivery.ts) |
| Bot 循环保护器 | [src/channels/turn/bot-loop-protection.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/bot-loop-protection.ts) |
| 历史窗口 | [src/channels/turn/history-window.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/history-window.ts) |
| 消息回合护栏 | 已删除,拆解到各 extension 本地实现(见 `src/channels/turn/message-turn-guardrails.test.ts` 迁移清单) |
| 传输 stall 检测器 | [src/channels/transport/stall-watchdog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/transport/stall-watchdog.ts) |
| DM 配对门 | [src/channels/plugins/pairing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/pairing.ts) |
| DM 配对适配 | [src/channels/plugins/pairing-adapters.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/pairing-adapters.ts) |
| DM 访问控制 | [src/channels/plugins/dm-access.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/dm-access.ts) |
| 线程绑定 API | [src/channels/plugins/thread-binding-api.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/thread-binding-api.ts) |
| 出站加载 | [src/channels/plugins/outbound/load.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/outbound/load.ts) |
| 展示限制 | [src/channels/plugins/outbound/presentation-limits.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/outbound/presentation-limits.ts) |
| 消息动作 | [src/channels/plugins/message-action-discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/plugins/message-action-discovery.ts) |
| 运行状态机 | [src/channels/run-state-machine.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/run-state-machine.ts) |
| 路由投影 | [src/channels/route-projection.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/route-projection.ts) |
| Hook:入站认领 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runInboundClaim) |
| Hook:回复派发 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runReplyDispatch) |
| Hook:回复发送 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runReplyPayloadSending) |
| 通道目录边界规则 | [src/channels/AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/AGENTS.md) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
