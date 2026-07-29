# 02 — 模块地图与目录职责

> 读完本章你将理解:OpenClaw 的代码分成哪几大块、每块的职责是什么、块与块之间的边界规则是什么、能力该归属到哪一层。

## 一句话定位

OpenClaw 是 monorepo,代码按职责分层组织:核心运行时承载所有业务逻辑,协议子包提供契约,SDK 边界是插件唯一入口,插件实现独立成包。每一层都有 AGENTS.md 强约束的边界规则。

## 全局协作图

下图展示 OpenClaw 的模块分层与依赖方向。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  协议契约层(独立子包)                               │
│                                                                      │
│   TypeBox Schema + 校验器 + 迁移 API                                 │
│   不依赖核心 session 类型,可独立演进                                │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ 被引用(契约)
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  核心运行时层(Core Runtime)                         │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ Gateway     │  │ Agent       │  │ Channels    │  │ State     │ │
│   │ 服务器      │  │ 运行时      │  │ Turn 内核   │  │ SQLite 层 │ │
│   │ (HTTP/WS)   │  │ (编排)      │  │ (消息回合)  │  │ (双层)    │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│   ┌─────────────┐  ┌─────────────┐                                  │
│   │ Plugins     │  │ Config      │                                  │
│   │ 加载/注册   │  │ 加载/迁移   │                                  │
│   └─────────────┘  └─────────────┘                                  │
│                                                                      │
│   约束:保持插件无关,不内嵌 bundled id/defaults/policy              │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ 通过 SDK 边界暴露
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  SDK 边界层(Plugin SDK)                             │
│                                                                      │
│   数百个懒加载接缝,插件唯一入口                                     │
│   Provider 入口 / Tool 入口 / Channel 入口 / Hook 入口              │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │ 通过 SDK 注册能力
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  插件实现层(Extensions)                            │
│                                                                      │
│   渠道插件:Telegram/Discord/Slack/WhatsApp/Signal/...               │
│   能力插件:browser/canvas/cron/nodes/sessions/...                   │
│                                                                      │
│   约束:独立 npm 子包,只通过 SDK 访问核心,禁止互相 import          │
└──────────────────────────────────────────────────────────────────────┘

    横向辅助层:

    ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
    │ UI 前端          │  │ 文档源           │  │ 配套应用         │
    │ (Control UI)     │  │ (发布到文档站)   │  │ (macOS/iOS/...)  │
    └──────────────────┘  └──────────────────┘  └──────────────────┘
```

## 组件清单

OpenClaw 的代码模块由 6 类核心组件构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **协议契约层** | TypeBox Schema 定义所有消息格式,提供校验器与迁移 API | 独立子包,不依赖核心 session 类型 |
| **核心运行时层** | Gateway 服务器、Agent 编排、Turn 内核、状态层、插件加载、配置管理 | 保持插件无关,不内嵌 bundled id/defaults/policy |
| **SDK 边界层** | 插件访问核心的唯一通道,数百个懒加载接缝 | 插件只能通过此层访问核心,禁止直接 import 核心 |
| **插件实现层** | 25+ 渠道插件 + 能力插件,各为独立 npm 子包 | 禁止 import 核心、import 其他插件、相对路径出包 |
| **UI 前端** | Control UI,独立子包 | 与核心运行时分包 |
| **文档与应用** | 源文档发布到文档站;配套应用覆盖多平台 | 文档随行为/API 同步更新 |

## 关联关系

### 模块依赖方向(允许的依赖)

```
                ┌─────────────────────────────────────────────┐
                │            协议契约层                        │
                │            (独立子包)                       │
                │            • TypeBox schemas                │
                │            • 校验器 + 迁移 API              │
                └──────────────┬──────────────────────────────┘
                               │ 被引用(契约)
                               ▼
                ┌─────────────────────────────────────────────┐
                │              核心运行时层                    │
                │  ┌──────────────────────────────────────────┐ │
                │  │ Gateway  ◄── Agent                       │ │
                │  │    ▲              │                      │ │
                │  │    │              ▼                      │ │
                │  │    └────── Channels                      │ │
                │  │                 ▲                        │ │
                │  │    Plugins ─────┘                        │ │
                │  │    Config ──────┘                        │ │
                │  │    State ◄── (所有层读写)                │ │
                │  └──────────────────────────────────────────┘ │
                └──────────────┬──────────────────────────────┘
                               │ 通过 SDK 边界暴露
                               ▼
                ┌─────────────────────────────────────────────┐
                │           SDK 边界层                         │
                │           • 数百个懒加载接缝                │
                │           • 插件唯一入口                    │
                └──────────────┬──────────────────────────────┘
                               │ 通过 SDK 调用
                               ▼
                ┌─────────────────────────────────────────────┐
                │           插件实现层                         │
                │  渠道:telegram/discord/slack/whatsapp...    │
                │  工具:browser/canvas/cron/nodes...          │
                └─────────────────────────────────────────────┘
```

### 边界规则(允许 vs 禁止)

```
    插件访问核心的边界规则

    允许(Allowed):
    ┌───────────────────────────────────────────────┐
    │   插件  ──►  SDK 边界(接缝)                  │
    │   插件  ──►  manifest metadata(声明式描述)   │
    │   插件  ──►  injected runtime helpers(注入)  │
    │   插件  ──►  documented barrels(文档化出口)  │
    └───────────────────────────────────────────────┘

    禁止(Forbidden):
    ┌───────────────────────────────────────────────┐
    │   插件  ──✗──►  核心内部源码                   │
    │   插件  ──✗──►  内部 SDK 源码                 │
    │   插件 A ──✗──► 插件 B 内部源码               │
    │   插件  ──✗──►  相对路径出包                  │
    └───────────────────────────────────────────────┘

    核心/tests 的边界规则:
    ┌───────────────────────────────────────────────┐
    │   核心/tests  ──✗──►  插件 internals          │
    │   核心/tests  ──✗──►  插件 onboarding         │
    │                                                │
    │   替代:用 public barrels / SDK facade /      │
    │        generic contracts                       │
    └───────────────────────────────────────────────┘
```

### Owner 边界(能力该放哪里)

```
                核心问题:某个能力该放哪里?

                         ┌───────────────┐
                         │ 是 owner 特定? │
                         └───────┬───────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
                    ▼                         ▼
              ┌─────────┐               ┌─────────┐
              │   是    │               │   否    │
              └────┬────┘               └────┬────┘
                   │                         │
                   ▼                         ▼
          ┌─────────────────┐       ┌─────────────────┐
          │ owner 插件       │       │ 核心 generic     │
          │                  │       │ seams           │
          │ • 检测逻辑       │       │ • 通用接口      │
          │ • onboarding     │       │ • 抽象契约      │
          │ • auth           │       │ • 注册机制      │
          │ • defaults       │       │                 │
          │ • provider 行为  │       │                 │
          └─────────────────┘       └─────────────────┘

    示例:
    ┌──────────────────────────────────────────────────┐
    │ Discord 特定:                                   │
    │   • DM pairing 流程      → Discord 插件          │
    │   • bot token 校验       → Discord 插件          │
    │   • 频道映射             → Discord 插件          │
    │ 通用:                                            │
    │   • DM pairing 接口     → 核心通道适配层        │
    │   • token 校验框架       → SDK 边界             │
    │   • 消息派发内核         → Turn 内核            │
    └──────────────────────────────────────────────────┘
```

### 依赖归属(随运行时归属)

```
    依赖放哪里?取决于谁运行时用它

    情况 1:插件 only 依赖(如渠道 SDK)
    ┌──────────────────────────────────────────────────┐
    │  放在:插件本地 package.json                      │
    │  原因:核心不依赖它,切换/移除插件时核心不受影响  │
    └──────────────────────────────────────────────────┘

    情况 2:核心 import 的依赖(如 TypeBox)
    ┌──────────────────────────────────────────────────┐
    │  放在:根 package.json                            │
    │  原因:核心运行时需要                            │
    └──────────────────────────────────────────────────┘

    情况 3:有意 internalized 的 bundled plugin runtime
    ┌──────────────────────────────────────────────────┐
    │  放在:根 package.json + 进 core dist             │
    │       + bundled-only facade loader               │
    │  原因:随核心发布,但只有这类插件能这样           │
    └──────────────────────────────────────────────────┘
```

## 协作流程

### 一个能力从需求到落地的归属判断

下面追踪"新增一个渠道特定能力"的归属判断全过程,标注每步由哪个组件负责。

```
开发者想新增"Discord 频道特定表情反应映射"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Owner 边界判断                                            │
│    → 这是 Discord 特定的吗?                                 │
│    → 是 → 归 Discord 插件                                    │
│    → 否 → 归核心 generic seams                               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 边界规则检查                                              │
│    → 能力放在 Discord 插件内                                 │
│    → 插件通过 SDK 边界访问核心(不直接 import 核心)          │
│    → 不 import 其他插件                                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 依赖归属判断                                              │
│    → 如果需要 Discord SDK 依赖 → 放插件本地 package.json     │
│    → 如果需要核心已有依赖 → 复用,不重复添加                 │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 通用 seam 评估                                            │
│    → 这个能力是否应该有通用接口?                            │
│    → 是 → 核心通道适配层提供 generic seam                    │
│    → 否 → 纯 Discord 特定,不污染核心                       │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 核心保持插件无关

- **为什么**:核心切换插件时不应改变,插件增删不应影响核心
- **怎么做**:核心不内嵌 bundled id、defaults、policy;owner 特定行为放 owner 插件
- **影响**:核心可独立测试,插件可独立发布

### 2. 插件只通过 SDK 边界访问核心

- **为什么**:防止插件与核心内部实现耦合,保证边界稳定
- **怎么做**:插件通过 SDK 接缝、manifest metadata、injected runtime helpers、documented barrels 访问核心
- **影响**:核心内部重构不影响插件,插件作者有稳定的 API 契约

### 3. 核心/tests 不深入插件 internals

- **为什么**:插件 internals 是插件私有的,核心不应依赖
- **怎么做**:核心/tests 用 public barrels、SDK facade、generic contracts,不深入插件源码
- **影响**:插件可自由重构 internals,核心测试不受影响

### 4. 依赖归属随运行时归属

- **为什么**:避免核心承担插件依赖,保持核心精简
- **怎么做**:插件 only 依赖留插件本地;核心 import 依赖放根;internalized bundled plugin 才放根 + dist
- **影响**:依赖树清晰,移除插件时依赖可干净移除

### 5. 每个 scoped 子树有自己的 AGENTS.md

- **为什么**:子树的边界规则需要就近定义,降低协作冲突
- **怎么做**:每个 scoped 目录(插件、通道、SDK 等)有自己的 AGENTS.md,进入子树前必读
- **影响**:规则就近可查,新开发者快速理解子树约束

## 设计观察

### 为什么核心不内嵌 bundled id/defaults/policy

```
错误设计(核心内嵌插件策略):
   核心 ── 内嵌 Telegram 默认配置
   核心 ── 内嵌 OpenAI provider id
   → 切换插件时核心要改,核心被插件绑架

正确设计(核心只暴露 generic seams):
   核心 ── 暴露通用注册机制
   插件 ── 通过 manifest 声明自己的 id/defaults/policy
   → 切换插件时核心不变,插件自管策略
```

### 为什么插件不能互相 import

```
错误设计(插件互相依赖):
   插件 A ──import──► 插件 B 源码
   → 插件 B 重构 internals 会破坏插件 A
   → 插件 B 移除会破坏插件 A
   → 耦合链难以追踪

正确设计(插件隔离):
   插件 A ──► SDK 边界 ◄── 插件 B
   → 插件间通过核心提供的通用契约协作
   → 各插件 internals 私有,可独立重构
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 本文件 — 模块地图与目录职责 |
| [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) | CLI → Gateway 启动流程 |
| [04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/04-agent-runtime.md) | Agent 运行时流程 |
| [05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/05-plugin-system.md) | 插件系统 |
| [06-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/06-channels.md) | 通道系统 |
| [07-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/07-protocol.md) | Gateway 协议与 Schema |
| [08-state.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/08-state.md) | SQLite 状态管理 |
| [09-config.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/09-config.md) | 配置加载与迁移 |
| [10-design-principles.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/10-design-principles.md) | 关键设计原则 |
| [11-assessment.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/11-assessment.md) | 评估与风险点 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 核心运行时 | [src/](file:///d:/DevSpace/person/ai_space/openclaw/src/) |
| Gateway 服务器 | [src/gateway/](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/) |
| Agent 运行时 | [src/agents/](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/) |
| 通道核心 | [src/channels/](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/) |
| 插件加载与注册 | [src/plugins/](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/) |
| SDK 边界 | [src/plugin-sdk/](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/) |
| 状态层 | [src/state/](file:///d:/DevSpace/person/ai_space/openclaw/src/state/) |
| 配置管理 | [src/config/](file:///d:/DevSpace/person/ai_space/openclaw/src/config/) |
| 协议契约 | [packages/gateway-protocol/](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/) |
| 插件实现 | [extensions/](file:///d:/DevSpace/person/ai_space/openclaw/extensions/) |
| UI 前端 | [ui/](file:///d:/DevSpace/person/ai_space/openclaw/ui/) |
| AGENTS.md 硬约束 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
