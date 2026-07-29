# 03 — CLI → Gateway 启动流程

> 读完本章你将理解:从用户敲下 openclaw 命令到 Gateway 就绪,中间经过哪些阶段、每个阶段做什么、失败如何处理、关闭如何有序退出。

## 一句话定位

OpenClaw 启动分两层:**进程入口层**负责参数解析、fast-path 拦截、运行时守卫;**Gateway 启动层**分 5 个阶段(Bootstrap → Runtime State → Lifecycle → Core Runtime → Finish)依次完成状态准备、生命周期绑定、核心服务启动、插件加载。任何阶段失败都会触发清理,关闭时按序释放资源。

## 全局协作图

下图展示从命令行到 Gateway 就绪的完整启动链路。**先看这张图建立心智模型,再读细节**。

```
    openclaw 命令
         │
         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  进程入口层(Entry Layer)                            │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 入口守卫    │  │ Fast-path   │  │ 全局错误    │  │ 启动追踪  │ │
│   │ (防重复启动)│  │ 拦截        │  │ 兜底        │  │ (trace)   │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   约束:零成本调用(--version/--help)直接拦截,不加载完整 CLI       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ 完整 CLI 加载
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  Gateway 启动层(5 阶段)                             │
│                                                                      │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐                      │
│   │ 阶段 1   │ ──►│ 阶段 2   │ ──►│ 阶段 3   │                      │
│   │ Bootstrap│    │ Runtime  │    │ Lifecycle│                      │
│   │ (引导)   │    │ State    │    │ (生命周期)│                      │
│   └──────────┘    └──────────┘    └──────────┘                      │
│                                          │                           │
│   ┌──────────┐    ┌──────────┐           │                           │
│   │ 阶段 5   │ ◄──│ 阶段 4   │ ◄─────────┘                           │
│   │ Finish   │    │ Core     │                                       │
│   │ (完成)   │    │ Runtime  │                                       │
│   └──────────┘    └──────────┘                                       │
│                                                                      │
│   约束:任何阶段失败 → 清理已启动资源 → 抛错(不留半启动状态)       │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ Gateway 就绪
                                       ▼
                              ┌─────────────────┐
                              │  Gateway Server │
                              │  (等待客户端)   │
                              └─────────────────┘
```

## 组件清单

OpenClaw 启动链路由 7 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **入口守卫** | 防止被当依赖 import 时重复启动 Gateway | 必须通过主模块判断 |
| **Fast-path 拦截器** | 拦截 --version / --help 等零成本调用 | 不加载完整 CLI 模块 |
| **全局错误兜底** | 区分 benign 与 fatal 错误,格式化输出 | fatal 错误恢复终端后退出 |
| **Bootstrap 阶段** | env 准备、worker 环境、auth token 警告、diagnostics | 懒加载贯穿 |
| **Runtime State 阶段** | 创建 runtime state、channel runtime、worker placement | 懒加载 channel runtime |
| **Lifecycle 阶段** | 绑定 close handler、sidecar、terminal sessions、close prelude | 关闭顺序固定 |
| **Core Runtime + Finish 阶段** | 启动早期服务、插件 bootstrap、HTTP/WS server、hooks、channels、cron | 失败触发清理 |

## 关联关系

### 进程入口层的 Fast-path 决策

```
                    进程启动
                        │
                        ▼
              ┌─────────────────────┐
              │ 入口守卫判断         │
              │ (是否被当依赖?)     │
              └─────────┬───────────┘
                        │
            ┌───────────┴───────────┐
            │                       │
            ▼ 是依赖                ▼ 是主模块
      ┌──────────────┐      ┌──────────────────────────┐
      │ 跳过所有      │      │ 设置进程标题             │
      │ entry 副作用  │      │ 安装警告过滤器           │
      │              │      │ 环境变量归一化           │
      └──────────────┘      │ 运行时守卫校验           │
                            └────────────┬─────────────┘
                                         │
                                         ▼
                            ┌─────────────────────────┐
                            │ --version fast-path?    │
                            └────────────┬────────────┘
                                         │
                            ┌────────────┴────────────┐
                            │ 命中?                   │
                        是  │                     否  │
                            ▼                         │
                      ┌─────────┐                    │
                      │ 输出版本 │                    │
                      │ 退出    │                    │
                      └─────────┘                    │
                                                     ▼
                            ┌─────────────────────────┐
                            │ --help fast-path?       │
                            └────────────┬────────────┘
                                         │
                            ┌────────────┴────────────┐
                        是  │                     否  │
                            ▼                         │
                      ┌─────────────┐                 │
                      │ 预计算文本  │                 │
                      │ 输出退出    │                 │
                      └─────────────┘                 │
                                                     ▼
                            ┌─────────────────────────┐
                            │ 完整 CLI 加载           │
                            │ (重量级 import)         │
                            └─────────────────────────┘
```

### Gateway 启动 5 阶段时序

```
    Gateway 启动编排
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 1: Bootstrap(引导)                                │
    │  • env 准备                                             │
    │  • worker environment 准备                              │
    │  • auth token 警告                                      │
    │  • diagnostics 初始化                                   │
    │  (懒加载:首次使用时才 import)                          │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 2: Runtime State(运行时状态准备)                 │
    │  • 创建 runtime state                                   │
    │  • channel runtime(懒加载)                            │
    │  • worker 环境                                          │
    │  • worker placement                                     │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 3: Lifecycle(生命周期)                           │
    │  • 绑定 close handler                                   │
    │  • sidecar 注册                                         │
    │  • terminal sessions                                    │
    │  • close prelude                                        │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 4: Core Runtime(核心运行时)                      │
    │  • 启动早期服务                                         │
    │  • 插件 bootstrap                                       │
    │  • model catalog(懒加载)                              │
    │  • post-attach                                          │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 5: Finish(完成)                                  │
    │  • HTTP/WS server 启动                                  │
    │  • hooks 注册                                           │
    │  • channels 启动                                        │
    │  • cron 启动                                            │
    │  • tailscale(可选)                                    │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
                    Gateway 就绪
                    (等待客户端连接)

    任何阶段失败:
    ┌──────────────────────────────────────────────────────────┐
    │  → 清理已启动资源(不留半启动状态)                     │
    │  → 抛错给调用方                                         │
    └──────────────────────────────────────────────────────────┘
```

### Close Handler 的有序退出

```
    Gateway 关闭流程(顺序固定,原因关键)

    关闭请求
         │
         ▼
    ┌──────────────────────────────────────────────┐
    │ 1. 开始关闭前奏(标记正在关闭)              │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 2. 杀掉所有活跃 operator shells              │
    │    (必须在 socket 关闭之前!)                │
    │    原因:防止 socket 关闭后僵尸 shell 进程   │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 3. 停止所有 sidecar 进程                     │
    │    (插件启动的辅助进程)                     │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 4. 运行 gateway_stop 插件 hook              │
    │    (让插件做清理)                           │
    │    原因:sidecar 已停,plugin hook 不会用   │
    │         已停 sidecar                        │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 5. 完成关闭(socket tear down)              │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 6. 清理 fallback context(finally)          │
    └──────────────────────────────────────────────┘
```

## 协作流程

### 一次完整启动的旅程

下面追踪用户执行 `openclaw` 命令到 Gateway 就绪的全过程,标注每步由哪个组件负责。

```
用户在终端执行 openclaw
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 进程入口层 — 入口守卫                                    │
│    → 判断是否被当依赖 import                                │
│    → 是主模块 → 设置进程标题、安装警告过滤器                │
│    → 环境变量归一化、运行时守卫校验                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 进程入口层 — Fast-path 拦截                              │
│    → 尝试 --version / --help / 子命令 --help fast-path       │
│    → 命中 → 零成本输出,退出                                 │
│    → 不命中 → 加载完整 CLI                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Gateway 启动 — 阶段 1 Bootstrap                          │
│    → env 准备、worker environment、auth token 警告           │
│    → diagnostics 初始化                                     │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Gateway 启动 — 阶段 2 Runtime State                      │
│    → 创建 runtime state、channel runtime(懒加载)          │
│    → worker 环境、worker placement                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Gateway 启动 — 阶段 3 Lifecycle                          │
│    → 绑定 close handler、sidecar 注册                       │
│    → terminal sessions、close prelude                       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. Gateway 启动 — 阶段 4 Core Runtime                       │
│    → 启动早期服务、插件 bootstrap                           │
│    → model catalog(懒加载)、post-attach                   │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. Gateway 启动 — 阶段 5 Finish                             │
│    → HTTP/WS server 启动                                    │
│    → hooks 注册、channels 启动、cron 启动                   │
│    → tailscale(可选)                                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
                  Gateway 就绪
                  (等待客户端连接)

    任何阶段失败:
    → 清理已启动资源 → 抛错(不留半启动状态)
```

## 关键设计约束

### 1. Fast-path 拦截零成本调用

- **为什么**:`--version`、`--help` 这类调用频繁,加载完整 CLI(含 gateway、plugins、channels)成本过高
- **怎么做**:在入口层用预计算文本拦截,不触发重量级 import
- **影响**:常见调用响应快,完整 CLI 只在真正需要时加载

### 2. 懒加载贯穿启动全程

- **为什么**:降低冷启动成本,只加载当前阶段需要的模块
- **怎么做**:从入口到 Gateway 启动到插件加载,处处用懒加载接缝,首次使用时才 import
- **影响**:启动快,但增加复杂度(需理解懒加载边界)

### 3. 失败安全:不留半启动状态

- **为什么**:半启动状态会导致端口占用、资源泄漏、下次启动失败
- **怎么做**:任何启动阶段失败都触发清理已启动资源,然后抛错
- **影响**:启动失败可安全重试,无残留状态

### 4. 关闭有序:先杀 shells 再关 socket

- **为什么**:如果先关 socket,operator shells 会变僵尸,继续运行但无人管理
- **怎么做**:关闭顺序固定 — 前奏 → 杀 shells → 停 sidecar → plugin hook → socket → 清理
- **影响**:关闭干净,无僵尸进程,插件有机会清理

### 5. 入口守卫防重复启动

- **为什么**:bundler 可能把入口当 shared dep,导致重复启动 Gateway(撞 lock/port)
- **怎么做**:主模块判断守卫,被当依赖 import 时跳过所有 entry 副作用
- **影响**:打包后不会意外启动多个 Gateway

## 设计观察

### 为什么用 Fast-path 而非完整加载

```
错误设计(每次都加载完整 CLI):
   openclaw --version
   → 加载 gateway 模块
   → 加载 plugins 模块
   → 加载 channels 模块
   → 最后输出版本退出
   → 用户等待数秒只为看版本号

正确设计(Fast-path 拦截):
   openclaw --version
   → 入口层直接拦截
   → 预计算文本输出
   → 立即退出
   → 重量级模块根本不加载
```

### 为什么关闭要先杀 shells 再关 socket

```
错误设计(先关 socket):
   1. 关闭 socket
   2. 杀 shells
   → socket 关闭后 shells 变僵尸
   → 继续运行但无人管理
   → 资源泄漏,可能继续输出

正确设计(先杀 shells):
   1. 杀 shells(还在管理下)
   2. 关闭 socket
   → shells 先被清理,无僵尸
   → socket 干净关闭
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 模块地图与目录职责 |
| [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) | 本文件 — CLI → Gateway 启动流程 |
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

| 组件 | 源码位置 |
|---|---|
| 进程入口 | [src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) |
| 全局错误兜底 | [src/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/index.ts) |
| CLI 主编排 | [src/cli/run-main.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/run-main.ts) |
| Gateway 启动 | [src/gateway/server-start.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts) |
| AGENTS.md 硬约束 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
