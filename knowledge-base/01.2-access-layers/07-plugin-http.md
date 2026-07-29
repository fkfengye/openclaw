# 07 — Plugin HTTP/Upgrade 接入(插件自定义路由)

> 读完本章你将理解:插件如何在不改核心的前提下注册自己的 HTTP endpoint 与 WebSocket upgrade,以及为什么插件路由优先于主路由、按路径决定是否强制认证。

## 一句话定位

Plugin HTTP/Upgrade 是插件的扩展接入面:插件通过 SDK 注册自定义 HTTP 路由(webhook 接收器、REST API)与 WS upgrade(自定义 WS 服务);插件路由**优先于主路由**被判断,认领即处理,未认领才走主路由;认证按路径上下文决定是否强制 Gateway auth(webhook 等可匿名,但需插件自保护)。

## 全局协作图

下图展示插件 HTTP/Upgrade 如何嵌入根 server 的请求分发链。**先看这张图建立心智模型,再读细节**。

```
                  外部请求
              (HTTP / WS upgrade)
                      │
                      ▼
   ┌───────────────────────────────────────┐
   │      Gateway HTTP/WS Server(根)      │
   │      (见 01 章)                      │
   └───────────────────┬───────────────────┘
                       │
                       ▼
   ┌───────────────────────────────────────┐
   │      插件路由优先判断                  │
   │                                       │
   │  把请求 URL 解析到插件能力面          │
   │  (plugin-id + capability)             │
   └───────────────────┬───────────────────┘
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
   ┌──────────────┐           ┌──────────────┐
   │ 插件认领该路径│           │ 插件未认领   │
   │              │           │              │
   │ 按路径决定:  │           │ 走主路由     │
   │ • 强制认证   │           │ 分类器       │
   │   → Gateway  │           │ (见 01 章)   │
   │     auth     │           └──────────────┘
   │ • 允许匿名   │
   │   → 插件自保 │
   └──────┬───────┘
          │
          ▼
   ┌──────────────────────────────────┐
   │ 插件 handler 处理                 │
   │                                  │
   │ HTTP:                            │
   │ • webhook 接收器                 │
   │ • 自定义 REST API                │
   │                                  │
   │ WS upgrade:                      │
   │ • 自定义 WS 服务                 │
   └──────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **插件能力面解析器** | 把请求 URL 解析到 plugin-id + capability | 确保插件间路径不冲突 |
| **插件 HTTP 请求处理器** | 处理插件认领的 HTTP 路由 | 认领即返回,未认领走主路由 |
| **插件 WS upgrade 处理器** | 处理插件认领的 WS upgrade | 与 Gateway/Worker upgrade 共享端口 |
| **路径认证策略** | 按路径上下文决定是否强制 Gateway auth | webhook 等可匿名,但插件需自保护 |
| **插件 API 构建器** | 插件通过 SDK 注册 HTTP 路由 / upgrade handler | 注册时机在插件 setup 阶段 |

## 关联关系

### 插件路由与主路由的优先级

```
                  外部请求
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ 1. 插件能力面解析器                   │
   │    URL → plugin-id + capability      │
   └──────────────────┬───────────────────┘
                      │
           ┌──────────┴──────────┐
           │                     │
           ▼                     ▼
     插件认领                插件未认领
           │                     │
           ▼                     ▼
   ┌───────────────┐     ┌─────────────────┐
   │ 插件 handler  │     │ 主路由分类器     │
   │ (优先,返回) │     │ (见 01 章)      │
   └───────────────┘     └─────────────────┘

   ⚠ 插件路由优先;插件可认领任意路径
     未认领的才走主路由分类器
```

### 认证策略按路径上下文分流

```
   插件认领的路径
        │
        ▼
   ┌──────────────────────────────────────┐
   │ 路径认证策略判断                      │
   │                                      │
   │  强制认证路径                         │
   │  (如 /api/my-service/*)              │
   │   → 走 Gateway auth                  │
   │   → 插件 handler 收到已认证请求       │
   │                                      │
   │  允许匿名路径                         │
   │  (如 /webhook/my-service)            │
   │   → 跳过 Gateway auth                │
   │   → 插件自行保护(如 webhook 签名)   │
   └──────────────────────────────────────┘
```

### 插件 HTTP 与插件 WS upgrade 的并列

```
   插件通过 SDK 注册两类能力:
        │
        ├─ HTTP 路由(http-route 能力)
        │   │
        │   ▼
        │   ┌──────────────────────────┐
        │   │ 插件 HTTP 请求处理器      │
        │   │ • webhook 接收器         │
        │   │ • 自定义 REST API        │
        │   └──────────────────────────┘
        │
        └─ WS upgrade(ws-upgrade 能力)
            │
            ▼
            ┌──────────────────────────┐
            │ 插件 WS upgrade 处理器    │
            │ • 自定义 WS 服务         │
            │ (与 Gateway/Worker       │
            │  upgrade 共享端口)       │
            └──────────────────────────┘
```

## 协作流程

### 一次插件 webhook 接收的完整旅程

下面追踪一个外部服务向插件 webhook 推送事件的全过程。

```
外部服务向 /webhook/my-service 推送事件
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Gateway HTTP/WS Server 接收(由 01 章根负责)              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 插件能力面解析器                                           │
│    • URL → plugin-id: my-webhook + capability: http-route    │
│    • 插件认领该路径                                           │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 路径认证策略判断                                           │
│    • 该路径配置为允许匿名(enforceAuth: false)              │
│    • 跳过 Gateway auth                                       │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 插件 handler 处理                                          │
│    • 插件自行验证 webhook 签名(插件自保护)                 │
│    • 处理 webhook 事件                                       │
│    • 转换为内部事件 → 进入 Gateway                           │
│    • 返回 200                                                │
└──────────────────────────────────────────────────────────────┘
```

### 典型使用场景

| 场景 | 认证策略 | 插件职责 |
|---|---|---|
| Webhook 接收器 | 允许匿名(enforceAuth: false) | 自行验证 webhook 签名 |
| 自定义 REST API | 强制认证(enforceAuth: true) | 收到已认证请求,提供 API |
| 自定义 WS 服务 | 按需 | 提供 WS 服务 |

## 关键设计约束

### 1. 插件路由优先于主路由

- **为什么**:插件需能扩展被主路由占用的路径前缀,扩展能力强
- **怎么做**:请求先经插件能力面解析器,认领即处理,未认领走主路由
- **影响**:插件可认领任意路径,主路由只兜底

### 2. 认证按路径上下文决定

- **为什么**:webhook 等场景外部服务无法携带 Gateway token,需允许匿名;但需插件自保护
- **怎么做**:每个插件路由声明 enforceAuth,强制认证走 Gateway auth,允许匿名则插件自行验证
- **影响**:允许匿名的路径是攻击面,插件必须自保护(如签名验证)

### 3. 插件间路径隔离

- **为什么**:多插件不能争抢同一路径
- **怎么做**:能力面解析器把 URL 唯一映射到 plugin-id + capability
- **影响**:路径冲突需明确解决策略

### 4. WS upgrade 与主升级共享端口

- **为什么**:用户只需开放一个端口
- **怎么做**:插件 WS upgrade 与 Gateway/Worker upgrade 共享端口,优先级明确
- **影响**:需明确插件 upgrade 与主 upgrade 的路由优先级

### 5. 插件 handler 异步执行

- **为什么**:插件逻辑可能涉及 IO,需异步
- **怎么做**:插件 handler 为异步函数
- **影响**:慢 handler 可能成为瓶颈,需关注性能

## 设计观察

### 为什么插件路由优先而非主路由优先

```
错误设计:
   主路由分类器先跑 → 插件只能用主路由未覆盖的路径
   → 插件无法扩展被主路由占用的前缀,扩展能力弱

正确设计:
   插件路由优先 → 插件可认领任意路径
   未认领才走主路由分类器
   → 插件扩展能力强,主路由只兜底
```

### 为什么允许插件路径匿名而非全部强制认证

```
错误设计:
   所有插件路径强制 Gateway auth
   → webhook 场景外部服务无法携带 Gateway token,无法接入

正确设计:
   按路径声明 enforceAuth
   • webhook 类:允许匿名,插件自验证签名
   • API 类:强制认证,插件收已认证请求
   → 适配不同场景,但允许匿名的路径需插件自负安全
```

### 为什么插件 WS upgrade 与主升级共享端口

```
错误设计:
   插件 WS upgrade 起独立端口
   → 用户需开多端口,部署复杂

正确设计:
   插件 WS upgrade 复用根 server 端口
   优先级:插件 upgrade > Gateway/Worker upgrade
   → 单端口,部署简单,但需明确优先级
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
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | 本文件 — Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 插件 HTTP 请求处理器 | [src/gateway/server/plugins-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server/plugins-http.ts) |
| 插件能力面解析 | [src/gateway/plugin-node-capability.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/plugin-node-capability.ts) |
| 插件 API 构建器(注册路由) | [src/plugins/api-builder.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/api-builder.ts) |
| Gateway HTTP/WS Server(路由分发) | [src/gateway/server-http.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-http.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
