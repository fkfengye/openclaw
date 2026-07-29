# 03 — 插件运行时

> 读完本章你将理解:单个插件在运行时如何被管理,运行时状态、渠道状态、降级状态、Sidecar 路径、工作区状态如何协作,以及插件的状态查询、更新、卸载流程。

## 一句话定位

插件运行时是单个插件的"运行时管家":
- 持有插件进程级运行时状态(主状态、渠道状态、降级状态、工作区状态、Sidecar 路径)
- 提供 status / update / uninstall 接口供 CLI / Doctor / Gateway 调用
- 状态写入 SQLite,降级时 fail closed

## 全局协作图

下图展示插件运行时内部各组件协作。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  上游(Provider 运行时 + 注册表)                    │
│                                                                      │
│   注册表核心 ──登记元数据──► Provider 运行时 ──启动实例──►          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ 提供运行时实例
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  插件运行时(Plugin Runtime)                       │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  运行时主入口                                                │    │
│   │  • 协调状态 / 渠道 / 降级 / Sidecar / 工作区                │    │
│   │  • 暴露 status / update / uninstall API                     │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 管理                                │
│         ┌──────────────────────┼──────────────────────┐             │
│         ▼                      ▼                      ▼             │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐     │
│   │ 运行时状态   │    │ 渠道状态    │    │ 降级状态         │     │
│   │              │    │              │    │                  │     │
│   │ • 主进程状态 │    │ • 渠道级     │    │ • 失败标记       │     │
│   │ • 健康状态   │    │   状态       │    │ • 配置不可用     │     │
│   │ • 生命周期   │    │ • 渠道绑定   │    │   owner         │     │
│   └──────┬───────┘    └──────┬───────┘    └────────┬─────────┘     │
│          │                   │                     │                │
│          │                   │                     │                │
│          ▼                   ▼                     ▼                │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐     │
│   │ Sidecar 路径 │    │ 工作区状态   │    │ 状态查询接口     │     │
│   │              │    │              │    │                  │     │
│   │ • 子进程路径 │    │ • 工作区     │    │ • status         │     │
│   │ • 资源隔离   │    │   绑定       │    │ • 健康检查       │     │
│   └──────────────┘    └──────────────┘    └──────────────────┘     │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  管理面                                                      │    │
│   │  • 状态查询(status)  • 更新(update)  • 卸载(uninstall)   │    │
│   └────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               │ 持久化
                               ▼
                  ┌────────────────────────┐
                  │  SQLite 状态层         │
                  │  • 共享库              │
                  │  • per-agent 库        │
                  └────────────────────────┘
```

## 组件清单

插件运行时由 8 类组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **运行时主入口** | 协调所有状态组件,暴露管理 API | 单一编排入口,所有状态修改经此 |
| **运行时状态** | 插件主进程级状态(健康、生命周期) | 写入 SQLite;不可变快照 |
| **渠道状态** | 渠道级运行时状态(渠道绑定、渠道级缓存) | 与主状态分离,渠道间互不影响 |
| **降级状态** | 失败标记与配置不可用 owner | fail closed;隔离到最小 owner |
| **Sidecar 路径** | 子进程路径与资源隔离(如插件有独立进程) | 路径确定性;资源隔离 |
| **工作区状态** | 工作区绑定与工作区级状态 | 与 agent 工作区解耦 |
| **状态查询接口** | 暴露 status / 健康检查 | 只读,不修改状态 |
| **管理面** | status / update / uninstall 三大管理操作 | update / uninstall 需走生命周期 gate |

## 关联关系

### 插件运行时与 Provider 运行时

```
   ┌──────────────────┐
   │ Provider 运行时  │
   │ (LLM 调用面)    │
   │                  │
   │ • OAuth          │
   │ • 模型路由       │
   └────────┬─────────┘
            │ 装配 Provider 实例后
            │ 委托给插件运行时管理
            ▼
   ┌──────────────────┐
   │ 插件运行时       │
   │ (插件级状态)     │
   │                  │
   │ • 主状态         │
   │ • 渠道状态       │
   │ • 降级状态       │
   │ • Sidecar 路径   │
   │ • 工作区状态     │
   └────────┬─────────┘
            │
            │ 持久化
            ▼
   ┌──────────────────┐
   │ SQLite 状态层    │
   └──────────────────┘
```

### 三类状态的隔离

```
              插件运行时主入口
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌──────────┐ ┌──────────┐ ┌──────────┐
   │主状态    │ │渠道状态  │ │降级状态  │
   │          │ │          │ │          │
   │ 进程级   │ │ 渠道级   │ │ 失败级   │
   │ 全局     │ │ 单渠道   │ │ 单 owner │
   └──────────┘ └──────────┘ └──────────┘
        │            │            │
        │            │            │
        └────────────┼────────────┘
                     │
                     ▼
              状态查询接口
              (统一对外只读)
```

### 错误的状态混淆(禁止)

```
   错误设计(主状态包含渠道状态):
        主状态 ──包含──► 渠道 A 状态
                       渠道 B 状态
        → 一个渠道失败影响主状态
        → 主状态刷新时渠道状态丢失

   正确设计(各类状态隔离):
        主状态 = 进程级
        渠道状态 = 渠道级(每渠道独立)
        → 渠道失败不影响主状态
        → 主状态刷新不影响渠道状态
```

## 协作流程

### 插件运行时初始化过程

下面追踪一个插件运行时初始化的全过程。

```
注册表登记完成,启动插件运行时
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 创建运行时主入口                                          │
│    • 绑定插件 ID 与生命周期                                  │
│    • 初始化各状态组件占位                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 初始化主状态                                              │
│    • 检查插件是否已安装                                      │
│    • 从 SQLite 读取上次状态                                 │
│    • 设置健康状态(健康 / 降级 / 失败)                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 初始化渠道状态(如插件是渠道插件)                         │
│    • 检查已绑定渠道                                          │
│    • 每个渠道独立初始化渠道状态                              │
│    • 渠道间互不影响                                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 检查降级状态                                              │
│    • 检查 SecretRef 是否就绪                                  │
│    • 检查依赖是否满足                                        │
│    • 失败 → 标记降级 owner,fail closed                      │
│    • 成功 → 进入健康状态                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 初始化 Sidecar 路径(如需要)                              │
│    • 检查插件是否需要独立进程                                │
│    • 准备 Sidecar 子进程路径                                 │
│    • 资源隔离(不共享主进程资源)                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 初始化工作区状态                                          │
│    • 绑定到 agent 工作区                                     │
│    • 工作区级缓存初始化                                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  插件运行时就绪
                  暴露管理 API
```

### 插件 update 流程

```
用户执行 openclaw update <plugin>
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 进入 update 生命周期 gate                          │
│    • 锁定插件,防止并发修改                          │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 检查当前状态                                      │
│    • 查询主状态 + 降级状态                           │
│    • 如有运行中任务 → 等待或拒绝                    │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 下载新版本                                        │
│    • 走 install 流程下载新包                         │
│    • 校验包完整性                                    │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 切换状态                                          │
│    • 旧状态归档                                      │
│    • 新状态写入 SQLite(原子事务)                   │
│    • 旧 Sidecar 进程关闭                            │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 5. 触发 reload                                       │
│    • 注册表 reload                                   │
│    • 新运行时实例装配                                │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  update 完成
                  上层查询返回新版本
```

### 插件 uninstall 流程

```
用户执行 openclaw uninstall <plugin>
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ 1. 进入 uninstall 生命周期 gate                       │
│    • 锁定插件                                        │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. 清理运行时资源                                    │
│    • 关闭 Sidecar 进程                              │
│    • 释放工作区绑定                                  │
│    • 渠道状态清理                                    │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. 从注册表移除                                       │
│    • 触发注册表 reload                               │
│    • 该插件的所有能力从快照移除                     │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 4. 清理持久化数据                                    │
│    • 删除 SQLite 中该插件的状态                      │
│    • 删除 SecretRef 中该插件的凭证                   │
│    • 删除 Sidecar 路径下的资源                       │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  uninstall 完成
                  插件完全移除
```

## 关键设计约束

### 1. 状态写入 SQLite,禁止 JSON/sidecar

- **为什么**:文件状态分散会导致跨进程一致性丢失;SQLite 是唯一可信源
- **怎么做**:主状态、渠道状态、降级状态、工作区状态都写 SQLite
- **影响**:插件持久化只能用 SDK 提供的 KV / state 接缝

### 2. 降级时 fail closed

- **为什么**:静默 fallback 会绕过授权面,引入安全风险
- **怎么做**:SecretRef 失败时隔离到最小已知 owner;未知 owner fail closed
- **影响**:Gateway 仅在自身 ingress 保护无法建立时拒绝启动;其他 owner 标记 configured-unavailable

### 3. Sidecar 路径确定性

- **为什么**:不确定路径会导致资源泄漏、清理困难
- **怎么做**:Sidecar 路径在初始化时确定;进程退出时按路径清理
- **影响**:同一插件多次启动路径相同;清理时按路径回收

### 4. update / uninstall 走生命周期 gate

- **为什么**:并发修改状态会导致数据竞争与不一致
- **怎么做**:update / uninstall 启动时进入 gate,锁定插件;完成后释放
- **影响**:并发 update / uninstall 请求会串行化

### 5. status 查询只读

- **为什么**:防止查询时副作用导致状态变化
- **怎么做**:status 接口只读;返回不可变快照
- **影响**:UI / CLI 可频繁查询 status 不影响运行时

### 6. 渠道状态隔离

- **为什么**:一个渠道失败不应影响其他渠道;主状态不应被渠道状态污染
- **怎么做**:每个渠道独立渠道状态;主状态不包含渠道状态
- **影响**:渠道失败可独立降级;主状态健康检查不受单渠道影响

## 设计观察

### 为什么不把所有状态塞进一个对象

```
错误设计(单一状态对象):
        pluginState = {
          main: ...,
          channelA: ...,
          channelB: ...,
          degraded: ...,
          sidecar: ...,
        }
        → 渠道 A 失败污染整个对象
        → 主状态刷新时渠道状态丢失
        → 降级标记与主状态混淆

正确设计(分类隔离):
        主状态 / 渠道状态 / 降级状态 / Sidecar / 工作区
        各自独立,主入口协调
        → 单点失败不扩散
        → 各类状态独立刷新
```

### 为什么 Sidecar 路径独立组件

```
错误设计(Sidecar 路径散落在主状态):
        主状态对象内嵌 Sidecar 路径
        → 主状态刷新时 Sidecar 路径丢失
        → 进程清理时找不到正确路径

正确设计:
        Sidecar 路径独立组件
        • 初始化时确定
        • 进程退出时按路径清理
        → 路径稳定,不随主状态刷新变化
```

### 为什么工作区状态独立

```
错误设计(工作区状态混入主状态):
        主状态包含工作区绑定
        → 工作区切换影响主状态
        → 多工作区时主状态混乱

正确设计:
        工作区状态独立
        • 与 agent 工作区解耦
        → 工作区切换不影响主状态
        → 多工作区并行
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 插件注册表总览 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 注册表核心 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | Provider 运行时 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 本文件 — 插件运行时 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 加载与发现 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 插件运行时主入口 | [src/plugins/runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime.ts) |
| 运行时状态 | [src/plugins/runtime-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-state.ts) |
| 运行时状态键 | [src/plugins/runtime-state-key.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-state-key.ts) |
| 渠道状态 | [src/plugins/runtime-channel-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-channel-state.ts) |
| 降级状态 | [src/plugins/runtime-degraded-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-degraded-state.ts) |
| Sidecar 路径 | [src/plugins/runtime-sidecar-paths.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-sidecar-paths.ts) |
| Sidecar 路径基线 | [src/plugins/runtime-sidecar-paths-baseline.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-sidecar-paths-baseline.ts) |
| 工作区状态 | [src/plugins/runtime-workspace-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-workspace-state.ts) |
| 运行时插件懒加载 | [src/plugins/runtime-plugins.runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/runtime-plugins.runtime.ts) |
| 激活上下文 | [src/plugins/activation-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/activation-context.ts) |
| 激活规划器 | [src/plugins/activation-planner.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/activation-planner.ts) |
| 当前插件元数据快照 | [src/plugins/current-plugin-metadata-snapshot.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/current-plugin-metadata-snapshot.ts) |
| 插件生命周期追踪 | [src/plugins/plugin-lifecycle-trace.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/plugin-lifecycle-trace.ts) |
| 插件生命周期租约 | [src/plugins/plugin-lifecycle-lease.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/plugin-lifecycle-lease.ts) |
| 插件控制面上下文 | [src/plugins/plugin-control-plane-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/plugin-control-plane-context.ts) |
| 管理服务 | [src/plugins/management-service.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/management-service.ts) |
| 启用入口 | [src/plugins/enable.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/enable.ts) |
