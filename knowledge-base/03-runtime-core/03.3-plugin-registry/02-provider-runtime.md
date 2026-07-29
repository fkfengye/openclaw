# 02 — Provider 运行时

> 读完本章你将理解:Provider 运行时如何把"已登记的 Provider 元数据"变成"可实际调用 LLM 的运行时实例",以及 OAuth、模型路由、策略面、自托管 setup 等组件如何协作。

## 一句话定位

Provider 运行时是 LLM 厂商调用的"装配层":
- 从注册表拿到 Provider 元数据后,装配出可调用 LLM 的运行时实例
- 处理 OAuth 流程、模型路由、主模型选择、思考能力、策略面
- 暴露 public artifacts 供 UI / CLI 展示 Provider 能力

## 全局协作图

下图展示 Provider 运行时内部的组件协作。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  上游(注册表核心)                                   │
│                                                                      │
│   Providers 登记器 ──写入──► 注册表状态(Provider 元数据)           │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ 提供 Provider 元数据
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  Provider 运行时(Provider Runtime)                  │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  运行时装配层                                                │    │
│   │  • Provider 运行时入口    • 运行时状态    • 类型契约        │    │
│   │  • 模型类型               • 使用 harness                    │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 装配时需要                          │
│                                ▼                                     │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│   │  OAuth 流程      │  │  模型路由        │  │  主模型选择      │  │
│   │  • ChatGPT OAuth │  │  • 路由策略      │  │  • 默认模型      │  │
│   │  • TLS           │  │  • 模型 → Provider│ │  • 兜底逻辑      │  │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘  │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│   │  策略面          │  │  思考能力        │  │  Public Artifacts│  │
│   │  • 调用约束      │  │  • Thinking 类型 │  │  • 对外暴露      │  │
│   │  • 限速/重试     │  │  • Active 状态  │  │  • 目录条目      │  │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘  │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│   │  Replay 辅助     │  │  Registry 共享   │  │  自托管 Setup    │  │
│   │  • 重放支持      │  │  • 跨运行时复用  │  │  • 本地部署配置  │  │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘  │
│                                                                      │
│   ┌──────────────────┐  ┌──────────────────┐                          │
│   │  校验            │  │  向导            │                          │
│   │  • 配置校验      │  │  • 交互式引导    │                          │
│   └──────────────────┘  └──────────────────┘                          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 调用 LLM
                               ▼
                  ┌────────────────────────┐
                  │  外部 LLM              │
                  │  OpenAI / Anthropic / │
                  │  本地模型 / 自托管    │
                  └────────────────────────┘
```

## 组件清单

Provider 运行时由 12 类组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **运行时装配层** | 把 Provider 元数据装配为运行时实例 | 装配过程不可阻塞主线程;失败 fail closed |
| **OAuth 流程** | 处理 LLM 厂商 OAuth(如 ChatGPT OAuth + TLS) | 凭证存 SecretRef;失败 fail closed |
| **模型路由** | 把模型 ID 路由到具体 Provider 实例 | 路由表确定性排序;主模型 + 兜底 |
| **主模型选择** | 选择 Agent 默认使用的模型 | 主模型优先;兜底仅 fallback |
| **策略面** | 调用约束、限速、重试策略 | 策略与运行时分离,可独立更新 |
| **思考能力** | 处理 reasoning / thinking 模型 | 与 LLM 调用解耦,可单独切换 |
| **Public Artifacts** | 对 UI / CLI 暴露 Provider 能力目录 | 只读;不暴露内部凭证 |
| **Replay 辅助** | 支持请求重放(测试 / 调试) | 不影响生产调用 |
| **Registry 共享** | 跨 Provider 运行时复用配置 | 共享部分独立于具体 Provider |
| **自托管 Setup** | 配置本地 / 自托管 LLM | 独立 setup 路径,不走 OAuth |
| **校验** | 校验 Provider 配置正确性 | 启动 + 运行时双重校验 |
| **向导** | 交互式引导用户配置 Provider | 可选,不阻塞非交互场景 |

## 关联关系

### Provider 运行时与注册表核心

```
   ┌──────────────────┐
   │ Providers 登记器 │
   │ (注册表核心)     │ ──登记元数据──► 注册表状态
   └──────────────────┘                          │
                                                 │ 提供
                                                 ▼
                                       ┌──────────────────┐
                                       │ Provider 运行时  │
                                       │ 装配层           │
                                       │                  │
                                       │ • 拿元数据       │
                                       │ • 装配实例        │
                                       │ • 注入策略        │
                                       └────────┬─────────┘
                                                │
                                                │ 装配完成
                                                ▼
                                       ┌──────────────────┐
                                       │ 可调用 Provider  │
                                       │ 运行时实例        │
                                       └──────────────────┘
```

### OAuth 流程与策略面、运行时实例

```
   ┌──────────────┐
   │ OAuth 流程   │ ──拿到 access token──► 运行时实例
   │              │                         │
   │ • ChatGPT    │                         │
   │ • TLS        │                         ▼
   └──────┬───────┘                  ┌──────────────┐
          │                          │ 策略面       │
          │ 凭证写入 SecretRef        │ • 限速       │
          │                          │ • 重试       │
          ▼                          │ • 调用约束   │
   ┌──────────────┐                  └──────┬───────┘
   │ SecretRef    │ ◄──读取凭证─────────────┘
   │ (凭证引用)   │
   └──────────────┘
```

### 模型路由的多 Provider 协作

```
   模型 ID 请求到达
         │
         ▼
   ┌──────────────────────────────────────┐
   │  模型路由                            │
   │  • 路由策略表(确定排序)            │
   │  • 模型 → Provider 映射              │
   └────────────────┬─────────────────────┘
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   ┌────────┐ ┌────────┐ ┌────────┐
   │Provider│ │Provider│ │Provider│
   │  A     │ │  B     │ │  C     │
   │(OpenAI)│ │(Claude)│ │(本地) │
   └────────┘ └────────┘ └────────┘
        │           │           │
        └───────────┼───────────┘
                    ▼
              主模型选择
              (确定 Agent 默认)
```

### 错误的运行时实例共享凭证(禁止)

```
   错误设计(多 Provider 共享一份 access token):
        Provider A 与 Provider B 共享同一份 OAuth token
        → 一个 Provider 失效 token 影响另一个
        → 凭证边界混乱

   正确设计(每 Provider 独立 SecretRef):
        每个 Provider 引用独立 SecretRef
        → 失败隔离到单个 Provider
        → 凭证边界清晰
```

## 协作流程

### Provider 运行时装配过程

下面追踪一个 OAuth Provider 从元数据到可用实例的全过程。

```
Gateway 启动到 Provider 装配阶段
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 从注册表拿 Provider 元数据                                 │
│    • Providers 登记器列出所有已登记 Provider                   │
│    • Provider 运行时装配层接收元数据                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 装配运行时实例                                              │
│    • 解析 Provider 类型(OpenAI / Anthropic / 自托管 / ...)  │
│    • 装配 OAuth 流程(如需要)                                │
│    • 装配模型路由策略                                          │
│    • 装配主模型选择                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. OAuth 凭证准备(如需要)                                    │
│    • 检查 SecretRef 是否就绪                                  │
│    • 如未就绪 → 启动 OAuth 流程(ChatGPT OAuth / TLS)        │
│    • 拿到 access token → 写入 SecretRef                      │
│    • 失败 → 隔离该 Provider,fail closed                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 策略面 + 思考能力装配                                       │
│    • 装配限速 / 重试 / 调用约束                                │
│    • 装配思考能力(如模型支持)                                │
│    • Replay 辅助注入(用于测试)                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 校验 + 暴露 Public Artifacts                                │
│    • 校验 Provider 配置完整性                                  │
│    • 构建 public artifacts(对外能力目录条目)                 │
│    • UI / CLI 可读 Provider 能力                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  Provider 运行时实例就绪
                  Agent Runner 可调用 LLM
```

### Agent run 中调用 LLM 的过程

```
Agent Runner 决定调用 Provider
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 模型路由                                          │
│    • 根据 agent 配置的模型 ID                       │
│    • 路由到具体 Provider 实例                        │
│    • 主模型优先,fallback 走兜底                    │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 策略面应用                                       │
│    • 应用调用约束(超时 / 限速)                     │
│    • 应用重试策略(失败重试)                        │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. OAuth 凭证读取                                   │
│    • 从 SecretRef 读取 access token                  │
│    • token 过期 → 触发 OAuth 流程刷新                │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 调用 LLM(流式)                                  │
│    • 发起 HTTP 请求                                  │
│    • 流式接收 chunk                                  │
│    • 思考能力处理(如模型支持)                      │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  流式输出回 Agent Runner
                  (经 Replay 辅助可重放)
```

## 关键设计约束

### 1. OAuth 凭证走 SecretRef

- **为什么**:凭证不应散落在内存或文件;集中管理才能做 fail closed 与隔离
- **怎么做**:OAuth 拿到 token 后写入 SecretRef;运行时通过 SecretRef 引用,不直接持有
- **影响**:token 过期时由 SecretRef 触发刷新;失败隔离到最小已知 owner

### 2. 模型路由确定性排序

- **为什么**:prompt cache 对路由顺序敏感;不确定顺序导致 cache miss
- **怎么做**:路由策略表在序列化前排序;同一组 Provider 多次路由结果一致
- **影响**:Agent 配置相同的模型 ID 时,路由到相同 Provider

### 3. 主模型与兜底分离

- **为什么**:主模型是 Agent 的明确选择;兜底是降级方案,不应混淆
- **怎么做**:主模型选择独立于路由策略;兜底仅在主模型不可用时启用
- **影响**:更换主模型不影响兜底逻辑;兜底失败可独立报警

### 4. 策略面与运行时实例分离

- **为什么**:限速 / 重试策略需要独立更新(如临时调限速),不应影响 Provider 实例
- **怎么做**:策略面是独立组件,运行时实例注入策略;策略可热更新
- **影响**:策略调整不需要重新装配 Provider 实例

### 5. Public Artifacts 不暴露内部凭证

- **为什么**:防止 UI / CLI 意外暴露 access token 等敏感信息
- **怎么做**:public artifacts 只包含能力描述、模型列表、状态;凭证始终在 SecretRef 内
- **影响**:UI 展示 Provider 能力时不接触凭证

### 6. 自托管 Setup 独立路径

- **为什么**:自托管 LLM(本地模型)不走 OAuth,setup 流程与云端 Provider 不同
- **怎么做**:自托管 Setup 独立组件;不混入 OAuth 流程
- **影响**:自托管 Provider 的配置 / 校验 / 启动独立于 OAuth Provider

## 设计观察

### 为什么 Provider 运行时与注册表分离

```
错误设计(注册表直接调 LLM):
        Providers 登记器 = LLM 调用入口
        → 注册表承担运行时职责,违反"只登记不调用"
        → 刷新注册表时 LLM 调用中断

正确设计:
        注册表只登记元数据
        Provider 运行时独立装配 + 调用
        → 注册表刷新不影响运行时实例
        → 运行时实例可独立刷新 auth
```

### 为什么思考能力独立组件

```
错误设计(思考能力耦合在 LLM 调用里):
        LLM 调用代码内嵌 thinking 处理
        → 切换 thinking 模式需要改 LLM 调用代码
        → 不同模型 thinking 协议不同,难以扩展

正确设计:
        思考能力独立组件
        • Thinking 类型契约
        • Active 状态管理
        → 不同模型的 thinking 协议各自实现
        → 切换 thinking 模式不影响 LLM 调用主体
```

### 为什么向导是可选的

```
错误设计(向导是必经环节):
        所有 Provider 配置都走向导
        → 非交互场景(CI / 自动部署)无法配置
        → 启动被向导阻塞

正确设计:
        向导是可选交互入口
        • 配置已就绪 → 直接装配,跳过向导
        • 配置缺失 + 交互环境 → 走向导
        • 配置缺失 + 非交互 → fail closed 报错
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 插件注册表总览 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 注册表核心 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | 本文件 — Provider 运行时 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 插件运行时 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 加载与发现 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Provider 运行时入口 | [src/plugins/provider-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime.ts) |
| Provider 运行时类型 | [src/plugins/provider-runtime.types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime.types.ts) |
| Provider 运行时懒加载 | [src/plugins/provider-runtime.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime.runtime.ts) |
| Provider 模型类型 | [src/plugins/provider-runtime-model.types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime-model.types.ts) |
| OAuth 流程 | [src/plugins/provider-oauth-flow.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-oauth-flow.ts) |
| ChatGPT OAuth | [src/plugins/provider-openai-chatgpt-oauth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-openai-chatgpt-oauth.ts) |
| ChatGPT OAuth TLS | [src/plugins/provider-openai-chatgpt-oauth-tls.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-openai-chatgpt-oauth-tls.ts) |
| 模型路由 | [src/plugins/provider-model-routes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-routes.ts) |
| 主模型选择 | [src/plugins/provider-model-primary.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-primary.ts) |
| 模型辅助 | [src/plugins/provider-model-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-helpers.ts) |
| 模型兼容 | [src/plugins/provider-model-compat.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-compat.ts) |
| 策略面 | [src/plugins/provider-policy-surface.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-policy-surface.ts) |
| 思考能力 | [src/plugins/provider-thinking.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-thinking.ts) |
| 思考类型 | [src/plugins/provider-thinking.types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-thinking.types.ts) |
| 思考激活 | [src/plugins/provider-thinking-active.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-thinking-active.ts) |
| Claude 思考 | [src/plugins/provider-claude-thinking.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-claude-thinking.ts) |
| Public Artifacts | [src/plugins/provider-public-artifacts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-public-artifacts.ts) |
| Replay 辅助 | [src/plugins/provider-replay-helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-replay-helpers.ts) |
| Registry 共享 | [src/plugins/provider-registry-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-registry-shared.ts) |
| 自托管 Setup | [src/plugins/provider-self-hosted-setup.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-self-hosted-setup.ts) |
| 校验 | [src/plugins/provider-validation.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-validation.ts) |
| 向导 | [src/plugins/provider-wizard.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-wizard.ts) |
| Auth 类型 | [src/plugins/provider-auth-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-auth-types.ts) |
| Auth Choice | [src/plugins/provider-auth-choices.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-auth-choices.ts) |
| Auth Token | [src/plugins/provider-auth-token.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-auth-token.ts) |
| Auth Ref | [src/plugins/provider-auth-ref.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-auth-ref.ts) |
| API Key Auth | [src/plugins/provider-api-key-auth.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-api-key-auth.ts) |
| Discovery | [src/plugins/provider-discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-discovery.ts) |
| Catalog | [src/plugins/provider-catalog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-catalog.ts) |
| Contract Public Artifacts | [src/plugins/provider-contract-public-artifacts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-contract-public-artifacts.ts) |
