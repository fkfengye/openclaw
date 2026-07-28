# 01 — 顶层定位与规模

## 产品定位

OpenClaw 是**本地优先的个人 AI 助手 Gateway**,而非简单的 CLI 聊天工具。

- [package.json](file:///d:/DevSpace/person/ai_space/openclaw/package.json#L1-L9):
  - `"name": "openclaw"`
  - `"description": "Multi-channel AI gateway with extensible messaging integrations"`
  - 版本 `2026.7.2`
  - `"openclaw": { "schemaVersions": { "state": 6, "agent": 16 } }` — 状态库已演进到第 6 代、Agent 库到第 16 代,说明项目有显著历史沉淀。
- [README.md](file:///d:/DevSpace/person/ai_space/openclaw/README.md#L17-L22):"OpenClaw is a personal AI assistant that learns and grows with you, running on your own devices"。Gateway 是 control plane,产品本身是 assistant。
- 已支持 25+ 渠道(WhatsApp/Telegram/Slack/Discord/Signal/iMessage/SMS/Teams/Matrix/Feishu/LINE/QQ 等),渠道列表见 [README.md](file:///d:/DevSpace/person/ai_space/openclaw/README.md#L22)。

## 技术栈

| 维度 | 选型 | 证据 |
|---|---|---|
| 语言 | TypeScript(严格模式,ESM) | AGENTS.md "Code" 段:"TS ESM, strict. Avoid any" |
| 运行时 | Node 22.22.3+ / 24.15+ / 25.9+ | AGENTS.md "Commands" 段 |
| 包管理 | pnpm + hoisted linker | [pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml#L115) |
| 构建 | rolldown + esbuild | [pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml#L75-L109) |
| 格式化 | oxfmt(非 Prettier) | AGENTS.md "Commands" 段 |
| Lint | oxlint | AGENTS.md "Commands" 段 |
| 测试 | Vitest(colocated `*.test.ts`) | AGENTS.md "Tests" 段 |
| Schema | TypeBox(`@sinclair/typebox`) | [packages/gateway-protocol/src/schema/](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/schema) |
| 数据库 | SQLite(Kysely helpers) | AGENTS.md "Architecture" 段 |
| 协议 | 自研 WebSocket 协议(v4) | [packages/gateway-protocol/src/version.ts](file:///d:/DevSpace/person/ai_space/openclaw/packages/gateway-protocol/src/version.ts) |

## 工作区结构

[pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml#L1-L7):

```yaml
packages:
  - .              # 核心 openclaw 包
  - ui             # Control UI 前端(独立子包)
  - packages/*     # 子包,如 gateway-protocol
  - extensions/*   # 插件(渠道 + 工具)
  - examples/*     # 示例
```

## 依赖治理

[pnpm-workspace.yaml](file:///d:/DevSpace/person/ai_space/openclaw/pnpm-workspace.yaml#L8-L150):

- `minimumReleaseAge: 2880`(48 小时冷却期) — 防止刚发布的有问题包进入。
- `minimumReleaseAgeExclude` 白名单约 80 项,多为 AWS SDK、esbuild 原生二进制、必需紧密跟踪的包。
- `blockExoticSubdeps: true` — 阻止外部 subdep 注入。
- `overrides` 锁定关键依赖版本(如 `axios: 1.18.1`、`hono: 4.12.31`、`tar: 7.5.20`)。
- `allowBuilds` 显式批准可构建包(node-pty、esbuild、baileys 等)。

## 项目规模信号

- `src/gateway/` 下 `server-*.ts` 已超 200 个文件(以 `server-startup-*.ts`、`server-runtime-*.ts`、`server-reload-*.ts`、`server-cron-*.ts` 等细分),反映 Gateway 启动流程被极度拆分。
- `src/plugins/` 下含 `loader-*.ts`、`registry-*.ts`、`registry-registrars-*.ts`、`provider-*.ts`、`wired-hooks-*.ts` 等,插件子系统本身已是一个独立工程。
- `src/plugin-sdk/` 数百个 `*-runtime.ts` 文件,SDK 表面积巨大。
- `extensions/` 渠道与工具插件各为独立 npm 子包。

## 与上游的关系

- AGENTS.md "Dependency-touching work" 段:**OpenAI Codex 相关工作必须 agent 亲自检查 `../codex` 源码**,subagent 报告、PR 文本、wrapper 都不满足该 gate。
- Codex 已折叠入 `openai` provider,不再有独立 `openai-codex` 路由(AGENTS.md "Architecture" 段)。
- 安装器在 sibling `../openclaw.ai` 仓库(AGENTS.md "Map" 段)。

## 架构图与流程图

### 技术栈分层依赖图

```
┌─────────────────────────────────────────────────────────────────┐
│                    协议层(Protocol Layer)                       │
│            packages/gateway-protocol (TypeBox schemas)           │
└───────────────────────────────┬─────────────────────────────────┘
                                │ 依赖
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    运行时层(Runtime Layer)                       │
│                      Node.js 22.22.3+ / 24.15+ / 25.9+           │
│                      TypeScript ESM(strict)                     │
└───────────────────────────────┬─────────────────────────────────┘
                                │ 依赖
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  基础设施层(Infrastructure)                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ pnpm hoisted │  │ rolldown +   │  │ SQLite (Kysely)      │  │
│  │ (包管理)      │  │ esbuild(构建)│  │ (状态存储)            │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ oxfmt(格式)  │  │ oxlint(lint) │  │ Vitest(测试)         │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 工作区包结构图

```
                    openclaw (root, package.json v2026.7.2)
                            │
        ┌──────────┬───────┴───────┬────────────┬──────────┐
        ▼          ▼               ▼            ▼          ▼
   ┌────────┐ ┌────────┐  ┌──────────────┐ ┌────────┐ ┌────────┐
   │   .    │ │   ui   │  │  packages/*  │ │  ext/* │ │ examp/*│
   │ (核心) │ │(UI 前端)│  │ (子包,如     │ │ (插件) │ │ (示例) │
   │        │ │        │  │  gateway-    │ │        │ │        │
   │ src/   │ │        │  │  protocol)   │ │ 25+    │ │        │
   │ agents/│ │        │  │              │ │ 渠道   │ │        │
   │ gateway│ │        │  │              │ │ + 工具 │ │        │
   │ plugins│ │        │  │              │ │        │ │        │
   │channels│ │        │  │              │ │        │ │        │
   └────────┘ └────────┘  └──────────────┘ └────────┘ └────────┘
        │                                              │
        │             sibling 仓库(独立)               │
        │                  ▼                            │
        │     ┌──────────────────────────┐               │
        │     │  ../openclaw.ai          │               │
        │     │  (安装器:install.sh /    │               │
        │     │   install.ps1)          │               │
        │     └──────────────────────────┘               │
        │                                                  │
        │             依赖 gate(必须)                      │
        │                  ▼                              │
        │     ┌──────────────────────────┐               │
        └────►│  ../codex (OpenAI Codex)  │◄──────────────┘
              │  Codex 相关工作必须 agent  │
              │  亲自检查源码,subagent    │
              │  报告不满足 gate           │
              └──────────────────────────┘
```

### 依赖治理示意图

```
pnpm-workspace.yaml 治理规则:

  minimumReleaseAge: 2880 (48h 冷却)
       │
       │ 例外(minimumReleaseAgeExclude,约 80 项):
       ├─ AWS SDK(紧密跟踪)
       ├─ esbuild 原生二进制(平台必需)
       ├─ @openai/codex(上游)
       ├─ @aws-sdk/*、@smithy/*
       ├─ @oxlint/*、@oxfmt/*、@rolldown/*
       └─ baileys、libsignal 等渠道 SDK
       │
       ▼
  blockExoticSubdeps: true(阻止外部 subdep 注入)
       │
       ▼
  overrides(锁定关键版本):
       ├─ axios: 1.18.1
       ├─ hono: 4.12.31
       ├─ tar: 7.5.20
       ├─ tough-cookie: 4.1.4
       ├─ @anthropic-ai/sdk: 0.112.3
       └─ ... 共 20+ 项
       │
       ▼
  allowBuilds(显式批准构建):
       ├─ node-pty: true
       ├─ esbuild: true
       ├─ baileys: true
       ├─ protobufjs: true
       ├─ koffi: false(禁构建)
       └─ node-llama-cpp: false(禁构建)
```

### 项目规模信号图

```
                    规模信号(基于源码统计)
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐      ┌───────────┐      ┌───────────┐
   │ Gateway  │      │  Plugins  │      │ Plugin-SDK│
   │ server-* │      │  loader-* │      │ *-runtime │
   │  200+    │      │ registry-*│      │  数百个    │
   │  文件    │      │ provider-*│      │   文件    │
   └─────────┘      └───────────┘      └────────────┘
        │                  │                  │
        ▼                  ▼                  ▼
   ┌─────────────────────────────────────────────────┐
   │  Schema 版本演进:                                │
   │  • state DB: v6(6 代演进)                       │
   │  • agent DB: v16(16 代演进)                     │
   │  • 累积迁移代码可观(*-migration.ts、*-backfills.ts)│
   └─────────────────────────────────────────────────┘
```
