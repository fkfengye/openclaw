# 03 — Respawn 体系 + 信号转发

> 读完本章你将理解:OpenClaw 为什么在启动时可能重启自身进程(三种互斥的 respawn 场景),parent 进程如何用三层 grace period 转发信号给 child,以及 hooks relay 为何必须保持 in-process。

## 一句话定位

Respawn 体系处理三种互斥的"重启自身"场景:源码 checkout 禁 compile cache、打包安装统一 cache 路径、NODE_OPTIONS 调整。信号转发用三层 grace period 兜底,确保 parent 不卡死同时给 child 足够清理时间。

## 全局协作图

下图展示三种 respawn 场景与信号转发的协作关系,框内是组件名 + 职责 + 关键约束。

```
                  openclaw <args>
                       │
                       ▼
   ┌──────────────────────────────────────────────────────────┐
   │ Hooks Relay 例外判断                                     │
   │ 职责:hooks relay 命令跳过所有 respawn                   │
   │ 约束:Codex 用 PID 管 timeout,respawn 会让 PID 漂移     │
   └──────────────────────────┬───────────────────────────────┘
                              │ 非 hooks relay
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 场景 A: 源码 Checkout 守卫                               │
   │ 职责:源码 checkout 禁用 compile cache                   │
   │ 约束:与场景 B 互斥;环境变量标记防无限 respawn          │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未触发
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 场景 B: 打包 Cache 统一器                                │
   │ 职责:打包安装统一 compile cache 路径                    │
   │ 约束:与场景 A 互斥;环境变量标记防无限 respawn          │
   └──────────────────────────┬───────────────────────────────┘
                              │ 未触发
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 场景 C: NODE_OPTIONS 调整器(TS bundle 内)              │
   │ 职责:调整 ExperimentalWarning / CA certs / stack size   │
   │ 约束:5 个跳过条件(help/version/tui/gateway/env)        │
   └──────────────────────────┬───────────────────────────────┘
                              │ respawn 发生
                              ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 信号转发器 + 信号退出屏障                                │
   │ 职责:parent 转发信号给 child + 三层 grace 兜底          │
   │ 约束:SIGINT→130, SIGTERM→143,符合 shell 约定          │
   └──────────────────────────────────────────────────────────┘
```

先看这张图建立心智模型,再读细节。

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Hooks Relay 例外判断** | hooks relay 命令跳过所有 respawn | Codex 用 PID 管 timeout,PID 不能漂移 |
| **源码 Checkout 守卫(场景 A)** | 源码 checkout 禁用 compile cache | 与场景 B 互斥;环境变量标记防循环 |
| **打包 Cache 统一器(场景 B)** | 打包安装统一 compile cache 路径 | 与场景 A 互斥;环境变量标记防循环 |
| **NODE_OPTIONS 调整器(场景 C)** | 调整 warning/CA/stack 等 NODE_OPTIONS | 5 个跳过条件;在 TS bundle 内评估 |
| **信号转发器** | parent 收到信号转发给 child | 平台信号集不同(Win/Unix) |
| **信号退出屏障** | 三层 grace period 兜底 parent 退出 | 1s+1s+1s;最后 hard exit |

## 关联关系

### 三种 Respawn 场景的互斥关系

```
              openclaw <args>
                    │
                    ▼
         ┌──────────────────────┐
         │ Hooks Relay 例外?   │
         │ (非 Windows)         │
         └──────────┬───────────┘
                    │
            ┌───────┴───────┐
            是              否
            │               │
            ▼               ▼
       跳过 respawn  ┌──────────────────────┐
       (in-process) │ 场景 A 评估:        │
                    │ 是源码 checkout?     │
                    └──────────┬───────────┘
                               │
                     ┌─────────▼─────────┐
                     │ 是源码 checkout?  │
                     └──┬─────────────┬───┘
                     是 │             │ 否
                        ▼             ▼
                 ┌──────────────┐  ┌──────────────────────┐
                 │ 已设 DISABLED│  │ 场景 B 评估:        │
                 │ _RESPAWNED?  │  │ cache 路径不统一?    │
                 └──┬───────┬───┘  └──────────┬───────────┘
                  是 │       │ 否             │
                     │       ▼          ┌─────▼─────┐
                     │   respawn        是          否
                     │   (场景 A)       │           │
                     ▼                  ▼           ▼
                  跳过            ┌──────────────────┐
                  respawn         │ waiting = A 或 B │
                                  └────────┬─────────┘
                                           │
                                  ┌────────▼─────────┐
                                  │ waiting?         │
                                  └──┬───────────┬────┘
                                   是 │           │ 否
                                      ▼           ▼
                                parent 等     启用 compile cache
                                待 child            │
                                                    ▼
                                          ┌──────────────────┐
                                          │ 场景 C 评估      │
                                          │ (TS bundle 内)   │
                                          └────────┬─────────┘
                                                   │
                                          ┌────────▼─────────┐
                                          │ 跳过策略命中?    │
                                          └──┬───────────┬────┘
                                           是 │         │ 否
                                              ▼         ▼
                                           继续     respawn
                                           命令树编排(场景 C)
```

### 信号转发的三层 Grace Period

```
信号到达(如 SIGINT)
     │
     ▼
┌─────────────────────────────────┐
│ Grace 1: 转发等待(1s)          │
│ • 转发信号给 child             │
│ • 等 child 自行退出            │
└────────────────┬────────────────┘
                 │ child 未退出
                 ▼
┌─────────────────────────────────┐
│ Grace 2: 强制 kill(1s)         │
│ • SIGTERM 请求 child 退出      │
│ • Unix:SIGKILL / Win:SIGTERM  │
└────────────────┬────────────────┘
                 │ child 仍未退出
                 ▼
┌─────────────────────────────────┐
│ Grace 3: Hard exit(1s)         │
│ • parent 自己 process.exit     │
│ • Exit code:                   │
│   SIGINT → 130                 │
│   SIGTERM → 143                │
│   其他 → 1                     │
└─────────────────────────────────┘
```

### 平台信号集差异

```
   ┌─────────────────────────────────────────────┐
   │ Windows 信号集                              │
   │   SIGTERM, SIGINT, SIGBREAK                 │
   │   (无 SIGHUP / SIGQUIT)                     │
   │   forceKill 用 SIGTERM(无 SIGKILL)         │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ Unix 信号集                                 │
   │   SIGTERM, SIGINT, SIGHUP, SIGQUIT          │
   │   forceKill 用 SIGKILL                      │
   └─────────────────────────────────────────────┘
```

### 错误设计 vs 正确设计:无限 respawn 防护

```
错误设计(无环境变量标记):
   源码 checkout → respawn 禁 cache
   → child 启动 → 又检测到源码 checkout
   → 又 respawn → 无限循环

正确设计(环境变量标记互斥):
   场景 A respawn → 设 DISABLED_RESPAWNED=1
   child 启动 → 检测到标记 → 跳过场景 A
   场景 B respawn → 设 PACKAGED_RESPAWNED=1
   child 启动 → 检测到标记 → 跳过场景 B
   → 严格互斥,无无限循环
```

## 协作流程

### 场景 A:源码 checkout 禁 compile cache 的完整旅程

```
用户在源码 checkout 目录敲下: openclaw doctor
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ Hooks Relay 例外判断                                          │
│ • 非 hooks relay 命令 → 继续                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 场景 A: 源码 Checkout 守卫 — 触发!                           │
│ ① 检测 .git/ 或 src/entry.ts 存在 → 是源码 checkout         │
│ ② 检测 DISABLED_RESPAWNED 标记 → 未设                        │
│ ③ 检测 compile cache 是否启用 → 启用                          │
│ ④ 设计原因:tsx 加载 TS 源码时,Node compile cache 与 tsx    │
│    transform 流程冲突,会导致缓存污染或加载错误               │
│ ⑤ respawn 动作:                                              │
│    • 设 NODE_DISABLE_COMPILE_CACHE=1                         │
│    • 设 DISABLED_RESPAWNED=1(防循环)                        │
│    • 删除 NODE_COMPILE_CACHE 环境变量                         │
│    • spawn child process                                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 信号转发器接管(parent 等待 child)                            │
│ • parent 转发信号给 child                                    │
│ • child 退出 → parent 透传 exit code                         │
└──────────────────────────────────────────────────────────────┘
```

### 场景 B:打包安装统一 cache 路径的完整旅程

```
用户通过 npm install -g openclaw 安装后敲下: openclaw doctor
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 场景 B: 打包 Cache 统一器 — 触发!                             │
│ ① 非源码 checkout → 不走场景 A                                │
│ ② compile cache 未禁用                                        │
│ ③ PACKAGED_RESPAWNED 标记未设                                 │
│ ④ 当前 cache 路径 ≠ 期望路径                                  │
│ ⑤ 期望路径:<tmp>/node-compile-cache/openclaw/<version>/    │
│    <installMarker>                                            │
│    (installMarker = package.json 的 mtime + size)            │
│ ⑥ 设计原因:不同 npm install 来源(tarball/git/archive)可能  │
│    产生不同 cache 路径,统一后所有安装共享 cache              │
│ ⑦ respawn 动作:                                              │
│    • 设 NODE_COMPILE_CACHE=期望路径                           │
│    • 设 PACKAGED_RESPAWNED=1(防循环)                         │
│    • spawn child process                                     │
└──────────────────────────────────────────────────────────────┘
```

### 场景 C:NODE_OPTIONS 调整的完整旅程

```
用户敲下: openclaw doctor(TS bundle 内评估)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 场景 C: NODE_OPTIONS 调整器 — 评估                            │
│ ① 已在 TS bundle 内(场景 A/B 未触发)                        │
│ ② 检查跳过策略(5 个条件):                                  │
│    • help/version 命令? → 跳过                               │
│    • tui/terminal/chat 交互命令? → 跳过                      │
│    • hooks relay? → 跳过                                      │
│    • gateway/gateway run 前台运行? → 跳过                    │
│    • OPENCLAW_NO_RESPAWN 环境变量? → 跳过                    │
│ ③ 需要调整的 NODE_OPTIONS:                                    │
│    • --disable-warning=ExperimentalWarning(若未设)           │
│    • --use-system-ca(macOS + 系统 CA)                        │
│    • --stack-size=8192(Windows 默认栈太小)                  │
│    • 自定义 CA certs(OPENCLAW_NODE_EXTRA_CA_CERTS)          │
│ ④ 需要 respawn → spawn child(parent 等待)                    │
│    不需要 → 继续命令树编排                                    │
└──────────────────────────────────────────────────────────────┘
```

### 信号转发的完整时序

```
  Parent              Child              OS Signal
    │                   │                    │
    │                   │   <-- 收到 SIGINT --│
    │ -- 转发 SIGINT -->│                    │
    │ 启动 Grace 1 定时 │                    │
    │ (1s)              │                    │
    │                   │ -- child 处理 -->  │
    │                   │    自行退出?        │
    │                   │  ┌─ 是 ─┐          │
    │                   │  ▼      │          │
    │                   │ exit    │          │
    │                   │         │ 否(1s 后)│
    │ -- 1s 到 ───────────────────────>      │
    │ Grace 2:请求退出  │                    │
    │ -- SIGTERM ------>│                    │
    │ 启动 Grace 2 定时 │                    │
    │ (1s)              │                    │
    │                   │ -- child 处理 -->  │
    │                   │  ┌─ 是 ─┐          │
    │                   │  ▼      │          │
    │                   │ exit    │          │
    │                   │         │ 否(1s 后)│
    │ -- 1s 到 ───────────────────────>      │
    │ Grace 3:强制 kill │                    │
    │ -- SIGKILL(Unix)->│                    │
    │ -- SIGTERM(Win)--->│                    │
    │ 启动 Grace 3 定时 │                    │
    │ (1s)              │                    │
    │                   │ -- child 死 ──>     │
    │ 信号退出屏障接管  │                    │
    │ 解除信号监听      │                    │
    │ parent exit(130) │                    │
    ▼                                       ▼
```

## 关键设计约束

### 1. 三种 Respawn 场景严格互斥

- **为什么**:同时触发多个 respawn 会产生多层进程树,排查困难且可能死锁
- **怎么做**:场景 A/B 在 launcher 用环境变量标记互斥;场景 C 在 A/B 之后评估;hooks relay 全部跳过
- **影响**:新增 respawn 场景需考虑与现有三者的互斥关系

### 2. 环境变量标记防无限 respawn

- **为什么**:child 启动后会再次评估 respawn 条件,若无标记会无限循环
- **怎么做**:每个场景 respawn 时设专属环境变量标记;child 检测到标记即跳过该场景
- **影响**:标记环境变量是 respawn 体系的硬约束,不可随意清除

### 3. Hooks Relay 必须保持 in-process

- **为什么**:Codex 通过 PID 管理 relay timeout;respawn 会产生新 PID,导致 timeout 失效,strand compile-cache respawn child
- **怎么做**:hooks relay 命令在非 Windows 平台跳过所有 respawn,保持 launcher 进程不变
- **影响**:Codex 相关变更必须 agent 亲自检查 `../codex` 源码,不可臆测

### 4. 信号转发三层 grace 确保不卡死

- **为什么**:child 可能不响应信号(死锁/挂起),parent 不能无限等待
- **怎么做**:1s 转发等待 → 1s 强制 kill → 1s hard exit,三层兜底
- **影响**:最坏情况 parent 在 3s 内退出,不会卡死

### 5. Exit code 语义符合 shell 约定

- **为什么**:shell 脚本用 exit code 判断信号退出(SIGINT=128+2=130,SIGTERM=128+15=143)
- **怎么做**:child 因转发信号退出时,parent 透传对应 exit code;非转发场景用 1
- **影响**:脚本可正确区分"用户 Ctrl+C"与"通用错误"

### 6. 场景 C 的 5 个跳过条件

- **为什么**:某些命令不应 respawn(interactive 命令需保持 TTY,gateway 前台运行需保持进程,hooks relay 需 in-process)
- **怎么做**:跳过策略检查 help/version、interactive tty、hooks relay、gateway 前台、环境变量 5 个条件
- **影响**:新增命令需评估是否应加入跳过列表

## 设计观察

### 为什么需要三层 grace 而非直接 SIGKILL

```
错误设计(收到信号直接 SIGKILL child):
   SIGINT → 立即 SIGKILL child
   → child 无法清理资源(数据库连接/文件句柄/子进程)
   → 资源泄漏,parent 也可能 hang

正确设计(三层 grace):
   Grace 1:转发信号,给 child 1s 自行清理
   Grace 2:SIGTERM 请求,再给 1s
   Grace 3:SIGKILL 兜底,1s 后 parent 强制退出
   → child 有机会清理,parent 也不卡死
```

### 为什么 hooks relay 要特殊例外

```
错误设计(hooks relay 也 respawn):
   openclaw hooks relay
   → 检测到源码 checkout → respawn 禁 cache
   → child 进程 PID 变了
   → Codex 用旧 PID 管 timeout → timeout 失效
   → compile-cache respawn child 被 strand

正确设计(hooks relay 跳过 respawn):
   openclaw hooks relay(非 Windows)
   → 跳过所有 respawn,保持 in-process
   → Codex 的 PID 不变 → timeout 正常工作
```

### 为什么场景 A/B 在 launcher 而场景 C 在 TS bundle

```
错误设计(场景 C 也在 launcher):
   launcher(JS)评估 NODE_OPTIONS 调整
   → 但 NODE_OPTIONS 调整可能依赖 config / profile
   → launcher 无法读 config
   → 调整逻辑受限

正确设计(分层评估):
   场景 A/B 在 launcher(纯 JS,与 compile cache 相关)
   场景 C 在 TS bundle(可读 config,有完整信息)
   → 各自在最适合的层评估
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/00-overview.md) | 本目录总览与索引 |
| [01-layer-architecture.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/01-layer-architecture.md) | 7 层层次结构与职责 |
| [02-fast-path-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/02-fast-path-system.md) | 三层 fast-path 体系 + 预计算 metadata |
| [03-respawn-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/03-respawn-system.md) | 本文件 — Respawn 体系 + 信号转发 |
| [04-runtime-guard.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/04-runtime-guard.md) | Runtime 守卫 + 版本兼容矩阵 |
| [05-call-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/05-call-flow.md) | 完整调用流程图 |
| [06-design-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/06-design-assessment.md) | 设计评估(优点/风险) |
| [07-source-index.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.1-external-entry-layer/07-source-index.md) | 关键源码索引 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 场景 A/B respawn 评估 + 信号转发 | [openclaw.mjs](file:///d:/DevSpace/person/ai_space/openclaw/openclaw.mjs) |
| 场景 C respawn 跳过策略 | [src/cli/respawn-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/respawn-policy.ts) |
| 场景 C NODE_OPTIONS 调整计划 | [src/entry.respawn.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.respawn.ts) |
| 信号退出屏障(TS 侧) | [src/cli/signal-exit-barrier.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/cli/signal-exit-barrier.ts) |
| Compile cache 管理(TS 侧) | [src/entry.compile-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.compile-cache.ts) |
| Child process 信号桥接(TS 侧) | [src/process/child-process-bridge.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/process/child-process-bridge.ts) |
| Respawn child 运行器(TS 侧) | [src/process/respawn-child-runner.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/process/respawn-child-runner.ts) |
| AGENTS.md Codex 强约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
