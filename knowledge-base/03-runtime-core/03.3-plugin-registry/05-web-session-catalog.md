# 05 — Web 能力与会话目录

> 读完本章你将理解:OpenClaw 的 Web 能力(搜索 / 抓取 / 内容抽取)如何独立于 LLM Provider 工作,以及会话目录如何管理会话级插件状态、讨论注册表、会话绑定。

## 一句话定位

Web 能力与会话目录是插件注册表的两个"独立扩展面":
- Web 能力:搜索 Provider / 抓取 Provider / 内容抽取 Provider,各自独立注册与选择
- 会话目录:管理会话级插件状态、讨论注册表、会话绑定,与会话生命周期耦合

## 全局协作图

下图展示 Web 能力与会话目录的组件协作。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  上游(加载与发现 + 注册表)                          │
│                                                                      │
│   加载与发现 ──加载──► 注册表核心(登记 Web 能力 + 会话目录能力)    │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 注册完成后
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│           Web 能力与会话目录(Web & Session Catalog)               │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  Web 能力面(Web Provider)                                  │    │
│   │                                                            │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ 搜索 Provider    │  │ 抓取 Provider    │                │    │
│   │  │ • 搜索后端       │  │ • HTTP 抓取      │                │    │
│   │  │ • 凭证存在检查   │  │ • 凭证存在检查   │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ 内容抽取 Provider│  │ Web Provider    │                │    │
│   │  │ • 抽取后端       │  │ 共享运行时       │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ Public Artifacts │  │ 安装目录         │                │    │
│   │  │ • 对外能力暴露   │  │ • 安装元数据     │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   └────────────────────────────────────────────────────────────┘    │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  会话目录面(Session Catalog)                               │    │
│   │                                                            │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ 会话目录         │  │ 会话激活         │                │    │
│   │  │ • 目录主入口     │  │ • active 状态   │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ 历史导入         │  │ 讨论注册表       │                │    │
│   │  │ • 历史会话导入   │  │ • 讨论级状态     │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   │  ┌──────────────────┐  ┌──────────────────┐                │    │
│   │  │ 会话绑定         │  │ 会话入口槽位键   │                │    │
│   │  │ • 会话 ↔ 渠道   │  │ • 入口槽位       │                │    │
│   │  └──────────────────┘  └──────────────────┘                │    │
│   └────────────────────────────────────────────────────────────┘    │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  Setup 注册表                                                │    │
│   │  • 协调 Web 能力与会话目录的 setup 流程                    │    │
│   └────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               │ 状态写入
                               ▼
                  ┌────────────────────────┐
                  │  SQLite 状态层         │
                  │  • 共享库              │
                  │  • per-agent 库        │
                  └────────────────────────┘
```

## 组件清单

Web 能力与会话目录由 9 类组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **搜索 Provider** | 提供 Web 搜索能力(对接搜索后端) | 独立于 LLM Provider;凭证走 SecretRef |
| **抓取 Provider** | 提供 HTTP 抓取能力 | 独立于搜索;凭证存在检查 |
| **内容抽取 Provider** | 提供 HTML / 文档内容抽取 | 独立于抓取;支持多种内容类型 |
| **Web Provider 共享运行时** | 跨 Web Provider 复用运行时逻辑 | 共享部分独立于具体 Provider |
| **Web Public Artifacts** | 对外暴露 Web 能力目录 | 只读;不暴露内部凭证 |
| **会话目录** | 管理会话级插件状态的主入口 | 与会话生命周期耦合 |
| **会话激活** | 跟踪当前 active 会话 | 单 agent 单 active 会话 |
| **讨论注册表** | 管理讨论级状态(讨论内消息组) | 讨论级状态隔离 |
| **会话绑定** | 会话与渠道的绑定关系 | 双向映射;绑定关系持久化 |
| **Setup 注册表** | 协调 Web 能力与会话目录的 setup 流程 | 可选;非交互场景跳过 |

## 关联关系

### Web 能力三类 Provider 的隔离

```
              Web Provider 共享运行时
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌──────────┐ ┌──────────┐ ┌──────────┐
   │搜索      │ │抓取      │ │内容抽取   │
   │Provider  │ │Provider  │ │Provider  │
   │          │ │          │ │          │
   │ • 后端 A │ │ • HTTP   │ │ • HTML   │
   │ • 后端 B │ │ • 抓取   │ │ • PDF    │
   └──────────┘ └──────────┘ └──────────┘
        │            │            │
        └────────────┼────────────┘
                     │
                     ▼
              Web Public Artifacts
              (对外能力目录)
```

### 会话目录与 Agent 运行时

```
   ┌──────────────────┐
   │ Agent Runner     │ ──启动会话──► 会话目录
   │                  │                  │
   │                  │ ◄──会话状态──────┘
   └──────────────────┘                  │
                                         ▼
                                ┌──────────────────┐
                                │ 会话激活          │
                                │ • active 会话    │
                                └────────┬─────────┘
                                         │
                                         ▼
                                ┌──────────────────┐
                                │ 讨论注册表        │
                                │ • 讨论级状态     │
                                └────────┬─────────┘
                                         │
                                         ▼
                                ┌──────────────────┐
                                │ 会话绑定          │
                                │ • 会话 ↔ 渠道   │
                                └──────────────────┘
```

### 错误的 Web 能力耦合 LLM Provider(禁止)

```
   错误设计(Web 搜索走 Provider 接缝):
        LLM Provider 接缝同时承载 Web 搜索
        → Provider 接口过载
        → 切换搜索后端影响 LLM Provider

   正确设计:
        Web 搜索 / 抓取 / 内容抽取 = 独立能力类别
        各自独立注册 + 独立选择
        → LLM Provider 只关心模型调用
        → Web 能力可独立替换后端
```

## 协作流程

### Web 搜索能力的使用过程

下面追踪 Agent run 中使用 Web 搜索能力的全过程。

```
Agent run 中 LLM 决定调用 Web 搜索工具
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 通过 Tool Hook 触发 Web 搜索                               │
│    • LLM 输出 tool call:搜索 query                          │
│    • Tool Hook 拦截,路由到搜索 Provider                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 选择搜索 Provider                                          │
│    • 从注册表拿可用搜索 Provider 清单                         │
│    • 凭证存在检查(过滤无凭证的 Provider)                    │
│    • 按优先级选择(配置 + 默认)                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 调用搜索 Provider                                         │
│    • 从 SecretRef 读取搜索后端凭证                           │
│    • 发起搜索请求                                            │
│    • 接收搜索结果                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 可选:内容抽取                                             │
│    • 如需抽取搜索结果页面内容                                 │
│    • 路由到内容抽取 Provider                                  │
│    • 抽取 HTML / 文档内容                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 结果返回 LLM                                              │
│    • 搜索结果 + 抽取内容送回 LLM                             │
│    • LLM 基于结果继续推理                                    │
└──────────────────────────────────────────────────────────────┘
```

### 会话目录的会话激活过程

```
Agent Runner 启动新会话
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 会话目录接收创建请求                              │
│    • 检查是否已有 active 会话                       │
│    • 创建新会话条目                                  │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 会话激活                                          │
│    • 标记新会话为 active                            │
│    • 旧 active 会话归档(如有)                     │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 讨论注册表初始化                                  │
│    • 创建默认讨论                                   │
│    • 讨论级状态占位                                  │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 会话绑定                                          │
│    • 建立 会话 ↔ 渠道 映射                          │
│    • 持久化到 SQLite                                │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  会话就绪
                  Agent Runner 可用
```

### 历史会话导入过程

```
用户请求导入历史会话
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 历史导入入口                                      │
│    • 读取历史会话源(外部格式)                     │
│    • 校验格式                                       │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 转换为内部格式                                    │
│    • 转换消息格式                                   │
│    • 转换讨论结构                                   │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 写入会话目录                                      │
│    • 创建会话条目                                   │
│    • 标记为非 active(历史归档)                     │
│    • 写入讨论注册表                                 │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  历史会话归档完成
                  用户可在 UI 查看
```

## 关键设计约束

### 1. Web 能力独立于 LLM Provider

- **为什么**:LLM 调用与 Web 搜索 / 抓取 / 抽取契约不同;耦合会导致接口过载
- **怎么做**:Web 能力作为独立能力类别注册;与 LLM Provider 分离
- **影响**:可独立替换 Web 后端而不影响 LLM Provider;反之亦然

### 2. Web Provider 凭证存在检查

- **为什么**:无凭证的 Web Provider 调用必然失败;提前过滤避免运行时错误
- **怎么做**:选择 Provider 时检查凭证存在;无凭证的 Provider 不进入候选
- **影响**:用户看到清晰的"未配置"提示;不会调用失败的 Provider

### 3. 会话目录与会话生命周期耦合

- **为什么**:会话级状态需要随会话创建 / 销毁;独立生命周期会导致状态泄漏
- **怎么做**:会话目录条目随会话创建而创建;会话销毁时清理目录条目
- **影响**:会话销毁后会话级状态自动清理;不会泄漏到其他会话

### 4. 单 agent 单 active 会话

- **为什么**:多 active 会话会导致状态竞争;Agent 难以判断 active 状态
- **怎么做**:每 agent 同时只有一个 active 会话;新会话激活时旧会话归档
- **影响**:Agent Runner 始终知道当前 active 会话;状态查询明确

### 5. 会话绑定双向映射

- **为什么**:渠道需要找到对应会话;会话也需要找到对应渠道
- **怎么做**:会话绑定维护双向映射;持久化到 SQLite
- **影响**:渠道消息可路由到正确会话;会话状态可查询对应渠道

### 6. Setup 注册表非阻塞

- **为什么**:Setup 流程不应阻塞非交互场景(CI / 自动部署)
- **怎么做**:Setup 注册表是可选入口;配置已就绪时跳过 setup
- **影响**:非交互场景能直接启动;交互场景才走向导

## 设计观察

### 为什么三类 Web Provider 各自独立

```
错误设计(单一 Web Provider 接缝):
        搜索 / 抓取 / 内容抽取混在一个 Provider 接缝
        → 接口过载
        → 切换搜索后端影响抓取

正确设计:
        搜索 Provider / 抓取 Provider / 内容抽取 Provider
        各自独立注册 + 独立选择
        → 接口清晰
        → 各类后端可独立替换
        → 抓取可独立缓存(不依赖搜索)
```

### 为什么讨论注册表独立于会话目录

```
错误设计(讨论状态混在会话目录):
        会话目录直接管理讨论状态
        → 会话目录职责过载
        → 讨论级状态刷新影响会话目录

正确设计:
        讨论注册表独立
        • 讨论级状态隔离
        • 一个会话可有多个讨论
        → 会话目录只管会话级
        → 讨论级状态独立刷新
```

### 为什么会话绑定持久化

```
错误设计(会话绑定仅在内存):
        会话 ↔ 渠道映射只存内存
        → 进程重启后映射丢失
        → 渠道消息无法路由到正确会话

正确设计:
        会话绑定持久化到 SQLite
        → 进程重启后映射恢复
        → 渠道消息始终能路由
        → 双向映射保证一致性
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 插件注册表总览 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 注册表核心 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | Provider 运行时 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 插件运行时 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 加载与发现 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | 本文件 — Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Web 搜索 Provider 共享 | [src/plugins/web-search-providers.shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-search-providers.shared.ts) |
| Web 搜索 Provider 运行时 | [src/plugins/web-search-providers.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-search-providers.runtime.ts) |
| Web 搜索安装目录 | [src/plugins/web-search-install-catalog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-search-install-catalog.ts) |
| Web 搜索凭证存在 | [src/plugins/web-search-credential-presence.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-search-credential-presence.ts) |
| Web 抓取 Provider 共享 | [src/plugins/web-fetch-providers.shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-fetch-providers.shared.ts) |
| Web 抓取 Provider 运行时 | [src/plugins/web-fetch-providers.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-fetch-providers.runtime.ts) |
| Web 内容抽取 Provider 运行时 | [src/plugins/web-content-extractors.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-content-extractors.runtime.ts) |
| Web 内容抽取类型 | [src/plugins/web-content-extractor-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-content-extractor-types.ts) |
| Web Provider 类型 | [src/plugins/web-provider-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-types.ts) |
| Web Provider 共享运行时 | [src/plugins/web-provider-runtime-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-runtime-shared.ts) |
| Web Provider 解析共享 | [src/plugins/web-provider-resolution-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-resolution-shared.ts) |
| Web Provider Public Artifacts | [src/plugins/web-provider-public-artifacts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-public-artifacts.ts) |
| Web Provider Public Artifacts 显式 | [src/plugins/web-provider-public-artifacts.explicit.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-public-artifacts.explicit.ts) |
| Setup 注册表 | [src/plugins/setup-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/setup-registry.ts) |
| 会话目录 | [src/plugins/session-catalog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-catalog.ts) |
| 会话目录激活 | [src/plugins/session-catalog-active.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-catalog-active.ts) |
| 会话目录历史导入 | [src/plugins/session-catalog-history-import.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-catalog-history-import.ts) |
| 会话讨论注册表 | [src/plugins/session-discussion-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-discussion-registry.ts) |
| 会话会话绑定 | [src/plugins/session-conversation-binding.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-conversation-binding.ts) |
| 会话入口槽位键 | [src/plugins/session-entry-slot-keys.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-entry-slot-keys.ts) |
| 会话绑定类型 | [src/plugins/conversation-binding.types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/conversation-binding.types.ts) |
| 会话绑定会话键 | [src/plugins/conversation-binding-session-key.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/conversation-binding-session-key.ts) |
| Web 内容抽取文档 | [src/plugins/document-extractors.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/document-extractors.runtime.ts) |
| Web 内容抽取 Public Artifacts | [src/plugins/document-extractor-public-artifacts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/document-extractor-public-artifacts.ts) |
