# 12 — 认证统一面 + ClientId 注册表

> 读完本章你将理解:7 种认证方式如何归一为单一结果对象,16 类客户端身份如何在中央注册表登记,以及为什么协议版本管理对不同客户端类型有差异化下限。

## 一句话定位

认证统一面与 ClientId 注册表是所有接入层共享的两个横切关注点:认证面把 7 种认证方式归一为单一结果对象,后续业务逻辑无需区分具体方式;ClientId 注册表集中登记 16 类客户端身份,用于可观测性、协议版本协商与客户端能力识别。两者共同保证所有接入路径的认证与身份一致。

## 全局协作图

下图展示所有接入如何经过统一认证面,以及 ClientId 注册表如何横切所有客户端类型。**先看这张图建立心智模型,再读细节**。

```
              所有接入方式
   (HTTP / WS / Worker / Node / Probe / Plugin / Channel)
                    │
                    │
        ┌───────────┼───────────┐
        │           │           │
        ▼           ▼           ▼
   ┌──────────────────────────────────────┐
   │      统一认证面                      │
   │                                      │
   │  Bind 模式 → 默认认证映射:          │
   │  • loopback  → none                  │
   │  • lan       → token / password      │
   │  • tailnet   → tailscale             │
   │  • auto      → 视环境                │
   │                                      │
   │  7 种认证方式:                       │
   │  1. none            无认证           │
   │  2. token           共享密钥         │
   │  3. password        共享密码         │
   │  4. tailscale       Tailscale Whois  │
   │  5. device-token    已配对设备       │
   │  6. bootstrap-token 引导配对         │
   │  7. trusted-proxy   可信代理转发头   │
   │                                      │
   │  → 归一为单一结果对象                │
   │    (method + identity + capabilities)│
   └───────────────────┬──────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────┐
   │      ClientId 注册表                │
   │      (16 类客户端身份)              │
   │                                      │
   │  • UI 类(9):webchat/control-ui/   │
   │    browser-copilot/tui/macos/linux/ │
   │    ios/watchos/android              │
   │  • CLI 类(1):cli                   │
   │  • 客户端类(1):gateway-client      │
   │  • Node 类(1):node-host(≥3)       │
   │  • Worker 类(1):openclaw-worker    │
   │  • Probe 类(1):openclaw-probe(≥3) │
   │  • 测试类(2):test/fingerprint      │
   └───────────────────┬──────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────┐
   │      协议版本管理                    │
   │                                      │
   │  通用协议版本:4                      │
   │  • UI/CLI/Worker   下限 4(最新)    │
   │  • Node Host       下限 3(宽松)    │
   │  • Probe           下限 3(宽松)    │
   └──────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **统一认证面** | 7 种认证方式归一为单一结果对象 | 所有接入必须经过,无认证旁路 |
| **Bind 模式映射** | 按绑定地址选默认认证策略 | loopback/lan/tailnet/auto 各有默认 |
| **ClientId 注册表** | 16 类客户端身份中央登记 | 新增客户端类型必须在此注册 |
| **协议版本管理** | 各客户端类型的协议版本下限 | 版本 bump 需 owner 显式确认 |
| **认证字段优先级** | 连接参数多 token 字段的匹配顺序 | 有明确优先级,避免歧义 |

## 关联关系

### Bind 模式与默认认证映射

```
   ┌──────────────────────────────────────────────────────┐
   │              Bind 模式 → 默认认证                    │
   │                                                      │
   │  ┌────────────┬─────────────────┬──────────────┐    │
   │  │ Bind 模式  │ 绑定地址        │ 默认认证     │    │
   │  ├────────────┼─────────────────┼──────────────┤    │
   │  │ loopback   │ 127.0.0.1       │ none         │    │
   │  │ lan        │ 0.0.0.0(局域网)│ token/password│   │
   │  │ tailnet    │ Tailscale 接口  │ tailscale    │    │
   │  │ auto       │ 自动判断        │ 视环境       │    │
   │  └────────────┴─────────────────┴──────────────┘    │
   │                                                      │
   │  Bind 模式决定默认认证策略,                         │
   │  客户端也可显式提供凭证覆盖默认                      │
   └──────────────────────────────────────────────────────┘
```

### 认证字段优先级

```
   连接参数携带多个认证字段,按优先级匹配:

   ┌──────────────────────────────────────────────────────┐
   │  优先级(从高到低):                                 │
   │                                                      │
   │  1. 审批运行时 token        (审批场景)               │
   │  2. Agent 运行时身份 token  (Agent 运行时)           │
   │  3. 设备 token              (设备长期凭证)           │
   │  4. 引导 token              (一次性引导)             │
   │  5. 共享 token              (共享密钥)               │
   │  6. 密码                    (共享密码)               │
   │                                                      │
   │  匹配 → 返回对应认证方式                             │
   │  不匹配 → 拒绝接入                                   │
   └──────────────────────────────────────────────────────┘
```

### ClientId 注册表的分类

```
   ┌──────────────────────────────────────────────────────┐
   │              16 类客户端身份分类                     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ UI 类(mode: ui)— 9 个                   │     │
   │  │   webchat-ui / webchat   嵌入式 Webchat    │     │
   │  │   openclaw-control-ui    Control UI        │     │
   │  │   openclaw-browser-copilot Browser 扩展    │     │
   │  │   openclaw-tui           终端 UI           │     │
   │  │   openclaw-macos         macOS app         │     │
   │  │   openclaw-linux         Linux Tauri app   │     │
   │  │   openclaw-ios           iOS app           │     │
   │  │   openclaw-watchos       watchOS app       │     │
   │  │   openclaw-android       Android app       │     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ CLI 类(mode: cli)— 1 个                  │     │
   │  │   cli                     CLI backend      │     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ 客户端类(mode: client)— 1 个             │     │
   │  │   gateway-client         Node.js 通用客户端│     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ Node 类(mode: node)— 1 个(协议 ≥3)     │     │
   │  │   node-host               配对节点          │     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ Worker 类(mode: worker)— 1 个            │     │
   │  │   openclaw-worker         Worker 进程      │     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ Probe 类(mode: probe)— 1 个(协议 ≥3)   │     │
   │  │   openclaw-probe          健康探测          │     │
   │  └────────────────────────────────────────────┘     │
   │                                                      │
   │  ┌────────────────────────────────────────────┐     │
   │  │ 测试类 — 2 个                              │     │
   │  │   test / fingerprint      测试/指纹        │     │
   │  └────────────────────────────────────────────┘     │
   └──────────────────────────────────────────────────────┘
```

## 协作流程

### 一次认证决策的完整旅程

下面追踪一个接入请求(如原生 App WS 接入)如何经过统一认证面的全过程。

```
接入请求(HTTP / WS)到达
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 提取 Bind 模式                                             │
│    • 判断绑定模式(loopback / lan / tailnet / auto)          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 按模式选择认证策略                                         │
│    • loopback → 默认 none                                    │
│    • lan/auto → 检查各 token 字段                            │
│    • tailnet  → Tailscale Whois                             │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 按字段优先级匹配(lan/auto 模式)                         │
│    1. 审批运行时 token                                        │
│    2. Agent 运行时身份 token                                  │
│    3. 设备 token                                              │
│    4. 引导 token                                              │
│    5. 共享 token                                              │
│    6. 密码                                                    │
│    匹配 → 返回对应 method                                     │
│    不匹配 → 拒绝                                              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 产出归一认证结果                                           │
│    • method: none/token/password/tailscale/device-token/...  │
│    • identity: 身份信息                                       │
│    • capabilities: 能力列表                                   │
│    (后续业务逻辑无需区分具体认证方式)                        │
└──────────────────────────────────────────────────────────────┘
```

### 7 种认证方式的使用场景

| 认证方式 | 含义 | 典型场景 |
|---|---|---|
| none | 无认证 | loopback 模式默认(仅本机) |
| token | 共享密钥 | LAN / tailnet 模式 |
| password | 共享密码 | LAN 模式 |
| tailscale | Tailscale Whois | tailnet 模式 |
| device-token | 已配对设备 | Control UI / 原生 App |
| bootstrap-token | 引导配对 | 首次配对 |
| trusted-proxy | 可信代理转发头 | 反向代理场景 |

## 关键设计约束

### 1. 所有接入必须经过统一认证面

- **为什么**:避免各接入路径各搞认证,导致认证逻辑不一致、审计困难
- **怎么做**:HTTP 与 WS 接入都走同一认证面,7 种方式归一为单一结果对象
- **影响**:业务代码只消费归一结果,不关心具体认证方式

### 2. Bind 模式决定默认认证

- **为什么**:不同部署环境的信任边界不同(loopback 可信、LAN 需 token、tailnet 用 Whois)
- **怎么做**:按绑定地址选默认认证策略,客户端也可显式提供凭证覆盖
- **影响**:部署配置即安全策略,降低误配置风险

### 3. ClientId 必须在注册表登记

- **为什么**:集中管理客户端身份,便于可观测性、协议版本协商、客户端能力识别
- **怎么做**:16 类客户端身份有中央注册表,新增客户端类型必须在此注册
- **影响**:未注册的 ClientId 无法接入

### 4. 协议版本 bump 是重大决策

- **为什么**:协议版本影响所有客户端,盲目 bump 会断裂旧版客户端
- **怎么做**:版本 bump 不能自动生成,需 owner 显式确认;兼容性变更必须 additive first
- **影响**:协议演进缓慢且谨慎

### 5. 协议版本下限差异化

- **为什么**:Node Host 与 Probe 功能集是子集,强制最新版本会阻碍基础设施升级
- **怎么做**:UI/CLI/Worker 下限 4(必须最新),Node/Probe 下限 3(允许旧版)
- **影响**:健康检查与远程节点基础设施无需同步升级

### 6. 认证字段有明确优先级

- **为什么**:连接参数可同时携带多个 token 字段,无优先级会产生歧义
- **怎么做**:6 个字段从审批运行时 token 到密码有明确优先级,按序匹配
- **影响**:认证决策确定性,避免歧义

## 设计观察

### 为什么 7 种认证方式归一为单一结果

```
错误设计:
   业务代码里到处判断:
   如果是 token 认证 → 走 A 分支
   如果是 password 认证 → 走 B 分支
   如果是 tailscale 认证 → 走 C 分支
   → 认证逻辑散落,新增方式要改所有调用点
   → 不一致风险高

正确设计:
   7 种方式归一为单一结果对象(method + identity + capabilities)
   业务代码只消费归一结果,不关心具体方式
   → 新增认证方式只改认证面,业务代码不变
```

### 为什么 Node/Probe 协议下限宽松

```
错误设计:
   所有客户端协议下限都是 4
   → 新 Gateway 上线,旧版 LB/K8s Probe 无法探测
   → 旧版远程节点无法接入
   → 基础设施升级被 Gateway 绑架

正确设计:
   UI/CLI/Worker 下限 4(需要最新功能)
   Node/Probe 下限 3(功能子集,允许旧版)
   → 基础设施无需同步升级
   → Gateway 可独立演进
```

### 为什么 Bind 模式决定默认认证

```
错误设计:
   所有模式都要求显式配置认证方式
   → loopback 本机接入也要配 token,繁琐
   → 用户易误配置(把 lan 配成 none,暴露风险)

正确设计:
   Bind 模式决定默认认证:
   • loopback → none(本机可信)
   • lan → token/password(需保护)
   • tailnet → tailscale(网络身份)
   → 安全策略与部署环境匹配,降低误配置
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
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 本文件 — 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| Bind 模式默认认证映射 | [src/gateway/server-public.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-public.ts) |
| 连接参数认证字段 | [packages/gateway-protocol/src/schema/frames.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema/frames.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
| 协议版本管理 | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |
