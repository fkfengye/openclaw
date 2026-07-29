# 00 — 外部入口层(External Entry Layer)总览

> 用户敲下 `openclaw <args>` 后,代码如何从 npm bin 一路走到 Commander 命令树分发?本章用组件视角讲清楚 7 层 launcher 链路的协作关系,不讲代码细节。

## 一句话定位

外部入口层是 OpenClaw 启动链路的最外层,负责**从用户敲下命令到 Commander 接管之前的全部工作**:
- 检查 Node/Bun 版本是否兼容
- 评估是否需要 respawn(进程重启以切换环境)
- 快速响应 `--version` / `--help`(不加载完整代码)
- 规范化运行时环境(env / argv / profile)
- 最后才把控制权交给 Commander 命令树

## 全局协作图

下图展示用户敲下命令后,7 层组件如何协作把命令送到 Commander。

```
                  用户敲下命令
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 1: npm bin 入口                                   │
   │                                                          │
   │ • package.json 声明可执行文件指向 openclaw.mjs           │
   │ • shebang #!/usr/bin/env node                            │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 2: Runtime 守卫 + Respawn 评估                    │
   │                                                          │
   │ • 检查 Node 22+/24+/25+ 或 Bun(含 node:sqlite)       │
   │ • 评估 3 种 respawn 场景(互斥):                       │
   │   ├─ 源码 checkout(禁 cache)                          │
   │   ├─ 打包安装(统一 cache 路径)                        │
   │   └─ NODE_OPTIONS 调整                                  │
   └──────────────────────────┬───────────────────────────────┘
                              │
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 3: Launcher Fast-path(纯 JS,不加载 TS)          │
   │                                                          │
   │ 拦截 3 类请求(命中即 exit):                           │
   │ • --version / -V       → 读 metadata                    │
   │ • --help / -h          → 读 metadata                    │
   │ • <cmd> --help         → 读 metadata                    │
   │                                                          │
   │ 数据源:构建时预计算的 cli-startup-metadata.json        │
   └──────────────────────────┬───────────────────────────────┘
                              │ fast-path 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 4: 动态 import TS bundle                          │
   │                                                          │
   │ • 从 launcher(JS)过渡到 entry(TS bundle)             │
   │ • 抑制 ExperimentalWarning 等 noise                     │
   │ • module not found → 友好错误提示                       │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 5: entry.ts 进程入口 + 环境规范化                 │
   │                                                          │
   │ 17 个步骤顺序执行:                                       │
   │ • isMainModule 守卫(防 bundler 重复执行)              │
   │ • process.title = "openclaw"                            │
   │ • 环境变量规范化                                         │
   │ • Windows argv 兼容                                     │
   │ • profile 解析                                          │
   │ • 第二次 runtime 守卫(更完整诊断)                     │
   │ • 第二次 respawn 评估                                    │
   │ • --no-color → NO_COLOR=1                               │
   │ • container / profile / NODE_OPTIONS 处理               │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 6: entry.ts Fast-path(第二次兜底)                 │
   │                                                          │
   │ • 在 TS bundle 内再次尝试 fast-path                     │
   │ • 可访问 config 文件判断是否 defer                      │
   │ • 命中 → exit(0)                                        │
   └──────────────────────────┬───────────────────────────────┘
                              │ fast-path 全部未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 7: Commander 编排                                 │
   │                                                          │
   │ • 命令树分发(gateway / agent / doctor / plugins ...)   │
   │ • JSON 输出模式路由                                     │
   │ • proxy dispatcher                                       │
   │ • 插件命令别名注册                                       │
   │                                                          │
   │ → 进入业务逻辑(gateway 启动 / agent 执行 / ...)       │
   └──────────────────────────────────────────────────────────┘
```

## 组件清单

外部入口层由 4 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Launcher(JS)** | 纯 JS 启动器,在 TS 加载前完成 runtime 守卫与 fast-path | 无法 import TS 代码;互斥控制严格 |
| **Entry(TS bundle)** | TS bundle 进程入口,完成所有运行时环境规范化 | isMainModule 守卫防重复执行 |
| **Fast-path 体系** | 三层独立 fast-path,逐层兜底拦截 --version/--help | 命中即 exit,不加载后续代码 |
| **预计算 Metadata** | 构建时预渲染的 help/version 文本 | 运行时只读 + 进程级 cache |

## 关联关系

### 三层 Fast-path 的协作

```
   openclaw <args>
        │
        ▼
   ┌─────────────────┐
   │ L1 Launcher     │ 命中 → exit(0)
   │ (openclaw.mjs)  │
   └────────┬────────┘
            │ 未命中
            ▼
   ┌─────────────────┐
   │ L2 Entry.ts     │ 命中 → exit(0)
   │ (TS bundle)     │
   └────────┬────────┘
            │ 未命中
            ▼
   ┌─────────────────┐
   │ L3 run-main.ts  │ 命中 → exit(0)
   │ (Commander 前)  │
   └────────┬────────┘
            │ 未命中
            ▼
       Commander 分发
```

**为什么需要三层?**
- L1 在纯 JS,无法访问 config
- L2 在 TS bundle,可读 config 判断是否含 plugins
- L3 在 Commander 前,有最完整信息

### 双重 Runtime 守卫的协作

```
   ┌─────────────────┐
   │ L1 守卫         │ 粗粒度(只查版本号)
   │ (openclaw.mjs)  │ → 不兼容直接 exit(1)
   └────────┬────────┘
            │ 通过
            ▼
   ┌─────────────────┐
   │ L2 守卫         │ 细粒度(完整诊断信息)
   │ (entry.ts)      │ → 不兼容给出详细原因
   └────────┬────────┘
            │ 通过
            ▼
        继续启动
```

**为什么需要两次?**
- L1 在 TS 加载前必须完成(否则不兼容 Node 加载 TS 会崩)
- L2 在 TS 内,可输出更完整的诊断信息

## 协作流程

### 一次启动的完整旅程

下面追踪 `openclaw --help` 命令从敲下到返回的全过程。

```
用户敲下: openclaw --help
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 1: npm bin 找到 openclaw.mjs                            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 2: Runtime 守卫                                        │
│ • 检查 Node 版本(22.22.3+ / 24.15+ / 25.9+)                │
│ • 检查 Bun 是否有 node:sqlite                                 │
│ • 评估 respawn(源码场景禁 cache,打包场景统一路径)           │
│ → 通过,继续                                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 3: Launcher Fast-path 命中!                            │
│ • 读 dist/cli-startup-metadata.json                          │
│ • 提取预渲染的 --help 文本                                   │
│ • stdout.write 输出                                          │
│ • exit(0)                                                    │
│                                                              │
│ ✨ 整个过程不加载 TS bundle,估算 < 100ms                    │
└──────────────────────────────────────────────────────────────┘

用户看到 help 输出,进程已退出
```

如果 fast-path 没命中(如 `openclaw agent --message "xxx"`),则继续走 Layer 4-7:

```
┌──────────────────────────────────────────────────────────────┐
│ Layer 4: 动态 import TS bundle                               │
│ • tryImport("./dist/entry.js")                              │
│ • 失败回退 tryImport("./dist/entry.mjs")                     │
│ • 都失败 → 友好错误提示(提示重新 build 或安装)             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 5: entry.ts 进程入口                                   │
│ • isMainModule 守卫(防 bundler 重复执行)                   │
│ • process.title = "openclaw"                                │
│ • normalizeEnv / normalizeWindowsArgv                       │
│ • parseCliProfileArgs + applyCliProfileEnv                  │
│ • 第二次 assertSupportedRuntime                              │
│ • 第二次 respawn 评估                                        │
│ • 启用 compile cache                                         │
│ • --no-color → NO_COLOR=1                                    │
│ • 解析 --container / --profile                              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 6: entry.ts Fast-path(再次尝试)                        │
│ • tryHandleRootVersionFastPath                               │
│ • tryHandleRootHelpFastPath(可读 config 判断)                │
│ • tryHandlePrecomputedCommandHelpFastPath                    │
│ • 全部未命中 → 继续                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 7: Commander 编排                                     │
│ • import("./cli/run-main.js")                                │
│ • runCli(argv)                                              │
│ • Console capture / Container dispatch                      │
│ • Plugin command alias 注册                                 │
│ • 命令树分发(如 agent 命令)                                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
                  进入 Agent 运行时
```

### 启动决策树

下面是完整的启动决策树,展示每个分支的去向。

```
              openclaw <args>
                    │
                    ▼
         ┌──────────────────────┐
         │ Runtime 守卫         │
         └──────────┬───────────┘
                    │
           ┌────────▼────────┐
           │ 是否 Bun?       │
           └────┬────────┬───┘
                │ 是     │ 否
                ▼        ▼
         ┌──────────┐  ┌─────────────┐
         │node:sqlite│  │ Node 版本   │
         │ 可用?    │  │ 范围检查    │
         └──┬───┬───┘  └──────┬──────┘
         是 │   │ 否          │
            ▼   ▼             ▼
        继续  exit(1)      继续
                    │
                    ▼
         ┌──────────────────────┐
         │ Launcher Fast-path   │
         │ (--version / -V)     │
         └──────────┬───────────┘
                    │
           ┌────────▼────────┐
           │ 命中?           │
           └────┬────────┬───┘
             是 │        │ 否
                ▼        ▼
           exit(0)  ┌────────────────────┐
                    │ respawn 评估       │
                    │ (源码/打包/hooks)  │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼─────────┐
                    │ 需要 respawn?     │
                    └───┬─────────┬─────┘
                      是 │         │ 否
                         ▼         ▼
                  spawn child  启用 compile cache
                  parent 等     │
                  待 child      ▼
                             ┌──────────────────────┐
                             │ Launcher Fast-path   │
                             │ (--help / <cmd> -h)  │
                             └─────────┬────────────┘
                                       │
                             ┌─────────▼─────────┐
                             │ 命中?             │
                             └──┬─────────┬──────┘
                              是 │         │ 否
                                 ▼         ▼
                           exit(0)    import dist/entry.js
                                     → entry.ts 流程
```

## 关键设计约束

### 1. 双层 Launcher(JS + TS)职责分离

- **Launcher(JS)**:在 TS 加载前必须完成的工作(runtime 守卫、respawn、fast-path)
- **Entry(TS bundle)**:TS 加载后的环境规范化、第二次 fast-path、Commander 编排
- **为什么分离**:launcher 是纯 JS,无法 import TS 代码;TS bundle 加载前必须完成 respawn 与 fast-path

### 2. 三种 Respawn 场景互斥

| 场景 | 触发条件 | 作用 |
|---|---|---|
| 源码 checkout | 检测到 `.git/` 且未 build | 禁用 compile cache(避免缓存污染) |
| 打包安装 | install 后首次运行 | 统一 cache 路径(便于卸载清理) |
| NODE_OPTIONS 调整 | stack size / CA certs 等 | 调整进程参数后重启 |

**互斥控制**:严格的环境变量标记(`COMPILE_CACHE_DISABLED_RESPAWNED_ENV` / `OPENCLAW_PACKAGED_COMPILE_CACHE_RESPAWNED`),防止无限 respawn。

### 3. 预计算 Metadata 同步约束

- `dist/cli-startup-metadata.json` 构建时预渲染
- 运行时只读 + 进程级 cache(Map)
- 源码 checkout 无此文件,fast-path 全部 fallback 到 dynamic
- **开发体验代价**:修改 help 文本后需重新 build 才能测试 L1 fast-path

### 4. Profile / Container / Respawn 互斥关系复杂

- `--container` 与 `--profile` / `--dev` 互斥
- `--dev` 与 `--profile` 互斥(除非 `gateway` 命令)
- `qa matrix` 命令保留 `--profile`
- respawn 跳过策略有 5 个条件

**影响**:新增命令需考虑与 profile/container/respawn 的互斥关系。

### 5. 信号转发三层 Grace

```
信号到达(如 SIGINT)
     │
     ▼
┌─────────────────────────────┐
│ Grace 1: 1s 转发等待       │
│ • 转发信号给 child         │
│ • 等 child 自行退出        │
└────────────┬────────────────┘
             │ child 未退出
             ▼
┌─────────────────────────────┐
│ Grace 2: 1s SIGKILL        │
│ • 强制 kill child          │
│ • 等 child 退出            │
└────────────┬────────────────┘
             │ child 仍未退出
             ▼
┌─────────────────────────────┐
│ Grace 3: 1s hard exit       │
│ • parent 自己 exit         │
│ • Exit code 语义:           │
│   SIGINT → 130              │
│   SIGTERM → 143             │
└─────────────────────────────┘
```

**设计目的**:parent 不卡死,同时给 child 足够时间清理。

## 设计观察

### 为什么不直接加载 TS bundle

```
错误设计:
   openclaw.mjs ──直接 import──► dist/entry.js(TS bundle)
   → 不兼容 Node 加载 TS 时崩溃
   → 无 fast-path,--version 也要加载完整 bundle
   → 冷启动慢

正确设计:
   openclaw.mjs(JS)──► 守卫 + fast-path ──► 才 import TS bundle
   → 不兼容 Node 在守卫阶段就被拦截
   → --version / --help 在 fast-path 阶段快速返回
   → 冷启动 < 100ms(估算)
```

### 为什么需要 isMainModule 守卫

- bundler(如 esbuild)可能把 entry.js 当 shared dep 多次引用
- 如果不守卫,会重复执行:多次设置 process.title、多次启动 gateway
- 守卫确保 entry.js 只执行一次

### 为什么 hooks relay 必须保持 in-process

- Codex 通过 PID 管理 relay timeout
- 如果 hooks relay 被 respawn 成独立进程,PID 会变
- timeout 无法 strand compile-cache respawn child
- **强约束**:Codex 相关变更必须 agent 亲自检查 `../codex` 源码

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本文件 — 总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 关键源码索引 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Launcher(JS) | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| Entry(TS bundle) | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| Commander 编排 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| 预计算 Metadata 读取 | [src/cli/startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/startup-metadata.ts) |
| 预计算 Metadata 生成 | [scripts/write-cli-startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/scripts/write-cli-startup-metadata.ts) |
| Runtime 守卫 | [src/infra/runtime-guard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/runtime-guard.ts) |
| Respawn 策略 | [src/cli/respawn-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/respawn-policy.ts) |
| Profile 解析 | [src/cli/profile.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/profile.ts) |
| Container 目标 | [src/cli/container-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/container-target.ts) |
| Windows argv 兼容 | [src/cli/windows-argv.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/windows-argv.ts) |
| 预计算 Help | [src/cli/precomputed-help.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/precomputed-help.ts) |
