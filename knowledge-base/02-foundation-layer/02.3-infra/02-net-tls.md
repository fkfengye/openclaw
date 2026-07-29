# 02 — 网络 / TLS

> 读完本章你将理解:OpenClaw 如何发起受保护的外部请求、代理与 SSRF 如何协作、TLS 证书如何指纹校验,以及失败重试与 WebSocket 如何处理。

## 一句话定位

这一层是基础设施的第二层,负责所有出站网络原语:
- fetch、WebSocket、表单数据、主机名解析
- 代理环境(代理生命周期、托管代理、TLS 代理)
- SSRF 防护(默认拒绝内网/保留地址段)
- TLS 证书指纹与 Gateway TLS 上下文
- 重试策略、退避、Retry-After 头部
- 依赖分层 1(文件系统/路径)提供证书与缓存的本地落点

## 全局协作图

下图展示网络/TLS 层内部组件如何协作,以及与上下游的关系。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       上层消费者                                     │
│   Provider 调用 LLM    插件 webhook    更新检查    节点通信          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 发起外部请求 / 建立 WS
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       分层 2:网络 / TLS                             │
│                                                                      │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 请求入口         │  │ SSRF 守卫          │  │ 代理环境        │  │
│   │ (fetch 入口)    │──►│ (内网/保留段拒绝) │  │                 │  │
│   │                  │  │                   │  │ • 环境变量      │  │
│   │ • 表单数据       │  │ • 重定向 pinning  │  │ • 生命周期管理  │  │
│   │ • 主机名解析     │  │ • 守卫体流        │  │ • 托管代理      │  │
│   │ • 头部处理       │  │                   │  │ • TLS 代理      │  │
│   └─────────┬────────┘  └─────────┬─────────┘  └────────┬────────┘  │
│             │                     │                      │          │
│             └─────────────────────┼──────────────────────┘          │
│                                   │                                  │
│                                   ▼                                  │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  TLS 子层                                                    │  │
│   │                                                              │  │
│   │  • 证书指纹比对(可选 pinning)                              │  │
│   │  • Gateway TLS 上下文(服务端证书 + mTLS)                   │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                   │                                  │
│                                   ▼                                  │
│   ┌───────────────────┐  ┌───────────────────┐  ┌─────────────────┐  │
│   │ 重试策略          │  │ WebSocket         │  │ HTTP 体处理     │  │
│   │                   │  │                   │  │                 │  │
│   │ • 退避            │  │ • 连接管理        │  │ • 响应体        │  │
│   │ • Retry-After     │  │ • 协议升级        │  │ • 错误体         │  │
│   │ • 可重试错误判定  │  │                   │  │ • 超时体         │  │
│   └───────────────────┘  └───────────────────┘  └─────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────┐
                  │  分层 1:文件系统    │
                  │  (证书/缓存落点)    │
                  └──────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **请求入口** | fetch 入口、表单数据、主机名解析、头部处理 | 所有外部请求统一入口,无旁路 |
| **SSRF 守卫** | 内网/保留地址段拒绝、重定向 pinning、守卫体流 | 默认拒绝;代理与 SSRF 互不绕过;重定向重检 |
| **代理环境** | 代理环境变量、生命周期管理、托管代理、TLS 代理 | 代理与 SSRF 校验叠加;TLS 代理单独处理 |
| **TLS 子层** | 证书指纹比对、Gateway TLS 上下文 | 可选 pinning;Gateway 服务端证书与 mTLS |
| **重试策略** | 退避、Retry-After 头部、可重试错误判定 | Retry-After 有下限;不可重试错误立即失败 |
| **WebSocket** | 连接管理、协议升级 | 与 fetch 共享代理/SSRF 守卫 |
| **HTTP 体处理** | 响应体、错误体、超时体 | 错误体归一,不泄漏原始字节 |

## 关联关系

### 一次请求中守卫的串联顺序

```
   上层发起请求
        │
        ▼
   ┌──────────────────┐
   │ 请求入口         │ ── 解析主机名 / 拼表单
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ SSRF 守卫         │ ── 目标地址在保留段?── 拒绝
   │                  │ ── 本地源绕过?
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ 代理环境         │ ── 读取代理配置 ── 无代理直连 / 走代理
   │                  │ ── 代理 TLS 处理
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ TLS 子层         │ ── 证书指纹比对(若开启)
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ 网络发送         │ ── 实际 fetch
   └────────┬─────────┘
            │
            ▼
   失败?─ 是 ──► 重试策略 ──► 退避 + Retry-After ──► 重试
        │
        否
        ▼
   成功响应 ──► HTTP 体处理 ──► 上层
```

### 代理与 SSRF 不能互相绕过

```
错误设计:
   配置了代理后,SSRF 校验被跳过
   "反正是代理去访问,与我本地无关"
   → 恶意目标经代理回连内网

正确设计:
   ┌──────────────┐    ┌──────────────┐
   │ SSRF 守卫    │    │ 代理环境     │
   │ (始终校验)   │    │ (始终生效)   │
   └──────┬───────┘    └──────┬───────┘
          └────────┬───────────┘
                   ▼
            两者叠加,无旁路
   代理也校验目标;直连也校验目标
```

### 重定向时 SSRF 必须重新 pinning

```
错误设计:
   首次 SSRF 校验通过 → 后续重定向直接跟随
   → 重定向到内网地址(127.0.0.1)→ SSRF 绕过

正确设计:
   每次重定向都重新校验目标
   重定向 pinning:目标主机不得漂移到内网段
```

## 协作流程

### 一次受保护的外部 fetch 全过程

```
上层请求:获取外部 URL
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 请求入口                                                   │
│    → 解析主机名(防主机名混淆攻击)                           │
│    → 拼装表单数据(若需)                                     │
│    → 处理头部                                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. SSRF 守卫                                                  │
│    → 解析目标 IP                                              │
│    → 校验是否落在内网/保留段                                  │
│    → 配置本地源绕过(可选,仅可信来源)                       │
│    → 失败则拒绝,不进入下一步                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 代理环境                                                    │
│    → 读取代理环境变量                                         │
│    → 若有代理:走代理(代理本身也校验目标)                   │
│    → 若无代理:直连                                          │
│    → 代理 TLS 处理(若代理为 HTTPS)                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. TLS 子层                                                   │
│    → 若开启证书 pinning:比对证书指纹                         │
│    → 建立 TLS 上下文                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 网络发送                                                   │
│    → 实际发起 fetch                                           │
│    → 流式接收响应                                             │
│    → 重定向时回到步骤 2 重新校验                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 失败处理(若失败)                                         │
│    → 判定是否可重试错误                                       │
│    → 读取 Retry-After 头部(若服务端给)                      │
│    → 按退避策略等待                                           │
│    → 重试上限耗尽则归一化错误体返回上层                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  HTTP 体处理 → 上层获得响应
```

### Gateway 服务端 TLS 上下文建立

```
Gateway 启动
     │
     ▼
┌──────────────────────────────────────────────────────┐
│ 1. 读取证书配置                                      │
│    → 证书路径(走分层 1 归一)                       │
│    → 私钥路径                                        │
│    → CA 路径(若需 mTLS)                            │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. TLS 子层                                          │
│    → 建立 Gateway TLS 上下文                         │
│    → 服务端证书绑定                                  │
│    → mTLS 客户端校验(若开启)                       │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 监听端口                                          │
│    → HTTPS 服务就绪                                  │
│    → 客户端握手时校验                                │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. SSRF 默认拒绝内网

- **为什么**:防止恶意 URL 让 Gateway 回连内网服务(云元数据、内部 API)
- **怎么做**:校验目标 IP 是否落在 RFC 保留段(127/8、10/8、172.16/12、192.168/16、169.254/16、::1 等);本地源绕过需显式可信来源
- **影响**:任何外部请求都受保护,无 SSRF 旁路

### 2. 代理与 SSRF 互不绕过

- **为什么**:配置代理后若跳过 SSRF,恶意目标可经代理回连内网
- **怎么做**:代理路径与直连路径都经过 SSRF 守卫;代理本身的目标也校验
- **影响**:即使运维误配代理,SSRF 仍生效

### 3. 重定向重新 pinning

- **为什么**:首次校验通过后,服务端 302 重定向到内网即可绕过 SSRF
- **怎么做**:每次重定向重新解析并校验目标;主机名不得漂移到保留段
- **影响**:重定向攻击无效

### 4. Retry-After 有下限

- **为什么**:服务端可能返回极小的 Retry-After(如 0)导致重试风暴,或极大值导致永久等待
- **怎么做**:Retry-After 取值有上下限钳制;退避策略独立于服务端建议
- **影响**:重试行为可预测,不因恶意服务端失控

### 5. 可重试错误显式判定

- **为什么**:并非所有错误都该重试(4xx 客户端错误重试无意义且浪费配额)
- **怎么做**:维护可重试网络错误清单;连接错误/超时/5xx 可重试;4xx 立即失败
- **影响**:重试只发生在真正可能成功的场景

### 6. 错误体不泄漏原始字节

- **为什么**:原始响应体可能含敏感信息或大体积数据
- **怎么做**:错误体归一化为结构化对象,只保留必要诊断字段
- **影响**:日志与上层处理不泄漏原始响应

## 设计观察

### 为什么 SSRF 校验放在统一入口而非各处

```
错误设计:
   Provider 调 LLM 时自己校验 URL
   插件 webhook 时自己校验 URL
   更新检查时自己校验 URL
   → 规则散落,易漏易不一致

正确设计:
   所有外部请求走统一请求入口
   统一入口串接 SSRF 守卫
   → 规则集中,新功能天然受保护
```

### 为什么 TLS pinning 是可选而非默认

```
错误设计:
   默认对所有外部请求 pinning 证书
   → 上游证书轮换立即故障

正确设计:
   pinning 仅对可信固定端点开启
   普通 HTTPS 走标准 CA 校验
   → 安全性与可用性平衡
```

### 为什么 WebSocket 与 fetch 共享守卫

```
错误设计:
   WebSocket 自己实现代理/SSRF
   → 与 fetch 规则不一致,出现旁路

正确设计:
   WebSocket 升级前复用 fetch 的 SSRF/代理守卫
   → 一套规则覆盖所有出站连接
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) | 基础设施总览 |
| [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) | 文件系统 / 路径 / 环境 |
| [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) | 本文件 — 网络 / TLS |
| [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) | 执行 / 进程 |
| [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) | 平台特定 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。网络相关源码集中在 `src/infra/net/` 与 `src/infra/tls/` 下。

| 组件 | 源码位置 |
|---|---|
| 请求入口/fetch | [src/infra/fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fetch.ts) |
| 运行时 fetch | [src/infra/net/runtime-fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/runtime-fetch.ts) |
| fetch 头部 | [src/infra/fetch-headers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fetch-headers.ts) |
| 表单数据 | [src/infra/net/form-data.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/form-data.ts) |
| 主机名解析 | [src/infra/net/hostname.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/hostname.ts) |
| SSRF 守卫 | [src/infra/net/ssrf.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/ssrf.ts) |
| SSRF 守卫体流 | [src/infra/net/guarded-body-stream.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/guarded-body-stream.ts) |
| SSRF fetch guard | [src/infra/net/fetch-guard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/fetch-guard.ts) |
| 本地源绕过 | [src/infra/net/configured-local-origin-bypass.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/configured-local-origin-bypass.ts) |
| 重定向头部 | [src/infra/net/redirect-headers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/redirect-headers.ts) |
| 代理环境 | [src/infra/net/proxy-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy-env.ts) |
| 代理 fetch | [src/infra/net/proxy-fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy-fetch.ts) |
| 代理生命周期 | [src/infra/net/proxy/proxy-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/proxy-lifecycle.ts) |
| 托管代理 undici | [src/infra/net/proxy/managed-proxy-undici.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/managed-proxy-undici.ts) |
| 代理 TLS | [src/infra/net/proxy/proxy-tls.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/proxy-tls.ts) |
| 代理校验 | [src/infra/net/proxy/proxy-validation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/proxy-validation.ts) |
| 代理活跃状态 | [src/infra/net/proxy/active-proxy-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/proxy/active-proxy-state.ts) |
| 节点代理 agent | [src/infra/net/node-proxy-agent.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/node-proxy-agent.ts) |
| undici 全局 dispatcher | [src/infra/net/undici-global-dispatcher.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/undici-global-dispatcher.ts) |
| undici 运行时 | [src/infra/net/undici-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/undici-runtime.ts) |
| undici 选项 | [src/infra/net/undici-dispatcher-options.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/undici-dispatcher-options.ts) |
| undici 错误诊断 | [src/infra/net/undici-error-diagnostics.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/undici-error-diagnostics.ts) |
| undici family 策略 | [src/infra/net/undici-family-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/net/undici-family-policy.ts) |
| TLS 证书指纹 | [src/infra/tls/fingerprint.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/tls/fingerprint.ts) |
| Gateway TLS 上下文 | [src/infra/tls/gateway.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/tls/gateway.ts) |
| 重试策略 | [src/infra/retry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/retry.ts) |
| 重试策略详情 | [src/infra/retry-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/retry-policy.ts) |
| Retry-After | [src/infra/retry-after.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/retry-after.ts) |
| 重试错误集 | [src/infra/retry-attempt-errors.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/retry-attempt-errors.ts) |
| 可重试网络错误 | [src/infra/retryable-network-errors.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/retryable-network-errors.ts) |
| WebSocket | [src/infra/ws.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/ws.ts) |
| HTTP 响应体 | [src/infra/http-body.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/http-body.ts) |
| HTTP 错误体 | [src/infra/http-error-body.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/http-error-body.ts) |
| HTTP 超时体 | [src/infra/http-response-body-timeout.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/http-response-body-timeout.ts) |
