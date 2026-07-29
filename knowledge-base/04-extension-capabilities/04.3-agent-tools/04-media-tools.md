# 04 — 媒体生成工具

> 读完本章你将理解:媒体生成工具由哪些组件构成、image / music / video / pdf 四类工具如何共享后台任务与状态轮询,以及为何所有长耗时生成都走后台任务而非阻塞 agent run。

## 一句话定位

媒体生成工具是 Agent 的**多媒体产出层**:
- 提供 image、music、video、pdf 四类生成能力
- 长耗时生成走后台任务,返回任务句柄,Agent 通过状态轮询查询
- 媒体产物落库或返回引用,不直接塞入 LLM 上下文

## 全局协作图

下图展示媒体生成工具在 Agent 工具集中的位置,以及四类工具与共享设施如何协作。

```
                    Agent Runner
                        │
                        │ 请求工具表
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              媒体生成工具(本章范围)                             │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  媒体工具共享层                                         │  │
│   │  (后台任务共享 / 动作共享 / 配置 / 结果)                │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 分四类生成能力                      │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │                                                            │  │
│   ▼                                                            ▼  │
│   ┌──────────────────────┐              ┌────────────────────┐  │
│   │  图像生成工具        │              │  音乐生成工具      │  │
│   │  (生成主入口 /       │              │ (生成主入口 /      │  │
│   │   后台任务 /         │              │  后台任务 /        │  │
│   │   动作 / 自定义      │              │  动作 / 状态)      │  │
│   │   provider 认证 /    │              │                    │  │
│   │   helpers / 结果)    │              │                    │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│   ┌──────────▼───────────┐              ┌──────────▼──────────┐  │
│   │  视频生成工具        │              │  PDF 工具           │  │
│   │  (生成主入口 /       │              │ (主入口 / helpers / │  │
│   │   后台任务 /         │              │  模型目录 /         │  │
│   │   动作 / 状态 /      │              │  模型配置 /         │  │
│   │   helpers)           │              │  原生 provider /    │  │
│   │                      │              │  运行时中止)        │  │
│   └──────────┬───────────┘              └─────────┬──────────┘  │
│              │                                     │             │
│              └──────────────┬──────────────────────┘             │
│                             ▼                                    │
│              ┌──────────────────────────────────┐                │
│              │  媒体生成配置                    │                │
│              │  (provider 选择 / 模型目录)      │                │
│              └──────────────────────────────────┘                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  外部生成 API          │
                  │  + per-agent SQLite    │
                  │  (产物引用落库)        │
                  └────────────────────────┘
```

## 组件清单

媒体生成工具由 4 类工具 + 4 类共享设施构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **图像生成主入口** | 接收 prompt,生成图像 | 支持后台任务 |
| **图像生成后台任务** | 后台执行长耗时生成 | 状态可轮询 |
| **图像生成动作** | 生成动作的共享逻辑 | 与音乐/视频共享模式 |
| **图像自定义 provider 认证** | 自定义 provider 的认证 | 凭据不外泄 |
| **图像 helpers** | 图像工具辅助逻辑 | 与结果分离 |
| **图像结果** | 图像生成结果形状 | 与工具结果归一对齐 |
| **音乐生成主入口** | 接收 prompt,生成音乐 | 支持后台任务 |
| **音乐生成后台任务** | 后台执行音乐生成 | 状态可轮询 |
| **音乐生成动作** | 音乐生成动作共享逻辑 | 复用共享模式 |
| **音乐生成状态** | 音乐生成状态查询 | 与后台任务协作 |
| **视频生成主入口** | 接收 prompt,生成视频 | 支持后台任务 |
| **视频生成后台任务** | 后台执行视频生成 | 状态可轮询 |
| **视频生成动作** | 视频生成动作共享逻辑 | 复用共享模式 |
| **视频生成状态** | 视频生成状态查询 | 与后台任务协作 |
| **视频 helpers** | 视频工具辅助逻辑 | 与状态分离 |
| **PDF 主入口** | PDF 生成主逻辑 | 模型目录驱动 |
| **PDF helpers** | PDF 工具辅助逻辑 | 与主入口分离 |
| **PDF 模型目录** | PDF 生成模型目录 | 集中维护可用模型 |
| **PDF 模型配置** | PDF 模型配置 | 运行时解析 |
| **PDF 原生 provider** | PDF 原生 provider 实现 | 与外部 provider 分离 |
| **PDF 运行时中止** | PDF 生成的运行时中止 | 可取消 |
| **媒体后台任务共享** | 后台任务的跨媒体共享逻辑 | 四类媒体复用 |
| **媒体动作共享** | 生成动作的跨媒体共享逻辑 | 统一动作模式 |
| **媒体生成配置** | provider 选择与模型配置 | 跨媒体一致 |
| **媒体工具共享** | 媒体工具的通用共享设施 | 跨媒体复用 |

## 关联关系

### 四类媒体工具与共享设施

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   每类媒体工具各自实现后台任务与状态轮询    │
   │   → 四份逻辑 → 行为不一致 → 维护负担        │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   图像生成 ─┐                              │
   │   音乐生成 ─┼──► 媒体后台任务共享          │
   │   视频生成 ─┤    媒体动作共享              │
   │   PDF 生成 ─┘    媒体生成配置              │
   │                  媒体工具共享              │
   │   → 一份共享逻辑 → 行为一致                │
   └─────────────────────────────────────────────┘
```

### 后台任务与状态轮询

```
   LLM 调用媒体生成工具
         │
         │ 长耗时生成
         ▼
   ┌─────────────────────────────────┐
   │ 后台任务派发                    │
   │ → 立即返回任务句柄              │
   │ → 不阻塞 agent run              │
   └──────────────┬──────────────────┘
                  │
                  ▼
   ┌─────────────────────────────────┐
   │ Agent run 继续其他工作          │
   │ 或调用状态轮询查询进度          │
   └──────────────┬──────────────────┘
                  │
                  ▼
   ┌─────────────────────────────────┐
   │ 状态轮询                        │
   │ → 进行中:返回进度              │
   │ → 完成:返回产物引用            │
   │ → 失败:返回错误                │
   └─────────────────────────────────┘
```

### 图像自定义 provider 认证

```
   ┌─────────────────────────────────────────────┐
   │ 错误设计:                                  │
   │   自定义 provider 认证散落在图像工具各处    │
   │   → 凭据可能外泄 → 认证不一致               │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 正确设计:                                  │
   │   图像工具                                    │
   │       │                                     │
   │       ▼                                     │
   │   自定义 provider 认证(集中)              │
   │       │                                     │
   │       ├─ 凭据解析(不外泄)                 │
   │       └─ 认证流程                           │
   └─────────────────────────────────────────────┘
```

## 协作流程

### 一次图像生成的旅程

下面追踪 LLM 调用图像生成工具到产物返回的全过程。

```
LLM 调用图像生成工具,传入 prompt
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 解析生成配置                                              │
│    → 选择 provider                                          │
│    → 解析模型配置                                            │
│    → 解析自定义 provider 认证(如使用)                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 派发后台任务                                              │
│    → 长耗时生成走后台任务                                    │
│    → 立即返回任务句柄给 LLM                                  │
│    → agent run 不阻塞                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 后台执行                                                  │
│    → 调用外部生成 API                                       │
│    → 监听取消信号(可中止)                                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 状态轮询(LLM 主动)                                      │
│    → 进行中:返回进度                                       │
│    → 完成:产物落库,返回引用                               │
│    → 失败:返回错误                                         │
└──────────────────────────────────────────────────────────────┘
```

### 一次 PDF 生成的旅程

```
LLM 调用 PDF 工具,传入生成参数
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 模型目录查找                                              │
│    → 从 PDF 模型目录选择模型                                │
│    → 解析模型配置                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. provider 选择                                             │
│    → 原生 provider 或外部 provider                          │
│    → 按配置决定                                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 执行生成                                                  │
│    → 调用 provider                                           │
│    → 监听运行时中止信号                                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果返回                                                  │
│    → PDF 产物引用回送 LLM                                    │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 长耗时生成走后台任务

- **为什么**:图像 / 音乐 / 视频生成可能耗时数十秒到数分钟,阻塞 agent run 会导致整个会话卡死
- **怎么做**:派发后台任务,立即返回任务句柄,Agent 通过状态轮询查询
- **影响**:agent run 不因媒体生成而长时间挂起,可继续其他工作

### 2. 四类媒体共享后台与动作逻辑

- **为什么**:四类媒体的"派发后台任务 / 状态轮询 / 动作执行"模式高度相似,各自实现会重复且不一致
- **怎么做**:媒体后台任务共享、媒体动作共享、媒体生成配置、媒体工具共享四个共享层统一承载
- **影响**:新增媒体类型复用共享层,行为一致,维护集中

### 3. 产物落库或返回引用

- **为什么**:媒体产物体积大,直接塞入 LLM 上下文会浪费 token 且无法还原
- **怎么做**:产物落 per-agent SQLite 或外部存储,返回引用给 LLM
- **影响**:LLM 拿到引用,需要时再通过其他工具访问产物

### 4. 自定义 provider 认证集中

- **为什么**:自定义 provider 凭据若散落处理,易外泄且认证行为不一致
- **怎么做**:自定义 provider 认证逻辑集中在图像工具的独立模块
- **影响**:凭据管理集中,认证流程统一

### 5. PDF 模型目录驱动

- **为什么**:PDF 生成依赖多种模型,模型选择与配置需集中管理
- **怎么做**:PDF 模型目录集中维护可用模型,模型配置运行时解析
- **影响**:新增模型只需更新目录,工具实现不感知具体模型

### 6. 运行时中止可取消

- **为什么**:长耗时生成可能需要中途取消(用户取消、超时)
- **怎么做**:PDF 工具与视频工具支持运行时中止,监听取消信号
- **影响**:取消即时生效,不浪费资源

## 设计观察

### 为什么媒体工具需要"动作共享"层

```
无动作共享:
   图像生成 ──► 自己的派发逻辑
   音乐生成 ──► 自己的派发逻辑
   视频生成 ──► 自己的派发逻辑
   → 三份派发逻辑 → 行为漂移

有动作共享:
   图像生成 ─┐
   音乐生成 ─┼──► 媒体动作共享 ──► 统一派发
   视频生成 ─┘
   → 一份派发逻辑 → 行为一致
```

### 为什么 PDF 工具需要原生 provider 与外部 provider 分离

```
单一 provider:
   PDF 工具 ──► 通用 provider
   → 原生能力(本地渲染)与外部能力(云 API)混在一起
   → 切换困难,行为不一致

分离设计:
   PDF 工具
       │
       ├─► 原生 provider(本地渲染,无网络)
       └─► 外部 provider(云 API)
   → 能力边界清晰,可按配置选择
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 内置工具:bash / edit / find / grep / ls / read / write 及共享设施 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | Web 工具:fetch / search / guarded-fetch / shared |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 会话工具:list / history / search / send / spawn / yield / access |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 本文件 — 媒体生成工具 |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 其他工具:computer / terminal / tts / dashboard / goal / nodes / message 等 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 图像生成主入口 | [src/agents/tools/image-generate-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-generate-tool.ts) |
| 图像生成后台任务 | [src/agents/tools/image-generate-background.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-generate-background.ts) |
| 图像生成动作 | [src/agents/tools/image-generate-tool.actions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-generate-tool.actions.ts) |
| 图像工具主入口 | [src/agents/tools/image-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-tool.ts) |
| 图像工具 helpers | [src/agents/tools/image-tool.helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-tool.helpers.ts) |
| 图像工具结果 | [src/agents/tools/image-tool.result.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/image-tool.result.ts) |
| 音乐生成主入口 | [src/agents/tools/music-generate-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/music-generate-tool.ts) |
| 音乐生成后台任务 | [src/agents/tools/music-generate-background.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/music-generate-background.ts) |
| 音乐生成动作 | [src/agents/tools/music-generate-tool.actions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/music-generate-tool.actions.ts) |
| 视频生成主入口 | [src/agents/tools/video-generate-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/video-generate-tool.ts) |
| 视频生成后台任务 | [src/agents/tools/video-generate-background.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/video-generate-background.ts) |
| 视频生成动作 | [src/agents/tools/video-generate-tool.actions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/video-generate-tool.actions.ts) |
| PDF 工具主入口 | [src/agents/tools/pdf-tool.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-tool.ts) |
| PDF 工具 helpers | [src/agents/tools/pdf-tool.helpers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-tool.helpers.ts) |
| PDF 模型目录 | [src/agents/tools/pdf-tool.model-catalog.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-tool.model-catalog.test.ts) |
| PDF 模型配置 | [src/agents/tools/pdf-tool.model-config.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-tool.model-config.ts) |
| PDF 原生 provider | [src/agents/tools/pdf-native-providers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-native-providers.ts) |
| PDF 运行时中止 | [src/agents/tools/pdf-tool.runtime-abort.test.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/pdf-tool.runtime-abort.test.ts) |
| 媒体后台任务共享 | [src/agents/tools/media-generate-background-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/media-generate-background-shared.ts) |
| 媒体动作共享 | [src/agents/tools/media-generate-tool-actions-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/media-generate-tool-actions-shared.ts) |
| 媒体生成配置 | [src/agents/tools/media-generation-config.test-support.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/media-generation-config.test-support.ts) |
| 媒体工具共享 | [src/agents/tools/media-tool-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/media-tool-shared.ts) |
| 媒体后台测试支撑 | [src/agents/tools/media-generate-background.test-support.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/tools/media-generate-background.test-support.ts) |
