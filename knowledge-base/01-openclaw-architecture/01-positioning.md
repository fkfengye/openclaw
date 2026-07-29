# 01 — 顶层定位与技术栈

> 这是知识库的第一章。读完本章你将理解:OpenClaw 是什么、用了哪些技术、工作区如何组织、依赖如何治理。

## 一句话定位

OpenClaw 是**本地优先的多渠道个人 AI 助手 Gateway**:
- 不是简单的 CLI 聊天工具,而是运行在用户自有设备上的控制平面
- 自研 WebSocket 协议连接所有客户端,SQLite 作为唯一状态层
- 25+ 渠道与能力以插件形式接入,核心保持插件无关

## 全局协作图

下图展示 OpenClaw 的技术栈分层与工作区组织。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       产品层(Product Layer)                          │
│                                                                      │
│   多渠道 AI 助手(Gateway 是控制平面,产品本身是 assistant)         │
│   25+ 渠道:WhatsApp/Telegram/Slack/Discord/Signal/iMessage/...      │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       协议层(Protocol Layer)                        │
│                                                                      │
│   自研 WebSocket 协议(v4)+ TypeBox Schema 契约                     │
│   独立子包,不依赖核心 session 类型                                  │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       运行时层(Runtime Layer)                        │
│                                                                      │
│   Node.js(22.22.3+ / 24.15+ / 25.9+)                                │
│   TypeScript ESM(strict 模式,禁止 any)                             │
└──────────────────────────────────────┬───────────────────────────────┘
                                       │
                                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  基础设施层(Infrastructure Layer)                    │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐      │
│   │ 包管理       │  │ 构建         │  │ 状态存储             │      │
│   │ pnpm hoisted │  │ rolldown +   │  │ SQLite + Kysely      │      │
│   │ (依赖治理)   │  │ esbuild      │  │ (唯一状态层)         │      │
│   └──────────────┘  └──────────────┘  └──────────────────────┘      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐      │
│   │ 格式化       │  │ Lint         │  │ 测试                 │      │
│   │ oxfmt        │  │ oxlint       │  │ Vitest(colocated)    │      │
│   └──────────────┘  └──────────────┘  └──────────────────────┘      │
└──────────────────────────────────────────────────────────────────────┘

    上游关系(独立仓库,需单独检查):

    ┌──────────────────────────┐    ┌──────────────────────────┐
    │  安装器仓库(sibling)    │    │  Codex 仓库(sibling)     │
    │  install.sh / install.ps1│    │  Codex 相关工作必须       │
    │  (独立维护)              │    │  agent 亲自检查源码       │
    └──────────────────────────┘    └──────────────────────────┘
```

## 组件清单

OpenClaw 的技术栈与工作区由 6 类组件构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **产品层** | 定义 OpenClaw 是什么:本地优先的个人 AI 助手 Gateway | Gateway 是控制平面,产品本身是 assistant |
| **协议层** | 自研 WebSocket 协议 + TypeBox Schema 契约 | 独立子包,版本 bump 需 owner 显式确认 |
| **运行时层** | Node.js + TypeScript ESM,承载所有运行时逻辑 | strict 模式,禁止 any,禁止 @ts-nocheck |
| **基础设施层** | 包管理、构建、存储、格式化、lint、测试 | SQLite 唯一状态层,oxfmt 非 Prettier |
| **工作区结构** | monorepo 组织:核心包 + UI 子包 + 协议子包 + 插件 + 示例 | 插件独立 npm 子包,核心不内嵌插件 |
| **依赖治理** | pnpm hoisted + 冷却期 + 白名单 + overrides + 构建批准 | 48 小时冷却期,阻止外部 subdep 注入 |

## 关联关系

### 工作区包结构

```
                    openclaw (根包)
                            │
        ┌──────────┬───────┴───────┬────────────┬──────────┐
        ▼          ▼               ▼            ▼          ▼
   ┌────────┐ ┌────────┐  ┌──────────────┐ ┌────────┐ ┌────────┐
   │  核心  │ │  UI    │  │  协议子包    │ │ 插件   │ │ 示例   │
   │  包    │ │ 子包   │  │  (独立)      │ │ 子包   │ │        │
   │        │ │        │  │              │ │        │ │        │
   │ • src/ │ │Control │  │ • TypeBox    │ │25+渠道 │ │        │
   │ • agents│ │  UI    │  │ • 校验器     │ │ +工具  │ │        │
   │ • gateway││        │  │ • 迁移 API   │ │        │ │        │
   │ • plugins││        │  │              │ │        │ │        │
   │ • channels││       │  │              │ │        │ │        │
   └────────┘ └────────┘  └──────────────┘ └────────┘ └────────┘
        │
        │  sibling 仓库(独立)
        ▼
   ┌──────────────────────────┐
   │  安装器仓库              │
   │  install.sh / install.ps1│
   └──────────────────────────┘
```

### 依赖治理策略

```
    依赖进入工作区的决策流程:

    新依赖发布
         │
         ▼
    ┌──────────────────────────────────────────────┐
    │ 是否过 48 小时冷却期?                        │
    │                                              │
    │  ├─ 否 → 拒绝(防止刚发布的有问题包进入)    │
    │  │                                          │
    │  └─ 是 → 继续                               │
    └──────────────────────┬───────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────┐
    │ 是否在白名单内?                              │
    │ (AWS SDK / esbuild / 渠道 SDK 等约 80 项)    │
    │                                              │
    │  ├─ 是 → 豁免冷却期(紧密跟踪上游)          │
    │  │                                          │
    │  └─ 否 → 走冷却期检查                        │
    └──────────────────────┬───────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────┐
    │ 是否触发外部 subdep 注入?                    │
    │                                              │
    │  ├─ 是 → 拒绝(blockExoticSubdeps: true)    │
    │  │                                          │
    │  └─ 否 → 继续                               │
    └──────────────────────┬───────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────┐
    │ 是否需要构建?(node-pty / esbuild / ...)    │
    │                                              │
    │  ├─ 是 → 需显式批准(allowBuilds 白名单)    │
    │  │                                          │
    │  └─ 否 → 通过                               │
    └──────────────────────────────────────────────┘
```

### 依赖归属与运行时归属对齐

```
    依赖该放哪里?取决于谁运行时用它

    错误设计(依赖与运行时归属错位):
    ┌──────────────────────────────────────────────────┐
    │  渠道 SDK(如 baileys)放进根 package.json        │
    │  → 核心被迫承担插件依赖                          │
    │  → 切换/移除插件时核心受影响                     │
    └──────────────────────────────────────────────────┘

    正确设计(依赖随运行时归属):
    ┌──────────────────────────────────────────────────┐
    │  插件 only 依赖 → 插件本地 package.json          │
    │  核心 import 依赖 → 根 package.json              │
    │  有意 internalized 的 bundled plugin → 根 + dist │
    └──────────────────────────────────────────────────┘
```

## 协作流程

### 一次依赖引入的完整旅程

下面追踪一个新依赖从评估到进入工作区的全过程,标注每步由哪个组件负责。

```
开发者想引入新依赖
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 依赖治理层                                                │
│    评估依赖是否过冷却期、是否需要白名单豁免                  │
│    → 检查是否会被外部 subdep 注入                            │
│    → 检查是否需要显式构建批准                                │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 运行时归属判断                                            │
│    → 谁运行时用这个依赖?                                    │
│    ├─ 插件 only → 放插件本地 package.json                    │
│    ├─ 核心 import → 放根 package.json                        │
│    └─ internalized bundled plugin → 放根 + 进 dist            │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 版本锁定                                                  │
│    → 关键依赖进 overrides 锁定版本                           │
│    → pnpm-workspace.yaml 记录治理规则                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 安装与验证                                                │
│    → pnpm install                                            │
│    → 构建、测试、lint 验证                                   │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. SQLite 是唯一状态层

- **为什么**:杜绝散落 JSON 文件,所有运行时状态集中管理,数据一致性强
- **怎么做**:所有状态、缓存、队列、注册表都存 SQLite,禁止 JSON/JSONL/TXT/sidecar 文件
- **影响**:进程重启后状态可恢复,迁移路径单一明确

### 2. 协议层独立于核心

- **为什么**:协议 schema 变更不应影响核心 session 类型,避免循环依赖
- **怎么做**:协议子包提供独立的结构化结果类型,不依赖核心 session 类型
- **影响**:第三方可仅引用子包做协议校验,核心可单独引用协议

### 3. TypeScript strict 模式

- **为什么**:类型安全是工程纪律的基础,降低运行时错误
- **怎么做**:strict 模式,禁止 any,禁止 @ts-nocheck,用 discriminated union 而非 freeform string
- **影响**:编译期捕获更多错误,代码可维护性高

### 4. 依赖治理严格

- **为什么**:防止有问题的依赖进入工作区,降低供应链风险
- **怎么做**:48 小时冷却期 + 白名单豁免 + 阻止外部 subdep + 构建批准 + 关键依赖 overrides 锁定
- **影响**:依赖引入成本高但安全,新发布包需等待冷却

### 5. 工作区按职责分包

- **为什么**:清晰边界利于长期演进和分工
- **怎么做**:核心包 + UI 子包 + 协议子包 + 插件子包 + 示例,各包独立
- **影响**:插件可独立发布,核心不被插件绑架

## 设计观察

### 为什么用 SQLite 而非文件存储

```
错误设计(散落文件存储):
   状态 → JSON 文件
   缓存 → JSONL 文件
   队列 → TXT 文件
   cursor → sidecar 文件
   → 文件散落各处,一致性难保证,迁移复杂

正确设计(SQLite 唯一):
   所有运行时状态 → SQLite(共享 DB + per-agent DB)
   → 集中管理,事务保证一致性,迁移单一 owner
   → 旧文件格式只在 doctor 迁移代码中出现
```

### 为什么用 TypeBox 而非 zod 定义协议

```
TypeBox(协议层选型):
   • 结构化 + 类型推导友好
   • 编译期优化更好
   • 适合协议 schema 定义

zod(外部边界选型):
   • 运行时校验强
   • 适合 user input / external API / file IO

→ 协议层用 TypeBox,外部边界用 zod,各取所长
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 本文件 — 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 模块地图与目录职责 |
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
| 根包配置 | [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json) |
| 工作区与依赖治理 | [pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml) |
| TypeScript 配置 | [tsconfig.json](file:///d:/DevSpace/person/ai_space/openclaw/tsconfig.json) |
| AGENTS.md 硬约束 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
| 项目说明 | [README.md](file:///d:/DevSpace/person/ai_space/openclaw/README.md) |
