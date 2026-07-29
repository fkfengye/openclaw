# 11 — Node Host + Probe 接入

> 读完本章你将理解:远程机器如何作为配对节点(Node Host)提供计算能力,以及轻量级 Probe 如何做健康探测,为什么两者协议版本下限比通用客户端宽松。

## 一句话定位

Node Host 与 Probe 是两类特殊的 WS 接入客户端:Node Host 是远程机器作为配对节点提供计算能力(如 CLI 运行、文件系统访问),通过 Gateway WS + 节点调用 RPC 接入;Probe 是轻量级健康探测客户端,用于负载均衡/K8s 就绪检查,可跳过完整握手。两者协议版本下限均为 3,允许旧版接入。

## 全局协作图

下图展示 Node Host 与 Probe 如何接入 Gateway。**先看这张图建立心智模型,再读细节**。

```
   ┌──────────────────────────────────────────────────────────┐
   │  Node Host(配对节点)              Probe(健康探测)     │
   │                                                          │
   │  远程机器提供:                  负载均衡器 / K8s / 监控  │
   │  • CLI 运行                                             │
   │  • 文件系统访问                                         │
   │  • GPU 计算                                             │
   │         │                              │                 │
   │         │ 1. SSH 配对预流程            │ 1. 轻量 WS 连接  │
   │         │    (建立信任)               │    (可跳过握手)  │
   │         ▼                              ▼                 │
   │  ┌─────────────────┐           ┌─────────────────┐       │
   │  │ SSH 配对验证器  │           │ Probe 认证器    │       │
   │  │ • SSH key 验证  │           │ • token 可选    │       │
   │  │ • 生成节点凭证  │           │ • 可跳过 hello  │       │
   │  └────────┬────────┘           └────────┬────────┘       │
   │           │                             │                │
   └───────────┼─────────────────────────────┼────────────────┘
               │                             │
               ▼                             ▼
   ┌──────────────────────────────────────────────────────────┐
   │              Gateway WS 协议                             │
   │                                                          │
   │  Node Host:    clientId=node-host,      mode=node,  ≥3   │
   │  Probe:        clientId=openclaw-probe, mode=probe, ≥3   │
   └────────────────────────────┬─────────────────────────────┘
                                │
               ┌────────────────┼────────────────┐
               │                │                │
               ▼                ▼                ▼
   ┌──────────────────┐ ┌──────────────┐ ┌──────────────────┐
   │ 节点注册中心     │ │ 健康状态返回 │ │ 统一认证面      │
   │ (Node Host)      │ │ (Probe)      │ │ (两者都经过)    │
   │                  │ │              │ │                 │
   │ • 节点能力列表   │ • Gateway 就绪│                  │
   │ • 节点状态       │ • 节点状态汇总│                 │
   │ • 节点凭证       │ • JSON 响应   │                 │
   └──────────────────┘ └──────────────┘ └──────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Node Host 客户端** | 远程机器作为配对节点提供计算能力 | 协议下限 3,需 SSH 配对建立信任 |
| **SSH 配对验证器** | 验证 SSH key,生成节点凭证 | 配对预流程,建立 Gateway 与节点的信任 |
| **节点注册中心** | 管理配对节点的能力、状态、凭证 | Gateway 调用节点能力的入口 |
| **Probe 客户端** | 轻量级健康探测 | 协议下限 3,可跳过完整握手 |
| **Probe 认证器** | 轻量认证(token 可选) | 允许快速健康检查,无需完整 hello |

## 关联关系

### Node Host 与 Probe 的对比

```
   ┌────────────────┬──────────────────────┬──────────────────────┐
   │ 维度           │ Node Host            │ Probe                │
   ├────────────────┼──────────────────────┼──────────────────────┤
   │ 用途           │ 提供远程计算能力     │ 健康检查/就绪检查    │
   │ ClientId       │ node-host            │ openclaw-probe       │
   │ Mode           │ node                 │ probe                │
   │ 协议下限       │ 3                    │ 3                    │
   │ 完整握手       │ 是                   │ 否(轻量,可跳过)   │
   │ 调用方向       │ Gateway → Node       │ Probe → Gateway      │
   │                │ (节点调用 RPC)      │ (查询健康)          │
   │ 典型客户端     │ 远程 Linux/Mac 机器  │ LB / K8s / 监控      │
   └────────────────┴──────────────────────┴──────────────────────┘
```

### Node Host 的 SSH 配对信任链

```
   ┌──────────────────────────────────────────────────────┐
   │              SSH 配对信任建立                         │
   │                                                      │
   │  ┌─────────────┐         ┌─────────────┐            │
   │  │ 远程机器    │         │ Gateway     │            │
   │  │ (待配对)    │         │             │            │
   │  └──────┬──────┘         └──────┬──────┘            │
   │         │                       │                   │
   │         │  1. SSH key 提交      │                   │
   │         │ ─────────────────────►│                   │
   │         │                       │                   │
   │         │  2. SSH key 验证      │                   │
   │         │ ◄─────────────────────│                   │
   │         │                       │                   │
   │         │  3. 生成节点凭证      │                   │
   │         │ ◄─────────────────────│                   │
   │         │                       │                   │
   │         │  4. 后续 WS 接入      │                   │
   │         │     携带节点凭证      │                   │
   │         │ ─────────────────────►│                   │
   │         │                       │                   │
   └──────────────────────────────────────────────────────┘
```

### 协议版本下限的差异化

```
   通用协议版本 = 4
        │
        ├──► UI / CLI / Worker  →  下限 4(必须最新)
        │
        ├──► Node Host          →  下限 3(允许旧版)
        │
        └──► Probe              →  下限 3(允许旧版)

   设计含义:
   Node Host 与 Probe 功能集是子集(健康检查、远程调用),
   不需要最新协议特性,允许旧版接入降低升级成本
```

## 协作流程

### 一次 Node Host 接入的完整旅程

下面追踪远程机器作为配对节点接入 Gateway 并被调用的全过程。

```
远程机器准备作为配对节点
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. SSH 配对预流程                                             │
│    • 提交 SSH key 给 Gateway                                 │
│    • Gateway 验证 SSH key                                    │
│    • 生成节点凭证                                            │
│    (建立 Gateway 与节点的信任)                              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. WS 连接 Gateway                                            │
│    • 发起 WS upgrade                                          │
│    • 携带 ClientId: node-host                                 │
│    • 携带 Mode: node                                          │
│    • 携带 Protocol-Version: ≥3                                │
│    • 携带节点凭证                                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 统一认证面校验                                             │
│    • 校验节点凭证                                             │
│    • 产出归一认证结果                                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 注册到节点注册中心                                         │
│    • 注册节点能力列表(计算/文件系统/GPU)                   │
│    • 注册节点状态(online/busy)                              │
│    • 保存节点凭证                                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 等待节点调用 RPC                                           │
│    • Gateway 可发起节点调用(运行 CLI/文件访问/计算)        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 执行调用,流式返回结果                                     │
│    • Gateway 发起节点调用 RPC                                 │
│    • 节点执行任务                                             │
│    • 流式返回输出(transcript/live-event)                    │
└──────────────────────────────────────────────────────────────┘
```

### 一次 Probe 健康探测的完整旅程

```
负载均衡器 / K8s / 监控系统
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 轻量 WS 连接                                               │
│    • 发起 WS upgrade                                          │
│    • 携带 ClientId: openclaw-probe                            │
│    • 携带 Mode: probe                                         │
│    • 携带 Protocol-Version: ≥3                                │
│    • token 可选                                               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 轻量认证                                                   │
│    • Probe 认证器校验(可跳过完整 hello 协商)               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 健康状态返回                                               │
│    • Gateway 就绪状态                                         │
│    • 节点状态汇总                                             │
│    • 简单 JSON 响应                                           │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. Node Host 通过 SSH 配对建立信任

- **为什么**:远程机器提供计算能力,需可信接入;手动 token 管理繁琐
- **怎么做**:SSH 配对预流程验证 SSH key,生成节点凭证;后续 WS 接入用凭证认证
- **影响**:节点接入需先配对,凭证生命周期需管理

### 2. Probe 可跳过完整握手

- **为什么**:负载均衡/K8s 健康检查高频且轻量,完整 hello 协商成本过高
- **怎么做**:Probe 走轻量认证,可跳过 hello,直接返回健康状态
- **影响**:健康检查成本低,但 Probe 不建立完整会话

### 3. 协议版本下限差异化

- **为什么**:Node Host 与 Probe 功能集是子集,不需要最新协议特性
- **怎么做**:两者协议下限均为 3(通用客户端为 4)
- **影响**:旧版 Node/Probe 可接入新版 Gateway,降低升级成本

### 4. 节点调用方向是 Gateway → Node

- **为什么**:节点是能力提供方,Gateway 是能力消费方
- **怎么做**:Gateway 通过节点调用 RPC 主动调用节点能力,节点流式返回结果
- **影响**:节点不主动发起业务调用,只响应 Gateway 请求

### 5. 节点注册中心管理节点状态

- **为什么**:Gateway 需知道哪些节点在线、有哪些能力、是否繁忙
- **怎么做**:节点接入后注册到节点注册中心,维护能力列表与状态
- **影响**:Gateway 可按能力与状态调度任务到合适节点

## 设计观察

### 为什么 Node Host 用 SSH 配对而非手动 token

```
错误设计:
   每个远程节点手动配置长期 token,管理员手动分发
   → token 泄漏难轮换,节点增多时管理成本高
   → 节点身份与机器脱钩

正确设计:
   SSH 配对预流程验证 SSH key,自动生成节点凭证
   → 凭证与机器 SSH 身份绑定
   → 配对流程自动化,信任建立可审计
```

### 为什么 Probe 协议下限宽松

```
错误设计:
   Probe 也要求协议版本 4,必须最新
   → 健康检查基础设施(LB/K8s)升级慢,新 Gateway 上线时探测失败
   → 健康检查受阻,影响部署

正确设计:
   Probe 协议下限 3,允许旧版
   → 健康检查基础设施无需同步升级
   → 新 Gateway 上线即可被旧版 Probe 探测
```

### 为什么 Probe 调用方向与 Node Host 相反

```
   Node Host:  Gateway ──► Node(Gateway 主动调用节点能力)
   Probe:      Probe  ──► Gateway(Probe 主动查询 Gateway 健康)

   原因:
   Node Host 是能力提供方,Gateway 消费 → Gateway 主动调用
   Probe 是健康消费方,Gateway 是被探测对象 → Probe 主动查询
   → 方向反映角色:谁有需求谁发起
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
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | 本文件 — Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Node Host 接入 | [src/gateway/node-agent-cli-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/node-agent-cli-runtime.ts) |
| 节点注册中心 | [src/gateway/node-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/node-registry.ts) |
| SSH 配对验证 | [src/gateway/node-pairing-ssh-verify.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/node-pairing-ssh-verify.ts) |
| Probe 接入 | [src/gateway/probe.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/probe.ts) |
| Probe 认证 | [src/gateway/probe-auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/probe-auth.ts) |
| 协议版本 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
