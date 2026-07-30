# 07 — 关键源码索引

> 读完本章你将理解:外部入口层涉及的全部源码如何按 6 个职责分层组织,每层各自负责什么,以及如何高效定位前 6 章讲过的组件在哪个源码文件中。

## 一句话定位

本章是外部入口层的"源码地图":把前 6 章的组件概念(Launcher、Entry、Fast-path、Runtime 守卫、Respawn、Commander 编排)映射到具体源码文件位置,供读者从概念视角切到代码视角。本章不讲解代码细节,只提供查阅入口。

## 全局协作图

下图展示源码的 6 个分层如何协作支撑入口层运行,框内是分层名 + 职责 + 关键约束。

```
                  用户敲下命令
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 1: Launcher 层(纯 JS)                             │
   │                                                          │
   │ • 职责:npm bin 入口 + 前置守卫 + 启动器 fast-path      │
   │ • 约束:单文件,无法 import TS 代码                      │
   │ • 文件数:1                                              │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 2: Entry 层(TS bundle 入口)                       │
   │                                                          │
   │ • 职责:进程入口 + 环境规范化 + 第二次 fast-path 兜底    │
   │ • 约束:isMainModule 守卫防重复执行                       │
   │ • 文件数:4(主入口 + 3 个辅助模块)                      │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 3: CLI 子层                                         │
   │                                                          │
   │ • 职责:Commander 编排 + argv/profile/container 解析     │
   │         + respawn 跳过策略 + 预计算 help/metadata 读取   │
   │ • 约束:命令树编排是入口层终点                            │
   │ • 文件数:13+                                            │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 4: Infra 层                                         │
   │                                                          │
   │ • 职责:runtime 守卫 + isMainModule + warning filter     │
   │         + env/git-commit/path/cwd 等基础设施             │
   │ • 约束:被多层共享,职责单一                              │
   │ • 文件数:11+                                            │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 5: Process 层                                       │
   │                                                          │
   │ • 职责:child process 信号桥接 + respawn child 运行器    │
   │ • 约束:parent/child 进程间协作专用                       │
   │ • 文件数:2                                              │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 分层 6: 构建脚本                                         │
   │                                                          │
   │ • 职责:构建时预计算 metadata + 确保 metadata 存在       │
   │         + 主构建流程 + tsdown 构建配置                   │
   │ • 约束:构建时生成,运行时只读                            │
   │ • 文件数:4                                              │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
                  配置文件(package.json 等)
                  声明 bin/files/workspace
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 源码分层 | 职责 | 关键约束 | 文件数 |
|---|---|---|---|
| **Launcher 层(纯 JS)** | npm bin 入口 + 前置守卫 + 启动器 fast-path | 单文件,无法 import TS 代码 | 1 |
| **Entry 层(TS bundle 入口)** | 进程入口 + 环境规范化 + 第二次 fast-path 兜底 | isMainModule 守卫防重复执行 | 4 |
| **CLI 子层** | Commander 编排 + argv/profile/container 解析 + respawn 跳过策略 + 预计算 help/metadata 读取 | 命令树编排是入口层终点 | 13+ |
| **Infra 层** | runtime 守卫 + isMainModule + warning filter + env/git/path/cwd 基础设施 | 被多层共享,职责单一 | 11+ |
| **Process 层** | child process 信号桥接 + respawn child 运行器 | parent/child 进程间协作专用 | 2 |
| **构建脚本** | 构建时预计算 metadata + 确保 metadata 存在 + 主构建流程 + tsdown 配置 | 构建时生成,运行时只读 | 4 |

## 关联关系

### 分层之间的依赖关系

```
   ┌──────────────────────────────────────────────────────────┐
   │ 构建脚本(分层 6)                                        │
   │   ↓ 生成 dist/cli-startup-metadata.json                  │
   │   ↓ 构建 dist/entry.js(TS bundle)                      │
   └──────────────────────────────────────────────────────────┘
                              │ 构建产物
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Launcher 层(分层 1)                                     │
   │   → 读取 metadata(L1 fast-path)                        │
   │   → 动态 import TS bundle                                │
   └──────────────────────────────────────────────────────────┘
                              │ import
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Entry 层(分层 2)                                        │
   │   → 调用 Infra 层守卫、env、isMainModule                 │
   │   → 调用 Process 层 respawn 运行器                       │
   │   → 委托 CLI 子层命令树编排                              │
   └──────────────────────────────────────────────────────────┘
                              │ 委托
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ CLI 子层(分层 3)                                        │
   │   → 调用 Infra 层 argv/root-options/git-commit           │
   │   → 调用 Infra 层 proxy 生命周期                         │
   │   → Commander 命令树分发                                 │
   └──────────────────────────────────────────────────────────┘
                              ▲
                              │ 被复用
   ┌──────────────────────────────────────────────────────────┐
   │ Infra 层(分层 4)                                        │
   │   ← 被 Launcher / Entry / CLI 三层共享                   │
   │   ← 提供 runtime 守卫、env、isMainModule、warning filter │
   └──────────────────────────────────────────────────────────┘
```

### 概念章节与源码分层的映射

```
   ┌──────────────────────────────────────────────────────────┐
   │ 第 1 章(7 层架构)                                       │
   │   → Launcher 层 + Entry 层 + CLI 子层(分层 1/2/3)       │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 第 2 章(fast-path 体系)                                 │
   │   → Launcher 层 fast-path + Entry 层 version fast-path   │
   │     + CLI 子层 precomputed-help + 构建脚本 metadata 生成 │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 第 3 章(respawn 体系)                                   │
   │   → Entry 层 respawn 计划 + CLI 子层 respawn 跳过策略    │
   │     + Process 层 child 运行器 + 信号桥接                 │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 第 4 章(runtime 守卫)                                   │
   │   → Launcher 层前置守卫 + Infra 层 runtime 守卫          │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 第 5 章(调用流程)                                       │
   │   → 全部 6 层(全景链路)                                 │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 第 6 章(设计评估)                                       │
   │   → 证据来自全部 6 层                                     │
   └──────────────────────────────────────────────────────────┘
```

### 测试文件组织

```
   ┌──────────────────────────────────────────────────────────┐
   │ 测试文件位置约定                                         │
   │                                                          │
   │ • Entry 层测试:与源码同目录(sibling)                   │
   │   - entry.compile-cache.test.ts                          │
   │   - entry.respawn.test.ts                                │
   │   - entry.test.ts                                        │
   │   - entry.version-fast-path.test.ts                      │
   │   - entry.root-help-fast-path.test.ts                    │
   │                                                          │
   │ • 命名约定:<源码名>.test.ts                              │
   │ • 位置约定:与被测文件同目录(Vitest colocated)          │
   └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 一次源码查阅的完整旅程

下面追踪"想了解 fast-path 实现"的查阅路径,展示从概念到源码的完整流程。

```
读者目标:想了解 L1/L2/L3 三层 fast-path 的实现细节
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 步骤 1: 从第 2 章建立概念心智模型                             │
│ • 阅读 02-fast-path-system.md                                │
│ • 理解三层 fast-path 的职责分工                              │
│ • 记下需要查阅的组件:L1 启动器、L2 入口、L3 命令树前         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 步骤 2: 查阅 L1 启动器 fast-path(Launcher 层)               │
│ • 翻到本章末尾"源码索引"小节                                 │
│ • 找到"Launcher 层"分组                                      │
│ • 打开对应 file:/// 链接                                     │
│ • 关注:help argv 解析、defer 判断、metadata 读取、           │
│        version/root-help/command-help fast-path 各分支       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 步骤 3: 查阅 L2 入口 fast-path(Entry 层)                    │
│ • 翻到本章末尾"源码索引"小节                                 │
│ • 找到"Entry 层"分组                                         │
│ • 打开主入口文件 + version-fast-path 辅助模块                │
│ • 关注:version fast-path、root-help fast-path、             │
│        command-help fast-path 的 TS bundle 侧实现            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌────────────────────────────┬─────────────────────────────────┐
│ 步骤 4: 查阅 metadata 读取(CLI 子层)                       │
│ • 翻到本章末尾"源码索引"小节                                 │
│ • 找到"CLI 子层"分组                                         │
│ • 打开预计算 help 读取 + metadata 读取两个文件               │
│ • 关注:metadata 路径解析、进程级 cache、子命令 help 解析     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 步骤 5: 查阅 metadata 生成(构建脚本)                        │
│ • 翻到本章末尾"源码索引"小节                                 │
│ • 找到"构建脚本"分组                                         │
│ • 打开 metadata 生成器                                       │
│ • 关注:字段类型、reusable 判断、输出路径                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  完整理解 fast-path 实现
```

### 按"想解决的问题"查阅

```
   ┌──────────────────────────────────────────────────────────┐
   │ 我想了解 runtime 守卫实现                                 │
   │   → Infra 层 runtime 守卫文件                             │
   │   → Launcher 层前置守卫(同一文件的 JS 版本)             │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 我想了解 respawn 跳过策略                                 │
   │   → CLI 子层 respawn 策略文件                             │
   │   → Entry 层 respawn 计划文件                             │
   │   → Process 层 child 运行器文件                           │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 我想了解 --profile / --container 解析                     │
   │   → CLI 子层 profile 解析 + container 目标文件            │
   │   → CLI 子层 profile 工具文件                             │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 我想了解信号转发三层 grace                                │
   │   → Launcher 层信号配置 + 信号转发(同一文件)            │
   │   → Process 层信号桥接文件                                │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │ 我想了解 Windows argv 兼容                                │
   │   → CLI 子层 Windows argv 兼容文件                        │
   └──────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 源码分层与运行时分层一致

- **为什么**:让读者从概念视角(7 层架构)到源码视角(6 个分层)的映射直观
- **怎么做**:Launcher 层 = Layer 1-3;Entry 层 = Layer 4-6;CLI 子层 = Layer 7;Infra 层 = 共享基础设施;Process 层 = 进程间协作;构建脚本 = 构建时产物
- **影响**:新增组件时需明确属于哪个分层,避免跨层放置

### 2. Infra 层被多层共享

- **为什么**:runtime 守卫、isMainModule、warning filter 等是基础设施,不应重复实现
- **怎么做**:Infra 层文件职责单一,被 Launcher / Entry / CLI 三层共享调用
- **影响**:修改 Infra 层文件需考虑对三层的影响

### 3. 构建脚本与运行时分离

- **为什么**:metadata 是构建时预渲染的产物,运行时只读,不能在运行时生成
- **怎么做**:构建脚本独立目录(scripts/),生成 dist/cli-startup-metadata.json 供运行时读取
- **影响**:修改 help 文本需重新 build 才能测试 L1 fast-path

### 4. 测试文件与源码同目录

- **为什么**:Vitest colocated 约定,便于查找与维护
- **怎么做**:测试文件命名 `<源码名>.test.ts`,与被测文件同目录
- **影响**:Entry 层有 5 个测试文件与源码同目录

### 5. 单文件 Launcher 是架构约束

- **为什么**:Launcher 是纯 JS,在 TS 加载前运行,无法 import TS 模块
- **怎么做**:Launcher 层只有一个文件,所有逻辑(守卫、fast-path、respawn、信号)集中其中
- **影响**:单文件较大(~819 行),但保持纯 JS 单文件是必要约束

### 6. 配置文件声明 bin/files 入口

- **为什么**:npm 发布需要明确 bin 入口和 files 白名单
- **怎么做**:package.json 声明 bin 指向 Launcher 文件,files 声明 dist 白名单;pnpm-workspace.yaml 声明 workspace
- **影响**:新增 dist 文件需更新 files 白名单

## 设计观察

### 为什么测试文件与源码同目录

```
错误设计(集中测试目录):
   tests/entry.test.ts
   tests/cli/run-main.test.ts
   → 查找测试需在两个目录间切换
   → 重构时容易遗漏测试

正确设计(colocated):
   src/entry.ts + src/entry.test.ts(同目录)
   → 查找测试:看源码目录即可
   → 重构时:同目录文件一起移动
   → 符合 Vitest 默认约定
```

### 为什么 Infra 层不按"功能域"拆分

```
错误设计(按功能域拆分):
   infra/runtime/ 守卫、版本、检测
   infra/process/ isMain、warning、exit
   → 层级过深,查找需记住功能域
   → 文件少但目录多,增加导航成本

正确设计(扁平化):
   infra/runtime-guard.ts
   infra/is-main.ts
   infra/warning-filter.ts
   → 文件名即职责,2-3 词唯一
   → 扁平目录,直接 grep 即可定位
   → 符合 AGENTS.md "agents navigate by grep" 原则
```

### 为什么 Process 层只有 2 个文件

```
错误设计(过度拆分):
   process/child-spawn.ts
   process/child-signal.ts
   process/child-exit.ts
   process/parent-wait.ts
   → 拆分过细,跨文件理解成本高
   → 进程协作本就是紧耦合逻辑

正确设计(按职责边界):
   process/child-process-bridge.ts(信号桥接)
   process/respawn-child-runner.ts(respawn 运行)
   → 2 个文件覆盖 parent/child 协作
   → 每个文件职责清晰,边界明确
   → 符合 "split files around ~700 LOC when clarity improves" 原则
```

## 关键常量速查

### 版本常量

```
Node 22 最低:22.22.3
Node 24 最低:24.15.0
Node 25 最低:25.9.0
推荐:Node 26
Bun:需支持 node:sqlite(≥1.4 Rust rewrite)
```

### 信号常量

```
Windows:SIGTERM, SIGINT, SIGBREAK
Unix:   SIGTERM, SIGINT, SIGHUP, SIGQUIT

Exit code 映射:
SIGINT  → 130
SIGTERM → 143
其他    → 1
```

### 环境变量速查

| 环境变量 | 用途 | 默认值 |
|---|---|---|
| `NODE_COMPILE_CACHE` | 编译缓存路径 | - |
| `NODE_DISABLE_COMPILE_CACHE` | 禁用编译缓存 | - |
| `OPENCLAW_COMPILE_CACHE_DISABLED_RESPAWNED` | 标记场景 A(源码)已 respawn | - |
| `OPENCLAW_PACKAGED_COMPILE_CACHE_RESPAWNED` | 标记场景 B(打包)已 respawn | - |
| `OPENCLAW_DISABLE_CLI_STARTUP_HELP_FAST_PATH` | 禁用 L1 help fast-path | - |
| `OPENCLAW_BUNDLED_PLUGINS_DIR` | bundled plugins 目录 | - |
| `OPENCLAW_DISABLE_BUNDLED_PLUGINS` | 禁用 bundled plugins | - |
| `OPENCLAW_CONTAINER` | container 目标 | - |
| `OPENCLAW_CONFIG_PATH` | 显式 config 路径 | - |
| `OPENCLAW_STATE_DIR` | state 目录覆盖 | - |
| `OPENCLAW_HOME` | home 目录覆盖 | - |
| `OPENCLAW_BUNDLED_VERSION` | 版本覆盖 | - |
| `OPENCLAW_NO_RESPAWN` | 禁用 respawn | - |
| `OPENCLAW_AUTH_STORE_READONLY` | auth store 只读(secrets audit) | - |
| `OPENCLAW_PROFILE` | profile(由 --profile 设置) | - |
| `OPENCLAW_NODE_EXTRA_CA_CERTS` | 自定义 CA certs | - |
| `OPENCLAW_NODE_OPTIONS_READY` | NODE_OPTIONS 已应用 | - |
| `GIT_COMMIT` / `GIT_SHA` | git commit 覆盖 | - |
| `NO_COLOR` / `FORCE_COLOR` | color 控制 | - |

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 本文件 — 关键源码索引 |

## 源码索引

> 以下为本章涉及的全部源码位置,供深入查阅使用。按 6 个分层分组,文件名即职责。

### Launcher 层(纯 JS)

| 组件 | 源码位置 |
|---|---|
| npm bin 入口 + 前置守卫 + 启动器 fast-path + respawn 评估 + 信号转发 + compile cache + warning filter + help argv 解析 + defer 判断 + metadata 读取 + version fast-path + git commit 解析 + root help fast-path + command help fast-path + import TS bundle | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |

### Entry 层(TS bundle 入口)

| 组件 | 源码位置 |
|---|---|
| TS bundle 进程入口(isMainModule 守卫 + 环境初始化 + 第二次 runtime 守卫 + 第二次 respawn + env 调整 + container/profile 解析 + fast-path 入口 + root help fast-path + command help fast-path + 命令树编排委托) | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| Compile cache 管理(Node 24 deadlock 检测 + 源码 checkout 判断 + compile cache 启用判断 + 路径 segment 清理 + 版本读取) | [src/entry.compile-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.compile-cache.ts) |
| Respawn 计划(volta-shim 处理 + experimental warning 抑制判断 + stack size 配置判断 + respawn 命令构建) | [src/entry.respawn.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.respawn.ts) |
| Version fast-path(TS bundle 侧 --version 快速返回) | [src/entry.version-fast-path.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.version-fast-path.ts) |
| 测试:compile cache | [src/entry.compile-cache.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.compile-cache.test.ts) |
| 测试:respawn 计划 | [src/entry.respawn.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.respawn.test.ts) |
| 测试:entry 主入口 | [src/entry.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.test.ts) |
| 测试:version fast-path | [src/entry.version-fast-path.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.version-fast-path.test.ts) |
| 测试:root help fast-path | [src/entry.root-help-fast-path.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.root-help-fast-path.test.ts) |

### CLI 子层

| 组件 | 源码位置 |
|---|---|
| Commander 编排(命令树分发 + JSON 输出路由 + console capture + proxy dispatcher) | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| argv helpers(help/version flag 识别 + root command 描述符 + help/version 调用判断) | [src/cli/argv.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/argv.ts) |
| argv invocation 解析 | [src/cli/argv-invocation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/argv-invocation.ts) |
| 预计算 help 读取(子命令 help 命令列表 + help flag 识别 + 子命令 help 解析) | [src/cli/precomputed-help.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/precomputed-help.ts) |
| metadata 文件读取(路径候选解析 + 进程级 cache + testing API) | [src/cli/startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/startup-metadata.ts) |
| profile 解析(--profile 参数解析) | [src/cli/profile.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/profile.ts) |
| profile 工具 | [src/cli/profile-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/profile-utils.ts) |
| container 目标(--container 参数解析 + 目标解析) | [src/cli/container-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/container-target.ts) |
| respawn 跳过策略(gateway flags + 交互式 TTY 命令 + hooks relay 判断 + 前台 gateway 判断 + 跳过决策) | [src/cli/respawn-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/respawn-policy.ts) |
| Windows argv 兼容 | [src/cli/windows-argv.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/windows-argv.ts) |
| 一次性 exit(vitest worker 标记 + node runtime option + exit code 解析) | [src/cli/one-shot-exit.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/one-shot-exit.ts) |
| root help 渲染 | [src/cli/program/root-help.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/program/root-help.ts) |
| live config help options | [src/cli/root-help-live-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/root-help-live-config.ts) |
| metadata-based help | [src/cli/root-help-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/root-help-metadata.ts) |

### Infra 层

| 组件 | 源码位置 |
|---|---|
| runtime 守卫(TS 侧,默认 runtime + 版本常量 + semver 解析 + 版本比较 + 运行时检测) | [src/infra/runtime-guard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/runtime-guard.ts) |
| isMainModule 守卫 | [src/infra/is-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/is-main.ts) |
| 进程 warning filter | [src/infra/warning-filter.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/warning-filter.ts) |
| env 规范化 | [src/infra/env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/env.ts) |
| exec marker | [src/infra/openclaw-exec-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/openclaw-exec-env.ts) |
| home dir 解析 | [src/infra/home-dir.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/home-dir.ts) |
| root option 解析 | [src/infra/cli-root-options.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/cli-root-options.ts) |
| git commit 解析 | [src/infra/git-commit.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/git-commit.ts) |
| PATH env 管理 | [src/infra/path-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-env.ts) |
| 安全 cwd | [src/infra/safe-cwd.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/safe-cwd.ts) |
| 数字解析 | [src/infra/parse-finite-number.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/parse-finite-number.ts) |
| proxy 生命周期 | [src/infra/net/proxy/proxy-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/proxy-lifecycle.ts) |

### Process 层

| 组件 | 源码位置 |
|---|---|
| child process 信号桥接 | [src/process/child-process-bridge.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/process/child-process-bridge.ts) |
| respawn child 运行器 | [src/process/respawn-child-runner.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/process/respawn-child-runner.ts) |

### 构建脚本

| 组件 | 源码位置 |
|---|---|
| metadata JSON 生成器(输出路径 + 字段类型 + reusable 判断 + 字段生成 + 输出) | [scripts/write-cli-startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/scripts/write-cli-startup-metadata.ts) |
| 主构建脚本(metadata 生成 step + 多处引用) | [scripts/build-all.mjs](file:///d:/DevSpace/person/ai_space/openclaw/scripts/build-all.mjs) |
| 确保 metadata 存在(startup metadata 路径检查) | [scripts/ensure-cli-startup-build.mjs](file:///d:/DevSpace/person/ai_space/openclaw/scripts/ensure-cli-startup-build.mjs) |
| tsdown 构建配置(preserved output files) | [scripts/tsdown-build.mjs](file:///d:/DevSpace/person/ai_space/openclaw/scripts/tsdown-build.mjs) |

### 配置文件

| 组件 | 源码位置 |
|---|---|
| 项目元数据(schemaVersions + bin + files 白名单) | [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json) |
| workspace 配置 | [pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml) |
