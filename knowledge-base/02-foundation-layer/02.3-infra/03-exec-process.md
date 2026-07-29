# 03 — 执行 / 进程

> 读完本章你将理解:OpenClaw 如何安全地执行外部命令、文件锁与 Gateway 锁如何防并发、Gateway 重启如何交接、退避与去重如何避免风暴。

## 一句话定位

这一层是基础设施的第三层,负责所有进程与执行原语:
- 命令安全(allowlist、trust plan、安全内建命令、wrapper 解析)
- 命令审批(策略、授权、socket 通道、SQLite 持久化)
- 文件锁与 Gateway 锁(防文件级与实例级并发)
- 重启编排(意图、哨兵、handoff、协调器、过期 PID)
- 退避、去重、信号、中止、Gateway 监督与启动生命周期
- 依赖分层 2(网络)拉取依赖、分发结果

## 全局协作图

下图展示执行/进程层内部组件如何协作,以及与上下游的关系。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       上层消费者                                     │
│   Agent Tool 执行    备份/恢复    插件安装    Gateway 重启          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 发起命令 / 触发重启
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       分层 3:执行 / 进程                            │
│                                                                      │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 命令安全          │  │ 命令审批           │  │ 执行宿主        │  │
│   │                   │  │                   │  │                 │  │
│   │ • 安全内建命令    │  │ • 策略快照        │  │ • 命令解析      │  │
│   │ • 安全 bin 策略   │  │ • 授权渲染        │  │ • 托管执行      │  │
│   │ • wrapper 解析    │  │ • 控制命令守卫    │  │ • 退出码归一    │  │
│   │ • allowlist 模式  │  │ • forwarder       │  │                 │  │
│   └───────────────────┘  └───────────────────┘  └─────────────────┘  │
│                                                                      │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 文件锁            │  │ Gateway 锁        │  │ 重启编排        │  │
│   │                   │  │                   │  │                 │  │
│   │ • 文件级互斥      │  │ • 实例级唯一      │  │ • 重启意图      │  │
│   │ • 锁管理器        │  │ • 防多实例        │  │ • 重启哨兵      │  │
│   │                   │  │                   │  │ • handoff 交接  │  │
│   │                   │  │                   │  │ • 协调器        │  │
│   │                   │  │                   │  │ • 过期 PID 清理 │  │
│   └───────────────────┘  └───────────────────┘  └─────────────────┘  │
│                                                                      │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 退避              │  │ 去重              │  │ 信号与中止      │  │
│   │                   │  │                   │  │                 │  │
│   │ • 退避策略        │  │ • 请求去重        │  │ • 中止信号      │  │
│   └───────────────────┘  └───────────────────┘  └─────────────────┘  │
│                                                                      │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 语义版本          │  │ Gateway 监督      │  │ Gateway 启动    │  │
│   │                   │  │                   │  │ 生命周期        │  │
│   │ • 版本比较        │  │ • 进程监督        │  │ • 启动编排      │  │
│   └───────────────────┘  └───────────────────┘  └─────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────┐
                  │  分层 2:网络        │
                  │  (远程拉取/分发)     │
                  └──────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **命令安全** | 安全内建命令、安全 bin 策略、wrapper 解析、allowlist 模式 | 默认拒绝未授权 bin;wrapper 信任需 plan |
| **命令审批** | 策略快照、授权渲染、控制命令守卫、forwarder 转发 | 审批策略可快照;授权可持久化"允许下次" |
| **执行宿主** | 命令解析、托管执行、退出码归一 | 退出码归一为统一终态;host 解析平台差异 |
| **文件锁** | 文件级互斥、锁管理器 | 锁有超时;支持锁管理器多资源 |
| **Gateway 锁** | 实例级唯一、防多实例 | 同机只能一个 Gateway 实例 |
| **重启编排** | 重启意图、哨兵、handoff、协调器、过期 PID | handoff 是显式契约;哨兵防重启丢失 |
| **退避** | 退避策略(与网络层重试退避独立) | 执行失败退避有上限 |
| **去重** | 请求去重(防风暴) | 去重窗口可配置 |
| **信号与中止** | 中止信号、控制命令守卫 | 中止可传播子进程 |
| **语义版本** | 版本比较与约束 | 仅用于依赖版本判定 |
| **Gateway 监督** | 进程监督、启动生命周期 | 监督与启动分离 |

## 关联关系

### 命令执行链路的三道闸

```
   上层发起命令执行
        │
        ▼
   ┌──────────────────┐
   │ 命令安全         │ ── 第一道闸
   │                  │ ── 解析 wrapper token
   │                  │ ── 匹配 allowlist
   │                  │ ── 判定安全 bin 信任
   └────────┬─────────┘
            │ 通过
            ▼
   ┌──────────────────┐
   │ 命令审批         │ ── 第二道闸
   │                  │ ── 取策略快照
   │                  │ ── 渲染授权请求
   │                  │ ── forwarder 转发给用户
   │                  │ ── "允许下次"持久化
   └────────┬─────────┘
            │ 已授权
            ▼
   ┌──────────────────┐
   │ 执行宿主         │ ── 第三道闸
   │                  │ ── 命令解析
   │                  │ ── 抢文件锁(若需)
   │                  │ ── 托管执行
   │                  │ ── 退出码归一
   └──────────────────┘
```

### Gateway 锁与文件锁的层级

```
   ┌──────────────────────────────────────────────┐
   │  Gateway 锁(实例级)                        │
   │                                              │
   │  • 保证同机唯一 Gateway 实例                │
   │  • 启动时抢占,退出时释放                  │
   │  • 锁过期兜底(防残留锁阻塞)               │
   └──────────────────────────────────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────────────┐
   │  文件锁(文件级)                            │
   │                                              │
   │  • 单个文件资源的互斥                       │
   │  • 锁管理器管理多资源                       │
   │  • 超时释放,防死锁                          │
   └──────────────────────────────────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────────────┐
   │  实际文件操作                                │
   └──────────────────────────────────────────────┘
```

### 重启交接(handoff)的契约

```
错误设计(无 handoff):
   旧进程退出 → 新进程启动
   → 进行中的任务丢失 / 状态不一致

正确设计(handoff 契约):
   ① 重启意图持久化到磁盘
   ② 写入重启哨兵
   ③ handoff 把待恢复任务交给协调器
   ④ 旧进程优雅退出
   ⑤ 新进程读取哨兵 + handoff 状态
   ⑥ 过期 PID 清理
   ⑦ 恢复未完成任务
```

## 协作流程

### 一次 Agent 工具命令执行的全过程

```
Agent 通过工具调用执行外部命令
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 命令安全                                                   │
│    → 解析命令行 wrapper token                                 │
│    → 匹配 allowlist 模式                                      │
│    → 判定安全 bin 信任(plan)                                │
│    → 命中安全内建命令?直接放行                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 命令审批                                                   │
│    → 取当前策略快照                                           │
│    → 渲染授权请求(给用户看)                                │
│    → forwarder 转发到用户渠道                                │
│    → 用户批准?                                              │
│         • "允许下次" → 持久化到 SQLite                       │
│         • "拒绝"   → 终止                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 执行宿主                                                   │
│    → 命令解析(host 平台差异)                                │
│    → 若涉及文件:抢文件锁                                     │
│    → 托管执行子进程                                           │
│    → 捕获 stdout/stderr                                      │
│    → 退出码归一为统一终态                                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 失败处理(若失败)                                         │
│    → 退避策略等待                                             │
│    → 去重(避免相同请求风暴)                                │
│    → 重试或返回错误                                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  结果返回 Agent
```

### Gateway 重启的完整交接流程

```
触发重启请求
     │
     ▼
┌──────────────────────────────────────────────────────┐
│ 1. 抢占 Gateway 锁                                   │
│    → 确保唯一重启者                                  │
│    → 锁被占?等或失败                                │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 重启编排                                          │
│    → 持久化重启意图                                  │
│    → 写入重启哨兵                                    │
│    → handoff:收集待恢复任务交给协调器              │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 旧进程退出                                       │
│    → 中止信号传播到子进程                           │
│    → 优雅 grace 退出                               │
│    → 释放 Gateway 锁                                │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 新进程启动                                       │
│    → Gateway 启动生命周期                           │
│    → 过期 PID 清理(防残留)                         │
│    → 读取重启哨兵 + handoff 状态                    │
│    → 恢复未完成任务                                  │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 命令执行三道闸

- **为什么**:防止 Agent/插件任意执行危险命令
- **怎么做**:命令安全(allowlist)→ 命令审批(用户授权)→ 执行宿主(托管执行);每道闸可独立失败
- **影响**:任何命令执行都经过安全 + 审批 + 托管,无旁路

### 2. Gateway 锁保证实例唯一

- **为什么**:防止多实例同时操作同一状态目录导致数据损坏
- **怎么做**:启动时抢占 Gateway 锁;锁有兜底过期机制防残留;退出时释放
- **影响**:同机同状态目录只能一个 Gateway

### 3. handoff 是显式契约

- **为什么**:重启时进行中任务会丢失,用户感知为"消息没回"
- **怎么做**:重启意图持久化 + 哨兵 + handoff 收集任务;新进程读取并恢复
- **影响**:重启不丢任务,用户体验连续

### 4. 退避与去重独立于网络层

- **为什么**:执行命令的风暴(如反复失败重试)与网络重试是不同场景
- **怎么做**:执行层有独立退避策略;去重窗口防相同请求风暴
- **影响**:命令执行失败不会无限重试耗尽资源

### 5. 中止信号传播子进程

- **为什么**:用户取消时,只杀主进程会留下孤儿子进程
- **怎么做**:中止信号传播到整个进程组;控制命令守卫防误杀
- **影响**:取消干净,无僵尸进程

### 6. 审批策略可快照

- **为什么**:审批期间策略可能变化,需保证一次执行用同一策略
- **怎么做**:执行开始时取策略快照;后续判断基于快照
- **影响**:策略热更新不影响进行中的执行

## 设计观察

### 为什么审批"允许下次"要持久化

```
错误设计:
   用户每次命令都需重新批准
   → 高频场景体验差,用户疲劳后无脑批准

正确设计:
   用户可"允许下次"→ 持久化到 SQLite
   → 同类命令后续自动通过
   → 但仍受 allowlist 与安全 bin 信任约束
```

### 为什么文件锁与 Gateway 锁分离

```
错误设计:
   用一个 Gateway 锁覆盖所有文件操作
   → 任何文件操作都阻塞整个 Gateway

正确设计:
   Gateway 锁:实例级,启动时抢一次
   文件锁:文件级,精细互斥
   → 不同文件操作可并行,Gateway 启动也不被文件锁阻塞
```

### 为什么过期 PID 清理是必要的

```
错误设计:
   新进程启动后直接读哨兵
   → 旧 PID 残留,可能引用已死进程

正确设计:
   新进程启动时先清理过期 PID
   → 确认旧进程已退出
   → 再恢复 handoff 任务
   → 避免与残留旧进程冲突
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) | 基础设施总览 |
| [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) | 文件系统 / 路径 / 环境 |
| [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) | 网络 / TLS |
| [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) | 本文件 — 执行 / 进程 |
| [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) | 平台特定 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 命令安全 | [src/infra/exec-safety.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safety.ts) |
| 安全内建命令 | [src/infra/exec-safe-builtins.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-builtins.ts) |
| 安全 bin 策略 | [src/infra/exec-safe-bin-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-policy.ts) |
| 安全 bin 信任 | [src/infra/exec-safe-bin-trust.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-trust.ts) |
| 安全 bin 语义 | [src/infra/exec-safe-bin-semantics.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-semantics.ts) |
| 安全 bin 运行时策略 | [src/infra/exec-safe-bin-runtime-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-runtime-policy.ts) |
| 安全 bin 配置 | [src/infra/exec-safe-bin-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-config.ts) |
| 安全 bin profile | [src/infra/exec-safe-bin-policy-profiles.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-policy-profiles.ts) |
| 安全 bin 校验器 | [src/infra/exec-safe-bin-policy-validator.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safe-bin-policy-validator.ts) |
| 执行策略 | [src/infra/exec-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-policy.ts) |
| wrapper 解析 | [src/infra/exec-wrapper-resolution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-wrapper-resolution.ts) |
| wrapper token | [src/infra/exec-wrapper-tokens.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-wrapper-tokens.ts) |
| wrapper 信任 plan | [src/infra/exec-wrapper-trust-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-wrapper-trust-plan.ts) |
| allowlist 模式 | [src/infra/exec-allowlist-pattern.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-allowlist-pattern.ts) |
| 命令解析 | [src/infra/exec-command-resolution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-command-resolution.ts) |
| 控制命令守卫 | [src/infra/exec-control-command-guard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-control-command-guard.ts) |
| argv 分析 | [src/infra/exec-argv-analysis.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-argv-analysis.ts) |
| 自动评审 | [src/infra/exec-auto-review.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-auto-review.ts) |
| 执行宿主 | [src/infra/exec-host.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-host.ts) |
| 审批 | [src/infra/exec-approvals.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals.ts) |
| 审批策略 | [src/infra/exec-approvals-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-policy.ts) |
| 审批授权 | [src/infra/exec-approvals-authorization.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-authorization.ts) |
| 审批授权 plan | [src/infra/exec-authorization-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-authorization-plan.ts) |
| 审批授权渲染 | [src/infra/exec-authorization-render.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-authorization-render.ts) |
| 审批核心 | [src/infra/exec-approvals-core.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-core.ts) |
| 审批配置 | [src/infra/exec-approvals-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-config.ts) |
| 审批契约 | [src/infra/exec-approvals-contracts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-contracts.ts) |
| 审批生效 | [src/infra/exec-approvals-effective.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-effective.ts) |
| 审批分析 | [src/infra/exec-approvals-analysis.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-analysis.ts) |
| 审批 resolver | [src/infra/exec-approvals-resolver.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-resolver.ts) |
| 审批存储 | [src/infra/exec-approvals-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-store.ts) |
| 审批 SQLite | [src/infra/exec-approvals-sqlite.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-sqlite.ts) |
| 审批 socket | [src/infra/exec-approvals-socket.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-socket.ts) |
| 审批 allow-always | [src/infra/exec-approvals-allow-always.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-allow-always.ts) |
| 审批 allowlist | [src/infra/exec-approvals-allowlist.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-allowlist.ts) |
| 审批迁移 gate | [src/infra/exec-approvals-migration-gate.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approvals-migration-gate.ts) |
| 审批 surface | [src/infra/exec-approval-surface.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-surface.ts) |
| 审批回复 | [src/infra/exec-approval-reply.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-reply.ts) |
| 审批 forwarder | [src/infra/exec-approval-forwarder.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-forwarder.ts) |
| 审批 forwarder runtime | [src/infra/exec-approval-forwarder.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-forwarder.runtime.ts) |
| 审批 channel runtime | [src/infra/exec-approval-channel-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-channel-runtime.ts) |
| 审批命令显示 | [src/infra/exec-approval-command-display.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-command-display.ts) |
| 审批 session target | [src/infra/exec-approval-session-target.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-session-target.ts) |
| 审批策略快照 | [src/infra/exec-approval-policy-snapshot.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-approval-policy-snapshot.ts) |
| 文件锁 | [src/infra/file-lock.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/file-lock.ts) |
| 文件锁管理器 | [src/infra/file-lock-manager.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/file-lock-manager.ts) |
| Gateway 锁 | [src/infra/gateway-lock.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-lock.ts) |
| 重启 | [src/infra/restart.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart.ts) |
| 重启意图 | [src/infra/restart-intent.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-intent.ts) |
| 重启哨兵 | [src/infra/restart-sentinel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-sentinel.ts) |
| 重启哨兵存储 | [src/infra/restart-sentinel-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-sentinel-store.ts) |
| 重启 handoff | [src/infra/restart-handoff.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-handoff.ts) |
| 重启 handoff 契约 | [src/infra/restart-handoff-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-handoff-contract.ts) |
| 重启协调器 | [src/infra/restart-coordinator.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-coordinator.ts) |
| 重启过期 PID | [src/infra/restart-stale-pids.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart-stale-pids.ts) |
| 退避 | [src/infra/backoff.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/backoff.ts) |
| 去重 | [src/infra/dedupe.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/dedupe.ts) |
| 中止信号 | [src/infra/abort-signal.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/abort-signal.ts) |
| 语义版本 | [src/infra/semver.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/semver.ts) |
| Gateway 监督 | [src/infra/gateway-supervision.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-supervision.ts) |
| Gateway 启动生命周期 | [src/infra/gateway-boot-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-boot-lifecycle.ts) |
| Gateway 进程 | [src/infra/gateway-processes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-processes.ts) |
| Gateway 挂起协调 | [src/infra/gateway-suspend-coordinator.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-suspend-coordinator.ts) |
| Gateway 活跃工作 | [src/infra/gateway-active-work.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-active-work.ts) |
