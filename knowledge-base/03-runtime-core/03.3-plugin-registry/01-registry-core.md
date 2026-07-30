# 01 — 注册表核心

> 读完本章你将理解:OpenClaw 插件注册表的核心组件如何按能力类别登记插件、如何管理生命周期与刷新、如何暴露查询 API。

## 一句话定位

注册表核心是插件能力的"中央登记处":
- 按能力类别(Provider / Tool / Hook / Network / Memory / Host / Capabilities)分别登记
- 统一持有进程级状态快照、生命周期管理、刷新机制
- 对外暴露查询 API,上层只读消费

## 全局协作图

下图展示注册表核心内部的组件协作关系。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  上层调用方(只读)                                    │
│                                                                      │
│   Agent Runner    Gateway 启动     通道系统     Control UI           │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 通过注册表 API 查询
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  注册表核心(Registry Core)                         │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  查询 API 层                                                │    │
│   │  (对外只读接口:列出 Provider/Tool/Hook/...)                │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 读                                 │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  注册表状态(进程级快照)                                   │    │
│   │  • 当前 contributions 快照  • 空表(empty)                │    │
│   │  • 生命周期 trace           • 事务边界                     │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 由各 registrar 写入                 │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  Registrars(按能力类别登记)                                │    │
│   │                                                            │    │
│   │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │    │
│   │  │ Providers    │ │ Tools/Hooks  │ │ Operations   │         │    │
│   │  │ 登记器       │ │ 登记器       │ │ 登记器       │         │    │
│   │  └──────────────┘ └──────────────┘ └──────────────┘         │    │
│   │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │    │
│   │  │ Network      │ │ Memory       │ │ Host         │         │    │
│   │  │ 登记器       │ │ 登记器       │ │ 登记器       │         │    │
│   │  │ (含 Channels)│ │              │ │              │         │    │
│   │  └──────────────┘ └──────────────┘ └──────────────┘         │    │
│   │  ┌──────────────┐                                          │    │
│   │  │ Capabilities │                                          │    │
│   │  │ 登记器       │                                          │    │
│   │  └──────────────┘                                          │    │
│   └────────────────────────────────────────────────────────────┘    │
│                                │                                     │
│                                │ 触发                                │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  生命周期 + 刷新                                            │    │
│   │  • 生命周期 gates     • 刷新机制     • 事务提交              │    │
│   └────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

注册表核心由 12 类组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **注册表入口** | 注册表的对外门面,提供登记与查询入口 | 进程级单例;所有 registrar 通过它聚合 |
| **注册表类型** | 定义注册表对内对外的类型契约 | 类型与运行时分离,避免循环 |
| **注册表状态** | 持有当前 contributions 的进程级快照 | 不可变快照;查询返回引用而非拷贝 |
| **Providers 登记器** | 登记插件提供的 LLM Provider 实例 | 与插件运行时分离;auth 走 SecretRef |
| **Tools/Hooks 登记器** | 登记插件工具与生命周期钩子 | 确定性排序(prompt cache 友好) |
| **Operations 登记器** | 登记操作类能力(命令、动作) | 与 Tool 分离,Operations 不一定走 LLM |
| **Network 登记器** | 登记网络类能力(MCP 解析等) | 网络能力独立于 LLM 调用 |
| **Memory 登记器** | 登记记忆 / 嵌入能力 | 与 Provider 分离,Memory 走独立路径 |
| **Host 登记器** | 登记宿主钩子(进程级钩子) | Host 钩子在进程级生效,非会话级 |
| **Capabilities 登记器** | 登记通用能力(浏览器 / 画布 / cron 等) | 通用能力不绑定特定 Provider |
| **生命周期管理** | 管理注册表的启动 / 刷新 / 关闭 gates | gate 顺序固定;刷新走原子事务 |
| **查询 API** | 对外暴露只读查询接口 | 只读,不修改快照;支持按类别查询 |

## 关联关系

### Registrars 与注册表状态

```
                各 registrar(7 类)
                       │
                       │ 各自登记能力
                       ▼
              ┌──────────────────┐
              │  注册表状态      │
              │  (进程级快照)    │
              │                  │
              │  • Providers     │
              │  • Tools/Hooks   │
              │  • Operations    │
              │  • Network       │
              │  • Memory        │
              │  • Host          │
              │  • Capabilities  │
              │  • Channels      │ (由 Network 登记器代理)
              └────────┬─────────┘
                       │ 单向只读
                       ▼
              ┌──────────────────┐
              │  查询 API        │
              │  (对外只读)      │
              └──────────────────┘
```

### 生命周期 gates 与刷新机制

```
   启动 gate         刷新 gate           关闭 gate
       │                │                   │
       ▼                ▼                   ▼
   ┌─────────┐     ┌─────────┐         ┌─────────┐
   │ 加载已  │     │ 触发刷新│         │ 释放所有│
   │ 安装插件│     │ 事务原子│         │ 插件 lease│
   │ 调用    │     │ 提交    │         │ 关闭    │
   │ registrar│   │         │         │ sidecar │
   └─────────┘     └─────────┘         └─────────┘
       │                │                   │
       └─────► 写入状态 ◄┴───────────────────┘
                       │
                       ▼
                  新快照可见
                  上层查询返回新值
```

### 错误的 registrar 跨类别写(禁止)

```
   错误设计(跨类别写):
        Providers 登记器直接写入 Tools 列表
        → 类别边界破坏,刷新时各自职责混乱

   正确设计(只写自己类别):
        Providers 登记器只写 Providers
        Tools 登记器只写 Tools
        → 刷新时可独立原子化每类
        → 新增类别不破坏老类别
```

## 协作流程

### 一次插件能力登记的过程

下面追踪一个 Provider 插件从加载到被 Agent Runner 查询的全过程。

```
加载器加载插件 A
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 注册表入口接收登记请求                                     │
│    • 加载器调用注册表入口的登记 API                           │
│    • 注册表入口启动生命周期 gate(进入"登记中")              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 路由到对应 registrar                                       │
│    • 检查插件能力类别                                         │
│    • 插件 A 是 Provider → 路由到 Providers 登记器              │
│    • 同时插件 A 提供 Hook → 路由到 Tools/Hooks 登记器          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. registrar 校验 + 写入                                     │
│    • Providers 登记器校验 manifest                            │
│    • 校验通过 → 写入注册表状态(原子事务)                    │
│    • 失败 → 隔离该插件,fail closed,不影响其他              │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 快照刷新                                                  │
│    • 生命周期管理触发刷新 gate                                │
│    • 旧快照替换为新快照(原子切换)                          │
│    • 上层查询返回新快照                                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 上层通过查询 API 拿到 Provider                             │
│    • Agent Runner 通过查询 API 列出可用 Provider              │
│    • 返回的是不可变快照引用                                   │
│    • 同一组插件多次查询返回相同结果                           │
└──────────────────────────────────────────────────────────────┘
```

### 注册表刷新的场景

```
场景:用户通过 CLI 安装新插件 → 触发注册表刷新

   CLI install 新插件
         │
         ▼
   ┌──────────────────────────────────┐
   │ 加载器发现新插件并加载 manifest  │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 注册表入口接收 reload 请求       │
   │ 启动刷新 gate                    │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 各 registrar 重新登记            │
   │ (在事务内重新构建 contributions) │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 事务原子提交                     │
   │ 旧快照 → 新快照(原子切换)      │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 关闭 gate,刷新完成              │
   │ 上层查询返回新值                 │
   └──────────────────────────────────┘
```

## 关键设计约束

### 1. 注册表状态是进程级不可变快照

- **为什么**:运行时热路径不能容忍 I/O 抖动与不确定顺序;快照稳定才能保证 prompt cache 命中
- **怎么做**:状态由原子事务构建,完成后上层只读引用;刷新生成新快照后原子替换
- **影响**:运行时修改能力必须走 reload / install / uninstall 流程,不能直接修改快照

### 2. Registrar 按能力类别严格隔离

- **为什么**:类别边界破坏会导致刷新时职责混乱;新增类别要影响所有 registrar
- **怎么做**:每个 registrar 只写自己类别;registrar 之间不互相写
- **影响**:新增能力类别只需新增 registrar,不改老的类别

### 3. 刷新走原子事务

- **为什么**:部分刷新会导致上层看到不一致的中间状态(Provider 已更新但 Tool 未更新)
- **怎么做**:刷新在事务内重新构建所有 contributions,完成后原子替换快照
- **影响**:刷新期间上层查询返回旧快照,刷新完成后立即返回新快照

### 4. 查询 API 只读

- **为什么**:防止上层修改快照破坏不可变性
- **怎么做**:查询 API 返回不可变引用;修改能力走 registrar 入口
- **影响**:上层代码不能绕过 registrar 直接写状态

### 5. 空表(empty)是一等公民

- **为什么**:某些场景下注册表可能为空(无插件 / 启动失败降级);需要明确表示"空"而非"未初始化"
- **怎么做**:空表是显式状态;查询 API 对空表返回空列表而非错误
- **影响**:上层不需要特殊处理空状态;降级模式下也能优雅返回

### 6. 生命周期 gate 顺序固定

- **为什么**:启动 / 刷新 / 关闭有依赖顺序;乱序会导致状态不一致
- **怎么做**:启动 gate 必须先于刷新 gate;关闭 gate 必须最后执行
- **影响**:任何修改状态的入口都必须经过 gate,不能绕过

## 设计观察

### 为什么 registrar 与运行时实例分离

```
错误设计(registrar 同时持运行时实例):
        Providers 登记器 = Provider 运行时实例
        → 刷新运行时实例 = 刷新整个注册表
        → 多个 Provider 共享一个运行时实例的耦合

正确设计:
        Providers 登记器只登记元数据与入口
        Provider 运行时是独立的运行时层
        → 登记器刷新不影响运行时实例
        → 运行时实例可独立刷新 auth / 路由
```

### 为什么 Host 登记器与 Tool 登记器分开

```
错误设计(Host 钩子混在 Tool 中):
        Tool 列表包含 Host 钩子
        → 会话级 Tool 与进程级 Host 钩子查询混淆
        → Host 钩子的生命周期无法独立管理

正确设计:
        Host 登记器独立 → 进程级钩子
        Tools/Hooks 登记器 → 会话级 / Run 级钩子
        → 生命周期边界清晰
        → 查询时按级别过滤
```

### 为什么 Memory 登记器与 Provider 登记器分开

```
错误设计(Memory 也走 Provider 接缝):
        Provider 接缝同时承载 LLM 与 Memory
        → Provider 接口过载
        → Memory 切换后端影响 LLM Provider

正确设计:
        Memory 登记器独立 → 嵌入 / 记忆能力
        Provider 登记器只关心 LLM 调用
        → 切换 Memory 后端不影响 LLM
        → LLM Provider 与 Memory 可独立组合
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 插件注册表总览 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 本文件 — 注册表核心 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | Provider 运行时 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 插件运行时 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 加载与发现 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 注册表入口 | [src/plugins/registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry.ts) |
| 注册表类型 | [src/plugins/registry-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-types.ts) |
| 注册表状态 | [src/plugins/registry-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-state.ts) |
| 注册表运行时 | [src/plugins/registry-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-runtime.ts) |
| Registrars 聚合 | [src/plugins/registry-registrars.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars.ts) |
| Tools/Hooks 登记器 | [src/plugins/registry-registrars-tools-hooks.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-tools-hooks.ts) |
| Providers 登记器 | [src/plugins/registry-registrars-providers.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-providers.ts) |
| Operations 登记器 | [src/plugins/registry-registrars-operations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-operations.ts) |
| Network 登记器 | [src/plugins/registry-registrars-network.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-network.ts) |
| Memory 登记器 | [src/plugins/registry-registrars-memory.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-memory.ts) |
| Host 登记器 | [src/plugins/registry-registrars-host.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-host.ts) |
| Capabilities 登记器 | [src/plugins/registry-registrars-capabilities.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-registrars-capabilities.ts) |
| 生命周期管理 | [src/plugins/registry-lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-lifecycle.ts) |
| 刷新机制 | [src/plugins/registry-refresh.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-refresh.ts) |
| 空表 | [src/plugins/registry-empty.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-empty.ts) |
| 查询 API | [src/plugins/registry-api.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/registry-api.ts) |
