# 00 — 插件注册表总览

> 这是插件注册表目录的入口。读完本章你将理解:OpenClaw 插件注册表的整体构成、各组件如何分层协作、能力如何从插件被登记到运行时被消费。

## 一句话定位

插件注册表是 OpenClaw 运行时核心的"能力中枢":
- 负责把外部插件的能力(Provider / Tool / Hook / Channel / Web 能力)按类别登记到进程内
- 上层 Agent Runner、Gateway、通道系统通过注册表统一拿到可用能力
- 注册表是进程级稳定快照,运行时热路径不重新发现文件

## 全局协作图

下图展示插件注册表的分层结构与外部上下文。**先看这张图建立心智模型,再读细节章节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          上层调用方                                   │
│                                                                      │
│   Agent Runner    Gateway 启动     通道系统     CLI / Doctor          │
│   (取 Provider/   (启动阶段5加载)  (取渠道)    (install/卸载)        │
│    Tool 表)                                                          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 只读进程内能力快照
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  插件注册表(Plugin Registry)                        │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │  ① 注册表核心(能力登记)                                 │      │
│   │     • Provider / Tool / Hook / Channel / 网络能力       │      │
│   │     • 生命周期 / 刷新 / 空表 / API / 状态                │      │
│   └──────────────────────────┬───────────────────────────────┘      │
│                              │ 注册完成后启动                       │
│                              ▼                                       │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │  ② Provider 运行时(LLM 调用面)                          │      │
│   │     • OAuth 流程 / 模型路由 / 策略面                      │      │
│   │     • 自托管 setup / 校验 / 向导                          │      │
│   └──────────────────────────┬───────────────────────────────┘      │
│                              │ 提供运行时实例                       │
│                              ▼                                       │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │  ③ 插件运行时(状态与生命周期)                            │      │
│   │     • 运行时状态 / 渠道状态 / 降级状态                    │      │
│   │     • Sidecar 路径 / 工作区状态                          │      │
│   │     • 状态查询 / 更新 / 卸载                              │      │
│   └──────────────────────────┬───────────────────────────────┘      │
│                              │ 依赖加载与发现                       │
│                              ▼                                       │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │  ④ 加载与发现                                             │      │
│   │     • Loader / Discovery / Installs                      │      │
│   │     • Schema 校验 / 诊断 / 槽位与槽位选择                 │      │
│   └──────────────────────────┬───────────────────────────────┘      │
│                              │ 可选扩展能力                         │
│                              ▼                                       │
│   ┌──────────────────────────────────────────────────────────┐      │
│   │  ⑤ Web 能力与会话目录                                     │      │
│   │     • 搜索 / 抓取 / 内容抽取 Provider                     │      │
│   │     • 会话目录 / 会话讨论注册表 / 会话绑定                 │      │
│   └──────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────────┘

   横向契约(对整个注册表):
   • 插件只能通过 SDK 边界访问核心
   • 注册表进程级稳定,运行时不重新发现文件
   • 能力按类别登记,确定排序(prompt cache 友好)
   • 状态写入 SQLite,禁止 JSON/sidecar
```

## 组件清单

插件注册表由 5 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **注册表核心** | 把外部插件按能力类别登记到进程内,提供查询接口 | 能力按 Provider / Tool / Hook / Channel 分类;进程级稳定 |
| **Provider 运行时** | 运行时实际调用 LLM,处理 OAuth、模型路由、策略面 | 由插件提供实例,核心不绑定厂商;auth 走 SecretRef |
| **插件运行时** | 管理单个插件运行时的状态、降级、Sidecar、工作区 | 状态写入 SQLite;降级时 fail closed |
| **加载与发现** | 启动时发现已安装插件,加载 manifest,校验 schema | 只在启动阶段执行;运行时热路径不重新发现 |
| **Web 能力与会话目录** | Web 搜索 / 抓取 / 内容抽取 Provider;会话级插件状态 | Web 能力独立于 LLM Provider;会话目录存会话级状态 |

## 关联关系

### 注册表与上层调用方

```
   ┌──────────────┐
   │ Agent Runner │ ──取 Provider/Tool 表──►  注册表核心
   │              │                                │
   │              │ ◄──返回确定性快照─────────────┘
   └──────────────┘
                   ┌──────────────┐
                   │ Gateway 启动 │ ──启动阶段5──► 加载与发现
                   │              │                  │
                   │              │ ◄──已加载清单───┘
                   └──────────────┘
                                       ┌──────────────┐
                                       │ 通道系统     │ ──取渠道──► 注册表核心
                                       └──────────────┘
   ┌──────────────┐
   │ CLI / Doctor │ ──install/uninstall──► 加载与发现
   └──────────────┘
```

### 注册表分层依赖(单向)

```
   ┌──────────────────────────┐
   │  状态层(共享库 +        │ ◄── 上游依赖
   │  per-agent 库)           │
   └────────────┬─────────────┘
                │ 读写注册记录与运行时状态
                ▼
   ┌──────────────────────────┐
   │  配置层(规范 shape)     │ ◄── 上游依赖
   └────────────┬─────────────┘
                │ 加载配置 → 注入注册
                ▼
   ┌──────────────────────────┐
   │  加载与发现               │
   │  (Loader / Discovery)    │
   └────────────┬─────────────┘
                │ 产出候选插件清单
                ▼
   ┌──────────────────────────┐
   │  注册表核心               │
   │  (按类别登记能力)        │
   └────────────┬─────────────┘
                │ 提供运行时实例与状态
                ▼
   ┌──────────────────────────┐
   │  Provider 运行时 +       │
   │  插件运行时              │
   └────────────┬─────────────┘
                │ 可选 Web 能力 + 会话目录
                ▼
   ┌──────────────────────────┐
   │  Web 能力与会话目录       │
   └──────────────────────────┘
```

### 错误的反向依赖(禁止)

```
   错误设计(注册表反向依赖上层):
        Agent Runner ──注入新能力──► 注册表核心
        → 注册表变成可变全局,失去快照稳定性

   正确设计(单向流动):
        加载阶段 ──► 注册表 ──► 上层只读
        上层修改能力 = 走 install / uninstall 流程,再 reload
```

## 协作流程

### 一次 Gateway 启动中注册表的形成过程

下面追踪从启动阶段 5 到上层可用能力的全过程。

```
Gateway 启动到阶段 5(Plugins)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 加载与发现                                                 │
│    • 扫描已安装插件目录(共享库 install 记录)              │
│    • 读取每个插件的 manifest                                 │
│    • Schema 校验 + 诊断输出                                  │
│    • 产出候选插件清单(含 provenance)                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 注册表核心登记                                             │
│    • 按能力类别分别调用 registrars:                          │
│      - Providers      登记可调用 LLM 厂商                    │
│      - Tools/Hooks    登记工具与生命周期钩子                 │
│      - Channels       登记渠道插件                           │
│      - Operations     登记操作类能力                         │
│      - Network        登记网络类能力(MCP 解析等)            │
│      - Memory         登记记忆 / 嵌入能力                    │
│      - Host           登记宿主钩子                           │
│      - Capabilities   登记通用能力                           │
│    • 生命周期管理 + 刷新空表 + 暴露查询 API                  │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Provider 运行时启动                                        │
│    • 解析 OAuth 流程 / 模型路由 / 主模型选择                 │
│    • 构建 public artifacts(对外暴露的目录条目)              │
│    • 装配 policy surface(策略面)                            │
│    • 校验 + 向导可选交互                                     │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 插件运行时初始化                                           │
│    • 每个插件绑定运行时状态 / 渠道状态 / 工作区状态          │
│    • 检查降级状态(SecretRef 失败时 fail closed)             │
│    • 准备 Sidecar 路径(如插件有独立进程)                   │
│    • 提供状态查询 / 更新 / 卸载接口                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Web 能力与会话目录(按需)                                  │
│    • 搜索 Provider / 抓取 Provider / 内容抽取 Provider 注册  │
│    • 会话目录建立(active / history import)                  │
│    • 会话讨论注册表 + 会话绑定就绪                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  注册表就绪
                  上层调用方可读
```

### Agent run 中读取注册表的过程

```
Agent Runner 启动一次 run
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 从注册表核心拿快照                                │
│    • 取可用 Provider 清单(确定排序)                │
│    • 取可用 Tool 清单(确定排序)                    │
│    • 取可用 Hook 清单                                │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 按 agent 配置选择实例                            │
│    • Provider 运行时根据模型路由选择具体实例         │
│    • 工具表过滤为 agent 实际可用的工具集             │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 调用 LLM 与工具                                  │
│    • Provider 运行时执行 OAuth → 调用 LLM            │
│    • Tool 通过 Tool Hook 同步执行                   │
│    • 结果经插件运行时状态记录                        │
└──────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 注册表是进程级稳定快照

- **为什么**:运行时热路径若重新发现文件,会引入 I/O 抖动、不确定顺序、缓存失效
- **怎么做**:启动阶段一次性加载 manifest 与 install 记录;进程内持有不可变快照
- **影响**:插件更新/卸载需要走 install / uninstall 流程,部分场景需要重启或显式 reload

### 2. 插件只能通过 SDK 边界访问核心

- **为什么**:防止插件耦合核心内部结构,导致核心无法演进
- **怎么做**:插件只能 import `plugin-sdk/*`,禁止 import 核心 `src/**` 或其他插件的 `src/**`
- **影响**:核心重构不破坏插件;新增能力只能通过新增 SDK 接缝

### 3. 能力按类别登记,确定排序

- **为什么**:prompt cache 对工具表顺序敏感;不确定顺序导致 cache miss
- **怎么做**:注册表对每类能力做确定性排序(map / set / registry 在序列化前排序)
- **影响**:同一组插件多次注册得到相同快照

### 4. 状态写入 SQLite,禁止 JSON/sidecar

- **为什么**:文件状态分散会导致跨进程一致性丢失、迁移困难
- **怎么做**:运行时状态、注册表索引、KV、租约都落在共享库或 per-agent 库
- **影响**:插件持久化只能用 SDK 提供的 KV / state 接缝

### 5. SecretRef 失败 fail closed

- **为什么**:静默 fallback 到其他凭证会绕过授权面,引入安全风险
- **怎么做**:Provider auth 由 SecretRef 引用;失败时隔离到最小已知 owner;未知 owner fail closed
- **影响**:Gateway 拒绝启动仅当自身 ingress 保护无法建立;其他 owner 标记 configured-unavailable

## 设计观察

### 为什么注册表分五层而不是一个大表

```
错误设计(单一全局表):
        Provider / Tool / Hook / Channel / Memory / Web 全部塞一张表
        → 查询时按 type 过滤,运行时分支多
        → 新增能力类型要改表 schema

正确设计(按类别登记 + 共享状态):
        每个 registrar 独立,共享 registry state
        → 查询按类别直接拿
        → 新增能力类型 = 新增 registrar,不改老的能力
        → 共享状态层统一处理快照、刷新、生命周期
```

### 为什么 Provider 运行时与插件运行时分离

```
错误设计(Provider 与插件状态混在一起):
        Provider 实例 = 插件实例
        → 切换 Provider 需要重置整个插件状态
        → 一个插件多个 Provider 时状态混乱

正确设计:
        Provider 运行时 = LLM 调用面(OAuth / 路由 / 策略)
        插件运行时 = 插件进程级状态(状态 / 降级 / Sidecar)
        → Provider 可单独刷新 auth 而不影响插件状态
        → 插件状态独立降级而不影响其他 Provider
```

### 为什么 Web 能力独立于 LLM Provider

```
错误设计(Web 搜索也走 Provider 接缝):
        Provider 接缝同时承载 LLM 调用与 Web 搜索
        → Provider 接口过载,LLM 调用与 Web 调用契约混淆
        → 无法单独替换搜索后端

正确设计:
        Web 搜索 / 抓取 / 内容抽取 = 独立能力类别
        各自独立注册 + 独立选择
        → LLM Provider 只关心模型调用
        → Web 能力可独立替换后端(如换搜索厂商)
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 本文件 — 插件注册表全景与索引 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 注册表核心:能力登记与生命周期 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | Provider 运行时:LLM 调用面 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 插件运行时:状态与生命周期 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 加载与发现:Loader 与 Schema 校验 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 注册表核心入口 | [src/plugins/registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry.ts) |
| 注册表类型 | [src/plugins/registry-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-types.ts) |
| 注册表状态 | [src/plugins/registry-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-state.ts) |
| Provider 运行时入口 | [src/plugins/provider-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/provider-runtime.ts) |
| 插件运行时入口 | [src/plugins/runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime.ts) |
| 加载器入口 | [src/plugins/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader.ts) |
| 加载发现 | [src/plugins/discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/discovery.ts) |
| Web Provider 共享 | [src/plugins/web-provider-runtime-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/web-provider-runtime-shared.ts) |
| 会话目录 | [src/plugins/session-catalog.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/session-catalog.ts) |
| AGENTS.md 边界约束 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) |
