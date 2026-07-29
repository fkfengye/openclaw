# 10 — 原生 App 接入(iOS / macOS / Linux / Android / watchOS)

> 读完本章你将理解:5 大平台的原生 App 如何通过统一的 Gateway WebSocket 协议接入 OpenClaw,以及为什么各平台有独立客户端实现却共享同一协议与认证面。

## 一句话定位

原生 App 是 OpenClaw 在 iOS、macOS、Linux、Android、watchOS 五大平台的客户端实现:全部通过 Gateway WebSocket 协议接入,共享统一认证面与 ClientId 注册表;各平台独立实现 WS 客户端(Swift / Rust / Kotlin),但协议与认证保持一致。

## 全局协作图

下图展示五大平台原生 App 如何汇聚到 Gateway WS 协议。**先看这张图建立心智模型,再读细节**。

```
   ┌──────────────────────────────────────────────────────────┐
   │              五大平台原生 App                            │
   │                                                          │
   │  ┌──────────┐ ┌──────────┐ ┌──────────┐                 │
   │  │ iOS App  │ │ macOS App│ │ Linux    │                 │
   │  │ (Swift)  │ │ (Swift)  │ │ Tauri    │                 │
   │  │          │ │          │ │ (Rust)   │                 │
   │  │ 双 WS    │ │ WS +     │ │ WS +     │                 │
   │  │ sessions │ │ 内部 IPC │ │ TLS pin  │                 │
   │  └────┬─────┘ └────┬─────┘ └────┬─────┘                 │
   │       │            │            │                        │
   │  ┌────┴─────┐ ┌────┴─────┐      │                        │
   │  │ Android  │ │ watchOS  │      │                        │
   │  │ /Wear OS │ │ (Swift)  │      │                        │
   │  │ (Kotlin) │ │          │      │                        │
   │  └────┬─────┘ └────┬─────┘      │                        │
   │       │            │            │                        │
   └───────┼────────────┼────────────┼────────────────────────┘
           │            │            │
           └────────────┼────────────┘
                        │
                        ▼ 统一 WebSocket 接入
   ┌──────────────────────────────────────────────────────────┐
   │              Gateway WS 协议                             │
   │                                                          │
   │  ConnectParams:                                         │
   │  • clientId: openclaw-{ios|macos|linux|android|watchos} │
   │  • mode: ui                                             │
   │  • protocolVersion: 4                                   │
   │  • 认证凭证(token/password/device-token/TLS pin)       │
   └────────────────────────────┬─────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────┐
   │              统一认证面                                  │
   │              (7 种认证方式归一)                         │
   └────────────────────────────┬─────────────────────────────┘
                                │
                                ▼
   ┌──────────────────────────────────────────────────────────┐
   │              Gateway HTTP/WS Server                      │
   │              (见 01-gateway-http-ws)                     │
   └──────────────────────────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **iOS App** | 双 WS sessions:设备能力 + 用户操作 | role=node 提供能力,role=operator 处理用户操作 |
| **macOS App** | WS 接入 + 内部 IPC(capability/canvas) | 接入走 WS,IPC 是 app 内部非 Gateway |
| **Linux Tauri App** | WS 接入(Rust 异步运行时) | 支持 TLS fingerprint pin(SHA-256) |
| **Android / Wear OS** | WS 接入(Kotlin) | 手机与手表共享 ClientId |
| **watchOS App** | WS 接入(Swift,功能受限) | 共享 iOS 工程的协议实现 |

## 关联关系

### iOS 双 session 设计

```
   ┌──────────────────────────────────────────────────────┐
   │              iOS App 双 WS sessions                  │
   │                                                      │
   │  ┌─────────────────────┐  ┌─────────────────────┐   │
   │  │  role=node session  │  │ role=operator session│  │
   │  │                     │  │                     │   │
   │  │  设备能力提供:      │  │  用户操作:         │   │
   │  │  • 计算能力         │  │  • chat 对话        │   │
   │  │  • 文件系统访问     │  │  • talk 语音        │   │
   │  │  • GPU              │  │  • config 配置      │   │
   │  │                     │  │                     │   │
   │  │  → 设备作为节点     │  │  → 用户作为操作者   │   │
   │  └─────────────────────┘  └─────────────────────┘   │
   │                                                      │
   │  两个 session 独立生命周期,职责分离                 │
   └──────────────────────────────────────────────────────┘
```

### 各平台认证方式对比

```
   ┌────────────┬──────────────────────────────────────┐
   │ 平台       │ 认证方式                             │
   ├────────────┼──────────────────────────────────────┤
   │ iOS        │ token / bootstrap token / password   │
   │            │ + TLS 证书 pin                       │
   ├────────────┼──────────────────────────────────────┤
   │ macOS      │ token / password(走统一认证面)     │
   ├────────────┼──────────────────────────────────────┤
   │ Linux      │ token / password                     │
   │            │ + TLS fingerprint pin(SHA-256)      │
   ├────────────┼──────────────────────────────────────┤
   │ Android    │ token / device token                 │
   ├────────────┼──────────────────────────────────────┤
   │ watchOS    │ token(功能受限)                    │
   └────────────┴──────────────────────────────────────┘
                          │
                          ▼
              全部归一到统一认证面
              (见 12-auth-clients)
```

### macOS app 内部 IPC(非 Gateway 接入)

```
   ┌──────────────────────────────────────────────────────┐
   │  macOS App 内部分层                                   │
   │                                                      │
   │  ┌─────────────────────┐                            │
   │  │ UI 层                │                            │
   │  └──────────┬──────────┘                            │
   │             │ 内部 IPC(capability/canvas)          │
   │             ▼                                        │
   │  ┌─────────────────────┐                            │
   │  │ 控制通道(WS)       │──► Gateway WS 协议         │
   │  │ (平台框架封装)       │    (这是 Gateway 接入)     │
   │  └─────────────────────┘                            │
   │                                                      │
   │  注意:内部 IPC 是 app 内组件通信,                   │
   │       不是 Gateway 接入,不经过认证面                │
   └──────────────────────────────────────────────────────┘
```

## 协作流程

### 一次 iOS App 通过 WS 接入的完整旅程

下面追踪 iOS App 启动后通过 WS 接入 Gateway 的全过程,标注每步由哪个组件负责。

```
iOS App 启动
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 建立双 WS sessions                                         │
│    • role=node session(设备能力)                            │
│    • role=operator session(用户操作)                        │
│    • 配置认证凭证(token/bootstrap token/password + TLS pin)│
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. WebSocket 握手                                             │
│    • 发起 WS upgrade                                          │
│    • 携带 ClientId: openclaw-ios                              │
│    • 携带 Protocol-Version: 4                                 │
│    • 携带认证凭证                                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 统一认证面校验                                             │
│    • 解析认证凭证                                             │
│    • 走 device token / token / password 认证                  │
│    • 校验 TLS 证书 pin(防 MITM)                            │
│    • 产出归一认证结果                                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. WS 连接建立                                                │
│    • 升级为 WebSocket                                         │
│    • 绑定到 Gateway WS 协议                                   │
│    • role=node session 注册为设备节点                        │
│    • role=operator session 注册为操作者                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 业务交互                                                   │
│    • operator session:发 RPC(agent.run),收流式事件,渲染 UI│
│    • node session:接受 Gateway 的能力调用(计算/文件)       │
└──────────────────────────────────────────────────────────────┘
```

### 平台实现语言与协议下限

| 平台 | 实现语言 | WS 库 | 协议下限 |
|---|---|---|---|
| iOS | Swift | 原生 | 4 |
| macOS | Swift | 平台框架封装 | 4 |
| Linux | Rust | 异步 WS 库 | 4 |
| Android / Wear OS | Kotlin | 平台实现 | 4 |
| watchOS | Swift | 共享 iOS 实现 | 4 |

## 关键设计约束

### 1. 所有原生 App 走统一 WS 协议

- **为什么**:统一认证、统一并发控制、统一可观测性;避免每平台各搞一套接入
- **怎么做**:五大平台都通过 Gateway WS 协议接入,共享 ClientId 注册表与认证面
- **影响**:新平台接入只需实现 WS 客户端 + 平台适配,不改核心

### 2. iOS 双 session 职责分离

- **为什么**:设备能力提供(作为节点)与用户操作(作为操作者)生命周期不同,混在一起难管理
- **怎么做**:role=node session 提供计算/文件系统能力,role=operator session 处理 chat/talk/config
- **影响**:两个 session 独立生命周期,职责清晰

### 3. TLS fingerprint pin 防 MITM

- **为什么**:公网或不可信网络下,WS 连接可能被中间人攻击
- **怎么做**:Linux 等平台支持 TLS 证书指纹 pin(SHA-256),只信任 pinned 证书
- **影响**:证书轮换时需同步更新 pin,否则连接失败

### 4. macOS 内部 IPC 与 Gateway 接入分离

- **为什么**:app 内组件通信(capability/canvas)是进程内/设备内事务,不应经过 Gateway 认证
- **怎么做**:macOS app 内部用独立 IPC 通道,只有控制通道(WS)走 Gateway 接入
- **影响**:IPC 不受 Gateway 认证面约束,是 app 私有实现

### 5. 协议版本下限对齐

- **为什么**:原生 App 使用完整 UI 功能,需要最新协议特性
- **怎么做**:五大平台协议下限均为 4(必须最新)
- **影响**:旧版 App 无法接入新版 Gateway,需同步升级

## 设计观察

### 为什么所有原生 App 走统一 WS 协议

```
错误设计:
   iOS 走自有协议,Android 走 HTTP 轮询,Linux 走 gRPC
   → 认证、并发、状态、可观测性各做一遍 → 不一致
   → 新增平台要重做整个接入层

正确设计:
   五大平台都走 Gateway WS 协议
   → 统一认证面、统一 ClientId、统一协议版本
   → 新平台只需实现 WS 客户端 + 平台适配
```

### 为什么 iOS 用双 session 而非单 session

```
错误设计:
   iOS App 单 session 既处理用户操作又提供设备能力
   → 设备能力调用阻塞用户操作,或反之
   → 生命周期耦合,一个断开影响另一个

正确设计:
   role=node session(设备能力)与 role=operator session(用户操作)分离
   → 独立生命周期,互不阻塞
   → 职责清晰,Gateway 可分别调度
```

### 为什么 macOS 内部 IPC 不走 Gateway

```
错误设计:
   macOS app 内组件通信也走 Gateway WS
   → app 内部高频通信经过网络往返,延迟高
   → 占用 Gateway 连接数与认证开销

正确设计:
   app 内部用独立 IPC 通道(capability/canvas)
   只有需要核心服务的控制通道才走 Gateway WS
   → app 内通信低延迟,Gateway 只承担核心交互
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 本文件 — 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| iOS App | [apps/ios/](file:///d:/DevSpace/person/ai_space/openclaw/apps/ios/) |
| iOS Gateway 连接配置 | [apps/ios/Sources/Gateway/](file:///d:/DevSpace/person/ai_space/openclaw/apps/ios/Sources/Gateway/) |
| macOS App | [apps/macos/](file:///d:/DevSpace/person/ai_space/openclaw/apps/macos/) |
| macOS 控制通道 | [apps/macos/Sources/OpenClaw/](file:///d:/DevSpace/person/ai_space/openclaw/apps/macos/Sources/OpenClaw/) |
| macOS 内部 IPC | [apps/macos/Sources/OpenClawIPC/](file:///d:/DevSpace/person/ai_space/openclaw/apps/macos/Sources/OpenClawIPC/) |
| Linux Tauri App | [apps/linux/](file:///d:/DevSpace/person/ai_space/openclaw/apps/linux/) |
| Linux WS 实现 | [apps/linux/src-tauri/src/](file:///d:/DevSpace/person/ai_space/openclaw/apps/linux/src-tauri/src/) |
| Android / Wear OS | [apps/android/](file:///d:/DevSpace/person/ai_space/openclaw/apps/android/) |
| watchOS App | [apps/ios/WatchApp/](file:///d:/DevSpace/person/ai_space/openclaw/apps/ios/WatchApp/) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
