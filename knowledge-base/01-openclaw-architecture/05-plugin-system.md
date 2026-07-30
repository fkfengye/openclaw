# 05 — 插件系统

> 插件是 OpenClaw 的能力来源:渠道、LLM、工具、生命周期钩子全部以插件形式接入。读完本章你将理解插件如何被发现、加载、注册,以及核心如何在不依赖任何具体插件的前提下运行。

## 一句话定位

插件系统是核心与外部能力的**唯一接缝**:
- 核心运行时不预知有哪些插件,所有能力(Provider / Tool / Channel / Hook)在启动时由插件注册
- 插件只能通过 SDK 边界访问核心,不能反向 import 核心 src 或其他插件
- 加载链路严格分离"控制面"(轻:发现 / 清单 / 校验)与"运行面"(重:实际执行),降低冷启动成本

## 全局协作图

下图展示插件系统内部各组件如何协作,把外部插件仓库变成核心可用的能力表。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      外部插件仓库(extensions/*)                     │
│                                                                      │
│   渠道插件              能力插件              Provider 插件           │
│   Telegram / WhatsApp   browser / canvas      openai / anthropic    │
│   Slack / Discord ...   cron / nodes ...      自托管 / 本地 ...      │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ① 发现器扫描
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      控制面(轻量,启动期)                          │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 发现器      │  │ 来源追溯器  │  │ 清单解析器  │  │ 注册计划  │ │
│   │ (扫描目录)  │  │ (trusted?)  │  │ (manifest)  │  │ (排序)    │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └───────────┘ │
│                                                                      │
│   约束:不 eager import 运行时 barrel,只读轻量元数据               │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ② 运行时按需加载
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      运行面(重量,按需加载)                        │
│                                                                      │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│   │ 运行时加载器│  │ 注册表      │  │ 进程级缓存  │  │ 模块运行时│ │
│   │ (主入口)    │─►│ (按能力分)  │─►│ (process-   │  │ (执行)    │ │
│   │             │  │             │  │  stable)    │  │           │ │
│   └─────────────┘  └──────┬──────┘  └─────────────┘  └───────────┘ │
│                             │                                        │
│                             │ ③ 按能力注册                          │
│            ┌────────────────┼────────────────┐                      │
│            ▼                ▼                ▼                      │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐          │
│   │ Provider     │ │ Tool / Hook  │ │ Network / Memory │          │
│   │ 注册器       │ │ 注册器       │ │ / Host / Ops     │          │
│   │ (LLM 调用)   │ │ (工具/钩子)  │ │ 注册器           │          │
│   └──────────────┘ └──────────────┘ └──────────────────┘          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ ④ 核心消费能力表
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      核心运行时(src/)                              │
│                                                                      │
│   Agent Runner / Turn 内核 / Gateway 编排 都从这里读能力            │
│   约束:核心不 import 插件 src,只读注册表                          │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

插件系统由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **加载器门面** | 对外暴露稳定的公共入口,内部按职责分文件实现 | 仅 re-export,真正逻辑分散在子模块 |
| **发现器** | 扫描 bundled 插件 + 外部 `extensions/*` 目录 | 控制面职责,不 eager import 运行时 barrel |
| **注册表** | 按能力分类注册(Provider / Tool / Hook / Network 等) | 7 类注册器,各自独立 |
| **来源追溯器** | 标记插件来源是 trusted 还是 untrusted | 影响执行隔离与权限授予 |
| **进程级缓存** | 缓存插件元数据,避免重复 stat / read | process-stable,变更需 restart 或显式 reload |
| **Hook 体系** | 覆盖消息 / LLM / 会话 / 回复全生命周期钩子 | 核心只定义触发点,具体行为由插件实现 |

## 关联关系

### 插件与核心的边界

```
   ┌──────────────────────────────────────────────────┐
   │  核心运行时(src/)                              │
   │                                                  │
   │  • Gateway 编排     • Agent Runner              │
   │  • Turn 内核        • 状态层                    │
   │                                                  │
   └──────────────────────┬───────────────────────────┘
                          │
                          │ 插件只能通过 SDK 边界访问
                          │ (禁止反向 import 核心 src)
                          │
   ┌──────────────────────▼───────────────────────────┐
   │  SDK 边界(plugin-sdk/*)                        │
   │                                                  │
   │  • 数百个懒加载接缝(*-runtime.ts)              │
   │  • Provider 入口 / Tool 入口 / Channel 入口     │
   │                                                  │
   └──────────────────────┬───────────────────────────┘
                          │
                          │ 插件通过 SDK 注册能力
                          │ (禁止 import 其他插件 src)
                          │
   ┌──────────────────────▼───────────────────────────┐
   │  外部插件(extensions/*)                       │
   │                                                  │
   │  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
   │  │ 渠道插件 │ │ 能力插件 │ │Provider  │ ...    │
   │  └──────────┘ └──────────┘ └──────────┘         │
   └──────────────────────────────────────────────────┘
```

### 控制面与运行面分离

```
    错误设计:启动时全量加载
    ┌──────────────────────────────────────────────────────┐
    │ Gateway 启动                                         │
    │   └─ eager import 所有插件的运行时 barrel            │
    │      → 冷启动慢                                      │
    │      → --version / --help 也要加载全部插件           │
    │      → 内存占用高                                    │
    └──────────────────────────────────────────────────────┘

    正确设计:控制面轻量,运行面按需
    ┌──────────────────────────────────────────────────────┐
    │ 控制面(启动期,轻):                                │
    │   discovery + manifest 解析 + config 校验 +          │
    │   setup/onboarding hints + activation planning       │
    │   (只读轻量元数据,不 import 运行时 barrel)          │
    │                                                      │
    │ 运行面(按需,重):                                  │
    │   实际插件执行                                       │
    │   (只在真正需要时才加载 heavy 模块)                 │
    └──────────────────────────────────────────────────────┘
```

### Hook 体系覆盖的生命周期

```
   消息生命周期                    Gateway 生命周期
   ════════════                    ══════════════

   ┌─────────────┐                 ┌─────────────────┐
   │ 入站认领    │                 │ Gateway 启动    │
   │ (插件认领   │                 │ (gateway_start) │
   │  消息)      │                 └────────┬────────┘
   └──────┬──────┘                          │
          ▼                                 ▼
   ┌─────────────┐                 ┌─────────────────┐
   │ 会话开始    │                 │ 运行中          │
   └──────┬──────┘                 │ (服务请求)      │
          ▼                         └────────┬────────┘
   ┌─────────────┐                          │
   │ 消息处理    │                          ▼
   └──────┬──────┘                 ┌─────────────────┐
          ▼                         │ Gateway 关闭    │
   ┌─────────────┐                 │ (安全停止所有   │
   │ 上下文压缩  │                 │  钩子链)        │
   │ (如需要)    │                 └─────────────────┘
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ LLM 调用前后│
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ Tool 调用后 │
   │ (同步执行) │
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ 子 Agent    │
   │ (如有)      │
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ 回复派发    │
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ 回复发送    │
   └──────┬──────┘
          ▼
   ┌─────────────┐
   │ 会话结束    │
   └─────────────┘
```

## 协作流程

### 一次插件加载的完整旅程

下面追踪 Gateway 启动时,一个外部插件从被发现到被核心消费的全过程。

```
Gateway 启动阶段 5(插件加载)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 发现器(控制面)                                           │
│    扫描 bundled 插件目录 + extensions/* 外部目录             │
│    → 产出候选插件清单(路径 + manifest 入口)                │
│    约束:只读元数据,不 eager import 运行时 barrel           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 来源追溯器(控制面)                                       │
│    对每个候选插件标记来源:                                  │
│    ├─ trusted(bundled / 官方目录)                          │
│    └─ untrusted(用户自定义 / 第三方)                       │
│    → 影响后续执行隔离与权限授予                              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 清单解析器(控制面)                                       │
│    读取每个插件的 manifest                                   │
│    → 校验 config 合规性                                      │
│    → 生成 setup/onboarding hints                            │
│    → 产出 activation plan(激活计划)                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 运行时加载器(运行面,按需)                               │
│    按激活计划加载 heavy 模块                                 │
│    → 通过 SDK 边界拿到插件运行时入口                         │
│    → 进程级缓存命中则跳过加载                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 注册表(按能力分类注册)                                   │
│    把插件能力分到 7 类注册器:                               │
│    ├─ Provider 注册器   → LLM 调用能力                      │
│    ├─ Tool / Hook 注册器 → 工具与钩子                       │
│    ├─ Operations 注册器 → 操作                              │
│    ├─ Network 注册器    → 网络(含 MCP resolver)           │
│    ├─ Memory 注册器     → 内存                              │
│    ├─ Host 注册器       → 宿主                              │
│    └─ Capabilities 注册器 → 能力声明                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 核心消费能力表                                             │
│    Agent Runner / Turn 内核 / Gateway 编排                   │
│    → 从注册表读 Provider 表 / Tool 表 / Hook 链              │
│    → 核心不 import 插件 src,只读注册表                      │
└──────────────────────────────────────────────────────────────┘
```

### Tool 表的确定性排序(为 Prompt Cache)

```
插件 A 注册 tool-1, tool-2
插件 B 注册 tool-3
         │
         ▼
┌──────────────────────────────────────────────┐
│  Tool 注册表                                 │
│                                              │
│  收集后必须做确定性排序:                    │
│   • 按 plugin id + tool name 排序            │
│   • 相同输入 → 相同顺序                      │
│                                              │
│  为什么?                                     │
│   → Prompt cache 命中率取决于字节级一致      │
│   → 工具描述符顺序变化 → cache miss          │
│   → 描述符缓存保证顺序稳定                   │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
              LLM 请求 payload
              (tools 字段顺序确定)
                   │
                   ▼
              Prompt cache 命中率高
              (相同会话历史 + 相同工具表
               → 相同 cache key)
```

## 关键设计约束

### 1. 控制面与运行面分离

- **为什么**:控制面(发现 / 清单 / 校验)是轻量操作,启动期就要跑;运行面(实际执行)是重量操作,只在需要时才加载。混在一起会导致冷启动慢、`--version` 也要加载全部插件。
- **怎么做**:发现、清单解析、config 校验、setup/onboarding hints、activation planning 全部留在控制面,只读轻量元数据;实际插件执行留在运行面,通过懒加载接缝按需加载。
- **影响**:启动快,`--version` / `--help` 不触发插件加载;但要求插件作者区分 light / heavy 两个 runtime surface。

### 2. 插件只能通过 SDK 边界访问核心

- **为什么**:防止插件反向耦合核心实现,保证核心可独立演进。
- **怎么做**:插件 prod 代码禁止 import 核心 `src/**`、`src/plugin-sdk-internal/**`、其他插件 `src/**`、相对路径跨包。只能通过 `openclaw/plugin-sdk/*` 进入。
- **影响**:核心重构不影响插件(只要 SDK 契约不变);插件作者只能用 SDK 暴露的能力,无法走捷径。

### 3. 元数据 process-stable,不做 freshness polling

- **为什么**:Gateway 运行时插件元数据(installs / manifests / catalogs / generated paths)是进程内稳定的,每次请求都 stat / realpath / reread / hash 会拖慢 hot path。
- **怎么做**:复用启动时建立的快照、安装记录、发现结果、查找表;插件元数据变更需要 restart 或显式 owner reload / install / doctor flow。
- **影响**:hot path 不做 freshness 校验,性能稳定;但插件热更新需要显式流程,不能自动感知。

### 4. Hook 全链路覆盖,核心只定义触发点

- **为什么**:把可扩展点从核心剥离,让插件能在消息 / LLM / 会话 / 回复各阶段注入行为,而不需要改核心。
- **怎么做**:核心在固定位置触发 Hook(入站认领、会话开始、消息处理、上下文压缩、LLM 前后、Tool 调用后、子 Agent、回复派发、回复发送、会话结束、Gateway 启停);具体行为由插件实现。
- **影响**:插件可深度介入处理链路;但 Hook 顺序与契约必须稳定,否则插件间会互相干扰。

### 5. Provider 系统不绑定特定厂商

- **为什么**:让 Agent Runner 不预知用哪个 LLM,切换厂商(OpenAI / Anthropic / 本地)只换 Provider 插件,核心不变。
- **怎么做**:Provider 由插件提供,通过注册表注入 Agent Runner;模型路由、思考层级、OAuth 流程、自托管设置都由 Provider 运行时内部处理。
- **影响**:同一 Agent 可配不同 Provider;但 Provider 契约(类型 / 传输 / 策略表面)是 SDK 公共契约,变更需 deprecation 窗口。

### 6. Codex 已折叠入 openai,不新增独立路由

- **为什么**:历史上有独立的 `openai-codex` provider / plugin / auth / model 路由,现在统一到 `openai` 下,减少重复 surface。
- **怎么做**:不再有 live `openai-codex` provider / plugin / auth / model 路由,只作为 legacy 输入处理;doctor / migrations 负责修复 stale `openai-codex/*` 配置。
- **影响**:Provider 表面更收敛;但历史配置需要 doctor 迁移,不能在 runtime 静默兼容。

## 设计观察

### 为什么加载器门面只做 re-export

```
错误设计:单文件巨型加载器
   loader.ts(2000+ LOC)
   ├─ discovery 逻辑
   ├─ runtime load 逻辑
   ├─ registry 逻辑
   ├─ cache 逻辑
   └─ provenance 逻辑
   → 单文件难维护,难测试,职责混乱

正确设计:门面 + 分文件
   loader.ts(仅 re-export,稳定公共入口)
   ├─ discovery 子模块      (发现)
   ├─ runtime-load 子模块   (主加载)
   ├─ runtime-registry 子模块 (注册表)
   ├─ cache 子模块          (缓存)
   └─ provenance 子模块     (来源追溯)
   → 每个文件职责单一,可独立测试
   → 外部调用方只看门面,内部重构不影响调用方
```

### 为什么 Tool 描述符要缓存

```
错误设计:每次 LLM 请求重新构建工具描述
   Agent Runner
   └─ 每次请求 → 遍历 Tool 注册表 → 构建 JSON 描述符
      → 顺序可能不稳定(Map 迭代顺序)
      → prompt cache 永远 miss
      → 每次请求都全量发送工具表

正确设计:描述符缓存 + 确定性排序
   Tool 注册表
   └─ 描述符缓存(按 plugin id + tool name 排序)
      → 顺序确定性保证
      → 相同输入 → 相同字节 → prompt cache 命中
      → 节省 token 与延迟
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
| [02-module-map.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/02-module-map.md) | 模块地图与目录职责 |
| [03-startup-flow.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/03-startup-flow.md) | CLI → Gateway 启动流程 |
| [04-agent-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/04-agent-runtime.md) | Agent 运行时流程 |
| [05-plugin-system.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/05-plugin-system.md) | 本文件 — 插件系统 |
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
| 加载器门面(公共入口) | [src/plugins/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader.ts) |
| 发现器 | [src/plugins/loader-discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-discovery.ts) |
| 运行时加载器(主入口) | [src/plugins/loader-runtime-load.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-runtime-load.ts) |
| 运行时注册表 | [src/plugins/loader-runtime-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-runtime-registry.ts) |
| CLI 命令组注册 | [src/plugins/loader-cli-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cli-registry.ts) |
| 进程级缓存 | [src/plugins/loader-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cache.ts) |
| 来源追溯 | [src/plugins/loader-provenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-provenance.ts) |
| 注册表(按能力分) | [src/plugins/registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry.ts) |
| Tool / Hook 注册器 | [src/plugins/registry-registrars-tools-hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-tools-hooks.ts) |
| Provider 注册器 | [src/plugins/registry-registrars-providers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-providers.ts) |
| Provider 运行时入口 | [src/plugins/provider-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime.ts) |
| 模型路由 | [src/plugins/provider-model-routes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-model-routes.ts) |
| Tool 注册入口 | [src/plugins/tools.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tools.ts) |
| Tool 描述符缓存 | [src/plugins/tool-descriptor-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tool-descriptor-cache.ts) |
| Hook:消息收发 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runMessageSending/runMessageSent) |
| Hook:LLM 调用前后 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runModelCallStarted/runLlmInput/runLlmOutput) |
| Hook:会话生命周期 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runSessionStart/runSessionEnd) |
| Hook:回复派发 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runReplyDispatch) |
| Hook:Gateway 生命周期 | [src/plugins/hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/hooks.ts)(runGatewayStart/runGatewayStop) |
| 公共表面:加载侧 | [src/plugins/public-surface-loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/public-surface-loader.ts) |
| 公共表面:运行时 | [src/plugins/public-surface-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/public-surface-runtime.ts) |
| 插件目录边界规则 | [src/plugins/AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/AGENTS.md) |
| SDK 入口 | [src/plugin-sdk/entrypoints.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/entrypoints.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
