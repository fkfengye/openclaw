# 02 — 三层 Fast-path 体系 + 预计算 Metadata

> 读完本章你将理解:OpenClaw 为什么在启动链路上设置三层独立的快速路径,它们各自的数据源与触发条件有何不同,以及构建时预计算的 metadata 如何让 `--version` / `--help` 冷启动低于 100ms 而不加载 TS bundle。

## 一句话定位

外部入口层在启动链路上设置三处独立 fast-path(L1 启动器、L2 入口、L3 Commander),逐层兜底拦截 `--version` / `--help` / `<cmd> --help`。前两层的数据源是构建时预渲染的 metadata JSON,运行时只读 + 进程级 cache。

## 全局协作图

下图展示三层 fast-path 与预计算 metadata 的协作关系,框内是组件名 + 职责 + 关键约束。

```
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ L1: 启动器快速路径(纯 JS)                              │
   │ 职责:拦截 --version / --help / <cmd> --help            │
   │ 约束:无法读 config;数据源 = metadata + package.json   │
   │ 命中即 exit(0)                                          │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ L2: 入口快速路径(TS bundle 内)                         │
   │ 职责:同上,但可读 live config 判断是否 defer           │
   │ 约束:config 含 config-sensitive plugins → 走 live 渲染 │
   │ 命中即 exit(0)                                          │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ L3: Commander 帮助系统                                   │
   │ 职责:Commander 自身 help/version 渲染(含动态插件信息) │
   │ 约束:会渲染完整 help;之后进入命令分发                  │
   └──────────────────────────────────────────────────────────┘


   ┌──────────────────────────────────────────────────────────┐
   │ 预计算 Metadata 体系(横切 L1 + L2)                      │
   │                                                          │
   │  ┌─────────────────┐    ┌─────────────────┐             │
   │  │ Metadata 生成器 │───►│ Metadata 读取器 │             │
   │  │ (构建时)        │    │ (运行时只读)    │             │
   │  │ 渲染所有 help   │    │ 进程级 cache    │             │
   │  │ 文本到 JSON     │    │ 候选路径回退    │             │
   │  └─────────────────┘    └─────────────────┘             │
   └──────────────────────────────────────────────────────────┘
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **L1 启动器快速路径** | 纯 JS 拦截 version/help/command-help | 无法读 config;命中即 exit(0) |
| **L2 入口快速路径** | TS bundle 内二次兜底拦截 | 可读 live config 判断 defer |
| **L3 Commander 帮助系统** | Commander 自身 help/version 渲染 | 渲染完整 help(含动态插件) |
| **Metadata 生成器** | 构建时预渲染所有 help 文本到 JSON | 修改 help 文本需重新 build |
| **Metadata 读取器** | 运行时只读 metadata + 进程级 cache | cache miss 也存 null,避免重复 IO |
| **Defer 判断器** | 检查 config 是否含 plugins/$include | 决定 root help 是否交给 L2 live 渲染 |

## 关联关系

### 三层 Fast-path 的逐层兜底

```
   openclaw <args>
        │
        ▼
   ┌─────────────────┐
   │ L1 启动器快速路径│ 命中 → exit(0)
   │ (纯 JS)         │
   └────────┬────────┘
            │ 未命中
            ▼
   ┌─────────────────┐
   │ L2 入口快速路径  │ 命中 → exit(0)
   │ (TS bundle)     │
   └────────┬────────┘
            │ 未命中
            ▼
   ┌─────────────────┐
   │ L3 Commander    │ 进入命令分发
   │ 帮助系统        │
   └─────────────────┘
```

**为什么需要三层?**
- L1 在纯 JS,无法访问 config
- L2 在 TS bundle,可读 config 判断是否含 config-sensitive plugins
- L3 在 Commander 前,有最完整信息(含动态插件命令)

### L1 与 L2 的差异(L2 多了 live config 检查)

```
   ┌─────────────────────────────────────────────┐
   │ L1 启动器快速路径(Layer 3)                │
   │                                             │
   │ version fast-path                           │
   │   ├─ 读 package.json + .git/HEAD            │
   │   └─ 命中 → exit(0)                         │
   │                                             │
   │ root help fast-path                         │
   │   ├─ Defer 判断器:config 含 plugins?       │
   │   │   是 → 不命中(defer 到 L2)             │
   │   │   否 → 读 metadata rootHelpText          │
   │   └─ 命中 → exit(0)                         │
   │                                             │
   │ command help fast-path                      │
   │   ├─ 跳过 root option tokens                │
   │   ├─ 第一非 option = 已知命令?              │
   │   ├─ 后续只允许 --help/-h                   │
   │   └─ 命中 → exit(0)                         │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ L2 入口快速路径(Layer 6)                  │
   │                                             │
   │ version fast-path                           │
   │   └─ 异步 import version 模块(兜底)        │
   │                                             │
   │ root help fast-path(多了 live config)      │
   │   ├─ 加载 live config                       │
   │   ├─ 有 config-sensitive plugins?           │
   │   │   是 → 走 live 渲染(显示插件命令)     │
   │   │   否 → 优先 precomputed,fallback live  │
   │   └─ 命中 → exit(0)                         │
   │                                             │
   │ command help fast-path                      │
   │   └─ 逻辑同 L1,作为兜底                    │
   └─────────────────────────────────────────────┘
```

### Metadata 生成与读取的时序

```
   构建时                                   运行时
   ──────                                  ──────

   ┌─────────────────┐                    ┌─────────────────┐
   │ Metadata 生成器 │                    │ L1/L2 fast-path │
   │                 │                    │                 │
   │ 渲染 root help  │                    │ 请求 rootHelpText│
   │ 渲染各子命令    │                    │     │           │
   │ help 文本       │                    │     ▼           │
   │ 写入 metadata   │◄───────────────────│ Metadata 读取器 │
   │ JSON 文件       │   首次读取          │                 │
   └─────────────────┘                    │ • 进程级 cache  │
                                          │ • 命中 cache →  │
                                          │   直接返回      │
                                          │ • 未命中 → 读文件│
                                          │ • 文件缺失 → null│
                                          │   (源码 checkout)│
                                          └─────────────────┘
```

### 错误设计 vs 正确设计:数据源选择

```
错误设计(运行时动态渲染 help):
   每次 --help → 加载 TS bundle → 渲染 root help → 输出
   → 冷启动慢(需加载完整 bundle)
   → 源码 checkout 也要加载 tsx

正确设计(构建时预计算 + 运行时只读):
   构建 → metadata JSON
   --help → 读 metadata → 输出
   → 冷启动 < 100ms(无 TS bundle)
   → 进程级 cache,重复 help 不重读文件
```

## 协作流程

### 一条 `openclaw --help` 的完整旅程(无 plugins 场景)

```
用户敲下: openclaw --help
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 启动器快速路径                                             │
│ ① argv 形态判断:bare --help(argv 长度恰好 3)               │
│ ② Defer 判断器:config 是否含 plugins/$include?              │
│    → 无 → 不 defer                                            │
│ ③ fast-path 禁用开关检查:OPENCLAW_DISABLE_...≠ "1"          │
│ ④ Metadata 读取器:读 metadata 的 rootHelpText               │
│    → cache miss → 读文件 → 写 cache                          │
│ ⑤ stdout.write 输出                                           │
│ ⑥ exit(0)                                                    │
│                                                              │
│ 整个过程不加载 TS bundle                                      │
└──────────────────────────────────────────────────────────────┘

用户看到 help 输出,进程已退出
```

### 一条 `openclaw --help` 的旅程(有 plugins 场景)

```
用户敲下: openclaw --help(config 含 plugins)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 启动器快速路径 — 不命中(defer)                            │
│ ① Defer 判断器:config 含 plugins → defer 到 L2              │
│ → 继续(不 exit)                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ (Layer 4 import TS bundle)                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ L2 入口快速路径 — 命中(走 live 渲染)                         │
│ ① 加载 live config                                            │
│ ② 检查 config-sensitive plugins                              │
│    → 有 → 走 live root help 渲染(显示插件命令)              │
│ ③ stdout.write 输出(含插件命令)                             │
│ ④ exit(0)                                                    │
└──────────────────────────────────────────────────────────────┘

用户看到含插件命令的 help 输出
```

### 一条 `openclaw browser --help` 的旅程

```
用户敲下: openclaw browser --help
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ L1 启动器快速路径 — 命中!                                     │
│ ① argv 解析:                                                  │
│    • 跳过 root option tokens(--dev/--no-color/--profile= 等) │
│    • 第一非 option token = "browser"(已知命令)              │
│    • 后续 token 只有 --help/-h                                │
│ ② container 目标检查:无 → 继续                               │
│ ③ Metadata 读取器:读 metadata 的 browserHelpText            │
│ ④ stdout.write 输出                                           │
│ ⑤ exit(0)                                                    │
└──────────────────────────────────────────────────────────────┘
```

### Metadata 字段与调用方对应关系

| Metadata 字段 | 用途 | 调用方 |
|---|---|---|
| rootHelpText | bare `--help` 输出 | L1 root help / L2 root help |
| browserHelpText | `openclaw browser --help` | L1 command help / L2 command help |
| secretsHelpText | `openclaw secrets --help` | L1 command help / L2 command help |
| nodesHelpText | `openclaw nodes --help` | L1 command help / L2 command help |
| subcommandHelpText(doctor/gateway/models/plugins/sessions/tasks) | 各子命令 `--help` | L1 command help / L2 command help |
| generatedBy | 生成脚本标识 | 内部 |

## 关键设计约束

### 1. Metadata 构建时生成,运行时只读

- **为什么**:运行时渲染 help 需加载 TS bundle,冷启动慢;构建时预渲染可让 L1 纯 JS 直接读
- **怎么做**:构建流程中由生成器渲染所有 help 文本写入 JSON;运行时只读 + 进程级 cache
- **影响**:修改 help 文本后需重新 build 才能测试 L1 fast-path

### 2. 源码 checkout 无 metadata,L1 全部 fallback

- **为什么**:源码 checkout 未 build,dist 下无 metadata JSON
- **怎么做**:Metadata 读取器文件缺失时返回 null,L1 fast-path 不命中,落到 L2 动态渲染
- **影响**:开发阶段 L1 fast-path 不生效,help 走 L2 live 渲染

### 3. Defer 判断器决定 root help 去向

- **为什么**:config 含 plugins 时,root help 需显示插件命令,L1 无法渲染(无插件信息)
- **怎么做**:Defer 判断器检查 config 是否含 plugins/$include,或环境变量是否启用 bundled plugins;命中则 defer 到 L2
- **影响**:有 plugins 的安装,`--help` 必须加载 TS bundle 走 live 渲染

### 4. Metadata 读取器进程级 cache 避免重复 IO

- **为什么**:一次进程生命周期内可能多次读 metadata(虽 fast-path 命中即 exit,但 L2 可能多次尝试)
- **怎么做**:用 Map 按 metadata 路径缓存;cache miss 也存 null,避免重复读缺失文件
- **影响**:候选路径包含同目录 + 上级目录(支持 source 和 bundled 布局)

### 5. Command help fast-path 的 argv 解析严格

- **为什么**:误命中会把非 help 命令当 help 处理,导致命令不执行
- **怎么做**:跳过 root option tokens 后,第一非 option 必须是已知命令名,后续只允许 --help/-h;任何其他 token 都不命中
- **影响**:新增命令需同步更新已知命令列表

### 6. L1 与 L2 逻辑相似但不完全相同

- **为什么**:L2 多了 live config 检查(config-sensitive plugins),L1 无法访问 config
- **怎么做**:L1 优先 precomputed,缺失时 fallback dynamic import;L2 先检查 live config,无 config-sensitive plugins 才用 precomputed
- **影响**:维护时需同步两处,容易遗漏

## 设计观察

### 为什么需要三层而非一层

```
错误设计(只在 L1 做 fast-path):
   openclaw --help(有 plugins)
   → L1 读 metadata 的 rootHelpText
   → 输出缺插件命令的 help
   → 用户看不到插件命令,误导

   openclaw --help(源码 checkout)
   → L1 无 metadata 文件
   → fallback dynamic import(加载 TS bundle)
   → 但 L1 在纯 JS,dynamic import 可能因路径异常失败

正确设计(三层):
   L1 命中(无 plugins + 有 metadata)→ 最快
   L1 不命中(defer / 无 metadata)→ L2 兜底
   L2 可读 live config,正确渲染插件命令
   L3 Commander 完整渲染,作为最后保障
```

### 为什么 metadata 用进程级 cache 而非每次读文件

```
错误设计(每次读文件):
   每次 fast-path → fs.readFileSync(metadata)
   → 重复 IO,即使同进程内多次请求
   → 文件缺失时重复尝试

正确设计(进程级 cache):
   首次读 → 缓存到 Map(含 null 结果)
   后续读 → 命中 cache 直接返回
   → 零 IO,文件缺失也不重复尝试
```

### 为什么 command help 的 argv 解析要跳过 root option tokens

```
错误设计(不跳过 root options):
   openclaw --dev browser --help
   → 第一 token = "--dev" → 非已知命令 → 不命中
   → 用户加了 --dev 就拿不到 precomputed help

正确设计(跳过 root options):
   openclaw --dev browser --help
   → 跳过 --dev → 第一非 option = "browser" → 已知命令
   → 后续只有 --help → 命中
   → 用户加 root option 也能 fast-path
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 本文件 — 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 关键源码索引 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| L1 启动器快速路径 | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| L2 入口快速路径 | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| L3 Commander 帮助系统 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| Metadata 读取器 | [src/cli/startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/startup-metadata.ts) |
| 预计算 help 逻辑 | [src/cli/precomputed-help.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/precomputed-help.ts) |
| Metadata 生成器(构建时) | [scripts/write-cli-startup-metadata.ts](file:///d:/DevSpace/person/ai_space/openclaw/scripts/write-cli-startup-metadata.ts) |
| Metadata JSON 产物 | [dist/cli-startup-metadata.json](file:///d:/DevSpace/person/ai_space/openclaw/dist/cli-startup-metadata.json) |
| argv helpers(help/version 检测) | [src/cli/argv.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/argv.ts) |
| Root help 渲染器 | [src/cli/program/root-help.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/program/root-help.ts) |
