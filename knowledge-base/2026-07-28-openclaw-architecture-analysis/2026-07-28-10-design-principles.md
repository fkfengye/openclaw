# 10 — 关键设计原则

从 AGENTS.md 各段提取的设计原则,按主题归类。每条原则附 AGENTS.md 出处。

## 10.1 边界与归属

### Owner 边界

> Owner boundary: owner-specific repair/detection/onboarding/auth/defaults/provider behavior lives in owner plugin. Shared/core gets generic seams only.

**含义**:owner 特定行为放 owner 插件,核心只暴露 generic seams。

### 依赖归属随运行时归属

> Dependency ownership follows runtime ownership: plugin-only deps stay plugin-local; root deps only for core imports or intentionally internalized bundled plugin runtime.

**含义**:插件 only 依赖留在插件本地;只有核心 import 或有意 internalized 的才放 root dep。

### 内部 bundled 插件 vs 外部 official 插件

> Internal bundled plugins ship in core dist; bundled-only facade loader ok only for them.
> External official plugins own package/deps and are excluded from core dist; core uses registry-aware `facade-runtime` or generic contracts.

**含义**:internal bundled plugin 进 core dist;bundled-only facade loader 只对它们 ok;external official plugin 自管 package/deps,不进 core dist。

## 10.2 兼容性策略

### 兼容是 opt-in

> Compatibility is opt-in. "Shipped" means reachable from a release Git tag; main/GitHub/PR/unreleased code is not shipped.

**含义**:兼容性是 opt-in 的,只有 release Git tag 可达的代码才算"shipped"。

### 默认删除而非保留

> Refactor default: one canonical path. Delete the old path unless user explicitly wants compat or the shipped public contract is obvious and cited.

**含义**:refactor 默认单 canonical path,删除旧 path,除非用户明确要 compat 或有明确 shipped public contract。

### Fallback 是产品决策

> Fallback is a product decision, not an implementation convenience. Before adding one, name the shipped contract, failure mode, removal plan, and why doctor cannot solve it. Otherwise delete it.

**含义**:加 fallback 前需命名 shipped contract、failure mode、removal plan、为何 doctor 解决不了;否则删除。

### 不保留 compat 除非明确

> If unsure, ask before preserving compat. Do not keep aliases, shims, fallback stacks, stale names, or obsolete tests just in case.

**含义**:不确定就问;不要"以防万一"保留 aliases、shims、fallback stacks、stale names、obsolete tests。

## 10.3 Lean Code

### 简洁是目标

> Lean code is a goal. No internal shims, aliases, legacy names, broad fallbacks, or defensive branches just to reduce diff or handle unrealistic edge cases.

**含义**:不为了减少 diff 或处理不现实 edge case 而加 shim/alias/legacy name/broad fallback/defensive branch。

### Refactor LOC 平衡

> Refactors should delete about as much local complexity as they add. If LOC grows, the new ownership/API needs to clearly pay for it.
> Refactors should reduce non-test LOC unless they remove a larger architectural cost. Treat positive prod LOC as a smell.

**含义**:refactor 应新增 ≈ 删除;非测试 LOC 增长是 smell;正 prod LOC 需明确解释。

### Helper 即时付租

> New helpers/files must pay rent immediately: fewer call paths, fewer concepts, or less repeated logic. No helpers for one-off compat, naming translation, or speculative resilience.
> Before adding helpers/files, check whether existing code can absorb the behavior with less new surface.

**含义**:新 helper/file 必须立即付租(更少 call path、更少概念、更少重复);不为 one-off compat/naming translation/speculative resilience 加 helper。

### API 窄

> Keep APIs narrow: export only current caller needs; keep types/helpers local by default.
> Return the smallest useful shape. Avoid broad result objects, flags, metadata unless callers use them.

**含义**:只导出当前 caller 需要的;类型/helper 默认 local;返回最小有用 shape。

## 10.4 Hot Path 优化

### 提前准备 facts

> Hot paths should carry prepared facts forward: provider id, model ref, channel id, target, capability family, attachment class. Do not rediscover with broad plugin/provider/channel/capability loaders.

**含义**:hot path 提前带 prepared facts,不重复发现。

### 不用 scattered caches 修重复发现

> Do not fix repeated request-time discovery with scattered caches. Move the canonical fact earlier; reuse prepared runtime objects; delete duplicate lookup branches.

**含义**:不用 scattered caches 修重复发现;把 canonical fact 提前;复用 prepared runtime objects;删除重复 lookup branches。

### 元数据 process-stable

> Gateway/plugin metadata is process-stable: installs, manifests, catalogs, generated paths, bundled metadata. Changes require restart or explicit owner reload/install/doctor flow.
> Runtime hot paths: no freshness polling (`stat`/`realpath`/JSON reread/hash).

**含义**:元数据进程内 stable,不做 freshness polling。

### Prompt cache 友好

> Prompt cache: deterministic ordering for maps/sets/registries/plugin lists/files/network results before model/tool payloads. Preserve old transcript bytes when possible.

**含义**:送入 model/tool payload 前确定性排序;保留旧 transcript bytes。

## 10.5 TS 严格

### 无 any

> TS ESM, strict. Avoid `any`; prefer real types, `unknown`, narrow adapters.

**含义**:避免 any,用 real types、unknown、narrow adapters。

### 无 @ts-nocheck

> No `@ts-nocheck`. Lint suppressions only intentional + explained.

**含义**:不允许 @ts-nocheck;lint 抑制必须 intentional + 解释。

### Discriminated union

> Runtime branching: discriminated unions/closed codes over freeform strings. Avoid semantic sentinels (`?? 0`, empty object/string).
> Cross-function state: when valid combos matter, return a closed mode/result shape. Avoid parallel nullable fields or derived booleans that callers must keep in sync; make impossible states unrepresentable.

**含义**:用 discriminated union/closed codes 而非 freeform strings;避免 semantic sentinels;让 impossible states 不可表示。

### External boundary 用 zod

> External boundaries: prefer `zod` or existing schema helpers.

**含义**:外部边界用 zod 或现有 schema helpers。

## 10.6 代码组织

### 文件拆分

> Split files around ~700 LOC when clarity/testability improves.

**含义**:~700 LOC 时考虑拆分,以改善 clarity/testability。

### 命名唯一

> Agents navigate by grep: exported symbols use 2-3 word unique names; no generic single-word exports (`get`, `run`, `create`, `handle`).
> New modules/dirs concept-named; no new `utils/`, `helpers/`, `common/`. One spelling per concept repo-wide.

**含义**:exported symbol 用 2-3 词唯一名;不允许 generic 单词 export;不新增 utils/helpers/common 目录;每个概念仓库内一种拼写。

### 早返回

> Prefer early returns over nested condition pyramids. Split code into gather -> normalize -> decide -> act.

**含义**:早返回而非嵌套金字塔;按 gather → normalize → decide → act 拆分。

### 调用应无趣

> Calls should be boring: complex decisions happen above; call args/object fields are names, literals, or simple property reads.

**含义**:复杂决策在调用方之上;call args/object fields 是 name、literal、简单 property read。

## 10.7 注释规则

> Inline comments: preserve reviewer context at the code site. Required for non-obvious cross-path/state invariants, lifecycle ordering, ownership boundaries, queue/dedupe symmetry, TTL/cache expiry, cleanup/release coupling, session/id adoption, fallback behavior, platform/dependency caps, deterministic ordering, compact encoded state, or intentional caller differences.
> Comment shape: 1-3 short lines; state why the branch/helper exists, what contract it protects, and the bad outcome if removed. Cite nearby constants/helpers when useful. No syntax narration, PR/user-specific lore, or obvious mechanics.

**含义**:注释为 reviewer 保留 context;1-3 行;说明 why、protects what、bad outcome if removed;不写语法叙述/PR lore。

## 10.8 验证与证明

### 验证门槛

> Reviews/answers: high confidence required. Default to exhaustive relevant codebase search/read, including owners, callers, siblings, tests, docs, and upstream/dependency contracts before verdict. Diff-only review is insufficient.

**含义**:review/answer 需高置信度,默认要读完整相关 codebase(owner、caller、sibling、test、doc、upstream contract)。

### Fix shape

> Fix shape: default to clean bounded refactor, not smallest patch. Move ownership to right boundary; delete stale abstractions, duplicate policy, dead branches, wrappers, fallback stacks.

**含义**:fix 默认 clean bounded refactor,不是最小 patch;把 ownership 移到正确边界;删除 stale abstractions、duplicate policy、dead branches、wrappers、fallback stacks。

### Best fix 判断

> Every PR review must explicitly ask whether the PR is the best fix, not merely a plausible fix.

**含义**:每个 PR review 必须明确问"这是 best fix 还是 plausible fix"。

## 10.9 关键观察

- **边界硬约束**:owner 特定行为放 owner 插件,核心只 generic。
- **兼容 opt-in**:不是默认,需明确 shipped contract。
- **Lean code 是目标**:refactor 应 LOC 平衡,helper 即时付租。
- **Hot path 不重复发现**:prepared facts 提前带,不 scattered cache。
- **TS 严格**:无 any、无 @ts-nocheck、用 discriminated union。
- **命名可 grep**:exported symbol 2-3 词唯一,无 generic 单词。
- **注释为 context**:1-3 行说明 why/protects/bad outcome。
- **验证需高置信**:diff-only review 不够,要读完整相关路径。

## 架构图与流程图

### 兼容性决策树(何时保留 compat)

```
    遇到旧代码/旧契约
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 问题 1:这是 shipped public contract?                  │
    │ (reachable from a release Git tag)                      │
    │                                                          │
    │  ├─ No(main/GitHub/PR/unreleased code)                  │
    │  │   └─ 不保留 compat,直接删除                         │
    │  │                                                      │
    │  └─ Yes(shipped)                                       │
    │      └─ 继续...                                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 问题 2:有明确的 shipped contract?                       │
    │                                                          │
    │  ├─ No                                                  │
    │  │   └─ ⚠️ If unsure, ask before preserving compat     │
    │  │       → 默认删除                                     │
    │  │                                                      │
    │  └─ Yes(明确引用)                                     │
    │      └─ 继续...                                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 问题 3:能否用 doctor 解决?                             │
    │                                                          │
    │  ├─ Yes                                                 │
    │  │   └─ 用 openclaw doctor --fix 迁移                  │
    │  │       → Runtime 假定新 shape                         │
    │  │       → 不保留 compat                               │
    │  │                                                      │
    │  └─ No                                                  │
    │      └─ 继续...                                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 问题 4:Fallback 是产品决策还是实现便利?                │
    │                                                          │
    │  ├─ 实现便利(implementation convenience)              │
    │  │   └─ ❌ 删除                                         │
    │  │                                                      │
    │  └─ 产品决策(product decision)                        │
    │      └─ 必须命名:                                      │
    │          ├─ shipped contract                            │
    │          ├─ failure mode                                │
    │          ├─ removal plan                                │
    │          └─ why doctor cannot solve it                  │
    │          → 才允许保留 fallback                          │
    └──────────────────────────────────────────────────────────┘

    禁止保留的情况:
    ┌────────────────────────────────────────────────────────┐
    │ ❌ "以防万一"保留:                                    │
    │   • aliases                                           │
    │   • shims                                             │
    │   • fallback stacks                                   │
    │   • stale names                                       │
    │   • obsolete tests                                    │
    │                                                        │
    │ ❌ 为了减少 diff 保留:                                │
    │   • internal shims                                   │
    │   • legacy names                                      │
    │   • broad fallbacks                                   │
    │   • defensive branches                                │
    └────────────────────────────────────────────────────────┘

    允许保留的情况(明确清单):
    ┌────────────────────────────────────────────────────────┐
    │ ✅ explicit public API/config/plugin SDK/data contract│
    │ ✅ tagged upgrade path                                │
    │ ✅ security/migration boundary                        │
    │ ✅ dependency contract                               │
    │ ✅ observed prod state                                │
    │                                                        │
    │ ✅ Plugin SDK exception:                              │
    │    shipped external API → new API first +             │
    │    named compat/deprecation +                         │
    │    small tests/docs + removal plan                    │
    └────────────────────────────────────────────────────────┘
```

### Hot Path 优化策略图

```
    Hot Path 优化原则
    ═════════════════

    ❌ 错误模式:重复发现
    ┌──────────────────────────────────────────────────────────┐
    │ Hot path 每次调用:                                     │
    │  ├─ 重新加载 plugin provider/channel/capability        │
    │  ├─ 重新 discover                                      │
    │  ├─ 用 scattered caches 修补重复发现                    │
    │  └─ 性能差,缓存不一致                                 │
    └──────────────────────────────────────────────────────────┘

    ✅ 正确模式:prepared facts 提前带
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
    │                                                        │
    │ AGENTS.md:                                            │
    │   "Hot paths should carry prepared facts forward:     │
    │    provider id, model ref, channel id, target,         │
    │    capability family, attachment class.                │
    │    Do not rediscover with broad plugin/provider/       │
    │    channel/capability loaders."                       │
    └──────────────────────────────────────────────────────────┘

    Freshness polling 禁令:
    ┌────────────────────────────────────────────────────────┐
    │ Runtime hot paths 禁止:                              │
    │  ❌ stat 文件                                         │
    │  ❌ realpath                                          │
    │  ❌ JSON reread                                       │
    │  ❌ hash 比较                                         │
    │                                                        │
    │ 原因:                                                │
    │  • Gateway/plugin metadata is process-stable          │
    │  • 变更需 restart 或 explicit owner reload/install/  │
    │    doctor flow                                        │
    │  • Freshness polling 浪费 CPU,引入 race              │
    │                                                        │
    │ 例外(需 named owner + tests):                      │
    │  • Process-local metadata caches(lifecycle-owned,    │
    │    bounded/single-slot)                               │
    └────────────────────────────────────────────────────────┘

    Prompt cache 友好:
    ┌────────────────────────────────────────────────────────┐
    │ 送入 model/tool payload 前:                          │
    │  ✅ maps/sets/registries/plugin lists/files/network   │
    │     results 确定性排序                                │
    │  ✅ Preserve old transcript bytes when possible       │
    │                                                        │
    │ 原因:                                                │
    │  • 顺序不确定性 → prompt cache 命中率下降            │
    │  • 保留旧 bytes → cache 命中                           │
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
    │  │   └─ 用 zod 或 existing schema helpers              │
    │  │       (运行时校验 + 类型推导)                       │
    │  │                                                      │
    │  └─ No(内部代码)                                       │
    │      └─ 继续...                                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 是否运行时分支?                                        │
    │                                                          │
    │  ├─ Yes                                                 │
    │  │   └─ discriminated unions / closed codes            │
    │  │       (而非 freeform strings)                        │
    │  │                                                      │
    │  │      ✅ 好:                                          │
    │  │      type Result =                                   │
    │  │        | { kind: "ok", value: T }                    │
    │  │        | { kind: "error", error: E };                │
    │  │                                                      │
    │  │      ❌ 坏:                                          │
    │  │      type Result = {                                 │
    │  │        ok: boolean;                                   │
    │  │        value?: T;                                     │
    │  │        error?: E;                                     │
    │  │      };                                               │
    │  │      (parallel nullable fields,callers 必须同步)    │
    │  │                                                      │
    │  └─ No                                                  │
    │      └─ 继续...                                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 是否需要 any?                                           │
    │                                                          │
    │  ⚠️ AGENTS.md: "Avoid any"                              │
    │                                                          │
    │  ├─ 能用 real types?                                    │
    │  │   └─ 用 real types                                   │
    │  │                                                      │
    │  ├─ 能用 unknown?                                       │
    │  │   └─ 用 unknown + narrow adapters                   │
    │  │                                                      │
    │  └─ 真的需要 any?                                      │
    │      └─ ⚠️ 必须 lint suppression(intentional + explained)│
    └──────────────────────────────────────────────────────────┘

    禁止的 TS 模式:
    ┌────────────────────────────────────────────────────────┐
    │  ❌ @ts-nocheck                                       │
    │  ❌ semantic sentinels(?? 0, empty object/string)    │
    │  ❌ parallel nullable fields(callers 必须同步)        │
    │  ❌ derived booleans(callers 必须同步)                │
    │  ❌ freeform strings(运行时分支)                     │
    │                                                        │
    │  AGENTS.md:                                            │
    │    "make impossible states unrepresentable"            │
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
    │  ├─ Yes → ✅ 好,LOC 平衡                               │
    │  └─ No(LOC 增长)                                       │
    │      └─ 新 ownership/API 是否 clearly pay for it?      │
    │          ├─ Yes → ✅ 可接受,但需解释                   │
    │          └─ No  → ❌ 重构失败,重新设计                 │
    └──────────────────────────────────────────────────────────┘

    非测试 LOC 增长是 smell:
    ┌────────────────────────────────────────────────────────┐
    │ AGENTS.md:                                            │
    │   "Refactors should reduce non-test LOC unless they   │
    │    remove a larger architectural cost.                │
    │    Treat positive prod LOC as a smell."               │
    │                                                        │
    │ Closeout 检查:                                        │
    │   git diff --numstat                                  │
    │   如果非测试 LOC 增长 → trim 或解释                   │
    └────────────────────────────────────────────────────────┘

    Helper / File 即时付租原则:
    ┌────────────────────────────────────────────────────────┐
    │ 新 helper/file 必须 pay rent immediately:            │
    │  ✅ fewer call paths                                  │
    │  ✅ fewer concepts                                    │
    │  ✅ less repeated logic                               │
    │                                                        │
    │  ❌ No helpers for:                                   │
    │     • one-off compat                                 │
    │     • naming translation                              │
    │     • speculative resilience                          │
    │                                                        │
    │ 加 helper 前:                                        │
    │  → 先检查 existing code 能否 absorb the behavior     │
    │    with less new surface                              │
    └────────────────────────────────────────────────────────┘

    Fix shape 决策:
    ┌────────────────────────────────────────────────────────┐
    │ 修复 bug 时:                                         │
    │  ❌ 最小 patch(smallest patch)                      │
    │  ✅ Clean bounded refactor(默认)                    │
    │     ├─ Move ownership to right boundary               │
    │     ├─ Delete stale abstractions                      │
    │     ├─ Delete duplicate policy                        │
    │     ├─ Delete dead branches                           │
    │     ├─ Delete wrappers                                 │
    │     └─ Delete fallback stacks                         │
    └────────────────────────────────────────────────────────┘
```
