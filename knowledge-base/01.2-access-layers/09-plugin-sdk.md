# 09 — Plugin SDK 接入(插件作者)

> 读完本章你将理解:插件作者如何通过 SDK 边界接入 OpenClaw 核心,以及为什么插件只能经由 SDK 子路径、manifest 元数据、注入式运行时助手访问核心,而不能直接导入核心内部代码。

## 一句话定位

Plugin SDK 是插件作者与 OpenClaw 核心之间的唯一接入面:插件以 Node.js ESM 包形式导入 SDK 子路径,通过 manifest 声明能力、通过注入式运行时助手调用核心;SDK 边界严格隔离插件代码与核心内部,确保核心可演进、插件可独立维护。

## 全局协作图

下图展示一个插件从编写、加载、注册到运行时调用的完整链路。**先看这张图建立心智模型,再读细节**。

```
              插件作者
                  │
                  │ 编写插件包(声明 manifest + 实现入口)
                  ▼
   ┌──────────────────────────────────────┐
   │      插件包(extensions/<id>/)       │
   │                                      │
   │  职责:                               │
   │  • 通过 SDK 子路径导入核心能力        │
   │  • 声明 manifest(ID/capabilities/   │
   │    hooks)                            │
   │  • 实现入口(setup 回调)            │
   │  • 注册 tools/providers/hooks        │
   │                                      │
   │  禁止:                               │
   │  • 直接 import 核心 src/**           │
   │  • import 内部 SDK                    │
   │  • import 其他插件内部                │
   │  • 相对路径出包                       │
   └───────────────────┬──────────────────┘
                       │ SDK 子路径(import 边界)
                       ▼
   ┌──────────────────────────────────────┐
   │      Plugin SDK 边界                 │
   │      (openclaw/plugin-sdk/*)        │
   │                                      │
   │  • 入口契约(plugin/channel/provider)│
   │  • 核心 API barrel                   │
   │  • 数百个懒加载接缝                  │
   │  • Facade SDK(特定平台简化封装)    │
   └───────────────────┬──────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────┐
   │      Facade 加载器                   │
   │      (核心入口,插件不能绕过)       │
   │                                      │
   │  • 发现插件                           │
   │  • 加载运行时                         │
   │  • 注入运行时助手                     │
   │  • 注册到注册中心                     │
   └───────────────────┬──────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────┐
   │      核心注册中心                    │
   │                                      │
   │  • tools / providers / network       │
   │  • memory / hooks / capabilities     │
   │  • operations                        │
   └───────────────────┬──────────────────┘
                       │
                       ▼
   ┌──────────────────────────────────────┐
   │      运行时调用                      │
   │                                      │
   │  • 插件通过注入助手回调核心能力      │
   │  • 核心 hooks 触发插件回调           │
   └──────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **SDK 入口集** | 暴露 plugin-sdk/* 子路径,声明可用接缝 | 子路径列表由构建产物驱动,变更影响外部插件作者 |
| **Manifest 元数据** | 声明插件 ID、capabilities、hooks | 声明式描述,与运行时逻辑解耦 |
| **Facade 加载器** | 发现、加载、注册插件 | 核心入口,插件不能绕过 |
| **注册中心** | 注册 tools/providers/network/hooks 等能力 | 按能力分类的 registrar |
| **注入式运行时助手** | 加载器注入给插件的核心能力句柄 | 插件通过它回调核心,不直接 import 核心 |
| **Facade SDK** | 为特定平台(Discord/Matrix/Telegram)提供简化封装 | 减少重复适配代码 |

## 关联关系

### SDK 边界规则:允许 vs 禁止

```
   ┌──────────────────────────────────────────────────────┐
   │              SDK 边界规则                             │
   │                                                      │
   │  允许(插件 → SDK 接缝):                            │
   │  • 插件 ──► SDK 子路径(plugin-sdk/*)               │
   │  • 插件 ──► manifest 元数据(声明式描述)            │
   │  • 插件 ──► 注入式运行时助手                         │
   │  • 插件 ──► 文档化 barrel(核心 API 入口)           │
   │                                                      │
   │  禁止(插件 → 核心内部):                            │
   │  • 插件 ──X──► 核心内部源码(src/**)                │
   │  • 插件 ──X──► 内部 SDK(plugin-sdk-internal/**)    │
   │  • 插件 A ──X──► 插件 B 内部源码                    │
   │  • 插件 ──X──► 相对路径出包                         │
   └──────────────────────────────────────────────────────┘
```

### Manifest 声明与运行时逻辑的分离

```
   ┌─────────────────────────┐    ┌─────────────────────────┐
   │   Manifest 元数据        │    │   运行时入口(setup)    │
   │   (声明式)              │    │   (命令式)              │
   │                         │    │                         │
   │   • 插件 ID             │    │   • 注册 tools          │
   │   • capabilities        │    │   • 注册 hooks          │
   │   • hooks 声明          │    │   • 注册 providers       │
   │   • 依赖关系            │    │   • 绑定回调             │
   │                         │    │                         │
   │   → 加载器先读 manifest │    │   → 加载器注入助手后     │
   │     判断能力与兼容性    │    │     执行 setup          │
   └─────────────────────────┘    └─────────────────────────┘
              │                              │
              └──────────────┬───────────────┘
                             ▼
              加载器把两者结合,注册到核心
```

### 懒加载接缝的分层

```
   SDK 边界内部接缝分层:

   ┌──────────────────────────────────────┐
   │ 入口契约层(立即加载)               │
   │  • 插件入口契约                      │
   │  • 渠道入口契约                      │
   │  • Provider 入口契约                 │
   │  → 插件 import 时即解析             │
   └──────────────────┬───────────────────┘
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ 核心 API barrel(按需)              │
   │  • 核心 API 聚合入口                 │
   │  → 插件调用时加载                    │
   └──────────────────┬───────────────────┘
                      │
                      ▼
   ┌──────────────────────────────────────┐
   │ 懒加载接缝(数百个)                 │
   │  • 各能力专属运行时接缝              │
   │  → 首次使用时加载,减少冷启动成本    │
   └──────────────────────────────────────┘
```

## 协作流程

### 一次插件接入的完整旅程

下面追踪一个插件从编写到运行时被调用的全过程,标注每步由哪个组件负责。

```
插件作者编写插件
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 编写插件包                                                │
│    • 声明 manifest(插件 ID、capabilities、hooks)           │
│    • 实现入口(通过 SDK 子路径导入并导出默认入口)          │
│    • 依赖 openclaw(workspace)                                │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 插件通过 SDK 边界接入                                     │
│    • 只从 SDK 子路径导入(不碰核心内部)                     │
│    • 入口契约提供类型化注册函数                              │
│    (插件不直接 import 核心 src/**)                          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Facade 加载器加载插件                                     │
│    • 发现插件包                                              │
│    • 读取 manifest 判断能力与兼容性                          │
│    • 加载运行时                                              │
│    • 注入运行时助手给插件                                    │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 注册到核心注册中心                                        │
│    • 按能力分类注册:tools/providers/network/hooks/...       │
│    • 插件 setup 回调执行,绑定 hooks                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 运行时调用                                                │
│    • 核心 hooks 触发时,回调到插件注册的回调函数             │
│    • 插件通过注入式运行时助手调用核心能力                   │
│    • (插件永远不直接 import 核心,只走助手)                 │
└──────────────────────────────────────────────────────────────┘
```

### Facade SDK 为特定平台简化

| Facade | 平台 | 作用 |
|---|---|---|
| Discord Facade | Discord | 简化 Discord bot 适配 |
| Matrix Facade | Matrix | 简化 Matrix 客户端适配 |
| Telegram Account Facade | Telegram Account | 简化 Telegram 账号接入 |

## 关键设计约束

### 1. SDK 是唯一接入面

- **为什么**:核心需要可演进,插件需要独立维护;若插件直接依赖核心内部,核心任何重构都会破坏所有插件
- **怎么做**:插件只能经由 SDK 子路径、manifest 元数据、注入式运行时助手、文档化 barrel 访问核心
- **影响**:核心内部可自由重构,只要 SDK 边界契约稳定

### 2. 禁止直接导入核心内部

- **为什么**:核心内部(src/**、内部 SDK)不是公开契约,随时变化
- **怎么做**:加载器与构建产物强制隔离;插件 import 核心内部源码、内部 SDK、其他插件内部、相对路径出包均为禁止
- **影响**:插件作者只能在 SDK 边界内工作,强制解耦

### 3. shipped API 兼容性

- **为什么**:已发布的外部插件依赖 SDK 表面,破坏性变更会断裂生态
- **怎么做**:shipped external API 变更需"新 API + 命名兼容/废弃 + 移除计划",内部/bundled 调用者在同一变更内迁移到新 API
- **影响**:SDK 表面演进缓慢且谨慎,内部兼容不会成为永久架构

### 4. 懒加载接缝减少冷启动

- **为什么**:数百个接缝全量加载会拖慢启动
- **怎么做**:入口契约立即加载,核心 API barrel 按需加载,各能力运行时接缝首次使用时加载
- **影响**:插件按需付出加载成本,启动快

### 5. Facade SDK 与 Host 运行时分工

- **为什么**:特定平台适配重复(签名、格式、回调),Facade 能收敛;核心能力注入由 Host 运行时负责
- **怎么做**:Facade SDK 为 Discord/Matrix/Telegram 提供简化封装;Host 运行时注入核心能力助手
- **影响**:平台适配代码集中,核心注入职责清晰

## 设计观察

### 为什么插件不能直接 import 核心 src/**

```
错误设计:
   插件直接 import 核心内部源码
   → 核心重构该文件,插件断裂
   → 核心无法自由演进,被插件反向绑架

正确设计:
   插件只 import SDK 子路径(openclaw/plugin-sdk/*)
   核心 src/** 可自由重构,只要 SDK 边界契约稳定
   → 核心可演进,插件可独立维护
```

### 为什么用 manifest + 注入式运行时助手

```
错误设计:
   插件自己 import 核心注册中心,直接注册
   → 插件与核心内部结构强耦合,加载顺序难控
   → 核心无法控制注入哪些能力给哪些插件

正确设计:
   插件声明 manifest(能力声明)
   加载器读 manifest,注入受控的运行时助手
   插件通过助手回调核心
   → 加载器是唯一入口,核心可控注入,插件解耦
```

### 为什么 Facade SDK 为特定平台简化

```
错误设计:
   每个 Discord bot 插件都自己实现签名验证、格式转换、回调映射
   → 重复代码,质量参差,平台 API 演进时各插件分别踩坑

正确设计:
   Discord Facade SDK 集中实现 Discord 适配
   插件基于 Facade 构建,只关注业务回调
   → 适配代码集中,平台演进时只更新 Facade
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | 本文件 — Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| SDK 入口集 | [src/plugin-sdk/entrypoints.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/entrypoints.ts) |
| Facade 运行时(懒加载) | [src/plugin-sdk/facade-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/facade-runtime.ts) |
| Host 运行时(注入助手) | [src/plugin-sdk/host-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/host-runtime.ts) |
| 渠道入口契约 | [src/plugin-sdk/channel-entry-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/channel-entry-contract.ts) |
| 插件加载器 | [src/plugins/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader.ts) |
| 注册中心 registrars | [src/plugins/](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/) |
| 插件 SDK 约束说明 | [src/plugin-sdk/AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/AGENTS.md) |
| 插件目录 | [extensions/](file:///d:/DevSpace/person/ai_space/openclaw/extensions/) |
