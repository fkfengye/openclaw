# 02 — Web 工具

> 读完本章你将理解:Web 工具由哪些组件构成、guarded-fetch 如何统一承载安全防护、搜索 provider 如何 late-bind、可读性提取与引用重定向如何协作,以及为何所有 Web 抓取必须走集中入口。

## 一句话定位

Web 工具是 Agent 的**对外信息获取层**:
- 提供 web-fetch 抓取与 web-search 搜索两类核心能力
- guarded-fetch 作为统一安全入口,集中 SSRF 校验、超时控制、provider fallback
- 搜索 provider 走 late-bind,凭据与配置在运行时按需解析

## 全局协作图

下图展示 Web 工具在 Agent 工具集中的位置,以及抓取、搜索、共享设施如何协作。

```
                    Agent Runner
                        │
                        │ 请求工具表
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              Web 工具(本章范围)                                 │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  Web 工具聚合入口                                       │  │
│   │  (统一启用默认 / 运行时上下文 / 可读性)                 │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 分两类核心能力                      │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  Web 抓取                       Web 搜索                  │  │
│   │                                                            │  │
│   │  • 抓取主入口                  • 搜索主入口               │  │
│   │  • 工具集                       • 输出与引用               │  │
│   │  • 可见性控制                  • provider 通用逻辑        │  │
│   │  • provider fallback           • provider 配置            │  │
│   │  • SSRF 防护                   • provider 凭据            │  │
│   │  • Markdown 转换               • late-bind                │  │
│   │  • 输出契约                    • 引用重定向               │  │
│   │  • 测试支撑                    • 信号处理                 │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 共享防护与上下文                    │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  guarded-fetch 入口        Web 共享设施                  │  │
│   │  (SSRF / 超时 /            (输出契约 / 引用 / 信号)      │  │
│   │   可读性 / fallback)                                     │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  外部网络               │
                  │  (HTTP / 搜索 API)     │
                  └────────────────────────┘
```

## 组件清单

Web 工具由 2 类核心能力 + 2 类共享设施构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **Web 抓取主入口** | 接收 URL,返回 Markdown 化内容 | 必须经 guarded-fetch |
| **抓取工具集** | 抓取能力的工具表注册与启用默认 | 启用默认集中维护 |
| **可见性控制** | 控制抓取结果对 LLM 的可见性 | 防止敏感内容回送 |
| **provider fallback** | 主 provider 失败时切换备用 | 切换策略集中 |
| **SSRF 防护** | 拦截内网地址、元数据端点 | 硬约束,不可绕过 |
| **Markdown 转换** | HTML 转 Markdown,带 Cloudflare 兼容 | 跨源页面行为一致 |
| **输出契约** | 抓取结果的统一形状 | 与工具结果归一对齐 |
| **Web 搜索主入口** | 接收查询,返回搜索结果 | provider late-bind |
| **搜索输出与引用** | 搜索结果的引用与重定向 | 引用稳定性 |
| **搜索 provider 通用逻辑** | 多 provider 共享行为 | 通用逻辑集中 |
| **搜索 provider 配置** | provider 选择与配置 | 运行时解析 |
| **搜索 provider 凭据** | provider 凭据管理 | 凭据不外泄 |
| **late-bind** | provider 在首次调用时绑定 | 延迟初始化 |
| **引用重定向** | 搜索引用的规范化 | 防止引用漂移 |
| **信号处理** | 搜索中断与取消信号 | 可取消 |
| **guarded-fetch 入口** | 统一安全防护入口 | 所有抓取必经 |
| **Web 共享设施** | 输出契约、引用、信号共享 | 跨抓取与搜索复用 |
| **运行时上下文** | Web 工具运行时上下文 | 请求级隔离 |

## 关联关系

### 抓取与 guarded-fetch

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   抓取工具 ──直接请求──► 任意 URL           │
   │   → SSRF 风险                              │
   │   → 无超时 / 无可读性 / 无 fallback         │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   抓取工具 ──► guarded-fetch ──► 实际请求   │
   │                 │                           │
   │                 ├─ SSRF 校验(拒绝内网)     │
   │                 ├─ 超时控制                 │
   │                 ├─ 可读性提取               │
   │                 ├─ Markdown 转换            │
   │                 └─ provider fallback        │
   └─────────────────────────────────────────────┘
```

### 搜索 provider 的 late-bind

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   启动时立即绑定所有搜索 provider           │
   │   → 未使用的 provider 也加载 → 启动慢       │
   │   → 凭据缺失即启动失败                      │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计(late-bind):                      │
   │   搜索主入口                                │
   │       │                                     │
   │       │ 首次调用时                          │
   │       ▼                                     │
   │   解析 provider 配置 + 凭据                 │
   │       │                                     │
   │       ▼                                     │
   │   绑定具体 provider                         │
   │   → 未使用则不加载 → 启动快                 │
   │   → 凭据缺失仅在该 provider 调用时报错      │
   └─────────────────────────────────────────────┘
```

### 抓取、搜索与共享设施

```
   Web 抓取 ─┐
              ├──► 共享输出契约
   Web 搜索 ─┘     共享引用设施
                   共享信号处理
                   共享运行时上下文
   → 抓取与搜索行为一致,维护集中
```

## 协作流程

### 一次 web-fetch 调用的旅程

下面追踪 LLM 调用 web-fetch 抓取一个 URL 到结果回送的全过程。

```
LLM 调用 web-fetch,传入 URL
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 进入 guarded-fetch                                         │
│    → SSRF 校验:拒绝内网地址、元数据端点                      │
│    → 超时控制设置                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 实际请求                                                   │
│    → 主 provider 发起请求                                    │
│    → 失败时按 fallback 策略切换备用 provider                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 内容处理                                                   │
│    → 可读性提取(去除导航 / 广告 / 模板)                    │
│    → HTML 转 Markdown(Cloudflare 页面兼容)                 │
│    → 可见性控制(过滤敏感内容)                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果归一                                                   │
│    → 套用输出契约                                            │
│    → 返回 Markdown 内容给 LLM                                │
└──────────────────────────────────────────────────────────────┘
```

### 一次 web-search 调用的旅程

```
LLM 调用 web-search,传入查询
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. provider late-bind                                         │
│    → 解析 provider 配置                                      │
│    → 解析 provider 凭据                                      │
│    → 绑定具体搜索 provider                                   │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 执行搜索                                                   │
│    → 调用 provider 搜索 API                                  │
│    → 监听取消信号(可中断)                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 结果处理                                                   │
│    → 引用重定向规范化                                        │
│    → 套用搜索输出契约                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 返回 LLM                                                   │
│    → 结果列表 + 引用                                         │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. guarded-fetch 是硬约束入口

- **为什么**:SSRF、超时、可读性、fallback 是横切关注点,散落各处会引入安全风险面
- **怎么做**:所有 Web 抓取必须经 guarded-fetch,安全策略集中维护
- **影响**:新增 Web provider 不引入新风险面,策略更新单点生效

### 2. 搜索 provider late-bind

- **为什么**:启动时绑定所有 provider 会拖慢启动且凭据缺失即失败
- **怎么做**:provider 在首次调用时按需解析配置与凭据并绑定
- **影响**:启动快,未使用 provider 不加载,凭据问题延迟到调用时暴露

### 3. 可读性提取保证内容可用

- **为什么**:原始 HTML 含大量导航、广告、模板噪声,直接回送 LLM 上下文浪费
- **怎么做**:抓取后做可读性提取,去除噪声,保留主体内容
- **影响**:LLM 拿到的是干净 Markdown,上下文利用率高

### 4. provider fallback 集中策略

- **为什么**:主 provider 可能因限流、宕机、网络问题失败,需要自动切换
- **怎么做**:fallback 策略在 guarded-fetch 集中维护,工具实现不感知
- **影响**:工具实现简单,容错策略统一

### 5. 引用重定向规范化

- **为什么**:搜索结果引用可能因 provider 差异而格式不一,甚至漂移
- **怎么做**:引用重定向模块统一规范化所有搜索结果的引用
- **影响**:LLM 看到的引用稳定,后续抓取不会因引用漂移而失败

### 6. 运行时上下文请求级隔离

- **为什么**:不同 agent run 的 Web 请求不应共享状态
- **怎么做**:运行时上下文按请求级隔离,不跨 run 复用
- **影响**:Web 工具调用相互独立,无状态泄漏

## 设计观察

### 为什么抓取需要可见性控制

```
无可见性控制:
   抓取工具 ──► 任意页面内容 ──► 直接回送 LLM
   → 可能含敏感信息(凭据 / 私密内容)
   → 可能含恶意指令(prompt injection)

有可见性控制:
   抓取工具 ──► 可见性过滤 ──► LLM
                 │
                 ├─ 过滤敏感内容
                 └─ 过滤潜在指令注入
```

### 为什么搜索结果需要信号处理

```
无信号处理:
   搜索发起 ──► 阻塞等待 ──► 返回
   → 用户取消时无法中断 → 资源浪费

有信号处理:
   搜索发起 ──► 监听取消信号
                 │
                 ├─ 收到取消 → 立即中断 → 返回部分结果
                 └─ 正常完成 → 返回完整结果
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 内置工具:bash / edit / find / grep / ls / read / write 及共享设施 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | 本文件 — Web 工具 |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 会话工具:list / history / search / send / spawn / yield / access |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 媒体生成工具:image / music / video / pdf |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 其他工具:computer / terminal / tts / dashboard / goal / nodes / message 等 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Web 抓取主入口 | [src/agents/tools/web-fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-fetch.ts) |
| Web 抓取工具集 | [src/agents/tools/web-tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-tools.ts) |
| Web 抓取可见性 | [src/agents/tools/web-fetch-visibility.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-fetch-visibility.ts) |
| Web 抓取工具 | [src/agents/tools/web-fetch-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-fetch-utils.ts) |
| Web 抓取输出契约 | [src/agents/tools/web-fetch-output-contract.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-fetch-output-contract.test.ts) |
| Web guarded-fetch | [src/agents/tools/web-guarded-fetch.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-guarded-fetch.ts) |
| Web 搜索主入口 | [src/agents/tools/web-search.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search.ts) |
| Web 搜索输出 | [src/agents/tools/web-search-output.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search-output.ts) |
| Web 搜索引用重定向 | [src/agents/tools/web-search-citation-redirect.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search-citation-redirect.ts) |
| Web 搜索 provider 通用 | [src/agents/tools/web-search-provider-common.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search-provider-common.ts) |
| Web 搜索 provider 配置 | [src/agents/tools/web-search-provider-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search-provider-config.ts) |
| Web 搜索 provider 凭据 | [src/agents/tools/web-search-provider-credentials.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-search-provider-credentials.ts) |
| Web 共享设施 | [src/agents/tools/web-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-shared.ts) |
| Web 工具运行时上下文 | [src/agents/tools/web-tool-runtime-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-tool-runtime-context.ts) |
| Web 工具启用默认 | [src/agents/tools/web-tools.enabled-defaults.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/web-tools.enabled-defaults.test.ts) |
