# 10 — 关键设计原则

> 设计原则是 OpenClaw 工程纪律的提炼。读完本章你将理解边界归属、兼容性策略、Lean Code、Hot Path 优化、TS 严格如何相互支撑,共同构成代码质量的底线。

## 一句话定位

设计原则是从 AGENTS.md 硬约束中提炼的工程哲学,贯穿所有章节:
- 边界归属:owner 特定行为放 owner 插件,核心只暴露 generic seams
- 兼容性策略:兼容是 opt-in,默认删除而非保留,除非有明确 shipped 契约
- Lean Code:简洁是目标,refactor 应 LOC 平衡,helper 必须即时付租
- Hot Path 优化:提前准备 facts,不重复发现,元数据 process-stable
- TS 严格:无 any,用 discriminated union,让 impossible states 不可表示

## 全局协作图

下图展示 6 个原则维度如何围绕工程纪律核心相互支撑。**先看这张图建立心智模型,再读细节**。

```
                        ┌─────────────────────────────┐
                        │     工程纪律核心            │
                        │   (AGENTS.md 硬约束提炼)    │
                        │                             │
                        │   高置信验证 · best fix 判断│
                        └──────────────┬──────────────┘
                                       │
         ┌──────────┬──────────┬───────┴───────┬──────────┬──────────┐
         │          │          │               │          │          │
         ▼          ▼          ▼               ▼          ▼          ▼
   ┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐
   │ 边界归属 ││ 兼容性   ││ Lean Code││ Hot Path ││ TS 严格  ││ 代码组织 │
   │          ││ 策略     ││          ││ 优化     ││          ││          │
   │ owner    ││          ││          ││          ││          ││          │
   │ 特定行为 ││ opt-in   ││ 简洁是   ││ 提前准备 ││ 无 any   ││ ~700 LOC │
   │ 放 owner ││ 默认删除 ││ 目标     ││ facts    ││ discrimi ││ 拆分     │
   │ 插件     ││ 非保留   ││ LOC 平衡 ││ 不重复   ││ nated    ││ 命名可   │
   │ 核心只   ││ 除非有   ││ helper   ││ 发现     ││ union    ││ grep     │
   │ generic  ││ shipped  ││ 即时付租 ││ 元数据   ││ 让       ││ 早返回   │
   │ seams    ││ 契约     ││ API 窄   ││ process- ││ impossible││ 调用应   │
   │          ││          ││          ││ stable   ││ states   ││ 无趣     │
   │          ││          ││          ││          ││ 不可表示 ││          │
   └──────────┘└──────────┘└──────────┘└──────────┘└──────────┘└──────────┘
         │          │          │               │          │          │
         └──────────┴──────────┴───────┬───────┴──────────┴──────────┘
                                      │
                                      ▼
                        ┌─────────────────────────────┐
                        │     代码质量底线            │
                        │                             │
                        │  • 边界清晰可维护           │
                        │  • 行为确定可预测           │
                        │  • 历史包袱可控             │
                        │  • 性能可保证               │
                        │  • 类型安全可演进           │
                        └─────────────────────────────┘
```

## 组件清单

设计原则由 6 类维度构成:

| 维度 | 职责 | 关键约束 |
|---|---|---|
| **边界归属** | owner 特定行为放 owner 插件,核心只暴露 generic seams | 依赖归属随运行时归属;内部 bundled 进 core dist,外部 official 自管 |
| **兼容性策略** | 兼容是 opt-in,默认删除而非保留 | shipped = release Git tag 可达;Fallback 是产品决策非实现便利 |
| **Lean Code** | 简洁是目标,refactor 应 LOC 平衡 | helper 必须即时付租;API 只导出当前 caller 需要;返回最小有用 shape |
| **Hot Path 优化** | 提前准备 facts,不重复发现 | 元数据 process-stable;不做 freshness polling;prompt cache 确定性排序 |
| **TS 严格** | 无 any,用 discriminated union | 让 impossible states 不可表示;外部边界用 zod;无 @ts-nocheck |
| **代码组织** | 文件拆分 ~700 LOC,命名可 grep | 早返回而非嵌套金字塔;复杂决策在调用方之上;调用应无趣 |

## 关联关系

### 兼容性决策树(何时保留 compat)

```
   遇到旧代码/旧契约
        │
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 1:这是 shipped public contract?                  │
   │ (reachable from a release Git tag)                      │
   │                                                          │
   │  ├─ No(main / GitHub / PR / unreleased code)            │
   │  │   └─ 不保留 compat,直接删除                         │
   │  │                                                      │
   │  └─ Yes(shipped)                                       │
   │      └─ 继续...                                         │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 2:有明确的 shipped contract?                       │
   │                                                          │
   │  ├─ No                                                  │
   │  │   └─ 不确定就问;默认删除                             │
   │  │                                                      │
   │  └─ Yes(明确引用)                                     │
   │      └─ 继续...                                         │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 3:能否用 Doctor 解决?                             │
   │                                                          │
   │  ├─ Yes                                                 │
   │  │   └─ 用 Doctor 迁移,runtime 假定新 shape            │
   │  │       → 不保留 compat                               │
   │  │                                                      │
   │  └─ No                                                  │
   │      └─ 继续...                                         │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 4:Fallback 是产品决策还是实现便利?                │
   │                                                          │
   │  ├─ 实现便利                                             │
   │  │   └─ 删除                                            │
   │  │                                                      │
   │  └─ 产品决策                                            │
   │      └─ 必须命名:                                       │
   │          ├─ shipped contract                            │
   │          ├─ failure mode                                │
   │          ├─ removal plan                                │
   │          └─ 为何 Doctor 解决不了                        │
   │          → 才允许保留 fallback                          │
   └──────────────────────────────────────────────────────────┘

   允许保留的情况(明确清单):
   ┌────────────────────────────────────────────────────────┐
   │  ✓ explicit public API / config / plugin SDK / data   │
   │    contract                                            │
   │  ✓ tagged upgrade path                                │
   │  ✓ security / migration boundary                      │
   │  ✓ dependency contract                               │
   │  ✓ observed prod state                                │
   │                                                        │
   │  ✓ Plugin SDK exception:                              │
   │     shipped external API → new API first +            │
   │     named compat/deprecation + removal plan           │
   └────────────────────────────────────────────────────────┘

   禁止保留的情况:
   ┌────────────────────────────────────────────────────────┐
   │  ✗ "以防万一"保留:aliases / shims / fallback stacks  │
   │  ✗ 为减少 diff 保留:internal shims / legacy names    │
   │  ✗ 为不现实 edge case 保留:defensive branches        │
   └────────────────────────────────────────────────────────┘
```

### Hot Path 优化策略对比

```
   错误模式:重复发现
   ┌──────────────────────────────────────────────────────────┐
   │ Hot path 每次调用:                                     │
   │  ├─ 重新加载 plugin provider/channel/capability        │
   │  ├─ 重新 discover                                      │
   │  ├─ 用 scattered caches 修补重复发现                    │
   │  └─ 性能差,缓存不一致                                 │
   └──────────────────────────────────────────────────────────┘

   正确模式:prepared facts 提前带
   ┌──────────────────────────────────────────────────────────┐
   │ 上游(决策层)提前准备:                                │
   │  ├─ provider id                                        │
   │  ├─ model ref                                          │
   │  ├─ channel id                                         │
   │  ├─ target                                             │
   │  ├─ capability family                                  │
   │  └─ attachment class                                   │
   │                                                        │
   │ Hot path 直接复用:                                    │
   │  ├─ 复用 prepared runtime objects                      │
   │  └─ 删除 duplicate lookup branches                     │
   └──────────────────────────────────────────────────────────┘

   Freshness polling 禁令:
   ┌────────────────────────────────────────────────────────┐
   │ Runtime hot paths 禁止:                              │
   │  ✗ stat 文件                                          │
   │  ✗ realpath                                           │
   │  ✗ JSON reread                                        │
   │  ✗ hash 比较                                          │
   │                                                        │
   │ 原因:元数据 process-stable,变更需 restart 或显式    │
   │       owner reload/install/doctor flow                │
   │ 例外:process-local metadata caches(lifecycle-owned, │
   │       bounded/single-slot,需 named owner + tests)    │
   └────────────────────────────────────────────────────────┘

   Prompt cache 友好:
   ┌────────────────────────────────────────────────────────┐
   │ 送入 model/tool payload 前:                          │
   │  ✓ maps/sets/registries/plugin lists/files/network   │
   │    results 确定性排序                                 │
   │  ✓ 保留旧 transcript bytes                           │
   │                                                        │
   │ 原因:顺序不确定性 → cache 命中率下降;             │
   │       保留旧 bytes → cache 命中                      │
   └────────────────────────────────────────────────────────┘
```

### TS 类型选择决策树

```
   需要 typing?
        │
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 是否外部边界?(user input、external API、file IO)      │
   │                                                          │
   │  ├─ Yes                                                 │
   │  │   └─ 用 zod 或现有 schema helpers                   │
   │  │       (运行时校验 + 类型推导)                       │
   │  │                                                      │
   │  └─ No(内部代码)                                       │
   │      └─ 继续...                                         │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 是否运行时分支?                                        │
   │                                                          │
   │  ├─ Yes                                                 │
   │  │   └─ discriminated unions / closed codes            │
   │  │       (而非 freeform strings)                        │
   │  │                                                      │
   │  │      正确:                                          │
   │  │      { kind: "ok", value: T }                       │
   │  │      { kind: "error", error: E }                    │
   │  │                                                      │
   │  │      错误:                                          │
   │  │      { ok: boolean; value?: T; error?: E }         │
   │  │      (parallel nullable fields,callers 必须同步)    │
   │  │                                                      │
   │  └─ No                                                  │
   │      └─ 继续...                                         │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 是否需要 any?                                           │
   │                                                          │
   │  ├─ 能用 real types? → 用 real types                    │
   │  ├─ 能用 unknown?    → 用 unknown + narrow adapters     │
   │  └─ 真的需要 any?    → 必须 lint suppression            │
   │                          (intentional + explained)      │
   └──────────────────────────────────────────────────────────┘

   禁止的 TS 模式:
   ┌────────────────────────────────────────────────────────┐
   │  ✗ @ts-nocheck                                        │
   │  ✗ semantic sentinels(?? 0,empty object/string)     │
   │  ✗ parallel nullable fields(callers 必须同步)        │
   │  ✗ derived booleans(callers 必须同步)                │
   │  ✗ freeform strings(运行时分支)                     │
   │                                                        │
   │  核心准则:make impossible states unrepresentable      │
   └────────────────────────────────────────────────────────┘
```

### Refactor LOC 平衡图

```
   Refactor 决策:是否值得?
   ═══════════════════════════

   ┌──────────────────────────────────────────────────────────┐
   │ 重构前评估:                                             │
   │                                                          │
   │  新增 LOC ≈ 删除 LOC?                                   │
   │  ├─ Yes → LOC 平衡,可接受                              │
   │  └─ No(LOC 增长)                                       │
   │      └─ 新 ownership/API 是否 clearly pay for it?      │
   │          ├─ Yes → 可接受,但需解释                      │
   │          └─ No  → 重构失败,重新设计                    │
   └──────────────────────────────────────────────────────────┘

   非测试 LOC 增长是 smell:
   ┌────────────────────────────────────────────────────────┐
   │  • refactor 应减少非测试 LOC,除非移除更大架构成本    │
   │  • 正 prod LOC 是 smell                                │
   │  • closeout 检查:git diff --numstat                  │
   │    如果非测试 LOC 增长 → trim 或解释                  │
   └────────────────────────────────────────────────────────┘

   Helper / File 即时付租原则:
   ┌────────────────────────────────────────────────────────┐
   │ 新 helper/file 必须 pay rent immediately:            │
   │  ✓ fewer call paths                                   │
   │  ✓ fewer concepts                                     │
   │  ✓ less repeated logic                                │
   │                                                        │
   │  ✗ 不为以下加 helper:                                 │
   │     • one-off compat                                  │
   │     • naming translation                              │
   │     • speculative resilience                          │
   │                                                        │
   │  加 helper 前:                                       │
   │     → 先检查 existing code 能否 absorb the behavior  │
   │       with less new surface                           │
   └────────────────────────────────────────────────────────┘

   Fix shape 决策:
   ┌────────────────────────────────────────────────────────┐
   │ 修复 bug 时:                                         │
   │  ✗ 最小 patch(smallest patch)                      │
   │  ✓ Clean bounded refactor(默认)                    │
   │     ├─ Move ownership to right boundary               │
   │     ├─ Delete stale abstractions                      │
   │     ├─ Delete duplicate policy                        │
   │     ├─ Delete dead branches                           │
   │     ├─ Delete wrappers                                │
   │     └─ Delete fallback stacks                         │
   └────────────────────────────────────────────────────────┘
```

## 协作流程

### 一次 refactor 决策的完整旅程

下面追踪一个开发者遇到旧代码时,各原则如何指导决策,标注每步由哪个维度负责。

```
开发者遇到一段需要修改的旧代码
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 边界归属判断                                              │
│    这段代码的 owner 是谁?                                   │
│    ├─ owner 特定行为 → 应在 owner 插件                      │
│    └─ 通用行为 → 核心只暴露 generic seams                   │
│    → 决定修改位置:owner 插件 or 核心                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 兼容性策略判断                                            │
│    这是 shipped public contract?                            │
│    ├─ No(main/PR/unreleased)→ 直接删除,不保留 compat      │
│    ├─ Yes 但无明确契约 → 不确定就问,默认删除               │
│    ├─ Yes 且 Doctor 能解决 → Doctor 迁移,runtime 不兼容    │
│    └─ Yes 且需 Fallback → 必须命名 4 项才能保留             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Lean Code 评估                                            │
│    refactor 是否 LOC 平衡?                                  │
│    ├─ 新增 ≈ 删除 → 可接受                                  │
│    └─ LOC 增长 → 新 ownership/API 是否 pay for it?          │
│    → 决定 refactor 形状:clean bounded,非最小 patch        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Hot Path 检查                                             │
│    这段代码在 hot path?                                     │
│    ├─ Yes → 提前准备 facts,不重复发现                      │
│    │        → 不用 scattered caches 修补                   │
│    │        → 元数据 process-stable,不做 freshness polling │
│    └─ No → 正常处理                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. TS 严格落地                                               │
│    类型设计:                                                │
│    ├─ 外部边界 → zod / schema helpers                       │
│    ├─ 运行时分支 → discriminated union                      │
│    ├─ 避免 any → real types / unknown / narrow adapters    │
│    └─ 让 impossible states 不可表示                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 代码组织                                                  │
│    实现时:                                                  │
│    ├─ 文件 ~700 LOC 考虑拆分                                │
│    ├─ exported symbol 2-3 词唯一,可 grep                   │
│    ├─ 早返回而非嵌套金字塔                                  │
│    ├─ 复杂决策在调用方之上,调用应无趣                      │
│    └─ 注释 1-3 行说明 why / protects what / bad outcome    │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. 验证与证明                                                │
│    review 前:                                              │
│    ├─ 高置信度:读完整相关 codebase                          │
│    │   (owner、caller、sibling、test、doc、upstream)       │
│    ├─ diff-only review 不够                                 │
│    └─ 每个 PR review 必须问:这是 best fix 还是 plausible?  │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. Owner 边界

- **为什么**:防止 owner 特定逻辑污染核心,导致核心无法保持插件无关
- **怎么做**:owner 特定行为(repair/detection/onboarding/auth/defaults/provider)放 owner 插件;核心只暴露 generic seams;依赖归属随运行时归属
- **影响**:核心可独立演进,owner 插件可独立变更,边界清晰利于分工

### 2. 兼容是 opt-in

- **为什么**:默认保留 compat 会导致历史包袱累积,旧路径永远无法删除
- **怎么做**:只有 release Git tag 可达的代码才算 shipped;不确定就问,默认删除;Fallback 是产品决策,需命名 shipped contract / failure mode / removal plan / 为何 Doctor 解决不了
- **影响**:历史包袱可控,代码路径单一,行为确定

### 3. Lean Code 是目标

- **为什么**:代码库已大,继续膨胀会降低可维护性
- **怎么做**:refactor 应 LOC 平衡(新增 ≈ 删除);非测试 LOC 增长是 smell;helper 必须即时付租(更少 call path / 更少概念 / 更少重复);API 只导出当前 caller 需要,返回最小有用 shape
- **影响**:代码精简,概念清晰,维护成本可控

### 4. Hot path 不重复发现

- **为什么**:重复发现浪费 CPU,scattered caches 导致缓存不一致
- **怎么做**:hot path 提前带 prepared facts(provider id / model ref / channel id / target / capability family / attachment class);复用 prepared runtime objects;删除 duplicate lookup branches;元数据 process-stable,不做 freshness polling
- **影响**:hot path 零开销,无 race condition,性能可保证

### 5. TS 严格,让 impossible states 不可表示

- **为什么**:freeform string 和 parallel nullable fields 会让调用方必须同步多个字段,容易出错
- **怎么做**:运行时分支用 discriminated union / closed codes;避免 semantic sentinels;外部边界用 zod;无 any、无 @ts-nocheck
- **影响**:类型安全可演进,编译期捕获错误,行为可预测

### 6. 命名可 grep

- **为什么**:开发者靠 grep 导航代码,generic 单词 export 无法定位
- **怎么做**:exported symbol 用 2-3 词唯一名;不允许 generic 单词 export;不新增 utils/helpers/common 目录;每个概念仓库内一种拼写
- **影响**:代码可搜索,概念可定位,新人上手成本低

## 设计观察

### 为什么 discriminated union 而非 freeform string

```
错误设计(parallel nullable fields):
   {
     ok: boolean;
     value?: T;
     error?: E;
   }

   后果:
   • callers 必须同步 ok / value / error 三个字段
   • { ok: true, error: "..." } 这种不可能状态可表示
   • 运行时分支需检查多个字段,易漏
   • 测试需覆盖所有字段组合

正确设计(discriminated union):
   { kind: "ok", value: T }
   { kind: "error", error: E }

   好处:
   • kind 是判别字段,TypeScript 可窄化
   • impossible states 不可表示
   • 运行时分支只需检查 kind
   • 测试只需覆盖每种 kind
```

### 为什么 default 删除而非保留 compat

```
错误设计(默认保留 compat):
   遇到旧代码 → "以防万一"保留
   → aliases / shims / fallback stacks / stale names 累积
   → 旧路径永远无法删除
   → 代码库膨胀,维护成本上升
   → 行为不可预测(多条路径)

正确设计(默认删除):
   遇到旧代码 → 先问:这是 shipped public contract?
   ├─ No → 直接删除
   ├─ Yes 但 Doctor 能解决 → Doctor 迁移,runtime 不兼容
   └─ Yes 且需 Fallback → 命名 4 项才能保留

   好处:
   • 历史包袱可控
   • 代码路径单一,行为确定
   • 用户被引导走新路径,而非静默 fallback
```

### 为什么 hot path 不用 scattered caches

```
错误设计(scattered caches 修补重复发现):
   hot path 每次调用:
   ├─ 重新加载 plugin provider/channel/capability
   ├─ 重新 discover
   ├─ 用 scattered caches 缓存结果
   └─ 缓存间不一致,失效逻辑散落

   后果:
   • 缓存一致性难保证
   • 失效逻辑散落,维护成本高
   • 缓存命中率不可预测

正确设计(提前准备 facts):
   上游决策层提前准备 prepared facts
   hot path 直接复用 prepared runtime objects
   删除 duplicate lookup branches

   好处:
   • 无缓存一致性问题
   • hot path 零开销
   • facts 在决策层确定,行为可预测
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
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 维度 | 源码位置 |
|---|---|
| 边界归属与 Map | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
| 兼容性策略 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" / "Code" 段 |
| Lean Code / Fix shape | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Code" 段 |
| Hot Path 优化 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
| TS 严格 / 类型选择 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Code" 段 |
| 代码组织 / 命名 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Code" 段 |
| 注释规则 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
| 验证与证明门槛 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Validation" 段 |
| Tests 规则 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Tests" 段 |
