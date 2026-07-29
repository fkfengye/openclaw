# 11 — 评估与风险点

> 本章基于源码证据,实事求是评估 OpenClaw 架构的成熟度、优点与风险。读完本章你将理解架构 strengths 在哪、代价在哪、适合什么场景、二次开发该怎么走。

## 一句话定位

评估章节基于源码证据,对 OpenClaw 架构做总体判断:
- 5 个优点:边界清晰、懒加载贯穿、Schema 严格、测试覆盖广、状态统一为 SQLite
- 8 个风险:文件爆炸、Schema 演进包袱、配置表面巨大、CLI 兼容约束、Codex 强制约束、SDK 表面积、Worker 协议待精读、Cron 子系统复杂
- 适用场景:长期维护的多渠道 AI 助手产品,多人协作;不适合快速原型或单人维护

## 全局协作图

下图展示优点如何支撑架构成熟度,风险如何影响维护成本,二者共同决定适用场景。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      架构优点(Strengths)                            │
│                                                                      │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│   │ 边界清晰 │  │ 懒加载   │  │ Schema   │  │ 测试覆盖 │          │
│   │ 强约束   │  │ 贯穿     │  │ 严格     │  │ 广       │          │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│        │             │             │             │                  │
│        └──────────┬──┴─────────────┴─────────────┘                 │
│                   │              ┌──────────┐                       │
│                   └──────────────│ 状态统一 │                       │
│                                  │ 为 SQLite│                       │
│                                  └────┬─────┘                       │
│                                       │                              │
└───────────────────────────────────────┼──────────────────────────────┘
                                        │
                                        ▼
                        ┌──────────────────────────────┐
                        │     架构成熟度高              │
                        │   (边界清晰 · 行为确定 ·      │
                        │    状态一致 · 类型安全)       │
                        └──────────────┬───────────────┘
                                       │
┌──────────────────────────────────────┼──────────────────────────────┐
│                      架构风险(Costs)                               │
│                                      │                              │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│   │ 文件爆炸 │  │ Schema   │  │ 配置表面 │  │ CLI 兼容 │          │
│   │ 定位成本 │  │ 演进包袱 │  │ 巨大     │  │ 约束     │          │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│        │             │             │             │                  │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                       │
│   │ Codex    │  │ SDK 表面 │  │ Worker / │                       │
│   │ 强制约束 │  │ 积巨大   │  │ Cron 待  │                       │
│   │          │  │          │  │ 精读     │                       │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘                       │
│        │             │             │                               │
│        └─────────────┴─────────────┘                              │
│                      │                                              │
└──────────────────────┼──────────────────────────────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │     维护成本                  │
        │   (上手成本 · 演进受限 ·     │
        │    迁移包袱 · 依赖成本)      │
        └──────────────┬───────────────┘
                       │
                       ▼
        ┌──────────────────────────────────────────┐
        │     适用场景判断                         │
        │                                          │
        │  ✓ 长期多渠道 AI 助手产品                │
        │  ✓ 多人协作、长期演进                    │
        │  ✗ 快速原型(规则太严、边界太硬)       │
        │  ✗ 单人维护(需多角色协作)              │
        └──────────────────────────────────────────┘
```

## 组件清单

评估由 7 类维度构成,每类维度有优点与风险两面:

| 评估对象 | 优点 | 风险 |
|---|---|---|
| **边界体系** | AGENTS.md 强约束,核心插件无关,scoped 子树各有规则 | 文件爆炸(gateway 200+ 文件),定位成本高 |
| **类型体系** | TypeBox + discriminated union,13 fragment 按领域拆分 | Schema 演进包袱(state=6, agent=16,22 代累积迁移) |
| **状态体系** | SQLite 唯一,双层结构,写事务同步 commit,迁移单一 owner | 历史迁移代码累积,任何 schema 变更需考虑 6/16 代路径 |
| **性能体系** | 懒加载贯穿(fast-path + createLazyRuntimeModule + control/runtime 分离) | Codex 双仓库检查成本高,依赖协议变更需亲查上游源码 |
| **扩展体系** | 插件 SDK 边界清晰,插件只通过 SDK 访问核心 | SDK 表面积巨大(数百 runtime 接缝),变更影响外部插件作者 |
| **配置体系** | 三步加载,只读最新 shape,Doctor 单一迁移 owner | 配置表面巨大,CLI setup 是公共 API 契约,演进受限 |
| **可观测体系** | 测试覆盖广(colocated + e2e + contracts),Trace 贯穿 | Worker 协议 / Cron 子系统复杂度未深入精读 |

## 关联关系

### 优点 vs 风险 矩阵

```
    优点(Architecture Strengths)
    ═══════════════════════════════

    ┌──────────────────────────────────────────────────────────────┐
    │ 优点 1: 边界清晰,有 AGENTS.md 强约束                       │
    │ 证据:                                                       │
    │  • 顶层 AGENTS.md 定义全局规则                              │
    │  • 每个 scoped 子树有自己的 AGENTS.md                       │
    │  • "Map" 段明确目录职责与边界规则                           │
    │  • 核心保持插件无关                                          │
    │ 影响: 高(降低耦合,提高可维护性)                          │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 优点 2: 懒加载贯穿                                          │
    │ 证据:                                                       │
    │  • Entry fast-path 拦截 --version / --help                  │
    │  • Gateway 启动用 createLazyRuntimeModule                   │
    │  • 插件分 control plane(light)与 runtime plane(heavy)    │
    │  • 通道 hot path 不静态拉 async-only surfaces               │
    │ 影响: 中高(降低冷启动成本,但增加复杂度)                  │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 优点 3: Schema 严格(TypeBox + discriminated union)         │
    │ 证据:                                                       │
    │  • TypeBox 定义,非 freeform string                         │
    │  • 13 个 fragment 按领域拆分                                │
    │  • ChannelTurnAdmission 用 discriminated union(4 种 kind) │
    │ 影响: 高(让 impossible states 不可表示)                   │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 优点 4: 测试覆盖广                                          │
    │ 证据:                                                       │
    │  • 每个核心模块都有 colocated 测试                          │
    │  • 关键流程有 e2e 测试                                       │
    │  • 专门 contracts 目录做 contract test                     │
    │ 影响: 中高(回归保护强,但测试维护成本)                    │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 优点 5: 状态统一为 SQLite                                  │
    │ 证据:                                                       │
    │  • 禁止 JSON/JSONL/TXT/sidecar 文件存运行时状态             │
    │  • 双层结构清晰(共享 + per-agent)                         │
    │  • 写事务同步 commit 约束严格                                │
    │  • 迁移单一 owner(Doctor),无 dual-write                  │
    │ 影响: 高(杜绝散落状态,数据一致性强)                      │
    └──────────────────────────────────────────────────────────────┘


    风险(Architecture Costs)
    ═══════════════════════════════

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 1: 文件爆炸,定位成本高                                │
    │ 严重度: 高                                                  │
    │ 证据:                                                       │
    │  • gateway 下 server-*.ts 已超 200 个文件                  │
    │  • server-startup-*.ts 单独文件 15+ 个                      │
    │  • plugins 下数百文件                                       │
    │  • plugin-sdk 数百个 *-runtime.ts 文件                      │
    │ 矛盾:                                                       │
    │  • AGENTS.md 规定 ~700 LOC 拆分,实际远小于此               │
    │ 影响:                                                       │
    │  • 新开发者上手需建立"文件命名前缀 → 职责"映射             │
    │  • 定位特定功能需多次 grep                                  │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 2: Schema 演进包袱                                     │
    │ 严重度: 中                                                 │
    │ 证据:                                                       │
    │  • state=6, agent=16(22 次版本演进)                      │
    │  • 累积迁移代码可观(多个 migration / backfills 文件)     │
    │ 缓解:                                                       │
    │  • AGENTS.md 不允许 agent 自主 bump schema 版本             │
    │  • 纯 additive 不 bump,下次自然 bump 合并                   │
    │ 影响:                                                       │
    │  • 任何 schema 变更需考虑 6/16 代迁移路径                   │
    │  • 迁移代码维护成本累积                                      │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 3: 配置表面巨大                                       │
    │ 严重度: 中                                                 │
    │ 证据:                                                       │
    │  • AGENTS.md 自己承认配置 + env vars 已很大                 │
    │  • config-*.ts 8 个 + server-reload-*.ts 8 个文件           │
    │  • 新增 config option 需先证明现有行为无法解决              │
    │ 影响:                                                       │
    │  • 配置项难以简化                                            │
    │  • 新增需高门槛证明                                          │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 4: CLI 兼容约束                                       │
    │ 严重度: 中                                                 │
    │ 证据:                                                       │
    │  • onboard / configure 是公共 API 契约                      │
    │  • 外部 docs/installers/integrations 可能复制               │
    │  • 变更需 additive flags + 弃号窗口                         │
    │ 影响:                                                       │
    │  • 长期演进受限                                              │
    │  • 无法轻易 breaking change                                 │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 5: Codex 强制约束                                     │
    │ 严重度: 高                                                  │
    │ 证据:                                                       │
    │  • AGENTS.md: Codex 相关工作必须 agent 亲自检查上游源码     │
    │  • subagent 报告、PR 文本、wrapper 都不满足 gate            │
    │  • 必须克隆上游 Codex 仓库才能 verdict                      │
    │ 影响:                                                       │
    │  • 依赖 Codex 协议的变更成本极高                            │
    │  • 需双仓库同步检查                                          │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 6: SDK 表面积巨大                                     │
    │ 严重度: 中                                                 │
    │ 证据:                                                       │
    │  • plugin-sdk 数百个 *-runtime.ts 文件                       │
    │  • 每个 *-runtime.ts 都是 SDK 接缝                           │
    │  • shipped external API 需 new API + compat/deprecation      │
    │ 影响:                                                       │
    │  • SDK 变更影响外部插件作者                                 │
    │  • 需保持向后兼容 + deprecation 窗口                        │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 7: Worker 协议未深入                                  │
    │ 严重度: 低(待精读)                                       │
    │ 证据:                                                       │
    │  • worker-inference / worker-admission / worker-protocol    │
    │  • worker-environment-startup / worker-placement-startup    │
    │ 待精读:                                                     │
    │  • worker 通信协议                                          │
    │  • placement 算法                                           │
    │  • environment 隔离细节                                     │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────┐
    │ 风险 8: Cron 子系统复杂                                    │
    │ 严重度: 低(待精读)                                       │
    │ 证据:                                                       │
    │  • server-cron-*.ts 7 个文件                                │
    │  • 多个测试 helper 与 interleavings 测试                    │
    │ 待精读:                                                     │
    │  • Cron 任务的持久化                                        │
    │  • 重启恢复路径                                             │
    └──────────────────────────────────────────────────────────────┘
```

### 适用场景判断图

```
    项目适用性评估
    ═════════════

    你的项目特征?
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 长期维护的多渠道 AI 助手产品?                          │
    │                                                          │
    │  ├─ Yes → 适合                                           │
    │  │       理由:                                          │
    │  │       • 边界清晰利于长期演进                          │
    │  │       • 状态统一利于数据一致                          │
    │  │       • 测试覆盖利于回归保护                          │
    │  │       • 插件架构利于扩展                             │
    │  │                                                      │
    │  └─ No → 继续...                                         │
    └──────────────────┬───────────────────────────────────────┘
                       ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 快速原型?                                                │
    │                                                          │
    │  ├─ Yes → 不适合                                         │
    │  │       理由:                                          │
    │  │       • 规则太严(AGENTS.md 强约束)                 │
    │  │       • 边界太硬(插件 SDK 限制)                    │
    │  │       • 启动流程复杂(5 阶段)                       │
    │  │       • 配置门槛高(需证明无法用现有行为解决)       │
    │  │                                                      │
    │  └─ No → 继续...                                         │
    └──────────────────┬───────────────────────────────────────┘
                       ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 单人维护?                                                │
    │                                                          │
    │  ├─ Yes → 不适合                                         │
    │  │       理由:                                          │
    │  │       • 规则要求多角色协作(owner、maintainer、      │
    │  │         reviewer)                                    │
    │  │       • Codex gate 需双仓库检查                      │
    │  │       • Schema bump 需 owner 显式确认                 │
    │  │       • 协议 bump 需 owner 显式确认                  │
    │  │                                                      │
    │  └─ No → 继续...                                         │
    └──────────────────┬───────────────────────────────────────┘
                       ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 多人协作、长期演进的项目?                                │
    │                                                          │
    │  ├─ Yes → 适合                                           │
    │  │       理由:                                          │
    │  │       • AGENTS.md 强约束降低协作冲突                 │
    │  │       • 边界清晰利于分工                             │
    │  │       • 测试覆盖利于回归                             │
    │  │       • 懒加载利于性能                               │
    │  │                                                      │
    │  └─ No → 重新评估需求                                   │
    └──────────────────────────────────────────────────────────┘
```

### 二次开发决策树

```
    想对 OpenClaw 做二次开发?
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 开发类型?                                               │
    │                                                          │
    │ ├─ 新增插件(渠道/工具)                                │
    │ │   └─ 走标准路径                                        │
    │ │       ├─ extensions/<id>/                              │
    │ │       ├─ 通过 plugin-sdk 调用核心                     │
    │ │       ├─ 不碰核心 src/**                              │
    │ │       └─ manifest metadata 声明能力                   │
    │ │                                                      │
    │ ├─ 修改核心                                             │
    │ │   └─ 高成本                                           │
    │ │       ├─ 先读对应 scoped AGENTS.md                   │
    │ │       ├─ 默认 clean bounded refactor(非最小 patch)   │
    │ │       ├─ Move ownership to right boundary             │
    │ │       └─ Delete stale abstractions / duplicate policy │
    │ │                                                      │
    │ ├─ 新增配置 option                                      │
    │ │   └─ 高门槛                                           │
    │ │       ├─ 先证明现有产品行为无法解决                   │
    │ │       ├─ 先证明 provider selection 无法解决           │
    │ │       ├─ 先证明 defaults 无法解决                    │
    │ │       ├─ 先证明 doctor migration 无法解决            │
    │ │       └─ 优先移除/合并现有 option,而非新增           │
    │ │                                                      │
    │ ├─ 数据库变更                                           │
    │ │   └─ 严格管控                                          │
    │ │       ├─ 纯 additive(新表,旧版本仍能工作)         │
    │ │       │   → 不 bump schema version                   │
    │ │       │   → 在 canonical schema 文件声明             │
    │ │       │   → 首次使用时 lazy ensure                   │
    │ │       │   → 下次自然 bump 合并 migration path        │
    │ │       │                                              │
    │ │       └─ 破坏性(旧 reader 无法容忍)                │
    │ │           → 必须 bump schema version                │
    │ │           → 需要 explicit user discussion            │
    │ │           → 需要 acceptance before implementation    │
    │ │           → Agents must not advance autonomously     │
    │ │                                                      │
    │ └─ 协议变更                                             │
    │     └─ 严格管控                                          │
    │         ├─ 优先 additive(向后兼容)                   │
    │         ├─ Breaking → 必须 bump 版本                   │
    │         │   → 需要 owner 显式确认(不可自动生成)      │
    │         │   → 需要更新 docs                             │
    │         │   → 需要 client follow-through                │
    │         └─ 不确定 → 默认按 breaking 处理,问 owner     │
    └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 如何判断 OpenClaw 是否适合你的项目

下面追踪一个技术决策者评估 OpenClaw 适用性的完整流程,标注每步由哪个评估维度负责。

```
技术决策者评估 OpenClaw
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 边界体系评估                                              │
│    项目是否需要多渠道接入?                                   │
│    ├─ Yes → OpenClaw 的边界体系是优点                       │
│    │        (25+ 渠道插件,核心插件无关)                    │
│    └─ No → 边界体系可能过度设计                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 状态体系评估                                              │
│    项目是否需要强数据一致性?                                 │
│    ├─ Yes → SQLite 唯一 + 写事务同步 commit 是优点          │
│    └─ No → 状态约束可能过严                                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 类型体系评估                                              │
│    项目是否需要类型安全 + 协议严格?                         │
│    ├─ Yes → TypeBox + discriminated union 是优点            │
│    └─ No → Schema 严格度可能不必要                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 团队规模评估                                              │
│    团队是否有多人协作 + 多角色?                             │
│    ├─ Yes → AGENTS.md 强约束降低协作冲突                    │
│    └─ No → 单人维护成本高(需多角色协作)                   │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 维护周期评估                                              │
│    项目是否长期维护?                                         │
│    ├─ Yes → 边界清晰 + 测试覆盖利于长期演进                 │
│    └─ No → 快速原型不适合(规则太严、启动复杂)             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 依赖评估                                                  │
│    项目是否依赖 Codex 协议?                                 │
│    ├─ Yes → 需双仓库检查,变更成本高                        │
│    └─ No → 无此约束                                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. 综合判断                                                  │
│    优点维度匹配数 ≥ 4 且风险维度可接受?                    │
│    ├─ Yes → 适合采用                                        │
│    └─ No → 重新评估或寻找更轻量方案                         │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 边界清晰度是核心评估维度

- **为什么**:边界清晰是 OpenClaw 架构的最大优点,也是所有规则的基石
- **怎么做**:评估时先看核心是否插件无关、scoped AGENTS.md 是否到位、SDK 边界是否严格
- **影响**:边界清晰的代价是文件拆分过细,需权衡可维护性与上手成本

### 2. 状态统一度决定数据一致性

- **为什么**:SQLite 唯一 + 写事务同步 commit 是数据一致性的保证
- **怎么做**:评估时检查是否有散落状态文件、是否有 dual-write、是否有 await in transaction
- **影响**:状态统一的代价是 Schema 演进包袱,需权衡一致性与迁移成本

### 3. Schema 严格度决定行为可预测性

- **为什么**:TypeBox + discriminated union 让 impossible states 不可表示
- **怎么做**:评估时检查是否有 freeform string、parallel nullable fields、semantic sentinels
- **影响**:Schema 严格的代价是 22 代演进包袱,需权衡类型安全与维护成本

### 4. 测试覆盖度决定回归保护

- **为什么**:colocated + e2e + contracts 三层测试是回归保护的保证
- **怎么做**:评估时检查核心模块是否有测试、关键流程是否有 e2e
- **影响**:测试覆盖的代价是测试维护成本,需权衡保护强度与维护投入

### 5. 懒加载贯穿度决定冷启动性能

- **为什么**:fast-path + createLazyRuntimeModule + control/runtime 分离降低冷启动
- **怎么做**:评估时检查 entry fast-path 是否拦截、插件是否分 control/runtime plane
- **影响**:懒加载的代价是复杂度增加,需权衡性能与可理解性

## 设计观察

### 为什么适合长期多渠道产品而非快速原型

```
长期多渠道产品(适合):
   • 边界清晰 → 多人协作不冲突
   • 状态统一 → 数据一致性强
   • 测试覆盖 → 回归保护好
   • 插件架构 → 扩展新渠道不改核心
   • Schema 严格 → 协议演进可控

   好处:
   • 长期演进成本可控
   • 多渠道接入标准化
   • 团队协作有规则可循

快速原型(不适合):
   • 规则太严 → 每个改动需读 AGENTS.md
   • 边界太硬 → 不能快速 hack 核心
   • 启动复杂 → 5 阶段启动流程
   • 配置门槛高 → 新增 config 需高门槛证明
   • Schema bump 需 owner 确认 → 不能随意改

   后果:
   • 原型迭代速度慢
   • 规则约束与快速验证矛盾
   • 单人无法承担多角色要求
```

### 为什么适合多人协作而非单人维护

```
多人协作(适合):
   • AGENTS.md 强约束 → 降低协作冲突
   • scoped AGENTS.md → 每个子树有规则
   • CODEOWNERS → 明确 ownership
   • ClawSweeper review → 自动化审查
   • 验证门槛高 → 防止低质量合并

   好处:
   • 多人可并行开发不同子树
   • review 有规则可循
   • 合并质量有保证

单人维护(不适合):
   • 规则要求多角色(owner、maintainer、reviewer)
   • Codex gate 需双仓库检查
   • Schema bump 需 owner 显式确认
   • 协议 bump 需 owner 显式确认
   • 每个 PR 需高置信度 review

   后果:
   • 单人需承担多角色,负担重
   • 决策需自己确认,无法委托
   • 验证门槛高,迭代慢
```

## 待精读项

以下细节本次未深入,需后续单独精读(不臆测):

| 待精读项 | 涉及模块 |
|---|---|
| Agent 终态归一化算法 | Agent 运行时(终态归一化器) |
| Lane 调度算法 | Gateway 核心(Lane 调度器) |
| Worker 通信协议 | 协议子包(worker schema 分片)+ Gateway(worker 启动) |
| Cron 持久化与重启恢复 | Gateway 核心(Cron 子系统) |
| Provider 模型路由具体算法 | 插件系统(Provider 路由) |
| Tool call 执行同步/异步边界 | 插件系统(Tool 注册表) |
| Auth profile 解析 fallback 策略 | Gateway 核心(认证面) |
| 流式输出 backpressure | 通道系统(流式输出) |
| 控制平面 audit | Gateway 核心(控制平面审计) |
| Channel health 监控算法 | Gateway 核心(Channel 健康监控) |

## 总体判断

**架构成熟度高**:边界清晰、规则严格、测试覆盖、状态统一。AGENTS.md 体现了项目对工程纪律的极致追求(每个 scoped 子树都有 AGENTS.md,每条规则都给出 rationale)。

**主要代价**:
- 文件拆分过细 → 上手成本
- Schema 演进包袱 → 维护成本
- 配置表面巨大 → 简化困难
- CLI/SDK 兼容约束 → 演进受限
- Codex 双仓库检查 → 依赖变更成本高

**适用场景判断**:
- 适合长期维护的多渠道 AI 助手产品
- 不适合快速原型(规则太严、边界太硬)
- 不适合单人维护(规则要求多角色协作:owner、maintainer、reviewer)
- 适合多人协作、长期演进的项目

**对二次开发的建议**:
- 新增插件:严格走 extensions/<id>/ + plugin-sdk 路径,不碰核心
- 修改核心:先读对应 scoped AGENTS.md,再做 refactor(默认 clean bounded refactor,非最小 patch)
- 新增配置:先证明现有行为无法解决
- 数据库变更:纯 additive 不 bump,破坏性需 owner 确认
- 协议变更:优先 additive,版本 bump 需 owner 确认

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
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 评估对象 | 源码位置 |
|---|---|
| 硬约束来源(边界/状态/配置/协议) | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
| Entry fast-path(懒加载优点) | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| Gateway 启动(懒加载优点) | [src/gateway/server-start.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts) |
| Schema 版本声明(演进包袱) | [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json) |
| 协议子包(Schema 严格) | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| Turn 内核(通道系统) | [src/channels/turn/kernel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/kernel.ts) |
| 状态库(状态统一) | [src/state/openclaw-state-db.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/state/openclaw-state-db.ts) |
| SDK 边界(扩展体系) | [src/plugin-sdk/entrypoints.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/entrypoints.ts) |
| Agent 终态归一化器(待精读) | [src/agents/agent-run-terminal-outcome.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-run-terminal-outcome.ts) |
| Lane 调度器(待精读) | [src/gateway/server-lanes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-lanes.ts) |
| Provider 模型路由(待精读) | [src/plugins/provider-model-routes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-routes.ts) |
| Tool 注册表(待精读) | [src/plugins/tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tools.ts) |
| 流式输出(待精读) | [src/channels/streaming.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/streaming.ts) |
| 控制平面审计(待精读) | [src/gateway/control-plane-audit.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-plane-audit.ts) |
| Channel 健康监控(待精读) | [src/gateway/channel-health-monitor.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/channel-health-monitor.ts) |
| Worker schema(待精读) | [packages/gateway-protocol/src/schema/worker-inference.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/worker-inference.ts) |
| Cron 子系统(待精读) | [src/gateway/server-cron-reconciled.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-cron-reconciled.ts) |
