# 03 — 传输层

> 读完本章你将理解:传输层如何接管网络策略与流式解析,路由分发器如何按 API 类型选择传输流,以及为什么 Provider 实现不直接发请求。

## 一句话定位

传输层是抽象层的第四层,集中处理网络与流式:
- 路由分发器按 API 类型选择对应传输流
- 每个传输流负责一种流式协议的解析(SSE / 事件流 / chunked)
- 统一注入 fetch 守卫、代理、TLS、重试、首事件超时
- Provider 实现只管翻译,网络策略全部集中在此层

## 全局协作图

下图展示传输层内部四个组件的协作,以及它们与上下游的边界。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  Provider 实现层(上游)                              │
│                                                                      │
│   Anthropic 适配器    OpenAI 补全适配器    OpenAI 响应适配器        │
│   (消息翻译)          (补全翻译)          (响应翻译)                │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 翻译后的请求 + 期望的 API 类型
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  传输层                                              │
│                                                                      │
│   ┌──────────────────────────────────────────────────┐              │
│   │  传输路由分发器                                   │              │
│   │                                                  │              │
│   │  • 按 API 类型选择对应传输流                     │              │
│   │  • 不在路由表中的 API → 走 Provider 自有 fetch   │              │
│   │  • 为主机策略端口提供接入点                      │              │
│   └──────────────────────┬───────────────────────────┘              │
│                          │                                           │
│          ┌───────────────┼───────────────┐                          │
│          │               │               │                          │
│          ▼               ▼               ▼                          │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐               │
│   │ Anthropic    │ │ OpenAI 补全  │ │ OpenAI 响应  │               │
│   │ 传输流       │ │ 传输流       │ │ 传输流       │               │
│   │              │ │              │ │              │               │
│   │•SSE 解析     │ │•chunked 解析 │ │•事件流解析   │               │
│   │•载荷策略     │ │•兼容处理     │ │•客户端构造   │               │
│   │•主机策略     │ │•字符串内容   │ │•载荷策略     │               │
│   │•URL 策略     │ │•会话头部     │ │•重放内部     │               │
│   │              │ │              │ │•流式槽位     │               │
│   │              │ │              │ │•流式终端     │               │
│   │              │ │              │ │•流式观察     │               │
│   │              │ │              │ │•Azure 共用   │               │
│   └──────┬───────┘ └──────┬───────┘ └──────┬───────┘               │
│          │                │                │                        │
│          └────────────────┼────────────────┘                        │
│                           │                                           │
│                           ▼                                           │
│   ┌──────────────────────────────────────────────────┐              │
│   │  共享网络策略(横向贯穿所有传输流)               │              │
│   │                                                  │              │
│   │  • fetch 守卫注入(密钥脱敏 / 端点校验)         │              │
│   │  • 代理端点处理                                  │              │
│   │  • TLS 证书错误归一                              │              │
│   │  • 首事件超时守卫                                │              │
│   │  • 字节级流式守卫                                │              │
│   │  • 重试与退避                                    │              │
│   │  • 调试传输 URL 构造                             │              │
│   │  • 模型最大 token 参数                           │              │
│   └──────────────────────────────────────────────────┘              │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  外部 LLM 服务         │
                  │  (各厂商 API 端点)     │
                  └────────────────────────┘
```

## 组件清单

传输层由 4 个核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **传输路由分发器** | 按 API 类型选择对应传输流;不在路由表中的走 Provider 自有 fetch | 路由表覆盖支持的 API 类型;别名映射 |
| **Anthropic 传输流** | 解析 Anthropic SSE 流,注入载荷策略与主机策略 | 载荷策略控制缓存标记;主机策略注入 fetch 守卫 |
| **OpenAI 补全传输流** | 解析 OpenAI 补全 chunked 流,处理兼容性与字符串内容 | 兼容处理多版本补全协议;会话头部注入 |
| **OpenAI 响应传输流** | 解析 OpenAI 响应事件流,含 Azure 变体;管理流式槽位与终端 | 工具调用槽位管理;终端用量归一;流式观察校验 |

## 关联关系

### 路由分发器的路由表

```
   ┌──────────────────────────────────────────────────┐
   │  传输路由分发器                                   │
   │                                                  │
   │  收到请求后,按 API 类型查找路由表:              │
   │                                                  │
   │  ┌─────────────────────┬──────────────────┐     │
   │  │ API 类型             │ 选择的传输流     │     │
   │  ├─────────────────────┼──────────────────┤     │
   │  │ Anthropic 消息      │ Anthropic 传输流 │     │
   │  │ OpenAI 补全         │ OpenAI 补全传输流│     │
   │  │ OpenAI 响应         │ OpenAI 响应传输流│     │
   │  │ Azure OpenAI 响应   │ OpenAI 响应传输流│     │
   │  │ OpenAI ChatGPT 响应 │ OpenAI 响应传输流│     │
   │  │ Google Gemini       │ Google 传输流    │     │
   │  └─────────────────────┴──────────────────┘     │
   │                                                  │
   │  不在路由表中的 API:                             │
   │  → 走 Provider 自有 fetch(不经过传输层)        │
   └──────────────────────────────────────────────────┘
```

### 传输流与共享网络策略的关系

```
   ┌──────────────────────────────────────────────────────────┐
   │  各传输流(Anthropic / OpenAI 补全 / OpenAI 响应)       │
   │                                                          │
   │  各自职责:                                              │
   │  • 解析各自的流式协议(SSE / chunked / 事件流)         │
   │  • 处理各自的载荷策略(缓存标记 / 内容格式)           │
   │  • 处理各自的兼容性(版本差异 / 字段映射)             │
   │                                                          │
   │  共同依赖(横向贯穿):                                   │
   │  ┌────────────────────────────────────────────┐         │
   │  │ 主机策略端口                               │         │
   │  │ → fetch 守卫(密钥脱敏 / 端点校验)        │         │
   │  │ → 代理端点处理                             │         │
   │  └────────────────────────────────────────────┘         │
   │  ┌────────────────────────────────────────────┐         │
   │  │ 流式守卫                                   │         │
   │  │ → 首事件超时(连接后多久没收到第一个事件) │         │
   │  │ → 字节级守卫(畸形分片防护)               │         │
   │  └────────────────────────────────────────────┘         │
   │  ┌────────────────────────────────────────────┐         │
   │  │ TLS 错误归一                               │         │
   │  │ → 证书过期 / 不匹配 / 未知 CA 分类        │         │
   │  └────────────────────────────────────────────┘         │
   │  ┌────────────────────────────────────────────┐         │
   │  │ 重试与退避                                 │         │
   │  │ → 重试后延迟解析                           │         │
   │  │ → 重试休眠                                 │         │
   │  └────────────────────────────────────────────┘         │
   └──────────────────────────────────────────────────────────┘
```

### OpenAI 响应传输流的内部模块

```
   ┌──────────────────────────────────────────────────────────┐
   │  OpenAI 响应传输流                                       │
   │                                                          │
   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
   │  │ 客户端构造   │  │ 载荷策略     │  │ 请求参数     │  │
   │  │ (请求发起)   │  │ (缓存标记)   │  │ (内部)       │  │
   │  └──────────────┘  └──────────────┘  └──────────────┘  │
   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
   │  │ 流式槽位     │  │ 流式终端     │  │ 流式观察     │  │
   │  │ (工具调用    │  │ (用量归一)   │  │ (一致性校验) │  │
   │  │  增量管理)   │  │              │  │              │  │
   │  └──────────────┘  └──────────────┘  └──────────────┘  │
   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
   │  │ 重放内部     │  │ 调试         │  │ 契约定义     │  │
   │  │ (请求重放)   │  │              │  │              │  │
   │  └──────────────┘  └──────────────┘  └──────────────┘  │
   │                                                          │
   │  Azure 变体:                                            │
   │  → 共用客户端构造与载荷策略                              │
   │  → 注入 Azure 部署名与端点映射                           │
   └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 一次流式请求的传输层旅程

下面追踪一个 Anthropic 请求从适配器到达传输层,到流式返回的全过程。

```
Anthropic 适配器完成消息翻译
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 路由分发                                                   │
│    → 路由分发器收到 API 类型 = Anthropic 消息                │
│    → 查路由表 → 选择 Anthropic 传输流                        │
│    → 若 API 不在路由表 → 走 Provider 自有 fetch              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 主机策略注入                                               │
│    → 从主机策略端口获取 fetch 守卫                           │
│    → 守卫包装原始 fetch:                                     │
│      • 密钥脱敏(日志中不出现 API Key)                      │
│      • 端点校验(拦截非法请求目标)                          │
│      • 代理注入(企业内网代理)                              │
│    → 诊断日志记录请求(脱敏后)                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 载荷策略应用                                               │
│    → Anthropic 载荷策略器处理缓存控制标记                   │
│    → 系统提示缓存边界标记注入                                │
│    → 确定性排序保证缓存友好                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 请求发送与超时守卫                                         │
│    → 请求发出(带总超时)                                    │
│    → 首事件超时守卫启动:连接后多久没收到第一个事件则超时    │
│    → TLS 错误归一器待命(若 TLS 握手失败)                   │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. SSE 流解析                                                │
│    → 字节级守卫:防止畸形分片导致解析错误                    │
│    → SSE 解析器逐行解析事件流                                │
│    → 每个事件解析为结构化数据                                │
│    → 重试后延迟解析器处理(若中途重试)                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 事件推入管道                                               │
│    → 解析后的事件推入事件流管道                              │
│    → 背压处理:消费慢时缓冲                                  │
│    → 流结束时发送终态事件                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  事件流管道交给 Provider 适配器
                  (适配器翻译为统一事件)
```

### 传输层处理 TLS 证书错误

```
请求发出 → TLS 握手
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ TLS 握手成功?                                        │
└────────────────────────────┬─────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼ 是                          ▼ 否
     [继续流式接收]              ┌──────────────────────┐
                                 │ TLS 错误归一器       │
                                 │                      │
                                 │ 分类错误类型:       │
                                 │ • 证书过期           │
                                 │ • 证书不匹配         │
                                 │ • 未知 CA            │
                                 │ • 自签证书           │
                                 │                      │
                                 │ 生成诊断信息:       │
                                 │ • 错误类型           │
                                 │ • 受影响端点         │
                                 │ • 建议操作           │
                                 └──────────┬───────────┘
                                            │
                                            ▼
                                 ┌──────────────────────┐
                                 │ 错误事件入管道       │
                                 │ (调用方可区分       │
                                 │  网络错误 vs 证书    │
                                 │  错误)              │
                                 └──────────────────────┘
```

### OpenAI 响应传输流的工具调用槽位管理

```
OpenAI 响应流开始(带工具调用)
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 收到工具调用开始事件                               │
│    → 分配流式槽位                                    │
│    → 槽位记录:工具名、调用 ID、初始状态              │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 收到工具参数增量(可能多次)                       │
│    → 累积到对应槽位                                  │
│    → 字节级守卫防止畸形增量                          │
│    → 流式观察器校验槽位状态一致性                    │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 收到工具调用结束事件                               │
│    → 封装槽位为完整工具调用                          │
│    → 推入事件流管道                                  │
│    → 释放槽位                                        │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 流结束时终端用量归一                               │
│    → 流式终端模块收集延迟到达的用量信息              │
│    → 归一为统一用量事件                              │
│    → 流式观察器对比流中累积用量与终端用量            │
│    → 不一致时发出警告事件                            │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 路由分发器是传输层唯一入口

- **为什么**:Provider 适配器不应自己选择传输流;集中路由确保所有请求经过统一的网络策略
- **怎么做**:路由分发器维护 API 类型到传输流的映射表;不在表中的走 Provider 自有 fetch(向后兼容)
- **影响**:新增 API 类型只需加路由表条目;网络策略变更只改传输层

### 2. 网络策略横向贯穿所有传输流

- **为什么**:fetch 守卫、代理、TLS、超时等策略对所有厂商都一样;散落到各传输流会重复且不一致
- **怎么做**:共享网络策略模块被所有传输流依赖;主机策略端口统一注入
- **影响**:策略变更一处生效,所有传输流同步;新传输流自动获得策略

### 3. 首事件超时与总超时分离

- **为什么**:连接建立但服务端迟迟不发第一个事件,与总请求超时是不同的故障模式;混合超时无法区分
- **怎么做**:首事件超时守卫独立于总超时;连接后 N 秒没收到第一个事件则触发首事件超时
- **影响**:能区分"连不上"与"连上了但不响应";便于排查厂商端问题

### 4. 字节级流式守卫防止畸形分片

- **为什么**:流式传输中,一个逻辑事件可能跨多个 TCP 分片;直接按行解析可能遇到半行导致解析错误
- **怎么做**:字节级守卫缓冲不完整的分片;确保解析器只处理完整的事件边界
- **影响**:网络抖动不会导致解析错误;流式接收更健壮

### 5. Azure 与 OpenAI 响应共用传输流

- **为什么**:Azure OpenAI 响应 API 与 OpenAI 响应 API 协议几乎相同;只是端点与认证不同
- **怎么做**:Azure 传输流复用 OpenAI 响应传输流的客户端构造与载荷策略;注入 Azure 部署名与端点映射
- **影响**:翻译逻辑单一来源;Azure 特有逻辑最小化;协议变更同步生效

### 6. 载荷策略与缓存控制

- **为什么**:prompt cache 命中要求请求体确定性;缓存标记位置与顺序影响 cache key
- **怎么做**:载荷策略器统一控制缓存标记注入位置;系统提示缓存边界标记确定性注入
- **影响**:相同输入产生相同请求体;cache 命中率提升;减少 token 消耗与延迟

## 设计观察

### 为什么传输层与 Provider 实现分离

```
错误设计:
   Provider 适配器内部直接 fetch + 解析流
   → 每个厂商各自处理代理 / TLS / 超时
   → 策略不一致,维护成本高
   → 修改网络策略要改每个适配器

正确设计:
   Provider 适配器只翻译
   传输层集中处理网络与流式
   → 网络策略统一
   → 适配器只管翻译,职责单一
   → 新增适配器自动获得网络策略
```

### 为什么不在路由表中的 API 走自有 fetch

```
严格路由设计:
   所有 API 必须经过传输层
   → 新增 API 类型必须先建传输流
   → 第三方插件 Provider 无法工作
   → 灵活性差

兼容路由设计:
   路由表覆盖内置 API
   不在表中的 → 走 Provider 自有 fetch
   → 内置 API 获得传输层策略
   → 插件 Provider 不强制接入传输层
   → 向后兼容,渐进迁移
```

### 为什么 OpenAI 响应传输流有流式观察器

```
无观察器设计:
   流式事件直接推入管道
   → 工具调用增量丢失无法发现
   → 终端用量与流中累积用量不一致无法发现
   → 用户看到的用量与实际不符

有观察器设计:
   流式观察器校验事件序列完整性
   → 工具调用槽位状态一致性检查
   → 终端用量与累积用量对比
   → 异常时发出警告事件
   → 用户能看到数据不一致的警告
```

## 章节索引

| 文件 | 主题 |
|---|---|
| 00-overview.md | Provider 抽象层总览 |
| 01-provider-core.md | Provider 核心:注册表 / 主机策略 / 密钥 / 选项 / 资源 / 流 / 类型 / 校验 |
| 02-provider-implementations.md | Provider 实现:9 个厂商适配器 |
| 03-transports.md | 本文件 — 传输层:流式解析 / fetch 守卫 / 路由分发 |
| 04-utils-internal.md | 工具与内部:溢出 / 缓存 / 错误 / OAuth / 内部适配器 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 传输路由分发器 | [packages/ai/src/transports/provider-transport-stream.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/provider-transport-stream.ts) |
| Anthropic 传输流 | [packages/ai/src/transports/anthropic-transport-stream.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/anthropic-transport-stream.ts) |
| Anthropic 载荷策略 | [packages/ai/src/transports/anthropic-payload-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/anthropic-payload-policy.ts) |
| OpenAI 补全传输流 | [packages/ai/src/transports/openai-completions-transport.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-completions-transport.ts) |
| OpenAI 补全兼容 | [packages/ai/src/transports/openai-completions-compat.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-completions-compat.ts) |
| OpenAI 补全字符串内容 | [packages/ai/src/transports/openai-completions-string-content.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-completions-string-content.ts) |
| OpenAI 响应传输流 | [packages/ai/src/transports/openai-responses-transport.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-transport.ts) |
| OpenAI 响应客户端 | [packages/ai/src/transports/openai-responses-client.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-client.ts) |
| OpenAI 响应契约 | [packages/ai/src/transports/openai-responses-contracts.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-contracts.ts) |
| OpenAI 响应载荷策略 | [packages/ai/src/transports/openai-responses-payload-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-payload-policy.ts) |
| OpenAI 响应参数内部 | [packages/ai/src/transports/openai-responses-params-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-params-internal.ts) |
| OpenAI 响应重放内部 | [packages/ai/src/transports/openai-responses-replay-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-replay-internal.ts) |
| OpenAI 响应重放 | [packages/ai/src/transports/openai-responses-replay.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-replay.ts) |
| OpenAI 响应流式内部 | [packages/ai/src/transports/openai-responses-stream-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-stream-internal.ts) |
| OpenAI 响应流式观察内部 | [packages/ai/src/transports/openai-responses-stream-observer-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-stream-observer-internal.ts) |
| OpenAI 响应流式槽位内部 | [packages/ai/src/transports/openai-responses-stream-slots-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-stream-slots-internal.ts) |
| OpenAI 响应流式终端内部 | [packages/ai/src/transports/openai-responses-stream-terminal-internal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-stream-terminal-internal.ts) |
| OpenAI 响应调试 | [packages/ai/src/transports/openai-responses-debug.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-responses-debug.ts) |
| OpenAI 传输参数 | [packages/ai/src/transports/openai-transport-params.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-transport-params.ts) |
| OpenAI 传输共享 | [packages/ai/src/transports/openai-transport-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-transport-shared.ts) |
| OpenAI 兼容对话轮次 | [packages/ai/src/transports/openai-compatible-conversation-turn.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-compatible-conversation-turn.ts) |
| OpenAI 推理兼容 | [packages/ai/src/transports/openai-reasoning-compat.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/openai-reasoning-compat.ts) |
| 主机策略 | [packages/ai/src/transports/host-policy.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/host-policy.ts) |
| 传输流共享 | [packages/ai/src/transports/transport-stream-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/transport-stream-shared.ts) |
| 传输工具 | [packages/ai/src/transports/transport-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/transport-utils.ts) |
| 模型传输调试 | [packages/ai/src/transports/model-transport-debug.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/model-transport-debug.ts) |
| 模型传输 URL | [packages/ai/src/transports/model-transport-url.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/model-transport-url.ts) |
| 模型最大 token 参数 | [packages/ai/src/transports/model-max-tokens-params.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/model-max-tokens-params.ts) |
| DeepSeek 文本过滤 | [packages/ai/src/transports/deepseek-text-filter.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/deepseek-text-filter.ts) |
| JSON 不安全整数 | [packages/ai/src/transports/json-unsafe-integers.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/json-unsafe-integers.ts) |
| 响应图像载荷清理 | [packages/ai/src/transports/responses-image-payload-sanitizer.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/responses-image-payload-sanitizer.ts) |
| 简单补全传输 | [packages/ai/src/transports/simple-completion-transport.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/transports/simple-completion-transport.ts) |
