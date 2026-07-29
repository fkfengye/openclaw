# 06 — Control UI 接入(浏览器 UI)

> 读完本章你将理解:用户通过浏览器操作 OpenClaw 时,HTTP(静态资源 + SPA)与 WebSocket(应用层 RPC)如何分工,以及配对设备认证如何从旧配置平滑迁移。

## 一句话定位

Control UI 是用户通过浏览器操作 OpenClaw 的主要接入方式:HTTP 提供静态资源(SPA + 资源 + 助手媒体)与严格 CSP,WebSocket 复用 Gateway WS 协议承载应用层 RPC;认证复用统一认证面(token / password / deviceToken / bootstrapToken),并支持从旧配置向配对设备认证迁移。

## 全局协作图

下图展示浏览器一次完整接入如何分裂为 HTTP(资源)+ WS(RPC)两路。**先看这张图建立心智模型,再读细节**。

```
                  用户浏览器
                      │
        ┌─────────────┴─────────────┐
        │                           │
        │ 1. HTTP(资源)            │ 2. WS(RPC)
        │  GET /                    │  ws upgrade
        │  GET /assets/*            │  clientId: openclaw-control-ui
        │  GET /__openclaw__/       │  mode: ui
        │    assistant-media        │  token/password/deviceToken/
        │                           │  bootstrapToken
        ▼                           ▼
   ┌───────────────────────────────────────────────┐
   │         Gateway HTTP/WS Server(根)           │
   │         (见 01 章)                           │
   └───────────────────────┬───────────────────────┘
                           │
            ┌──────────────┴──────────────┐
            │                             │
            ▼                             ▼
   ┌──────────────────┐          ┌──────────────────┐
   │ Control UI 服务端 │          │ Gateway WS 协议  │
   │ 处理器            │          │ (见 02 章)       │
   │                  │          │                  │
   │ • 严格 CSP       │          │ • 握手 + 认证    │
   │ • 静态资源服务   │          │ • HelloOk + 快照 │
   │ • HTML body 注入 │          │ • 双向 RPC/Event │
   │ • SPA fallback   │          └──────────────────┘
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ 统一认证面       │
   │ (见 12 章)       │
   └──────────────────┘
            │
            ▼
   ┌──────────────────┐
   │ 业务内核         │
   │ (Lane/Agent/Turn)│
   └──────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Control UI 服务端处理器** | 提供 SPA、静态资源、HTML body、SPA fallback | 严格 CSP 防 XSS |
| **静态资源服务** | 提供 JS/CSS/icons | 需 cache-busting |
| **助手媒体端点** | 提供助手图片/文件 | 访问控制需明确 |
| **浏览器 WS 客户端** | 浏览器侧 WS 接入,走 Gateway WS 协议 | 复用统一认证面 |
| **CSP 策略** | 严格内容安全策略,防 XSS 与数据外泄 | 可能限制第三方库 |
| **设备认证迁移器** | 从旧配置迁移到配对设备认证 | 平滑迁移,不破坏旧部署 |

## 关联关系

### HTTP 资源路与 WS RPC 路的分工

```
   浏览器
     │
     ├─ HTTP 路(资源,一次性或缓存)
     │   │
     │   ▼
     │   ┌──────────────────────────────┐
     │   │ Control UI 服务端处理器       │
     │   │ • /                → SPA     │
     │   │ • /assets/*        → JS/CSS  │
     │   │ • /__openclaw__/            │
     │   │   assistant-media → 媒体    │
     │   │ • 任意前端路由 → SPA fallback│
     │   └──────────────────────────────┘
     │
     └─ WS 路(长连接,双向 RPC)
         │
         ▼
         ┌──────────────────────────────┐
         │ Gateway WS 协议(见 02 章)  │
         │ • 握手 + 认证                │
         │ • HelloOk(snapshot)         │
         │ • Method / Event 双向通信    │
         └──────────────────────────────┘
```

### Control UI 与其他接入面的认证共享

```
   Control UI 复用统一认证面(见 12 章):

   ┌──────────────────────────────────────┐
   │ Control UI 可用的认证方式            │
   │                                      │
   │ • token          共享密钥            │
   │ • password       共享密码            │
   │ • deviceToken    已配对设备(主用)  │
   │ • bootstrapToken 引导配对(首次)    │
   └──────────────────────────────────────┘
                    │
                    ▼
            归一为单一认证结果
            后续业务逻辑无感知
```

### 设备认证迁移路径

```
   旧配置(禁用设备认证)
        │
        ▼
   ┌──────────────────────────────────┐
   │ 1. 启动引导检测旧配置            │
   │    • 识别旧的危险配置项          │
   └──────────────┬───────────────────┘
                  ▼
   ┌──────────────────────────────────┐
   │ 2. 迁移到配对设备认证            │
   │    • 生成 device token           │
   │    • 写入状态库                  │
   │    • 启用 deviceToken 认证       │
   │    • 禁用旧配置项                │
   └──────────────┬───────────────────┘
                  ▼
   ┌──────────────────────────────────┐
   │ 3. 用户首次访问                  │
   │    • 引导配对流程                 │
   │    • 生成 bootstrapToken         │
   │    • 用户确认配对                 │
   │    • 颁发 deviceToken            │
   └──────────────────────────────────┘
```

## 协作流程

### 一次浏览器接入的完整旅程

下面追踪用户首次打开浏览器到双向通信的全过程。

```
用户浏览器打开 Gateway 地址
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. HTTP 请求 /(由 01 章根 server 接收)                       │
│    • 路径分类器命中 Control UI 路由                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Control UI 服务端处理器                                    │
│    • 设置严格 CSP headers                                    │
│    • 服务静态资源 / HTML body 注入                           │
│    • SPA fallback(前端路由回退 index.html)                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 浏览器加载 SPA                                            │
│    • 加载 JS/CSS/icons                                       │
│    • 初始化前端应用                                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 浏览器发起 WS upgrade                                     │
│    • clientId: openclaw-control-ui                           │
│    • mode: ui                                                │
│    • 携带 token/password/deviceToken/bootstrapToken          │
│    • 走第 02 章 Gateway WS 协议握手                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 统一认证面校验 → HelloOk 返回(snapshot)                  │
│    • 浏览器拿到初始状态快照                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 双向 RPC + Event 通信                                     │
│    • 浏览器发 Method(session.attach / agent.run / ...)      │
│    • Gateway 推 Event(agent.message / channel.event / ...)  │
│    • 浏览器渲染 UI                                           │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. HTTP 与 WS 分工

- **为什么**:资源加载适合无状态 HTTP,实时交互适合长连接 WS
- **怎么做**:HTTP 提供静态资源 + SPA,WS 承载 RPC + Event
- **影响**:浏览器需同时维护两条路,但职责清晰

### 2. 严格 CSP

- **为什么**:浏览器环境易受 XSS 攻击,需防数据外泄
- **怎么做**:Control UI 服务端设置严格 Content-Security-Policy
- **影响**:部分第三方库可能不兼容,需评估

### 3. SPA fallback

- **为什么**:前端路由(如 /settings)需直接访问,不能 404
- **怎么做**:所有未匹配路径回退到 index.html,由前端路由处理
- **影响**:静态资源缓存策略需配合 cache-busting

### 4. 复用 Gateway WS 协议

- **为什么**:避免为 UI 单独设计协议
- **怎么做**:浏览器 WS 客户端走标准 Gateway WS 协议(见 02 章)
- **影响**:UI 与原生 App 共享协议演进

### 5. 设备认证迁移

- **为什么**:旧配置(禁用设备认证)不安全,需平滑迁移到配对设备认证
- **怎么做**:启动引导检测旧配置,生成 device token,启用 deviceToken 认证
- **影响**:旧部署升级时自动迁移,operator 需理解迁移行为

## 设计观察

### 为什么 Control UI 不单独起 server 而复用根 server

```
错误设计:
   Control UI 独立 HTTP server(另一端口)
   → 用户需开多端口,认证、CSP、状态各做一遍

正确设计:
   Control UI 复用 Gateway 根 server
   → 单端口、共享认证面、共享状态库、统一可观测
```

### 为什么用 SPA fallback 而非服务端路由

```
错误设计:
   每个前端路由都服务端渲染或单独处理
   → 路由变更需改服务端,前后端耦合

正确设计:
   SPA fallback:未匹配路径回退 index.html
   → 前端路由完全由 SPA 处理,服务端只兜底
```

### 为什么设备认证要迁移而非保留旧配置

```
错误设计:
   保留"禁用设备认证"旧配置长期可用
   → 不安全的部署长期存在,攻击面大

正确设计:
   启动引导自动迁移到配对设备认证
   → 旧部署升级即安全,operator 无需手动改
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
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | 本文件 — Control UI 接入 |
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
| Control UI 服务端处理器 | [src/gateway/control-ui.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui.ts) |
| Control UI 静态资源 | [src/gateway/control-ui-static.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-static.ts) |
| Control UI CSP 策略 | [src/gateway/control-ui-csp.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-csp.ts) |
| 浏览器 WS 客户端 | [ui/src/api/gateway-browser-socket.ts](file:///d:/DevSpace/person/ai_space/openclaw/ui/src/api/gateway-browser-socket.ts) |
| 设备认证迁移(启动引导) | [src/gateway/server-startup-bootstrap.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-startup-bootstrap.ts) |
| 统一认证面 | [src/gateway/auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/auth.ts) |
| ClientId 注册表 | [packages/gateway-protocol/src/client-info.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/client-info.ts) |
