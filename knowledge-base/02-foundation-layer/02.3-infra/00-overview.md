# 00 — 基础设施(Infra)总览

> 这是知识库基础设施层入口。读完本章你将理解:基础设施层是干什么的、由哪几类组件构成、彼此如何分层协作、为什么被全代码库依赖。

## 一句话定位

基础设施层是 OpenClaw 的**最底层工具集**:
- 所有上层(Gateway / Agent / 插件 / 通道)都依赖这一层
- 只做通用原语:文件、路径、网络、TLS、执行、进程、平台适配
- 不含任何业务语义,不知道 Agent / 插件 / 渠道为何物
- 底层依赖只有 Node.js 标准能力与少量第三方库

## 全局协作图

下图展示基础设施层的内部分层与上层依赖关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       上层业务(src 各处)                            │
│                                                                      │
│   Gateway 核心    Agent 运行时    插件系统    通道系统    状态层     │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 只能依赖以下基础设施原语
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       基础设施层(src/infra)                          │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │  分层 1:文件系统 / 路径 / 环境                              │   │
│   │  (路径解析 / 符号链接 / 环境变量 / dotenv)                  │   │
│   └────────────────────────────┬─────────────────────────────────┘   │
│                                │ 上层为网络/TLS 提供本地落点        │
│                                ▼                                     │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │  分层 2:网络 / TLS                                          │   │
│   │  (fetch / 代理 / SSRF 防护 / 证书指纹 / 重试 / ws)           │   │
│   └────────────────────────────┬─────────────────────────────────┘   │
│                                │ 上层调用网络来拉取/分发执行依赖     │
│                                ▼                                     │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │  分层 3:执行 / 进程                                          │   │
│   │  (命令安全 / 文件锁 / Gateway 锁 / 重启 / 退避 / 去重)       │   │
│   └────────────────────────────┬─────────────────────────────────┘   │
│                                │ 上层用执行能力调用平台工具          │
│                                ▼                                     │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │  分层 4:平台特定                                            │   │
│   │  (ssh / tailscale / wsl / brew / 推送 / 语音唤醒 /          │   │
│   │   widearea-dns / 节点配对 / 节点 shell)                      │   │
│   └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────┐
                  │  Node.js 运行时      │
                  │  (fs / net / tls /   │
                  │   child_process /    │
                  │   os / crypto)       │
                  └──────────────────────┘
```

## 组件清单

基础设施层按依赖深度分为 4 类组件:

| 组件分类 | 职责 | 关键约束 |
|---|---|---|
| **文件系统/路径/环境** | 路径解析、符号链接处理、JSON 读写、环境变量、dotenv | 处理 macOS `/var` → `/private/var` 符号链接;路径越界强校验 |
| **网络/TLS** | fetch、代理环境、SSRF 防护、TLS 证书指纹、重试策略、ws | 默认拒绝内网地址;代理与 SSRF 互不绕过;重试含 Retry-After |
| **执行/进程** | 命令安全、文件锁、Gateway 锁、重启编排、退避、去重、信号 | 文件锁与 Gateway 锁防并发竞争;重启需 handoff 交接 |
| **平台特定** | ssh 隧道、tailscale、wsl、brew、APNS/Web 推送、语音唤醒、节点配对 | 按平台可用性降级;不假设工具一定存在 |

## 关联关系

### 分层依赖的单向流动

```
   上层业务
       │
       │ 只能向下依赖,不能跨层
       ▼
   ┌─────────────────┐
   │ 分层 1:FS/路径 │  ← 最底层,只依赖 Node.js
   │ (无内部依赖)   │
   └────────┬────────┘
            │
            ▼
   ┌─────────────────┐
   │ 分层 2:网络/TLS │  ← 依赖分层 1(本地证书/缓存落点)
   └────────┬────────┘
            │
            ▼
   ┌─────────────────┐
   │ 分层 3:执行/进程│  ← 依赖分层 2(远程拉取/分发)
   └────────┬────────┘
            │
            ▼
   ┌─────────────────┐
   │ 分层 4:平台特定 │  ← 依赖分层 3(调用平台原生工具)
   └─────────────────┘
```

### 为什么必须分层而不是平铺

```
错误设计(平铺,任意互引):
   网络工具 ──► 执行工具 ──► 文件系统工具
        ▲                   │
        └───────────────────┘
   → 循环依赖,任意模块可引用任意模块 → 无法独立测试

正确设计(单向分层):
   文件系统 ──► 网络 ──► 执行 ──► 平台特定
   → 每层只依赖下层,无环 → 可逐层替换与测试
```

## 协作流程

### 一个外部 HTTP 请求贯穿基础设施层的全过程

下面追踪一次"上层业务发起受保护的外部请求"的完整旅程,标注每步由哪类基础设施组件负责。

```
上层业务发起:获取一个外部 URL
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 文件系统/路径/环境                                         │
│    → 读取本地配置目录(符号链接归一)                         │
│    → 解析环境变量(含 dotenv 注入)                           │
│    → 提供证书/缓存的本地落点路径                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 网络/TLS                                                  │
│    → 读取代理环境变量                                        │
│    → SSRF 校验:目标地址是否落在内网/保留段                  │
│    → TLS 证书指纹比对(若开启 pinning)                       │
│    → 发起 fetch,流式接收响应                                │
│    → 失败时按重试策略 + Retry-After 退避重试                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 执行/进程(若需调用外部命令)                              │
│    → 命令安全校验(allowlist / trust plan)                   │
│    → 抢占文件锁/Gateway 锁(防并发)                          │
│    → 执行子进程,捕获 stdout/stderr                          │
│    → 退出码归一,失败按退避策略重试                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 平台特定(若需平台能力)                                   │
│    → macOS:brew 安装依赖                                    │
│    → Windows:wsl 进入 Linux 子系统                           │
│    → 远端节点:ssh 隧道 / tailscale 认证                     │
│    → 推送通知:APNS / Web Push                               │
└──────────────────────────────────────────────────────────────┘
```

### Gateway 重启时基础设施层的协作顺序

```
收到重启请求
     │
     ▼
┌──────────────────────────────────────────────────────┐
│ 1. 文件系统层                                        │
│    → 持久化重启意图到磁盘(防重启中丢失)             │
│    → 写入重启哨兵(sentinel)                         │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 执行/进程层                                       │
│    → 抢占 Gateway 锁(确保唯一重启者)                │
│    → handoff:把待恢复任务交给下一代进程             │
│    → 旧进程优雅退出(信号 + grace)                   │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 网络层                                            │
│    → 新进程重新绑定端口                               │
│    → 重建 TLS 上下文                                 │
│    → 恢复 WS 连接                                    │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 单向分层,无环依赖

- **为什么**:防止任意模块互相引用导致不可测试、不可替换
- **怎么做**:文件系统为最底层,平台特定为最上层;上层只能向下依赖
- **影响**:新增基础设施模块必须归入某一层,跨层引用需重构

### 2. 处理真实平台状态,不为假想防御

- **为什么**:基础设施跑在真实操作系统上,必须处理符号链接、权限、平台差异
- **怎么做**:正确处理 macOS `/var` → `/private/var`、Windows 路径分隔符、WSL 子系统
- **影响**:测试断言路径归一时必须先 `realpath` 临时目录,否则 macOS 本地过 CI 失败

### 3. 网络默认受保护

- **为什么**:SSRF 是基础设施层的核心安全风险
- **怎么做**:默认拒绝内网/保留地址段;代理与 SSRF 校验互不绕过;证书可 pinning
- **影响**:任何外部请求都经过统一守卫,无旁路

### 4. 并发靠锁,不靠约定

- **为什么**:Gateway、文件操作、重启都涉及多进程并发
- **怎么做**:文件锁保护文件级并发;Gateway 锁保证唯一运行实例;锁有超时与兜底
- **影响**:重启交接(handoff)是显式契约,不靠"约定谁先退出"

### 5. 平台能力按可用性降级

- **为什么**:不是每个平台都有 brew/wsl/tailscale
- **怎么做**:探测平台能力存在性,缺失时返回明确诊断而非崩溃
- **影响**:上层不应假设某平台工具必然可用

## 设计观察

### 为什么基础设施不包含业务语义

```
错误设计:
   基础设施层 ──► 知道"Agent 配置"是什么
   基础设施层 ──► 知道"Telegram 消息"格式
   → 业务变更牵连底层 → 底层无法复用

正确设计:
   基础设施层 ──► 只提供"读 JSON 文件"原语
   上层业务 ──► 自己定义"Agent 配置 schema"
   → 底层稳定,业务可演进
```

### 为什么 SSRF 校验不能放在上层各处

```
错误设计:
   每个上层模块自己判断"这个 URL 安不安全"
   → 规则散落,易漏易不一致

正确设计:
   网络层统一守卫 ──► 所有 fetch 经过单一 SSRF 校验
   → 规则集中,可审计,无旁路
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) | 本文件 — 基础设施总览与索引 |
| [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) | 文件系统 / 路径 / 环境 |
| [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) | 网络 / TLS |
| [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) | 执行 / 进程 |
| [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) | 平台特定 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。基础设施全部位于 `src/infra/` 下。

| 组件分类 | 源码位置 |
|---|---|
| 文件系统/路径/环境 | [src/infra/fs-safe.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe.ts) |
| 文件系统(高级) | [src/infra/fs-safe-advanced.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe-advanced.ts) |
| 路径安全 | [src/infra/path-safety.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-safety.ts) |
| 主目录 | [src/infra/home-dir.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/home-dir.ts) |
| 网络/SSRF | [src/infra/net/ssrf.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/ssrf.ts) |
| 网络/代理 | [src/infra/net/proxy-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy-env.ts) |
| 网络/fetch | [src/infra/fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fetch.ts) |
| TLS/指纹 | [src/infra/tls/fingerprint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/tls/fingerprint.ts) |
| 执行/命令安全 | [src/infra/exec-safety.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/exec-safety.ts) |
| 执行/文件锁 | [src/infra/file-lock.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/file-lock.ts) |
| 执行/Gateway 锁 | [src/infra/gateway-lock.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/gateway-lock.ts) |
| 执行/重启 | [src/infra/restart.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/restart.ts) |
| 平台/ssh | [src/infra/ssh-tunnel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/ssh-tunnel.ts) |
| 平台/tailscale | [src/infra/tailscale.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/tailscale.ts) |
| 平台/wsl | [src/infra/wsl.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/wsl.ts) |
| 平台/brew | [src/infra/brew.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/brew.ts) |
| 平台/推送 | [src/infra/push-apns.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns.ts) |
