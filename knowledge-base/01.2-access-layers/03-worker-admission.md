# 03 — Worker 接入(独立子协议)

> 读完本章你将理解:Worker 进程为什么不用普通客户端协议,而是走独立的 upgrade handler 与一套细粒度匹配的握手,以及它如何流式提交 Agent run 的 transcript。

## 一句话定位

Worker 进程通过 WebSocket 子协议接入 Gateway,用于流式提交 Agent run 的 transcript 与 live event;它与普通 Gateway 客户端使用**独立的 upgrade handler**实现隔离,通过多维度握手字段(bundleHash / environmentId / ownerEpoch / rpcSetVersion 等)确保 Worker 与 Gateway 状态严格一致。

## 全局协作图

下图展示 Worker 与普通客户端在同一个根 server 上如何分流到两套独立协议。**先看这张图建立心智模型,再读细节**。

```
                  Worker 进程
              (流式提交 Agent run)
                        │
                        │ WS upgrade(独立 handler)
                        ▼
   ┌───────────────────────────────────────┐
   │      Gateway HTTP/WS Server(根)      │
   │      (见 01 章)                      │
   └───────────────────┬───────────────────┘
                       │ WS 升级分流器
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
   ┌──────────────┐           ┌──────────────┐
   │ Gateway 客户端│           │  Worker      │
   │ upgrade       │           │  upgrade     │
   │ (见 02 章)   │           │  (本章)      │
   └──────────────┘           └──────┬───────┘
                                     │
                                     ▼
                          ┌────────────────────┐
                          │ Worker 接入握手     │
                          │                    │
                          │ 多维度校验:        │
                          │ • credential       │
                          │ • bundleHash       │
                          │ • openclawVersion  │
                          │ • protocolFeatures │
                          │ • environmentId    │
                          │ • ownerEpoch       │
                          │ • rpcSetVersion    │
                          │ • sessionId/runId  │
                          └─────────┬──────────┘
                                    │
                     ┌──────────────┴──────────────┐
                     │                             │
                     ▼                             ▼
               校验失败                        校验通过
                     │                             │
                     ▼                             ▼
              ┌─────────────┐           ┌──────────────────┐
              │ close 帧    │           │ ready + 心跳定时器│
              │(16 种原因)│           │ (15s 间隔)       │
              └─────────────┘           └────────┬─────────┘
                                                 │
                                                 ▼
                                  ┌──────────────────────┐
                                  │ 流式提交 RPC          │
                                  │ • transcript.commit   │
                                  │ • live-event          │
                                  │ • heartbeat(每15s)   │
                                  └──────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Worker upgrade handler** | 独立于 Gateway 客户端 upgrade,接收 Worker 连接 | 与普通客户端协议逻辑隔离 |
| **Worker 接入握手帧** | 携带 credential + 多维度握手字段 | 任一字段不匹配即关闭 |
| **多维度校验器** | 校验 bundle/version/environment/ownerEpoch/rpcSet/session 等 | 6+ 维度同时匹配 |
| **心跳定时器** | 每 15 秒发送一次心跳,超时则关闭 | 防止 Worker 卡死拖垮 Gateway |
| **流式提交 RPC 集** | transcript.commit / live-event / heartbeat 三类 RPC | RPC 集合固定,版本由 rpcSetVersion 标识 |
| **关闭原因集** | 16 种细粒度关闭原因 | 便于排查具体不匹配维度 |

## 关联关系

### Worker 协议与 Gateway 客户端协议的隔离

```
                  Gateway HTTP/WS Server(根)
                          │
                   WS 升级分流器
                          │
           ┌──────────────┴──────────────┐
           │                             │
           ▼                             ▼
   ┌────────────────┐           ┌────────────────┐
   │ Gateway 客户端  │           │   Worker        │
   │ upgrade handler │           │ upgrade handler │
   │                 │           │                 │
   │ 协议:Gateway WS│           │ 协议:Worker   │
   │ 用途:双向 RPC  │           │ 用途:流式提交  │
   │ 认证:统一认证面│           │ 认证:credential│
   └────────────────┘           │      + 多维握手  │
                                 └────────────────┘

   ⚠ 共享端口,但 upgrade handler 与逻辑完全独立
```

### 握手字段的多维度校验矩阵

```
   Worker 接入握手帧
        │
        ▼
   ┌────────────────────────────────────────────┐
   │           多维度校验                       │
   │                                            │
   │  credential        ──► Worker 身份凭证     │
   │  bundleHash        ──► 代码包一致性        │
   │  openclawVersion   ──► 版本一致            │
   │  protocolFeatures  ──► 协议特性兼容        │
   │  environmentId     ──► 环境隔离一致        │
   │  ownerEpoch        ──► owner 轮次一致      │
   │  rpcSetVersion     ──► RPC 集合版本        │
   │  sessionId/runId   ──► 绑定到具体 run      │
   │                                            │
   │  任一不匹配 → 对应 close 原因              │
   └────────────────────────────────────────────┘
```

### 流式提交 RPC 与 Agent run 的关系

```
   Agent run 在 Worker 进程执行
        │
        │ 流式输出
        ▼
   ┌──────────────────────────────────┐
   │  Worker 流式提交 RPC             │
   │                                  │
   │  transcript.commit ──► 提交一段  │
   │                        transcript│
   │                                  │
   │  live-event ─────────► 推送实时  │
   │                        事件      │
   │                                  │
   │  heartbeat ──────────► 每 15s    │
   │                        保活      │
   └──────────────┬───────────────────┘
                  │
                  ▼
            Gateway 接收并归并
            到对应 Agent run
```

## 协作流程

### 一次 Worker 接入到流式提交的完整旅程

下面追踪一个 Worker 进程从启动到流式提交 Agent run 的全过程。

```
Worker 进程启动(承接一个 Agent run)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Worker 凭证获取                                            │
│    • 从 Gateway 或环境获取 credential                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. WS 连接 Gateway(由根 server 接收)                        │
│    • 走独立的 Worker upgrade handler(非 Gateway 客户端路)   │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 发送 Worker 接入握手帧                                     │
│    • credential + 多维度握手字段                              │
│    • bundleHash / openclawVersion / protocolFeatures         │
│    • environmentId / ownerEpoch / rpcSetVersion              │
│    • sessionId / runId                                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Gateway 多维度校验                                         │
│    • credential 有效性                                        │
│    • bundleHash / version / features 匹配                    │
│    • environmentId / ownerEpoch / rpcSetVersion 匹配         │
│    • sessionId / runId 匹配                                   │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
                ┌─────────────┴─────────────┐
                │                           │
                ▼                           ▼
          校验失败                       校验通过
                │                           │
                ▼                           ▼
        ┌───────────────┐         ┌──────────────────────┐
        │ close 帧      │         │ 5. ready + 心跳启动  │
        │(具体原因)    │         │   (15s 间隔)         │
        └───────────────┘         └──────────┬───────────┘
                                              ▼
                        ┌──────────────────────────────────────┐
                        │ 6. 流式提交                          │
                        │   • transcript.commit(分段提交)     │
                        │   • live-event(实时事件推送)       │
                        │   • heartbeat(每 15s 保活)         │
                        └──────────────────┬───────────────────┘
                                           │ 直到:
                                           │ • Agent run 完成
                                           │ • credential 过期
                                           │ • gateway-shutdown
                                           │ • slow-consumer 背压
                                           ▼
                                  ┌─────────────────┐
                                  │ close 帧        │
                                  │(关闭原因)      │
                                  └─────────────────┘
```

### 关闭原因与触发场景

| 关闭原因 | 触发场景 |
|---|---|
| invalid-credential | credential 无效 |
| credential-expired | credential 过期 |
| credential-replaced | credential 被替换 |
| environment-mismatch | environmentId 不匹配 |
| bundle-mismatch | bundleHash 不匹配 |
| version-mismatch | openclawVersion 不匹配 |
| session-mismatch | sessionId 不匹配 |
| placement-mismatch | placement 不匹配 |
| owner-epoch-mismatch | ownerEpoch 不匹配 |
| rpc-set-mismatch | rpcSetVersion 不匹配 |
| protocol-features-mismatch | protocolFeatures 不匹配 |
| invalid-handshake | 握手格式错误 |
| protocol-mismatch | 协议版本不兼容 |
| gateway-unavailable | Gateway 不可用 |
| slow-consumer | 消费过慢(背压) |
| gateway-shutdown | Gateway 关闭 |

## 关键设计约束

### 1. 独立 upgrade handler 实现隔离

- **为什么**:Worker 流式提交流量大且高频,不能与普通客户端的双向 RPC 互相影响
- **怎么做**:Worker 走独立 upgrade handler,与 Gateway 客户端 upgrade 分离
- **影响**:排查 WS 问题需先判断属于哪类协议;两类协议可独立演进

### 2. 多维度握手确保状态严格一致

- **为什么**:Worker 承接的 Agent run 必须与 Gateway 当前的 bundle/环境/owner/RPC 集严格匹配,否则 transcript 与 live event 无法正确归并
- **怎么做**:6+ 个字段同时校验,任一不匹配即关闭并返回具体原因
- **影响**:排查接入失败需逐项核对维度,但运行时一致性得到强保证

### 3. 心跳 + 背压双重保护

- **为什么**:Worker 卡死会拖垮 Gateway;慢消费会堆积内存
- **怎么做**:15s 心跳定时器,超时关闭;slow-consumer 关闭原因防背压
- **影响**:Worker 必须及时发送心跳并消费,否则被断开

### 4. RPC 集合固定且版本化

- **为什么**:Worker 的三类 RPC(transcript.commit / live-event / heartbeat)是契约,变更需双方感知
- **怎么做**:rpcSetVersion 标识 RPC 集合版本,握手时校验匹配
- **影响**:新增/变更 RPC 必须 bump rpcSetVersion,旧 Worker 无法接入新 RPC 集

### 5. 流式提交语义

- **为什么**:Agent run 输出是流式的 chunk + tool call,需要实时推送而非一次性返回
- **怎么做**:transcript.commit 分段提交,live-event 推送实时事件
- **影响**:Gateway 侧需支持流式归并与增量更新

## 设计观察

### 为什么 Worker 不复用 Gateway 客户端协议

```
错误设计:
   Worker ──► Gateway 客户端 upgrade ──► 普通 RPC 通道
   → Worker 流式高频提交与客户端双向 RPC 混在一起,
     互相影响;且普通协议无 bundleHash 等一致性校验

正确设计:
   Worker ──► 独立 Worker upgrade ──► Worker 子协议
   → 流量隔离 + 多维度一致性校验 + 流式 RPC 语义
```

### 为什么握手要校验这么多维度

```
错误设计:
   只校验 credential,不校验 bundleHash/environmentId/...
   → 旧 bundle 的 Worker 可接入新 Gateway,
     transcript 格式不兼容 → 数据错乱

正确设计:
   bundleHash + openclawVersion + protocolFeatures +
   environmentId + ownerEpoch + rpcSetVersion 全部匹配
   → 代码包、环境、owner 轮次、RPC 集全部一致
   → transcript 与 live event 可正确归并
```

### 为什么心跳间隔是 15 秒

```
错误设计:
   心跳过长(如 60s)→ Worker 卡死后 Gateway 长时间才发现
   心跳过短(如 1s)→ 大量 Worker 时心跳流量爆炸

正确设计:
   15s 间隔 → 平衡检测延迟与流量开销
   → 卡死在 15s 内被发现,流量可控
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | 本文件 — Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Worker 接入握手协议定义 | [packages/gateway-protocol/src/schema/worker-admission.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/worker-admission.ts) |
| Worker 关闭原因与原语 | [packages/gateway-protocol/src/schema/worker-protocol-primitives.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/worker-protocol-primitives.ts) |
| Gateway HTTP/WS Server(Worker upgrade handler) | [src/gateway/server-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-http.ts) |
| Worker 环境启动 | [src/gateway/server-worker-environment-startup.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-worker-environment-startup.ts) |
| Worker 放置启动 | [src/gateway/server-worker-placement-startup.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-worker-placement-startup.ts) |
| WS 连接类型(区分 worker/gateway) | [src/gateway/server/ws-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server/ws-types.ts) |
