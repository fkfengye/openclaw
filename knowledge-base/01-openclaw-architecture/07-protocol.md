# 07 — Gateway 协议与 Schema

> 协议是 OpenClaw 客户端与服务端之间的"契约层":所有跨进程通信都走自研 WebSocket 协议,由 TypeBox Schema 严格定义。读完本章你将理解协议版本如何演进、13 个 Schema 分片如何组合、为什么版本 bump 是重大决策。

## 一句话定位

Gateway 协议是客户端与服务端之间的**唯一契约**:
- 自研 WebSocket 协议,用 TypeBox Schema 定义所有消息格式(非 freeform string)
- 13 个 Schema 分片按领域拆分(传输 / 会话 / 调度 / 插件 / 通道 / 审批等),组合器拼成完整协议
- 协议变更优先 additive(向后兼容),不兼容变更需版本 bump + 文档 + 客户端跟进
- 版本 bump 不可自动生成,需 owner 显式确认;子包独立于核心 session 类型,可独立演进

## 全局协作图

下图展示协议层如何把客户端与服务端解耦,以及 Schema 如何分片组合。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      客户端(CLI / UI / App / Bot)                  │
│                                                                      │
│   按 PROTOCOL_VERSION = 4 发送 / 接收消息帧                         │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ WebSocket 帧(TypeBox Schema 校验)
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      Gateway 服务端                                 │
│                                                                      │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  协议版本管理器                                              │  │
│   │                                                             │  │
│   │   当前版本:PROTOCOL_VERSION = 4                            │  │
│   │   最低 client 版本:4(与当前一致,发生过 breaking change) │  │
│   │   最低 node 版本:3(更稳定,演进慢)                       │  │
│   │   最低 probe 版本:3(轻量级,兼容性优先)                  │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  帧守卫 + 校验器注册表                                      │  │
│   │                                                             │  │
│   │   • 帧守卫:校验入站帧结构                                  │  │
│   │   • 协议校验器:校验消息内容合规                            │  │
│   │   • 终端校验器 / 审批结果校验器 / 校验错误格式化            │  │
│   └─────────────────────────────────────────────────────────────┘  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 引用 Schema
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      协议子包(独立于核心)                         │
│                                                                      │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  13 个 Schema 分片(按领域拆分)                            │  │
│   │                                                             │  │
│   │   传输  会话生命周期  会话核心  会话协作                    │  │
│   │   调度器  插件生命周期  操作  节点                          │  │
│   │   集成  通道  看板  审批  Agent 技能  Agent 控制            │  │
│   └────────────────────────────┬────────────────────────────────┘  │
│                                │                                     │
│                                │ 组合                                │
│                                ▼                                     │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  Schema 组合器                                              │  │
│   │  (把 13 个分片拼成完整协议 schema)                         │  │
│   └────────────────────────────┬────────────────────────────────┘  │
│                                │                                     │
│                                ▼                                     │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │  完整协议 Schema + 40+ 领域 Schema + 迁移 API               │  │
│   │  (会话 / Agent / Cron / 通道 / 节点 / 审批 / 审计 / 看板)  │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   约束:子包不依赖核心 session 类型,可独立演进                    │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

协议层由 5 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **协议版本管理器** | 定义当前版本与各类客户端最低接受版本 | 版本 bump 需 owner 显式确认,不可自动生成 |
| **Schema 组合器** | 把 13 个分片拼成完整协议 schema | 分片按领域拆分,避免单文件巨型 schema |
| **13 个 Schema 分片** | 按领域定义消息格式(传输 / 会话 / 调度 / 插件等) | 用 TypeBox,非 freeform string |
| **校验器注册表** | 注册协议校验器、终端校验器、审批结果校验器 | 帧守卫 + 内容校验双层 |
| **迁移 API** | 协议版本演进时的迁移接口 | additive first,不兼容需版本 bump + 文档 + 客户端跟进 |

## 关联关系

### 协议版本兼容矩阵

```
                    Gateway 服务端
                    PROTOCOL_VERSION = 4
                         ▲
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   ┌────┴────┐      ┌────┴────┐      ┌────┴────┐
   │ Client  │      │  Node   │      │  Probe  │
   │         │      │         │      │         │
   │ 最低:4  │      │ 最低:3  │      │ 最低:3  │
   │         │      │         │      │         │
   │ 必须 v4 │      │ 兼容    │      │ 兼容    │
   │(与当前  │      │ 到 v3  │      │ 到 v3  │
   │ 一致)   │      │         │      │         │
   └─────────┘      └─────────┘      └─────────┘

   版本演进趋势:
   • Client 协议:v3 → v4(已发生 breaking change)
     → client 协议演进更快,要求严格对齐
   • Node 协议:仍兼容 v3
     → node 协议更稳定,演进慢
   • Probe 协议:仍兼容 v3
     → probe 是轻量级,兼容性优先
```

### Schema 分片的组合关系

```
   13 个分片(按领域拆分)
   ════════════════════

   ┌────────────────┐  ┌────────────────┐
   │ 传输            │  │ 会话生命周期   │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ 会话核心        │  │ 会话协作       │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ 调度器          │  │ 插件生命周期   │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ 操作            │  │ 节点           │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ 集成            │  │ 通道           │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ 看板            │  │ 审批           │
   └────────────────┘  └────────────────┘
   ┌────────────────┐  ┌────────────────┐
   │ Agent 技能      │  │ Agent 控制     │
   └────────────────┘  └────────────────┘
                │
                │ 组合
                ▼
   ┌────────────────────────────────┐
   │  Schema 组合器                 │
   │  (把 13 个分片拼成完整协议)   │
   └────────────────┬───────────────┘
                    │
                    ▼
   ┌────────────────────────────────┐
   │  完整协议 Schema               │
   └────────────────────────────────┘

   40+ 领域 Schema(独立于分片):
   会话 / Agent / Cron / 通道 / 节点 /
   审批 / 审计 / 看板 / 配置 / 迁移 /
   工作树 / Worker / 技能历史 / 任务 /
   系统事件 / 终端 / UI 命令 / 用户 /
   向导 / 快照 / 密钥 / 问题 / 推送 /
   插件 / 日志 / 网关挂起 / 文件系统 /
   帧 / 错误码 / 环境 / 命令 / 工件 ...
```

### 协议变更决策树

```
   想变更协议?
        │
        ▼
   ┌──────────────────────────────────────────────┐
   │ 是 additive(向后兼容)?                    │
   │                                              │
   │  ├─ Yes → 可以直接加,不 bump 版本          │
   │  │         (新字段可选,旧客户端忽略)       │
   │  │                                           │
   │  └─ No  → 继续...                           │
   └──────────────────┬───────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────┐
   │ 是 breaking(不兼容)?                       │
   │                                              │
   │  └─ Yes → 必须 bump 版本                    │
   │      ├─ 需要 owner 显式确认(不可自动生成) │
   │      ├─ 需要更新文档                         │
   │      └─ 需要客户端跟进                       │
   └──────────────────┬───────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────┐
   │ 不确定?                                     │
   │  └─ 默认按 breaking 处理,问 owner          │
   └──────────────────────────────────────────────┘
```

## 协作流程

### 一条协议消息的校验旅程

下面追踪一条客户端消息从入站到被服务端消费的全过程,展示协议层如何校验。

```
客户端发送 WebSocket 帧
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 帧守卫                                                    │
│    校验入站帧结构是否合规                                    │
│    → 帧类型是否在已知集合                                    │
│    → 必填字段是否存在                                        │
│    → 不合规则拒绝连接                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 协议版本检查                                              │
│    检查客户端协议版本是否 >= 对应最低版本:                   │
│    ├─ Client  >= 4                                           │
│    ├─ Node    >= 3                                           │
│    └─ Probe   >= 3                                           │
│    → 版本过低则拒绝                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 协议校验器                                                │
│    用对应领域的 Schema 分片校验消息内容                      │
│    → 会话消息用会话核心分片                                  │
│    → 通道消息用通道分片                                      │
│    → 审批消息用审批分片                                      │
│    → 校验失败则返回格式化错误                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 专项校验器(按需)                                        │
│    ├─ 终端校验器(终端相关消息)                            │
│    └─ 审批结果校验器(审批结果消息)                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 服务端消费                                                │
│    校验通过的消息进入 Gateway 核心                           │
│    → 路由到对应处理器(Agent / 通道 / 插件等)               │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 协议变更优先 additive

- **为什么**:breaking change 会让旧客户端无法工作,增加用户升级负担;additive change(新增可选字段)让旧客户端忽略新字段,新客户端用新字段,平滑过渡。
- **怎么做**:新增字段设为可选,旧字段不删不改语义;不兼容变更(删字段 / 改语义 / 改结构)才 bump 版本。
- **影响**:协议演进平滑;但要求客户端容忍未知字段,不能 strict mode 拒绝。

### 2. 版本 bump 需 owner 显式确认

- **为什么**:协议是跨进程契约,bump 意味着旧客户端必须升级,影响范围大;自动生成的 bump 会让协议演进失控。
- **怎么做**:版本 bump 不可自动生成,必须 owner 显式确认;同时需更新文档 + 客户端跟进。
- **影响**:协议稳定性高;但演进决策慢,需人工把关。

### 3. Schema 用 TypeBox 而非 freeform string

- **为什么**:freeform string 容易拼写错误、无法编译期检查、文档与实现易漂移;TypeBox 提供结构化定义 + 类型推导 + 编译期校验。
- **怎么做**:所有消息格式用 TypeBox 定义;用 discriminated union 表达互斥状态(如 4 种 Admission);让 impossible states 不可表示。
- **影响**:消息格式严格;但要求所有变更都更新 Schema,不能临时加字段。

### 4. Schema 分片按领域拆分

- **为什么**:单文件巨型 schema 难维护、难 review、难定位;按领域拆分让每个分片职责单一。
- **怎么做**:13 个 fragment 按领域拆分(传输 / 会话 / 调度 / 插件 / 通道 / 审批等);组合器拼成完整协议;40+ 领域 schema 独立维护。
- **影响**:每个分片可独立演进;但组合器需保证分片间引用一致。

### 5. 子包独立于核心 session 类型

- **为什么**:如果协议子包依赖核心 session 类型,核心变更会连带协议变更,耦合过紧;独立子包让协议可独立演进、独立引用。
- **怎么做**:子包提供独立的结构化结果类型,不依赖核心 session 类型;核心反向引用协议子包。
- **影响**:协议可独立演进;第三方可仅引用子包做协议校验;但要求子包自给自足,不能反向依赖核心。

### 6. Client / Node / Probe 版本兼容策略不同

- **为什么**:Client 是完整客户端,协议演进快,要求严格对齐;Node 是已认证节点,协议更稳定;Probe 是轻量级探测,兼容性优先。
- **怎么做**:Client 最低版本 4(与当前一致),Node / Probe 最低版本 3;不同客户端类型有不同兼容窗口。
- **影响**:Client 协议演进快但 breaking change 频繁;Node / Probe 协议稳定,演进慢。

## 设计观察

### 为什么用 TypeBox 而非 zod

```
错误设计:用 freeform string 或 zod
   消息格式靠文档描述,运行时靠手写校验
   → 文档与实现易漂移
   → 编译期无法检查消息结构
   → 新增字段容易遗漏校验

正确设计:用 TypeBox
   消息格式用 TypeBox 结构化定义
   → 编译期类型推导(消息字段自动有类型)
   → 运行时校验(Schema 即校验器)
   → discriminated union 让 impossible states 不可表示
   → 比 zod 更轻量,编译期优化更好
```

### 为什么 Schema 要分片而非单文件

```
错误设计:单文件巨型 schema
   protocol-schemas.ts(5000+ LOC)
   ├─ 传输消息
   ├─ 会话消息
   ├─ 通道消息
   ├─ 审批消息
   └─ ... 全部混在一起
   → 难维护,难 review
   → 改一个领域要翻整个文件
   → 冲突频繁

正确设计:13 个分片 + 组合器
   分片:传输 / 会话生命周期 / 会话核心 / 会话协作 /
         调度器 / 插件生命周期 / 操作 / 节点 /
         集成 / 通道 / 看板 / 审批 / Agent 技能 / Agent 控制
   组合器:把分片拼成完整协议
   → 每个分片职责单一,可独立 review
   → 改一个领域只动一个分片
   → 冲突减少
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
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | 本文件 — Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 协议版本管理器 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| 子包入口 | [packages/gateway-protocol/src/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/index.ts) |
| Schema 组合器 | [packages/gateway-protocol/src/schema/protocol-schema-composer.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-composer.ts) |
| 分片:传输 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-transport.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-transport.ts) |
| 分片:会话生命周期 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-sessions-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-sessions-lifecycle.ts) |
| 分片:会话核心 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-sessions-core.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-sessions-core.ts) |
| 分片:通道 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-channels.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-channels.ts) |
| 分片:审批 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-approvals.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-approvals.ts) |
| 分片:Agent 技能 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-agents-skills.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-agents-skills.ts) |
| 分片:Agent 控制 | [packages/gateway-protocol/src/schema/protocol-schema-fragment-agent-control.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schema-fragment-agent-control.ts) |
| 完整协议 Schema | [packages/gateway-protocol/src/schema/protocol-schemas.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/protocol-schemas.ts) |
| 校验器注册表 | [packages/gateway-protocol/src/validator-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/validator-registry.ts) |
| 协议校验器 | [packages/gateway-protocol/src/protocol-validator.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/protocol-validator.ts) |
| 帧守卫 | [packages/gateway-protocol/src/schema/frame-guards.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/frame-guards.ts) |
| 终端校验器 | [packages/gateway-protocol/src/terminal-validators.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/terminal-validators.ts) |
| 审批结果校验器 | [packages/gateway-protocol/src/approval-result-validators.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/approval-result-validators.ts) |
| 校验错误格式化 | [packages/gateway-protocol/src/validation-errors.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/validation-errors.ts) |
| 迁移 API | [packages/gateway-protocol/src/migration-api.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/migration-api.ts) |
| 领域 Schema:会话 | [packages/gateway-protocol/src/schema/sessions.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/sessions.ts) |
| 领域 Schema:帧 | [packages/gateway-protocol/src/schema/frames.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/frames.ts) |
| 领域 Schema:Worker 推理 | [packages/gateway-protocol/src/schema/worker-inference.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/worker-inference.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
