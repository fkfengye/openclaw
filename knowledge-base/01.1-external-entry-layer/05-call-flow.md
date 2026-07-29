# 05 — 完整调用流程图

> 读完本章你将理解:从用户敲下 `openclaw <args>` 到 Commander 命令树分发的完整链路,每个决策点(是否 respawn、是否 fast-path 命中、是否 container re-exec)如何影响流程走向,以及关键 exit code 的语义。

## 一句话定位

本章是入口层的"全景地图":把前 4 章的 7 层架构、三层 fast-path、respawn 体系、双重守卫串成一条完整的调用链,用决策树与编号框图展示每个分支的去向。

## 全局协作图

下图展示完整调用链路的顶层视图,框内是组件名 + 职责 + 关键约束。

```
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Bin 入口 + 前置守卫                                      │
   │ 职责:shebang 启动 + runtime 版本检查 + respawn 评估    │
   │ 约束:TS 加载前完成;不兼容直接 exit(1)                │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 启动器快速路径                                           │
   │ 职责:拦截 --version / --help / <cmd> --help            │
   │ 约束:命中即 exit(0);未命中继续                        │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ TS Bundle 加载器                                         │
   │ 职责:动态 import TS bundle + 容错 fallback             │
   │ 约束:加载不可逆;失败给友好提示                         │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 进程入口规范化                                           │
   │ 职责:env/argv/profile/container 全部归一 + 二次守卫     │
   │ 约束:17 步顺序执行;isMainModule 守卫                   │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 入口快速路径                                             │
   │ 职责:TS bundle 内二次兜底 fast-path                     │
   │ 约束:可读 config 判断 defer;命中即 exit(0)            │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 命令树编排                                               │
   │ 职责:Commander 分发 + 容器 re-exec + proxy + capture   │
   │ 约束:入口层终点;之后进入业务逻辑                       │
   └──────────────────────────────────────────────────────────┘
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Bin 入口 + 前置守卫** | shebang 启动 + runtime 检查 + respawn 评估 | TS 加载前完成;不兼容 exit(1) |
| **启动器快速路径** | 拦截 --version/--help/command-help | 命中即 exit(0);纯 JS |
| **TS Bundle 加载器** | 动态 import + 容错 fallback | 加载不可逆;失败给友好提示 |
| **进程入口规范化** | env/argv/profile/container 归一 + 二次守卫 | 17 步顺序;isMainModule 守卫 |
| **入口快速路径** | TS bundle 内二次兜底拦截 | 可读 config 判断 defer |
| **命令树编排** | Commander 分发 + 容器/proxy/capture | 入口层终点 |

## 关联关系

### 三个关键决策点

```
   ┌──────────────────────────────────────────────────────────┐
   │ 决策 1: 是否 respawn?                                   │
   │                                                          │
   │  hooks relay + 非 Windows? → 跳过(in-process)          │
   │  源码 checkout + cache 启用? → respawn(场景 A)         │
   │  打包安装 + cache 路径不统一? → respawn(场景 B)        │
   │  需要 NODE_OPTIONS 调整 + 非跳过命令? → respawn(场景 C)│
   │  否则 → 不 respawn                                       │
   └──────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │ 决策 2: 是否 fast-path 命中?                            │
   │                                                          │
   │  --version? → L1 启动器 / L2 入口 fast-path             │
   │  --help(无 plugins)? → L1 / L2 root help fast-path     │
   │  <cmd> --help? → L1 / L2 command help fast-path         │
   │  都不命中 → 命令树编排                                  │
   └──────────────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────────────┐
   │ 决策 3: 是否 container re-exec?                         │
   │                                                          │
   │  --container <id> 指定?                                  │
   │    + --profile/--dev? → 报错 exit(2)                    │
   │    单独使用 → 容器内 re-exec                             │
   │  否 → 继续                                              │
   └──────────────────────────────────────────────────────────┘
```

### Exit Code 语义总览

| 触发条件 | Exit Code | 含义 |
|---|---|---|
| --version / --help / <cmd> --help 命中 | 0 | 正常退出 |
| Runtime 不兼容(Node/Bun) | 1 | 通用错误 |
| TS bundle 缺失(未 build) | 1 | 通用错误(throw) |
| --container 解析错误 | 2 | 参数错误 |
| --profile 解析错误 | 2 | 参数错误 |
| --container + --profile 同时使用 | 2 | 互斥违规 |
| 命令树编排执行错误 | 1 | 通用错误(process.exitCode) |
| SIGINT(Ctrl+C) | 130 | shell 约定(128+2) |
| SIGTERM | 143 | shell 约定(128+15) |

### 关键 Trace 标记

| Mark 名 | 含义 |
|---|---|
| entry | trace context 创建(进程入口开始) |
| bootstrap | runtime 守卫完成,准备 respawn 评估 |
| argv | argv/profile/container 处理完成 |
| run-main-import | 开始 import 命令树编排模块 |
| cli.main | 命令树编排的新 trace context |

## 协作流程

### 完整调用链路(详细版)

下面追踪一条会落到 Commander 的命令,展示从敲下到分发的全过程。

```
用户输入: openclaw <args>
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Bin 入口 + 前置守卫                                          │
│                                                              │
│ ① npm bin 找到可执行文件,shebang 用 node 启动              │
│ ② 前置守卫:检查 Node/Bun 版本                              │
│    • Bun? → 探测 node:sqlite                               │
│    • Node? → 检查 22.22.3+ / 24.15+ / 25.9+               │
│    • 不兼容 → exit(1)                                      │
│ ③ --version fast-path 评估                                  │
│    • 命中 → stdout.write + exit(0)                         │
│ ④ respawn 评估                                              │
│    • hooks relay + 非 Windows? → 跳过(in-process)         │
│    • 源码 checkout? → respawn 禁 cache(场景 A)            │
│    • 打包安装 + 路径不统一? → respawn 统一路径(场景 B)   │
│    • respawn → parent 等待 child,透传 exit code            │
│ ⑤ 启用 compile cache(若未 respawn)                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 启动器快速路径(纯 JS)                                      │
│                                                              │
│ ① root help fast-path                                        │
│    • bare --help?                                            │
│    • Defer 判断器:config 含 plugins? → defer               │
│    • fast-path 禁用开关?                                    │
│    • 读 metadata rootHelpText → stdout.write + exit(0)      │
│ ② command help fast-path                                    │
│    • 跳过 root option tokens                                 │
│    • 第一非 option = 已知命令?                              │
│    • 后续只有 --help/-h?                                     │
│    • container 目标? → 不命中                               │
│    • 读 metadata 子命令 help → stdout.write + exit(0)      │
│ • 全部未命中 → 继续                                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ TS Bundle 加载器                                             │
│                                                              │
│ ① 抑制 ExperimentalWarning 噪声                             │
│ ② 动态 import TS bundle(.js 优先)                         │
│ ③ 失败 fallback(.mjs)                                      │
│ ④ 都失败 → 友好错误提示(重新 build / 重新安装)           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 进程入口规范化(17 步顺序执行)                              │
│                                                              │
│ ① isMainModule 守卫(防 bundler 重复执行)                  │
│ ② process.title 设置                                         │
│ ③ 进程标记                                                   │
│ ④ TS bundle 侧 warning filter 安装                          │
│ ⑤ 环境变量规范化                                             │
│ ⑥ Windows argv 兼容                                         │
│ ⑦ 早期 profile 解析 + 应用                                  │
│ ⑧ 第二次 runtime 守卫(完整诊断)                          │
│ ⑨ bootstrap trace mark                                      │
│ ⑩ 第二次 respawn 评估(TS bundle 侧)                       │
│ ⑪ 启用 compile cache                                        │
│ ⑫ secrets audit 强制只读 auth store                         │
│ ⑬ --no-color → NO_COLOR=1, FORCE_COLOR=0                   │
│ ⑭ NODE_OPTIONS / CA certs / stack size 调整计划             │
│    • 需 respawn → spawn child + return                      │
│ ⑮ --container 解析(错误 → exit(2))                        │
│ ⑯ 完整 profile 应用(错误 → exit(2))                       │
│ ⑰ container 目标解析 + argv trace mark                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 入口快速路径(TS bundle 内)                                 │
│                                                              │
│ ① version fast-path(container 模式跳过)                    │
│ ② root help fast-path                                       │
│    • 加载 live config                                        │
│    • 有 config-sensitive plugins? → live 渲染              │
│    • 无 → 优先 precomputed,fallback live                   │
│ ③ command help fast-path(逻辑同启动器,兜底)              │
│ • 全部未命中 → 继续                                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 命令树编排                                                   │
│                                                              │
│ ① argv / profile / container 第三次解析(防御性)           │
│ ② JSON 输出模式 console 路由到 stderr                       │
│ ③ 新 trace context(cli.main)                               │
│ ④ 容器内 re-exec(如指定 --container)                      │
│ ⑤ console capture(JSON 日志 capture)                       │
│ ⑥ proxy dispatcher 装配                                      │
│ ⑦ Commander 命令树分发:                                     │
│    • gateway run/restart/status                             │
│    • doctor / configure / onboard                            │
│    • plugins / models / sessions / tasks                    │
│    • browser / secrets / nodes                              │
│    • tui / terminal / chat(interactive)                    │
│    • hooks relay(in-process,Codex)                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  进入业务逻辑
```

### 简化版调用链(去除细节)

```
openclaw <args>
    │
    ▼
[Bin 入口 + 前置守卫]
    │
    ├─→ runtime 守卫(不兼容 → exit(1))
    ├─→ respawn 评估(可能 spawn child)
    ├─→ --version fast-path(命中 → exit(0))
    │
    └─→ 启动器快速路径
            │
            ├─→ --help / <cmd> --help(命中 → exit(0))
            │
            └─→ import TS bundle
                    │
                    ▼
                [进程入口规范化]
                    │
                    ├─→ isMainModule 守卫
                    ├─→ env/argv/profile/container 归一
                    ├─→ 第二次 runtime 守卫
                    ├─→ 第二次 respawn 评估
                    ├─→ --container/--profile 互斥校验(错误 → exit(2))
                    ├─→ 入口快速路径(命中 → exit(0))
                    │
                    └─→ import 命令树编排模块
                            │
                            ▼
                        [命令树编排]
                            │
                            ├─→ 第三次 profile/container 解析
                            ├─→ container re-exec(可选)
                            ├─→ console capture + proxy
                            └─→ Commander 分发
```

### 启动决策树(完整分支)

```
              openclaw <args>
                    │
                    ▼
         ┌──────────────────────┐
         │ 前置守卫             │
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
         │ --version fast-path  │
         └──────────┬───────────┘
                    │
           ┌────────▼────────┐
           │ 命中?           │
           └────┬────────┬───┘
             是 │        │ 否
                ▼        ▼
           exit(0)  ┌────────────────────┐
                    │ respawn 评估       │
                    │ (场景 A/B/hooks)   │
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
                             │ --help / <cmd> -h    │
                             │ 启动器 fast-path     │
                             └─────────┬────────────┘
                                       │
                             ┌─────────▼─────────┐
                             │ 命中?             │
                             └──┬─────────┬──────┘
                              是 │         │ 否
                                 ▼         ▼
                           exit(0)    import TS bundle
                                     → 进程入口规范化
                                     → 入口 fast-path
                                     → 命令树编排
```

## 关键设计约束

### 1. 三个决策点串联,顺序不可乱

- **为什么**:respawn 必须在 fast-path 前(否则 fast-path 在 child 重复执行);container 校验必须在 profile 之后(互斥关系)
- **怎么做**:前置守卫 → respawn 评估 → 启动器 fast-path → TS bundle → 入口规范化 → 入口 fast-path → 命令树
- **影响**:调整顺序会破坏 respawn 互斥与 fast-path 兜底

### 2. 三次 profile/container 解析是防御性兜底

- **为什么**:不同 install 场景路径不同,某一层解析可能因环境异常未生效
- **怎么做**:进程入口规范化层早期解析 + 完整解析,命令树编排层第三次解析
- **影响**:新增命令需考虑与 profile/container 的互斥关系

### 3. Exit code 语义必须符合 shell 约定

- **为什么**:脚本用 exit code 判断退出原因(0 成功,1 通用错误,2 参数错误,130 中断,143 终止)
- **怎么做**:fast-path 命中 exit(0);参数错误 exit(2);信号退出透传 130/143
- **影响**:脚本可正确区分退出原因,做对应处理

### 4. Trace mark 贯穿启动全程

- **为什么**:启动链路长,排查"启动慢"或"卡在某层"需要可观测标记
- **怎么做**:entry → bootstrap → argv → run-main-import → cli.main,每个关键节点打 mark
- **影响**:trace 是排查启动问题的核心依据,不可省略

### 5. Container re-exec 是独立分支

- **为什么**:--container 指定在容器内执行,需 re-exec;与 --profile/--dev 互斥
- **怎么做**:container 解析后,如指定则在容器内 re-exec;互斥违规直接 exit(2)
- **影响**:新增命令需考虑是否支持 container 模式

### 6. Hooks relay 走特殊路径(in-process)

- **为什么**:Codex 用 PID 管 timeout,respawn 会让 PID 漂移
- **怎么做**:hooks relay 命令跳过 respawn,保持 launcher 进程不变,直接进命令树编排
- **影响**:Codex 相关变更需双仓库检查

## 设计观察

### 为什么 import TS bundle 不能早于 fast-path

```
错误设计:
   Bin 入口 → 直接 import TS bundle → 守卫 + fast-path
   → --version 也要加载完整 TS bundle,冷启动慢
   → 不兼容 Node 加载 TS 时崩溃,无法给友好错误

正确设计:
   Bin 入口 → 守卫 + respawn → 启动器 fast-path → 才 import TS bundle
   → --version / --help 不加载 TS bundle(< 100ms)
   → 不兼容 Node 在守卫阶段被拦截
```

### 为什么需要三层 fast-path 而非两层

```
错误设计(只两层 fast-path):
   启动器 fast-path + 入口 fast-path
   → 启动器无法读 config(误命中会输出缺插件命令的 help)
   → 入口能读 config,但若两层都因路径异常未命中,help 无保障

正确设计(三层):
   启动器(快)→ 入口(可读 config)→ Commander help(完整渲染)
   → 最后一层 Commander 自身 help 系统作为兜底
   → 即使前两层都未命中,help 也能正确渲染
```

### 为什么 respawn 评估要在 fast-path 之前

```
错误设计:
   先 fast-path → 再 respawn 评估
   → --version 命中后 exit(0),但若需 respawn(源码 checkout)
     fast-path 在 parent 执行,child 重新走一遍
   → parent 与 child 都执行 fast-path,行为不确定

正确设计:
   先 respawn 评估 → 再 fast-path
   → respawn 后 child 从头执行,fast-path 只在最终进程执行一次
   → 行为确定,无重复
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 本文件 — 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 关键源码索引 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Bin 入口 + 前置守卫 + 启动器 fast-path | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| 进程入口规范化 + 入口 fast-path | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| 命令树编排 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| Gateway 服务启动(命令树分发后) | [src/gateway/server-start.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts) |
| AGENTS.md 调用约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Commands" 段 |
