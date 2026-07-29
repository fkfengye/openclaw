# 04 — Runtime 守卫 + 版本兼容矩阵

> 读完本章你将理解:OpenClaw 为什么在启动链路上设置两处 runtime 守卫,它们各自的检测粒度与错误输出有何不同,以及 Node/Bun 的版本兼容矩阵如何决定一个 runtime 能否启动。

## 一句话定位

外部入口层有两处 runtime 守卫:L1 前置守卫在 TS 加载前快速 fail(纯文本错误),L2 完整诊断守卫在 TS bundle 内输出 JSON diagnostic。两者共用 semver 解析与 Bun feature 探针,但检测粒度与错误格式不同。

## 全局协作图

下图展示两处守卫与版本检测组件的协作关系,框内是组件名 + 职责 + 关键约束。

```
                  启动 openclaw
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ L1 前置守卫(纯 JS)                                     │
   │ 职责:TS 加载前快速判断 Node/Bun 是否兼容               │
   │ 约束:不兼容直接 exit(1),纯文本错误,不加载 TS        │
   └──────────────────────────┬───────────────────────────────┘
                              │ 通过
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ (Layer 4 import TS bundle)                               │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ L2 完整诊断守卫(TS bundle 内)                          │
   │ 职责:细粒度检测 + JSON diagnostic 输出                  │
   │ 约束:可访问 dotenv / trace 格式化;不兼容 exit(1)      │
   └──────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │ 版本检测组件(横切 L1 + L2)                              │
   │                                                          │
   │  ┌─────────────────┐  ┌─────────────────┐              │
   │  │ Semver 解析器   │  │ Bun Feature 探针│              │
   │  │ 解析版本字符串  │  │ 探测 node:sqlite│              │
   │  │ + 范围比较      │  │ (feature-probe) │              │
   │  └─────────────────┘  └─────────────────┘              │
   │                                                          │
   │  ┌─────────────────┐  ┌─────────────────┐              │
   │  │ Engine Clause   │  │ Node 版本范围   │              │
   │  │ 解析器(L2 专属)│  │ 检查器         │              │
   │  │ 解析 engines.node│  │ 22/24/25/26+   │              │
   │  └─────────────────┘  └─────────────────┘              │
   └──────────────────────────────────────────────────────────┘
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **L1 前置守卫** | TS 加载前快速判断 runtime 兼容性 | 纯 JS,纯文本错误,不加载 TS |
| **L2 完整诊断守卫** | TS bundle 内细粒度检测 + JSON diagnostic | 可访问 dotenv / trace 格式化 |
| **Semver 解析器** | 解析版本字符串并做范围比较 | regex 解析 major.minor.patch |
| **Bun Feature 探针** | 探测 Bun 是否支持 node:sqlite | feature-probe 而非版本拒绝 |
| **Engine Clause 解析器** | 解析 package.json 的 engines.node(L2 专属) | 确保硬编码与声明一致 |
| **Node 版本范围检查器** | 判断 Node 是否在 22/24/25/26+ 范围 | 26+ 直接通过,23 不支持 |

## 关联关系

### 双重守卫的接力

```
   ┌─────────────────┐
   │ L1 前置守卫     │ 粗粒度(只查版本号)
   │ (纯 JS)         │ → 不兼容直接 exit(1),纯文本错误
   └────────┬────────┘
            │ 通过
            ▼
   ┌─────────────────┐
   │ L2 完整诊断守卫 │ 细粒度(完整 RuntimeDetails)
   │ (TS bundle)     │ → 不兼容输出 JSON diagnostic + exit(1)
   └────────┬────────┘
            │ 通过
            ▼
        继续启动
```

**为什么需要两次?**
- L1 在 TS 加载前必须完成(否则不兼容 Node 加载 TS 会崩,无法给友好错误)
- L2 在 TS 内,可输出与运行时 JSONL 日志对齐的 diagnostic,可访问 dotenv

### L1 与 L2 的差异对比

```
   ┌─────────────────────────────────────────────┐
   │ L1 前置守卫(Layer 2)                      │
   │                                             │
   │ 检测内容:                                   │
   │   • Bun? → 探测 node:sqlite                │
   │   • Node? → 版本范围检查(22/24/25/26+)    │
   │                                             │
   │ 错误输出:                                   │
   │   • process.stderr.write 纯文本             │
   │   • 例:"openclaw: Node.js >=22.22.3...     │
   │          is required (current: v20.x)"     │
   │                                             │
   │ 退出:exit(1)                               │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ L2 完整诊断守卫(Layer 5)                  │
   │                                             │
   │ 检测内容:                                   │
   │   • 运行时检测器 → 完整运行时详情           │
   │     (kind/version/execPath/pathEnv/         │
   │      hasNodeSqlite)                         │
   │   • Engine Clause 解析(engines.node)       │
   │                                             │
   │ 错误输出:                                   │
   │   • dotenv 加载器(静默模式)                │
   │   • trace 控制台格式化器                    │
   │   • JSON diagnostic(与运行时 JSONL 对齐)   │
   │                                             │
   │ 退出:exit(1)                               │
   └─────────────────────────────────────────────┘
```

### Bun 兼容性策略:feature-probe 而非版本拒绝

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计(版本拒绝):                       │
   │   检测到 Bun → 直接拒绝                     │
   │   → capable Bun builds 也被拒绝             │
   │   → Bun 在 install/package scripts 阶段    │
   │     始终可用,运行时不一定                  │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计(feature-probe):                  │
   │   检测到 Bun → 探测 node:sqlite            │
   │   有 sqlite → 继续                          │
   │   无 sqlite → exit(1)                       │
   │   → Bun ≥1.4(Rust rewrite)支持 sqlite     │
   │   → 降低 false negative                     │
   └─────────────────────────────────────────────┘
```

### Node 版本范围检查逻辑

```
                Node 版本
                    │
         ┌──────────┴──────────┐
         │ major === 22?       │
         └──┬───────────────┬──┘
          是│               │否
            ▼               ▼
     检查 ≥ 22.22.3   ┌──────────────┐
                      │ major === 24?│
                      └──┬────────┬──┘
                       是│        │否
                         ▼        ▼
                  检查 ≥ 24.15.0  ┌──────────────┐
                                 │ major === 25?│
                                 └──┬────────┬──┘
                                  是│        │否
                                    ▼        ▼
                            检查 ≥ 25.9.0  ┌──────────────┐
                                         │ major > 25?  │
                                         └──┬────────┬──┘
                                          是│        │否
                                            ▼        ▼
                                         通过     不支持(23 等)
```

## 协作流程

### 一次 Node 20 启动的完整旅程(不兼容场景)

```
用户在 Node 20 环境敲下: openclaw doctor
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 前置守卫 — 不兼容!                                        │
│ ① Semver 解析器:解析 process.versions.node → 20.x.x        │
│ ② Node 版本范围检查器:                                       │
│    • major === 22? 否                                        │
│    • major === 24? 否                                        │
│    • major === 25? 否                                        │
│    • major > 25? 否                                          │
│    → 不支持                                                  │
│ ③ 错误输出(stderr 纯文本):                                 │
│    "openclaw: Node.js >=22.22.3 <23, >=24.15.0 <25,        │
│     or >=25.9.0 is required (current: v20.x.x)."            │
│ ④ exit(1)                                                   │
│                                                              │
│ 整个过程不加载 TS bundle,直接退出                           │
└──────────────────────────────────────────────────────────────┘

用户看到错误提示,进程已退出
```

### 一次 Bun(无 sqlite)启动的完整旅程

```
用户在旧版 Bun 环境敲下: openclaw doctor
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 前置守卫 — 不兼容!                                        │
│ ① 检测 process.versions.bun 存在 → 是 Bun                   │
│ ② Bun Feature 探针:探测 node:sqlite                         │
│    • 尝试获取 node:sqlite 内置模块                           │
│    → 失败(Bun 版本太旧,无 sqlite)                         │
│ ③ 错误输出(stderr 纯文本):                                 │
│    "openclaw: this Bun runtime is unsupported..."            │
│ ④ exit(1)                                                   │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Node 24 启动的完整旅程(兼容场景,落到 L2)

```
用户在 Node 24.20 环境敲下: openclaw doctor
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 前置守卫 — 通过                                            │
│ ① Semver 解析器:解析 → 24.20.0                              │
│ ② Node 版本范围检查器:major === 24,≥ 24.15.0 → 通过       │
│ → 继续                                                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ (Layer 4 import TS bundle)                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ L2 完整诊断守卫 — 通过                                        │
│ ① 运行时检测器 → 完整运行时详情:                             │
│    • kind: "node"                                            │
│    • version: "24.20.0"                                      │
│    • execPath / pathEnv / hasNodeSqlite                      │
│ ② Engine Clause 解析器:解析 engines.node,与硬编码一致       │
│ ③ 兼容性检查 → 通过                                          │
│ → 继续(不输出 diagnostic)                                   │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. L1 必须在 TS 加载前完成

- **为什么**:不兼容 Node 加载 TS bundle 会直接崩溃(语法不支持/特性缺失),无法给出友好错误
- **怎么做**:L1 在纯 JS 侧用 semver 解析 + 版本范围检查,不兼容直接 exit(1)
- **影响**:L1 错误只能是纯文本,无法输出 JSON diagnostic

### 2. L2 提供完整诊断作为兜底

- **为什么**:L1 可能因 install 异常未拦住;L2 在 TS 内可输出更友好的 JSON diagnostic
- **怎么做**:L2 检测 RuntimeDetails(kind/version/execPath/pathEnv/hasNodeSqlite),解析 engines.node,输出与运行时 JSONL 日志对齐的 diagnostic
- **影响**:不兼容时,用户能看到结构化错误信息,便于排查

### 3. Bun 用 feature-probe 而非版本拒绝

- **为什么**:Bun ≥1.4(Rust rewrite)支持 node:sqlite,可运行 OpenClaw;直接拒绝 Bun 会误伤 capable builds
- **怎么做**:Bun Feature 探针尝试获取 node:sqlite 内置模块,成功则通过,失败才 exit(1)
- **影响**:降低 false negative,Bun 在 install/package scripts 阶段始终可用

### 4. Node 26+ 直接通过,23 不支持

- **为什么**:OpenClaw 跟随 Node LTS 节奏;23 是奇数版本(非 LTS),跳过;26 是推荐版本
- **怎么做**:版本范围检查只匹配 22/24/25 的最低版本,major > 25 直接通过,其他拒绝
- **影响**:用户用 Node 23 会被拒绝,需升级到 24/25/26

### 5. CI/release 仍 pin Node 24

- **为什么**:开发与 CI 一致性优先于"最新"版本;Node 26 是推荐但 CI 仍用 24
- **怎么做**:AGENTS.md 明确"CI and release workflows still pin Node 24"
- **影响**:开发者本地可用 26,但 CI/release 流程统一用 24

### 6. Engine Clause 与硬编码版本一致性

- **为什么**:package.json 的 engines.node 声明与硬编码版本常量不一致会导致误导
- **怎么做**:L2 的 Engine Clause 解析器解析 engines.node,确保与硬编码版本范围一致
- **影响**:修改支持版本时需同步更新 engines.node 与硬编码常量

## 设计观察

### 为什么需要双重守卫而非一处

```
错误设计(只在 L1 守卫):
   openclaw.mjs 检查版本 → 不兼容 exit(1)
   → L1 因 install 异常未拦住时,TS bundle 加载崩溃
   → 无友好错误,用户不知所措

   只在 L2 守卫:
   → 必须加载 TS bundle 才能检查
   → 不兼容 Node 加载 TS 时直接崩溃,无法给错误
   → 用户体验差

正确设计(双重守卫):
   L1 在 TS 加载前快速 fail(纯文本错误)
   L2 在 TS 内提供完整 JSON diagnostic(兜底)
   → 无论如何都能给出友好错误
```

### 为什么 Bun 用 feature-probe 而非版本号检查

```
错误设计(版本号检查):
   比较 Bun 版本号 < 1.4 → 拒绝
   → Bun 版本号语义不稳定,不同 build 可能差异
   → 误伤 capable Bun builds

正确设计(feature-probe):
   探测 node:sqlite 内置模块是否可用
   → 直接检测能力,不依赖版本号
   → capable Bun builds(无论版本号)都能通过
```

### 为什么 26+ 直接通过而不设上限

```
错误设计(设上限):
   major > 26 → 拒绝
   → Node 27 出来时需手动更新常量
   → 用户用新版 Node 被拒

正确设计(只设下限):
   major > 25 → 通过
   → 未来 Node 版本自动支持
   → 只在奇数版本(23)和非 LTS 跳过
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | 本文件 — Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 关键源码索引 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| L1 前置守卫(纯 JS) | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| L2 完整诊断守卫(TS bundle) | [src/infra/runtime-guard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/runtime-guard.ts) |
| L2 守卫调用点 | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| AGENTS.md 版本约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Commands" 段 |
| package.json engines 声明 | [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json) |
