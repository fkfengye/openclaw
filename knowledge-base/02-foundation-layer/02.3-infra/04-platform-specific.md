# 04 — 平台特定

> 读完本章你将理解:OpenClaw 如何适配不同平台能力:ssh 隧道与 tailscale 认证、WSL 子系统、brew 包管理、APNS/Web 推送、语音唤醒、widearea-dns、节点配对与节点 shell。

## 一句话定位

这一层是基础设施的最上层,负责所有平台相关能力:
- 远程节点通信:ssh 隧道、ssh 配置、tailscale 认证
- 平台适配:WSL(Windows)、brew(macOS)
- 推送通知:APNS(iOS/macOS)、Web Push(浏览器)
- 语音唤醒与路由
- widearea-dns 节点发现
- 节点配对(认证、状态、迁移、surface)与节点 shell
- 依赖分层 3(执行)调用平台原生工具

## 全局协作图

下图展示平台特定层内部组件如何协作,以及与上下游的关系。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       上层消费者                                     │
│   节点 Host    推送通知    语音助手    远程配对    更新检查          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 调用平台能力
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       分层 4:平台特定                               │
│                                                                      │
│   ┌──────────────────────┐  ┌──────────────────────┐  ┌───────────┐  │
│   │ SSH 工具             │  │ Tailscale 认证       │  │ WSL 适配  │  │
│   │                      │  │                      │  │           │  │
│   │ • ssh 隧道           │  │ • 网络认证           │  │ • Linux   │  │
│   │ • ssh 配置解析       │  │ • 节点身份           │  │   子系统  │  │
│   └──────────────────────┘  └──────────────────────┘  └───────────┘  │
│                                                                      │
│   ┌──────────────────────┐  ┌──────────────────────┐  ┌───────────┐  │
│   │ Brew 包管理          │  │ APNS 推送            │  │ Web Push  │  │
│   │                      │  │                      │  │           │  │
│   │ • macOS 依赖安装     │  │ • iOS/macOS 推送     │  │ • 浏览器  │  │
│   │                      │  │ • HTTP/2 传输        │  │   推送    │  │
│   │                      │  │ • Token store        │  │ • store   │  │
│   └──────────────────────┘  └──────────────────────┘  └───────────┘  │
│                                                                      │
│   ┌──────────────────────┐  ┌──────────────────────┐  ┌───────────┐  │
│   │ 语音唤醒             │  │ Widearea DNS         │  │ 节点配对  │  │
│   │                      │  │                      │  │           │  │
│   │ • 唤醒检测           │  │ • 节点发现           │  │ • 认证    │  │
│   │ • 唤醒路由           │  │ • DNS 解析           │  │ • 状态    │  │
│   │                      │  │                      │  │ • 迁移    │  │
│   │                      │  │                      │  │ • surface│  │
│   └──────────────────────┘  └──────────────────────┘  └───────────┘  │
│                                                                      │
│   ┌──────────────────────┐                                          │
│   │ 节点 Shell          │                                          │
│   │                      │                                          │
│   │ • 远程 shell 执行   │                                          │
│   └──────────────────────┘                                          │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────┐
                  │  分层 3:执行/进程   │
                  │  (调用平台原生工具) │
                  └──────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **SSH 工具** | ssh 隧道建立、ssh 配置解析 | 不存储私钥明文;配置遵循 OpenSSH 规范 |
| **Tailscale 认证** | 网络认证、节点身份 | 不假设 tailscale 必然可用;缺失时降级 |
| **WSL 适配** | Windows 上 Linux 子系统接入 | 探测 WSL 可用性;路径在 Windows/Linux 间转换 |
| **Brew 包管理** | macOS 依赖安装 | 不假设 brew 已安装;安装失败给诊断 |
| **APNS 推送** | iOS/macOS 推送、HTTP/2 传输、Token store | Token 持久化到 SQLite;HTTP/2 多路复用 |
| **Web Push** | 浏览器推送、store | 遵循 Web Push 协议;VAPID 密钥管理 |
| **语音唤醒** | 唤醒检测、唤醒路由 | 唤醒路由可配置;不假设设备有麦克风 |
| **Widearea DNS** | 节点发现、DNS 解析 | 用于广域节点发现;DNS 失败降级 |
| **节点配对** | 认证、状态、迁移、surface | 配对状态落 SQLite;迁移有 gate |
| **节点 Shell** | 远程 shell 执行 | 受执行层命令安全约束 |

## 关联关系

### 远程节点通信的三条路径

```
   上层需要与远端节点通信
        │
        ├─ 路径 A:SSH 隧道
        │     │
        │     ▼
        │   ┌──────────────────┐
        │   │ SSH 工具         │ ── 解析 ssh 配置
        │   │                  │ ── 建立隧道
        │   └──────────────────┘
        │
        ├─ 路径 B:Tailscale 认证
        │     │
        │     ▼
        │   ┌──────────────────┐
        │   │ Tailscale 认证   │ ── 节点身份校验
        │   │                  │ ── 加密通道
        │   └──────────────────┘
        │
        └─ 路径 C:节点配对 + 节点 Shell
              │
              ▼
            ┌──────────────────┐
            │ 节点配对         │ ── 配对认证
            │                  │ ── 状态管理
            └────────┬─────────┘
                     │
                     ▼
            ┌──────────────────┐
            │ 节点 Shell       │ ── 远程 shell 执行
            └──────────────────┘
```

### 推送通知的平台分流

```
   上层请求推送通知
        │
        ▼
   ┌──────────────────────────┐
   │ 判定目标设备类型         │
   └────────────┬─────────────┘
                │
       ┌────────┴────────┐
       │                 │
       ▼                 ▼
   ┌──────────┐    ┌──────────┐
   │ APNS     │    │ Web Push │
   │ 推送     │    │          │
   │          │    │          │
   │ iOS/macOS│    │ 浏览器   │
   │ HTTP/2   │    │ VAPID    │
   │ Token DB │    │ store    │
   └──────────┘    └──────────┘
```

### 平台能力按可用性降级

```
错误设计:
   假设每个平台都有 brew / wsl / tailscale
   → 缺失时崩溃

正确设计:
   ┌──────────────────┐
   │ 能力探测器       │
   │ (统一入口)      │
   └────────┬─────────┘
            │
            ▼
   探测每个能力是否存在
            │
   ┌────────┴────────┐
   │                 │
   ▼                 ▼
   存在              缺失
   │                 │
   ▼                 ▼
   正常使用         返回明确诊断
                    上层降级处理
```

## 协作流程

### 节点配对与远程 shell 执行全过程

```
用户请求:在配对节点上执行命令
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 节点配对                                                   │
│    → 校验节点配对认证                                         │
│    → 读取配对状态(从 SQLite)                                │
│    → 配对状态迁移(若需)                                     │
│    → 获取 surface(节点能力面)                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 通道选择                                                  │
│    → 优先:Tailscale 认证(若可用)                          │
│    → 备选:SSH 隧道(若有配置)                              │
│    → 备选:Widearea DNS 发现节点                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 节点 Shell                                                │
│    → 建立远程 shell 通道                                      │
│    → 命令安全校验(走分层 3 守卫)                            │
│    → 远程执行命令                                             │
│    → 退出码归一                                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  结果返回上层
```

### APNS 推送发送流程

```
上层请求:给 iOS 设备发推送
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. APNS 推送                                         │
│    → 从 Token store 读取设备 Token                  │
│    → 拼装 payload                                    │
│    → 认证(APNS auth)                              │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. HTTP/2 传输                                      │
│    → 建立 HTTP/2 连接到 APNS                        │
│    → 多路复用发送                                   │
│    → 处理取消                                       │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 结果处理                                         │
│    → 成功:更新 Token 状态                          │
│    → 失败:Token 失效则从 store 移除                │
│    → 可重试错误:走分层 2 重试策略                  │
└──────────────────────────────────────────────────────┘
```

### macOS 上通过 brew 安装依赖的流程

```
上层请求:安装某依赖(macOS)
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 能力探测                                          │
│    → brew 是否安装?                                │
│    → 否:返回明确诊断,不崩溃                      │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. brew 包管理                                       │
│    → 调用 brew install(走分层 3 命令执行)         │
│    → 捕获输出                                       │
│    → 退出码归一                                     │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 平台能力按可用性降级

- **为什么**:不是每个平台都有 brew/wsl/tailscale/麦克风
- **怎么做**:统一能力探测入口;缺失时返回明确诊断而非崩溃;上层据诊断降级
- **影响**:同一份代码可在多平台运行,无需平台分支散落

### 2. 推送 Token 持久化到 SQLite

- **为什么**:Token 是设备身份,丢失需用户重新配对,体验差
- **怎么做**:APNS/Web Push Token 存 SQLite;失效 Token 自动移除
- **影响**:重启不丢 Token;并发更新有事务保证

### 3. SSH 不存储私钥明文

- **为什么**:私钥是高敏感凭据,泄露即节点失守
- **怎么做**:遵循 OpenSSH 配置规范;私钥路径解析走分层 1;不在内存外留存
- **影响**:凭据安全,符合凭据存储规范

### 4. 节点配对迁移有 gate

- **为什么**:配对状态变更影响认证,误迁移会导致节点失联
- **怎么做**:配对迁移走 migration gate;状态变更需校验
- **影响**:配对状态可演进,但不会静默破坏现有配对

### 5. 远程 shell 受执行层守卫约束

- **为什么**:远程执行命令同样有安全风险,不能绕过命令安全
- **怎么做**:节点 Shell 调用前走分层 3 命令安全 + 审批
- **影响**:远程命令与本地命令同等受保护

### 6. 语音唤醒路由可配置

- **为什么**:不同设备唤醒词与路由目标不同
- **怎么做**:唤醒检测与唤醒路由分离;路由可配置
- **影响**:同一唤醒机制可对接不同后端

## 设计观察

### 为什么推送分 APNS 与 Web Push 两套

```
错误设计:
   统一一套推送抽象覆盖所有平台
   → APNS 的 HTTP/2 与 Web Push 的 VAPID 差异被掩盖
   → 协议特性丢失

正确设计:
   APNS 推送(原生 iOS/macOS,HTTP/2,Token store)
   Web Push(浏览器,VAPID,store)
   → 各自保留协议特性,上层按目标选择
```

### 为什么不假设 tailscale 必然可用

```
错误设计:
   代码硬依赖 tailscale 存在
   → 未装 tailscale 的环境直接崩溃

正确设计:
   探测 tailscale 可用性
   存在:走 tailscale 认证
   缺失:降级到 SSH 或其他通道
   → 同一节点多种接入方式可选
```

### 为什么节点配对状态要落 SQLite

```
错误设计:
   配对状态存内存或 JSON 文件
   → 重启丢失 / 并发写坏

正确设计:
   配对状态存 SQLite
   → 重启可恢复
   → 并发更新有事务保证
   → 与状态层规范一致(禁止 JSON sidecar)
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) | 基础设施总览 |
| [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) | 文件系统 / 路径 / 环境 |
| [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) | 网络 / TLS |
| [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) | 执行 / 进程 |
| [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) | 本文件 — 平台特定 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| SSH 隧道 | [src/infra/ssh-tunnel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/ssh-tunnel.ts) |
| SSH 配置 | [src/infra/ssh-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/ssh-config.ts) |
| Tailscale 认证 | [src/infra/tailscale.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/tailscale.ts) |
| WSL 适配 | [src/infra/wsl.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/wsl.ts) |
| Brew 包管理 | [src/infra/brew.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/brew.ts) |
| APNS 推送 | [src/infra/push-apns.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns.ts) |
| APNS HTTP/2 | [src/infra/push-apns-http2.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns-http2.ts) |
| APNS 认证 | [src/infra/push-apns-auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns-auth.ts) |
| APNS payload | [src/infra/push-apns-payloads.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns-payloads.ts) |
| APNS relay | [src/infra/push-apns.relay.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns.relay.ts) |
| APNS store | [src/infra/push-apns-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns-store.ts) |
| APNS store 事务 | [src/infra/push-apns-store-transaction.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-apns-store-transaction.ts) |
| Web Push | [src/infra/push-web.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-web.ts) |
| Web Push store | [src/infra/push-web-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/push-web-store.ts) |
| 语音唤醒 | [src/infra/voicewake.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/voicewake.ts) |
| 语音唤醒路由 | [src/infra/voicewake-routing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/voicewake-routing.ts) |
| Widearea DNS | [src/infra/widearea-dns.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/widearea-dns.ts) |
| 节点配对 | [src/infra/node-pairing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-pairing.ts) |
| 节点配对认证 | [src/infra/node-pairing-authz.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-pairing-authz.ts) |
| 节点配对状态 | [src/infra/node-pairing-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-pairing-state.ts) |
| 节点配对迁移 | [src/infra/node-pairing-migration.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-pairing-migration.ts) |
| 节点配对 surface | [src/infra/node-pairing-surface.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-pairing-surface.ts) |
| 节点 Shell | [src/infra/node-shell.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-shell.ts) |
| 节点命令 | [src/infra/node-commands.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/node-commands.ts) |
