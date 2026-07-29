# 01 — 7 层层次结构与职责

> 读完本章你将理解:用户敲下 `openclaw <args>` 后,7 层启动组件如何从 npm bin 一路接力,把控制权交到 Commander 命令树,以及为什么必须分成 7 层而非更少。

## 一句话定位

外部入口层从外到内分为 7 层,每层职责独立、副作用清晰、可单独排查。前 4 层在纯 JS launcher 完成,后 3 层在 TS bundle 内完成,中间以"动态 import TS bundle"为分水岭。

## 全局协作图

下图展示 7 层组件的接力关系,框内是组件名 + 职责 + 关键约束。

```
                  用户敲下命令
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 1: Bin 入口                                       │
   │ 职责:声明可执行文件 + shebang                          │
   │ 约束:files 白名单决定发布包内容                        │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 2: 前置守卫 + Respawn 评估                        │
   │ 职责:检查 Node/Bun 版本 + 评估三种 respawn 场景        │
   │ 约束:必须在 TS bundle 加载前完成                       │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 3: 启动器快速路径                                 │
   │ 职责:拦截 --version / --help / <cmd> --help            │
   │ 约束:纯 JS,无法读 config;命中即 exit(0)             │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 4: TS Bundle 加载器                               │
   │ 职责:动态 import TS bundle + 容错 fallback             │
   │ 约束:加载后不可卸载;失败给友好提示                     │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 5: 进程入口规范化                                 │
   │ 职责:env / argv / profile / container 全部归一         │
   │ 约束:isMainModule 守卫防 bundler 重复执行              │
   └──────────────────────────┬───────────────────────────────┘
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 6: 入口快速路径                                   │
   │ 职责:TS bundle 内二次兜底 fast-path                    │
   │ 约束:可读 config 判断是否 defer;命中即 exit(0)        │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未命中
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Layer 7: 命令树编排                                     │
   │ 职责:Commander 分发 + 容器 re-exec + proxy + capture   │
   │ 约束:本层是入口层终点,之后进入业务逻辑                │
   └──────────────────────────────────────────────────────────┘
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Bin 入口** | 声明 npm 可执行文件与 shebang | files 白名单决定发布包内容 |
| **前置守卫 + Respawn 评估** | TS 加载前完成 runtime 检查与 respawn | 不兼容 runtime 直接 exit(1),不加载 TS |
| **启动器快速路径** | 纯 JS 拦截 --version/--help | 无法读 config;命中即 exit(0) |
| **TS Bundle 加载器** | 动态 import TS bundle,容错 fallback | 加载不可逆;失败给友好提示 |
| **进程入口规范化** | env/argv/profile/container 全部归一 | isMainModule 守卫防重复执行 |
| **入口快速路径** | TS bundle 内二次兜底拦截 | 可读 config 判断是否 defer |
| **命令树编排** | Commander 分发 + 容器/proxy/capture | 入口层终点,之后进业务逻辑 |

## 关联关系

### 7 层的依赖链与副作用

```
Layer 1 (Bin 入口)
   │  依赖:package.json files 白名单
   │  被依赖:用户/脚本调用
   ▼
Layer 2 (前置守卫 + Respawn)
   │  依赖:Node 内置 child_process / fs / module
   │  副作用:可能 spawn child process
   ▼
Layer 3 (启动器快速路径)
   │  依赖:预计算 metadata + package.json + .git/HEAD
   │  副作用:命中即 exit(0)
   ▼
Layer 4 (TS Bundle 加载器)
   │  依赖:dist 下的 TS bundle 产物
   │  副作用:加载 TS bundle 到内存(不可卸载)
   ▼
Layer 5 (进程入口规范化)
   │  依赖:CLI 子层 + Infra 层
   │  副作用:进程级 env/argv/title 修改
   ▼
Layer 6 (入口快速路径)
   │  依赖:预计算 help + root help 渲染器
   │  副作用:命中即 exit(0)
   ▼
Layer 7 (命令树编排)
   │  依赖:Commander + 完整依赖图
   │  副作用:执行业务命令(gateway/doctor/plugins...)
```

### 双层 Launcher 分水岭

```
   纯 JS 侧(Layer 1-4)          │       TS bundle 侧(Layer 5-7)
                                   │
   无法 import TS 代码             │       可读 config / 访问完整 Infra
   必须完成守卫 + respawn          │       可输出 JSON diagnostic
   fast-path 数据源:metadata      │       fast-path 可 live config 判断
                                   │
   ──────────────────动态 import TS bundle──────────────────
```

### 副作用不可逆性对比

| 层 | 副作用 | 不可逆性 |
|---|---|---|
| Layer 2 | spawn child process(respawn) | parent 进程退出 |
| Layer 3 | stdout.write + exit(0) | 进程退出 |
| Layer 4 | 加载 TS bundle 到内存 | 不可卸载 |
| Layer 5 | 修改 env / argv / title | 进程级 |
| Layer 6 | stdout.write + exit(0) | 进程退出 |
| Layer 7 | 启动 gateway / 执行命令 | 视命令而定 |

## 协作流程

### 一次 `openclaw --help` 的完整旅程

下面追踪 bare `--help` 命令从敲下到返回的全过程,标注每层职责。

```
用户敲下: openclaw --help
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 1: Bin 入口                                             │
│ • npm 安装时根据 bin 字段生成可执行文件                       │
│ • shebang 让 shell 用 node 解释                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 2: 前置守卫                                             │
│ • 检查 Node 22.22.3+ / 24.15+ / 25.9+(或 Bun 含 node:sqlite)│
│ • 评估 respawn(源码/打包/hooks 三场景互斥)                  │
│ → 通过,继续                                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 3: 启动器快速路径 — 命中!                               │
│ • 检查 config 是否含 plugins/$include → 无 → 不 defer        │
│ • 读预计算 metadata 的 root help 文本                         │
│ • stdout.write 输出                                           │
│ • exit(0)                                                     │
│                                                               │
│ 整个过程不加载 TS bundle                                      │
└──────────────────────────────────────────────────────────────┘

用户看到 help 输出,进程已退出
```

### 一次 `openclaw agent --message "xxx"` 的完整旅程

下面追踪一个会落到 Commander 的命令,展示 Layer 4-7 如何接力。

```
用户敲下: openclaw agent --message "xxx"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 1-2: Bin 入口 + 前置守卫                                │
│ • runtime 守卫通过                                            │
│ • respawn 评估完成(本场景不 respawn)                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 3: 启动器快速路径 — 未命中                              │
│ • --version? 否                                              │
│ • --help? 否                                                 │
│ • <cmd> --help? 否(有 --message,非纯 --help)               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 4: TS Bundle 加载器                                     │
│ • 抑制 ExperimentalWarning 噪声                              │
│ • 动态 import TS bundle(.js 优先,失败 fallback .mjs)       │
│ • 都失败 → 友好错误提示(重新 build / 重新安装)             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 5: 进程入口规范化(17 步顺序执行)                      │
│ • isMainModule 守卫(防 bundler 重复执行)                    │
│ • process.title 设置                                          │
│ • env / Windows argv / profile 早期解析                      │
│ • 第二次 runtime 守卫(完整诊断)                            │
│ • 第二次 respawn 评估                                         │
│ • compile cache 启用                                          │
│ • --no-color → NO_COLOR=1                                     │
│ • NODE_OPTIONS / CA certs / stack size 调整                   │
│ • --container / --profile 完整解析 + 互斥校验                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 6: 入口快速路径 — 未命中                                │
│ • version fast-path? 否                                      │
│ • root help fast-path? 否                                    │
│ • command help fast-path? 否                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ Layer 7: 命令树编排                                           │
│ • argv / profile / container 第三次解析(防御性)             │
│ • JSON 输出模式 console 路由                                 │
│ • 容器内 re-exec(如指定 --container)                        │
│ • proxy dispatcher 装配                                       │
│ • Commander 命令树分发 → agent 命令                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  进入 Agent 运行时
```

## 关键设计约束

### 1. 双层 Launcher(JS + TS)职责分离

- **为什么**:launcher 是纯 JS,无法 import TS 代码;TS bundle 加载前必须完成 respawn 与 fast-path
- **怎么做**:Layer 1-4 在纯 JS 完成"守卫 + respawn + fast-path + import",Layer 5-7 在 TS bundle 完成"环境规范化 + 二次 fast-path + Commander"
- **影响**:两层逻辑相似但独立,维护时需同步

### 2. 守卫必须在 TS 加载前完成

- **为什么**:不兼容 Node 加载 TS 会直接崩溃(语法不支持),无法给出友好错误
- **怎么做**:Layer 2 在纯 JS 侧完成粗粒度版本检查,不兼容直接 exit(1)
- **影响**:Layer 5 内的细粒度守卫可输出更完整诊断,作为兜底

### 3. TS Bundle 加载不可逆

- **为什么**:模块加载后无法卸载,内存与进程状态已改变
- **怎么做**:Layer 3 尽可能在 import 前拦截 fast-path;Layer 4 独立成层便于排查 module resolution 问题
- **影响**:fast-path 命中可省去整个 TS bundle 加载开销

### 4. isMainModule 守卫防 bundler 重复执行

- **为什么**:bundler(如 esbuild)可能把 entry 当 shared dep 多次引用
- **怎么做**:Layer 5 入口处用 isMainModule 守卫,只执行一次
- **影响**:避免多次设置 process.title、多次启动 gateway

### 5. 三次 profile/container 解析是防御性兜底

- **为什么**:不同 install 场景路径不同,某一层解析可能因环境异常未生效
- **怎么做**:Layer 5 早期解析 + 完整解析,Layer 7 第三次解析(防御性)
- **影响**:新增命令需考虑与 profile/container/respawn 的互斥关系

### 6. 副作用顺序固定且不可乱序

- **为什么**:env/argv/profile 修改影响后续所有逻辑;compile cache 启用必须在 respawn 之后
- **怎么做**:Layer 5 的 17 步严格顺序执行,trace mark 标记关键节点
- **影响**:调整顺序需评估对后续步骤的影响

## 设计观察

### 为什么是 7 层而非更少

```
错误设计(合并为 3 层):
   Bin → 守卫 + fast-path → Commander
   → 不兼容 Node 加载 TS 时崩溃
   → fast-path 无法读 config 判断 defer
   → 环境规范化散落各处,排查困难

正确设计(7 层):
   Bin → 守卫/respawn → 启动器 fast-path → import TS
        → 入口规范化 → 入口 fast-path → Commander
   → 每层职责单一,副作用清晰
   → fast-path 分两层,后者可读 config
   → 环境规范化集中在一层
```

### 为什么 Layer 4 独立成层

```
错误设计:
   把 TS bundle import 混在 fast-path 里
   → module resolution 失败时,无法定位是 fast-path 问题还是 import 问题

正确设计:
   Layer 4 独立负责 import + 容错 + 友好提示
   → module not found 给明确指引(重新 build / 重新安装)
   → import 失败不会污染 fast-path 逻辑
```

### 为什么 fast-path 要分两层(Layer 3 + Layer 6)

```
错误设计(只在一层 fast-path):
   只在 launcher 做 fast-path
   → launcher 无法读 config,无法判断是否 defer
   → 含 plugins 的 config 会输出错误 help(缺插件命令)

   只在 entry 做 fast-path
   → 必须加载 TS bundle,冷启动慢
   → --version 也要加载完整 bundle

正确设计(两层):
   Layer 3 在纯 JS 先拦截(快)
   Layer 6 在 TS bundle 内兜底(可读 config 判断 defer)
   → 既快又准
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 本文件 — 7 层层次结构与职责 |
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
| Bin 入口 | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| Bin 声明与 files 白名单 | [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json) |
| 进程入口规范化 | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| 命令树编排 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| 前置守卫与 respawn 评估 | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Commands" 段 |
