# 02 — Provider 实现

> 读完本章你将理解:9 个厂商适配器各自的职责与特点,为什么 Cloudflare 只做元数据,Copilot 只做头部注入,以及各适配器如何共用传输层而不重复网络策略。

## 一句话定位

Provider 实现层是抽象层的第三层,逐厂商翻译:
- 每个适配器把统一消息格式翻译成厂商请求体
- 每个适配器把厂商响应事件翻译成统一事件
- 不直接发请求,网络策略交给传输层
- 惰性注册,首次调用才加载厂商 SDK

## 全局协作图

下图展示 9 个适配器如何挂载到 API 注册表,以及它们与传输层的分工。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       API 注册表(来自 Provider 核心)               │
│                                                                      │
│   按 API 类型分发到对应适配器(惰性加载)                            │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
        ┌──────────┬───────────┼───────────┬──────────┐
        │          │           │           │          │
        ▼          ▼           ▼           ▼          ▼
┌──────────┐┌──────────┐┌──────────┐┌──────────┐┌──────────┐
│ Anthropic││  OpenAI  ││  OpenAI  ││  Azure   ││  Google  │
│ 消息流   ││  补全流  ││  响应流  ││  响应流  ││  Gemini  │
│          ││          ││          ││          ││          │
│•消息翻译 ││•补全翻译 ││•响应翻译 ││•Azure 部 ││•Gemini翻 │
│•工具投影 ││•工具投影 ││•工具追踪 ││  署映射  ││  译      │
│•思考重放 ││•停止原因 ││•用量终端 ││•客户端兼 ││•图像清理 │
│•用量解析 ││•兼容处理 ││•流式校验 ││  容      ││          │
│•拒绝处理 ││          ││          ││          ││          │
└────┬─────┘└────┬─────┘└────┬─────┘└────┬─────┘└────┬─────┘
     │           │           │           │           │
     ▼           ▼           ▼           ▼           ▼
┌──────────┐┌──────────┐┌──────────┐┌──────────┐
│  Vertex  ││ Mistral  ││Cloudflare││ Copilot  │
│ Google企 ││ 对话流   ││ 元数据   ││ 头部注入 │
│          ││          ││          ││          │
│•企业认证 ││•对话翻译 ││•URL 占位 ││•发起者推 │
│•共享翻译 ││•有界流   ││  符替换  ││  断      │
│          ││          ││•厂商判断 ││•视觉头部 │
│          ││          ││•不直接   ││•意图头部 │
│          ││          ││  fetch   ││          │
└────┬─────┘└────┬─────┘└──────────┘└──────────┘
     │           │
     └─────┬─────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       传输层(第四层)                                │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐                       │
│   │ Anthropic 传输流  │  │ OpenAI 补全传输   │                       │
│   │ (SSE 解析)        │  │ (chunked 解析)   │                       │
│   └──────────────────┘  └──────────────────┘                       │
│   ┌──────────────────┐  ┌──────────────────┐                       │
│   │ OpenAI 响应传输   │  │ 传输路由分发器    │                       │
│   │ (事件流解析)      │  │ (按 API 选传输)  │                       │
│   └──────────────────┘  └──────────────────┘                       │
│                                                                      │
│   接管:fetch 守卫 / 代理 / TLS / 重试 / 首事件超时                  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  外部 LLM 服务         │
                  │  (各厂商 API 端点)     │
                  └────────────────────────┘
```

## 组件清单

9 个适配器分三类:完整流式适配器、共享翻译适配器、辅助适配器。

| 适配器 | 职责 | 关键约束 |
|---|---|---|
| **Anthropic 消息流** | 翻译 Anthropic 消息 API,处理思考重放、工具投影、用量解析、拒绝处理 | 思考级别钳制;服务器降级回退;内联图像预算 |
| **OpenAI 补全流** | 翻译 OpenAI 聊天补全 API,处理停止原因与兼容性 | 工具投影;模式兼容;字符串内容处理 |
| **OpenAI 响应流** | 翻译 OpenAI 响应 API,处理工具调用追踪与终端用量 | 工具调用追踪器;流式槽位管理;终端用量归一 |
| **Azure OpenAI 响应流** | 翻译 Azure 托管的 OpenAI 响应 API | 部署名映射;客户端兼容性适配 |
| **Google Gemini** | 翻译 Google Generative AI(Gemini) | 图像输入清理;客户端认证;并行图像处理 |
| **Google Vertex** | 翻译 Google Vertex AI(企业版) | 共享 Gemini 翻译逻辑;企业认证流程 |
| **Mistral 对话流** | 翻译 Mistral 对话 API | 有界流处理;对话格式翻译 |
| **Cloudflare 元数据** | 提供 Cloudflare 托管模型的 URL 元数据 | 只做 URL 占位符替换;不直接 fetch;由其他适配器注入守卫 |
| **GitHub Copilot 头部** | 构建 Copilot 请求头部 | 发起者推断;视觉意图头部;不独立成流 |

## 关联关系

### 完整流式适配器的共同结构

```
   ┌──────────────────────────────────────────────────────────┐
   │  完整流式适配器(Anthropic / OpenAI / Google / Mistral) │
   │                                                          │
   │  共同职责:                                              │
   │  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
   │  │ 消息翻译   │  │ 工具投影   │  │ 用量解析   │        │
   │  │ 统一→厂商  │  │ 统一→厂商  │  │ 厂商→统一  │        │
   │  └────────────┘  └────────────┘  └────────────┘        │
   │  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
   │  │ 停止原因   │  │ 流式事件   │  │ 错误处理   │        │
   │  │ 厂商→统一  │  │ 厂商→统一  │  │ 厂商→统一  │        │
   │  └────────────┘  └────────────┘  └────────────┘        │
   │                                                          │
   │  共同不做:                                              │
   │  · 不直接 fetch(交传输层)                             │
   │  · 不处理代理 / TLS                                    │
   │  · 不处理重试 / 超时                                    │
   └──────────────────────────────────────────────────────────┘
```

### 辅助适配器与完整适配器的协作

```
   ┌──────────────────┐
   │ Cloudflare 元数据 │
   │                  │
   │ 只提供 URL 解析  │
   │ 不提供流式函数   │
   └────────┬─────────┘
            │
            │ URL 解析后
            ▼
   ┌──────────────────────────────────────────┐
   │ Anthropic 或 OpenAI 适配器               │
   │                                          │
   │ 用 Cloudflare 的 URL + 注入的 fetch 守卫 │
   │ → 构造请求 → 流式返回                    │
   └──────────────────────────────────────────┘

   ┌──────────────────┐
   │ Copilot 头部注入  │
   │                  │
   │ 只构建请求头部   │
   │ 不提供流式函数   │
   └────────┬─────────┘
            │
            │ 头部注入后
            ▼
   ┌──────────────────────────────────────────┐
   │ OpenAI 适配器                            │
   │                                          │
   │ 用 Copilot 头部 + OpenAI 翻译逻辑       │
   │ → 构造请求 → 流式返回                    │
   └──────────────────────────────────────────┘
```

### Google 与 Vertex 的共享翻译

```
   ┌──────────────────┐         ┌──────────────────┐
   │ Google Gemini    │         │ Google Vertex    │
   │ 适配器            │         │ 适配器            │
   │                  │         │                  │
   │ • 公共认证       │         │ • 企业认证       │
   │ • Gemini 翻译    │◄──共享──►│ • 共享翻译逻辑  │
   │ • 图像清理       │   翻译  │ • 部署端点不同  │
   └──────────────────┘   逻辑  └──────────────────┘

   为什么共享:
   • Vertex 本质是 Gemini 的企业托管版
   • 翻译逻辑完全相同,只是认证与端点不同
   • 共享避免重复,维护统一
```

## 协作流程

### Anthropic 适配器处理一次请求

下面追踪 Anthropic 适配器从接收统一消息到流式返回的全过程。

```
统一消息到达 Anthropic 适配器
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 消息翻译                                                  │
│    → 统一消息格式翻译为 Anthropic 消息参数                   │
│    → 内联图像预算计算(控制图像大小与数量)                  │
│    → 图像媒体类型解析                                        │
│    → 内容块归一化                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 选项应用                                                  │
│    → 思考级别钳制(限制推理深度)                            │
│    → 缓存保留策略应用                                        │
│    → 服务层级选择(若支持)                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 工具投影                                                  │
│    → 统一工具定义投影为 Anthropic 工具格式                   │
│    → 工具参数模式转换                                        │
│    → 缓存控制标记注入                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 请求发送(交传输层)                                      │
│    → 传输层注入 fetch 守卫与代理策略                        │
│    → 请求发出(带首事件超时守卫)                            │
│    → 服务器降级回退(若主端点失败,尝试备用端点)            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 流式事件翻译                                              │
│    → Anthropic 原始事件 → 统一事件                           │
│    • 文本块 → 文本事件                                       │
│    • 思考块 → 思考事件(支持重放)                           │
│    • 工具调用 → 工具事件                                     │
│    • 用量 → 用量事件                                         │
│    • 结束 → 终态事件(含停止原因)                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 用量与拒绝处理                                            │
│    → 用量解析器把 Anthropic 用量翻译为统一用量               │
│    → 拒绝检测(若模型拒绝请求,标记拒绝原因)               │
│    → 推入事件流管道                                          │
└──────────────────────────────────────────────────────────────┘
```

### OpenAI 响应适配器的工具调用追踪

```
OpenAI 响应流开始
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 初始化工具调用追踪器                              │
│    → 追踪器记录工具调用的增量状态                    │
│    → 槽位管理:每个工具调用占一个槽位                │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 流式接收(循环)                                  │
│    → 收到工具调用开始事件 → 分配槽位                 │
│    → 收到工具参数增量 → 累积到对应槽位               │
│    → 收到工具调用结束 → 封装为统一工具事件           │
│    → 收到文本增量 → 累积到文本事件                   │
│    → 收到推理增量 → 累积到思考事件                   │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 终端用量归一                                      │
│    → 响应流的用量信息在流结束时才到达                 │
│    → 终端用量归一器把延迟到达的用量归入终态          │
│    → 流式校验:对比流中累积的用量与终端用量          │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 流式一致性校验                                    │
│    → 流式校验器检查事件序列的完整性                   │
│    → 确保工具调用、文本、用量无遗漏                   │
│    → 异常时发出错误事件                               │
└──────────────────────────────────────────────────────┘
```

### Cloudflare 元数据适配器的协作

```
模型配置指向 Cloudflare 端点
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. Cloudflare 适配器介入                              │
│    → 判断 Provider 是否为 Cloudflare 系列             │
│    → 解析 baseUrl 中的占位符                          │
│    • 从进程环境变量替换 {VAR} 占位符                  │
│    • 缺失变量 → 抛出明确错误                          │
│    → 返回解析后的 URL                                 │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 选择实际流式适配器                                 │
│    → Cloudflare 模型底层用 Anthropic 或 OpenAI 协议   │
│    → 对应适配器接管翻译                               │
│    → 注入 Cloudflare 的 URL 与 fetch 守卫             │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 请求发送与流式返回                                 │
│    → 实际适配器构造请求体                             │
│    → 传输层注入网络策略                               │
│    → 流式返回走对应传输流                             │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 适配器只翻译不引入新契约

- **为什么**:契约由核心契约层统一定义;适配器引入新类型会破坏统一性,导致调用方需要按厂商写不同代码
- **怎么做**:适配器的输入输出严格使用统一类型;厂商特有概念在适配器内部吸收,不泄漏到接口
- **影响**:Agent Runner 不需要知道用的是哪个厂商;切换厂商不改调用方代码

### 2. 辅助适配器不独立成流

- **为什么**:Cloudflare 底层用 Anthropic / OpenAI 协议,Copilot 底层用 OpenAI 协议;独立实现会重复翻译逻辑
- **怎么做**:Cloudflare 只提供 URL 元数据;Copilot 只提供头部注入;实际流式由对应完整适配器接管
- **影响**:翻译逻辑单一来源;辅助适配器职责清晰;不重复网络策略

### 3. 思考重放保证一致性

- **为什么**:Anthropic 的思考过程可能在流式与终端之间有差异;若不重放,后续轮次的上下文会不一致
- **怎么做**:思考重放器记录流式中的思考块;在终端时确保思考内容与流式一致;支持回放给后续请求
- **影响**:多轮对话中思考上下文一致;避免"思考丢失"导致的模型行为漂移

### 4. 工具投影按厂商格式化

- **为什么**:各厂商的工具定义格式不同(Anthropic 与 OpenAI 的工具参数字段名与结构各异);统一格式需投影
- **怎么做**:每个适配器有工具投影器,把统一工具定义翻译为厂商格式;处理参数模式转换
- **影响**:Agent Runner 用统一工具定义;适配器自动翻译;新增工具不改适配器

### 5. 服务器降级回退

- **为什么**:Anthropic 等厂商可能有主端点与备用端点;主端点偶发故障时需要自动回退
- **怎么做**:服务器降级回退器在主端点失败时尝试备用端点;回退策略封装在适配器内部
- **影响**:提升可用性;调用方无感知;回退失败才报错给调用方

### 6. Azure 部署名映射

- **为什么**:Azure OpenAI 用部署名而非模型名;部署名与模型名的映射因账户而异
- **怎么做**:Azure 部署映射器维护部署名与模型名的对应关系;请求时用部署名路由
- **影响**:用户配置 Azure 部署名后自动映射;不混淆模型名与部署名

## 设计观察

### 为什么 Cloudflare 不做完整适配器

```
错误设计:
   Cloudflare 适配器自己实现完整流式
   → 重复 Anthropic / OpenAI 的翻译逻辑
   → 维护两份翻译代码,容易不一致
   → 厂商协议变更要改两处

正确设计:
   Cloudflare 适配器只做 URL 元数据
   → 实际翻译复用 Anthropic / OpenAI 适配器
   → 翻译逻辑单一来源
   → Cloudflare 只管 URL 解析与厂商判断
```

### 为什么 Copilot 用头部注入而非独立协议

```
错误设计:
   Copilot 适配器独立实现完整协议
   → 重复 OpenAI 翻译逻辑
   → Copilot 协议本质是 OpenAI + 额外头部
   → 维护成本高

正确设计:
   Copilot 适配器只构建头部
   → 发起者推断(用户 vs 代理)
   → 视觉意图头部(有图像时)
   → 意图头部(会话编辑)
   → 实际请求走 OpenAI 适配器
```

### 为什么 Vertex 与 Google 共享翻译

```
独立实现:
   Google 适配器一份翻译代码
   Vertex 适配器一份翻译代码
   → Gemini 协议变更要改两处
   → 容易不一致

共享设计:
   Gemini 翻译逻辑提取为共享模块
   Google 适配器:公共认证 + 共享翻译
   Vertex 适配器:企业认证 + 共享翻译
   → 翻译逻辑单一来源
   → 认证各自独立(公共 vs 企业)
```

## 章节索引

| 文件 | 主题 |
|---|---|
| 00-overview.md | Provider 抽象层总览 |
| 01-provider-core.md | Provider 核心:注册表 / 主机策略 / 密钥 / 选项 / 资源 / 流 / 类型 / 校验 |
| 02-provider-implementations.md | 本文件 — Provider 实现:9 个厂商适配器 |
| 03-transports.md | 传输层:流式解析 / fetch 守卫 / 路由分发 |
| 04-utils-internal.md | 工具与内部:溢出 / 缓存 / 错误 / OAuth / 内部适配器 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Anthropic 适配器 | [packages/ai/src/providers/anthropic.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic.ts) |
| Anthropic 认证头部 | [packages/ai/src/providers/anthropic-auth-headers.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-auth-headers.ts) |
| Anthropic 模型契约 | [packages/ai/src/providers/anthropic-model-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-model-contract.ts) |
| Anthropic 拒绝处理 | [packages/ai/src/providers/anthropic-refusal.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-refusal.ts) |
| Anthropic 服务器降级 | [packages/ai/src/providers/anthropic-server-fallback.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-server-fallback.ts) |
| Anthropic 思考重放 | [packages/ai/src/providers/anthropic-thinking-replay.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-thinking-replay.ts) |
| Anthropic 工具投影 | [packages/ai/src/providers/anthropic-tool-projection.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-tool-projection.ts) |
| Anthropic 用量解析 | [packages/ai/src/providers/anthropic-usage.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/anthropic-usage.ts) |
| OpenAI 补全适配器 | [packages/ai/src/providers/openai-completions.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-completions.ts) |
| OpenAI 补全兼容 | [packages/ai/src/providers/openai-completions.compat.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-completions.compat.test.ts) |
| OpenAI 停止原因 | [packages/ai/src/providers/openai-stop-reason.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-stop-reason.ts) |
| OpenAI 工具投影 | [packages/ai/src/providers/openai-tool-projection.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-tool-projection.ts) |
| OpenAI 工具模式兼容 | [packages/ai/src/providers/openai-tool-schema-compat.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-tool-schema-compat.ts) |
| OpenAI 响应适配器 | [packages/ai/src/providers/openai-responses.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-responses.ts) |
| OpenAI 响应工具调用追踪 | [packages/ai/src/providers/openai-responses-tool-call-tracker.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-responses-tool-call-tracker.ts) |
| OpenAI 响应终端用量 | [packages/ai/src/providers/openai-responses-terminal-usage.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-responses-terminal-usage.ts) |
| OpenAI ChatGPT 响应适配器 | [packages/ai/src/providers/openai-chatgpt-responses.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-chatgpt-responses.ts) |
| OpenAI 推理强度 | [packages/ai/src/providers/openai-reasoning-effort.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-reasoning-effort.ts) |
| OpenAI 提示缓存 | [packages/ai/src/providers/openai-prompt-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/openai-prompt-cache.ts) |
| Azure OpenAI 响应适配器 | [packages/ai/src/providers/azure-openai-responses.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/azure-openai-responses.ts) |
| Azure 部署映射 | [packages/ai/src/providers/azure-deployment-map.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/azure-deployment-map.ts) |
| Azure 客户端兼容 | [packages/ai/src/providers/azure-openai-responses-client-compat.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/azure-openai-responses-client-compat.ts) |
| Google Gemini 适配器 | [packages/ai/src/providers/google.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/google.ts) |
| Google 共享翻译 | [packages/ai/src/providers/google-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/google-shared.ts) |
| Google 客户端认证 | [packages/ai/src/providers/google-client-auth.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/google-client-auth.test.ts) |
| Gemini 图像清理 | [packages/ai/src/providers/clean-for-gemini.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/clean-for-gemini.ts) |
| Google Vertex 适配器 | [packages/ai/src/providers/google-vertex.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/google-vertex.ts) |
| Mistral 适配器 | [packages/ai/src/providers/mistral.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/mistral.ts) |
| Cloudflare 元数据 | [packages/ai/src/providers/cloudflare.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/cloudflare.ts) |
| GitHub Copilot 头部 | [packages/ai/src/providers/github-copilot-headers.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/github-copilot-headers.ts) |
| 内置注册器 | [packages/ai/src/providers/register-builtins.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/register-builtins.ts) |
| 缓存保留策略 | [packages/ai/src/providers/cache-retention.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/cache-retention.ts) |
| 消息转换 | [packages/ai/src/providers/transform-messages.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/transform-messages.ts) |
| 工具结果文本 | [packages/ai/src/providers/tool-result-text.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/tool-result-text.ts) |
| 简化选项 | [packages/ai/src/providers/simple-options.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/simple-options.ts) |
| 工具参数模式 | [packages/ai/src/providers/agent-tools-parameter-schema.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/ai/src/providers/agent-tools-parameter-schema.ts) |
