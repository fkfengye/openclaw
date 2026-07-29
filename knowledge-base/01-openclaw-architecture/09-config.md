# 09 — 配置加载与迁移

> 配置是 OpenClaw 的"启动契约":所有运行时行为都由配置驱动。读完本章你将理解配置如何三步加载、为什么核心只读最新 shape、热重载为何不做 freshness polling、CLI setup 为什么是公共 API。

## 一句话定位

配置管理是 OpenClaw 的启动契约层:
- 三步加载流程:读取 → 迁移 → 校验,清晰可追溯
- 核心运行时只读 canonical config(最新 shape),不静默兼容旧/畸形 key
- 旧 shape 由 Doctor 迁移,无 runtime shim / alias / fallback
- 热重载不做 freshness polling,靠显式 trigger;元数据 process-stable

## 全局协作图

下图展示配置层如何被核心运行时、Doctor 迁移器、热重载触发器协作使用。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                      配置源(Source)                                 │
│                                                                      │
│   配置文件(~/.openclaw/openclaw.json)    环境变量(env vars)        │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 读取原始配置
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      配置加载器(三步)                              │
│                                                                      │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐            │
│   │ 步骤 1 读取 │ ──►│ 步骤 2 迁移 │ ──►│ 步骤 3 校验 │            │
│   │             │    │             │    │             │            │
│   │ 读配置文件  │    │ 旧 shape →  │    │ 校验最新    │            │
│   │ 读 env vars │    │ 当前 shape  │    │ shape       │            │
│   │ 返回 raw    │    │ 单向迁移    │    │ 失败即报错  │            │
│   └─────────────┘    └─────────────┘    └──────┬──────┘            │
│                                                 │                    │
└─────────────────────────────────────────────────┼────────────────────┘
                                                  │
                                                  ▼
                                    ┌──────────────────────┐
                                    │  LoadedConfig        │
                                    │  (规范化的最新 shape) │
                                    └──────────┬───────────┘
                                               │
                  ┌────────────────────────────┼────────────────────────────┐
                  │                            │                            │
                  ▼                            ▼                            ▼
┌──────────────────────────────┐ ┌──────────────────────────┐ ┌──────────────────────────┐
│  核心运行时                   │ │ Doctor 迁移器            │ │ 热重载触发器             │
│                              │ │                          │ │                          │
│  只读 canonical config       │ │ 单一迁移 owner           │ │ 不做 freshness polling   │
│  不读旧 shape                │ │ 迁移 → 校验 →            │ │ 靠显式 trigger:          │
│  不读 retired keys           │ │ runtime 假定新 shape     │ │  • configure 命令        │
│  不做 runtime shim/alias     │ │                          │ │  • doctor --fix          │
│                              │ │ 禁止:                    │ │  • gateway reload        │
│                              │ │  • dual-write           │ │                          │
│                              │ │  • read-through fallback│ │ 规划重载类型:            │
│                              │ │  • lazy import          │ │  • hot(不中断)         │
│                              │ │  • SQLite 失败用 JSON   │ │  • channel restart       │
│                              │ │                          │ │  • full restart          │
└──────────────────────────────┘ └──────────────────────────┘ └──────────────────────────┘
```

## 组件清单

配置层由 6 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **配置加载器** | 三步加载:读取 → 迁移 → 校验,产出 LoadedConfig | 顺序固定,校验失败即报错,不静默兼容 |
| **配置迁移器** | 把旧 shape 单向迁移到当前 shape | 旧 shape 只在此处兼容,runtime 不兼容 |
| **配置校验器** | 校验最新 shape 结构正确 | 只校验最新 shape,retired keys 永久退役 |
| **Doctor 迁移器** | 单一迁移 owner,负责用户级旧 shape 升级 | 迁移后 runtime 假定新 shape,无 dual-write |
| **热重载规划器** | 分析配置 diff,制定重载计划(hot / channel restart / full restart) | 不 stat 文件,靠显式 trigger |
| **配置契约管理器** | 保持导出类型、schema/help、metadata、baselines、docs 对齐 | retired keys 只在 raw migration/doctor 兼容 |

## 关联关系

### 三步加载的组件协作

```
    配置源(文件 + env vars)
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 配置加载器 · 步骤 1:读取                                 │
    │                                                          │
    │  • 读取配置文件                                          │
    │  • 读取环境变量                                          │
    │  • 返回 raw config(原始结构,可能含旧 shape)          │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 配置迁移器 · 步骤 2:迁移                                 │
    │                                                          │
    │  把旧 shape 迁移到当前 shape                             │
    │                                                          │
    │  关键:                                                   │
    │  ├─ 旧 shape 只在此处兼容(runtime 不兼容)             │
    │  ├─ 迁移是单向的(旧 → 新)                            │
    │  └─ isReload 标志区分首次加载与热重载                   │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 配置校验器 · 步骤 3:校验                                 │
    │                                                          │
    │  校验配置结构正确                                        │
    │                                                          │
    │  关键:                                                   │
    │  ├─ 只校验最新 shape(不校验旧 shape)                 │
    │  ├─ 校验失败 → 报错(不静默兼容)                      │
    │  └─ retired keys 永久退役(不允许读取)                │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │ LoadedConfig             │
              │ (规范化的最新 shape)     │
              │                          │
              │  • config(校验后配置)  │
              │  • sourceConfig(raw)    │
              │  • configPath            │
              └─────────────────────────┘

    运行时只读这个产物:
    ┌────────────────────────────────────────────────────────┐
    │  ✓ Runtime 只读 canonical config(最新 shape)         │
    │                                                        │
    │  ✗ 不静默兼容旧/畸形 key                              │
    │  ✗ 不读 retired keys                                  │
    │  ✗ 不做 runtime shim / alias / fallback reader       │
    │                                                        │
    │  ✓ 旧 shape 由 Doctor 迁移                            │
    │  ✓ Core/auth 修复在 core doctor                       │
    │  ✓ Plugin 修复在 plugin doctor contract              │
    └────────────────────────────────────────────────────────┘
```

### 配置变更门槛决策树

```
   想新增 config option / env var?
        │
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 1:现有产品行为能否解决?                            │
   │                                                          │
   │  ├─ Yes → 用现有行为,不新增 config                     │
   │  │                                                      │
   │  ├─ provider selection 能解决?                          │
   │  │   └─ Yes → 用 provider selection                    │
   │  │                                                      │
   │  ├─ defaults 能解决?                                    │
   │  │   └─ Yes → 用 defaults                              │
   │  │                                                      │
   │  ├─ doctor migration 能解决?                            │
   │  │   └─ Yes → 用 doctor migration                      │
   │  │                                                      │
   │  └─ 都不行?                                            │
   │      └─ 才考虑新增 config option                       │
   └──────────────────┬───────────────────────────────────────┘
                      ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 问题 2:新增后能否移除或合并?                            │
   │                                                          │
   │  优先考虑移除/合并现有 option,而非新增                  │
   │                                                          │
   │  → 配置表面门槛高,配置项难以简化                        │
   │  → 新增需高门槛证明                                      │
   └──────────────────────────────────────────────────────────┘
```

### 热重载策略选择

```
    配置变更(显式 trigger)
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 热重载规划器(制定重载计划)                              │
    │                                                          │
    │  分析配置 diff,判断变更类型:                            │
    │  ├─ 热重载可处理(hot reload)                          │
    │  ├─ 需要重启 channel(channel restart)                 │
    │  ├─ 需要完整 restart(full restart)                    │
    │  └─ 需要重新加载 secrets(managed secrets)              │
    └──────────────────────┬───────────────────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ 热重载执行器 │ │ Channel      │ │ Full         │
    │ (hot)        │ │ 重启执行器   │ │ restart      │
    │              │ │              │ │ 执行器       │
    │ 不中断服务   │ │ channel 重启 │ │              │
    │              │ │              │ │ 中断服务     │
    └──────────────┘ └──────────────┘ └──────────────┘
            │              │              │
            ▼              ▼              ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 重载恢复器(失败回滚)                                   │
    │                                                          │
    │  如果重载失败:                                          │
    │  ├─ 回滚到 last-known-good                             │
    │  └─ 标记重载失败                                        │
    └──────────────────────┬───────────────────────────────────┘
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 已应用版本记录器                                        │
    │                                                          │
    │  记录当前应用的配置版本                                 │
    │  用于后续重载比较                                       │
    └──────────────────────────────────────────────────────────┘
```

## 协作流程

### 一次配置变更的完整旅程

下面追踪用户修改配置后,系统如何选择重载策略,标注每步由哪个组件负责。

```
用户修改了配置文件(如调整模型参数)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 显式触发                                                  │
│    用户调用重载命令                                          │
│    → 显式 trigger,不是 freshness polling                   │
│    → 系统不主动 stat 文件,不 realpath,不 JSON reread      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 重新加载配置(三步)                                      │
│    配置加载器执行:                                          │
│    ① 读取新配置文件 + env vars                              │
│    ② 迁移(如需要)                                         │
│    ③ 校验最新 shape                                         │
│    → 产出新的 LoadedConfig                                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 计算配置 diff                                             │
│    热重载规划器分析哪些配置项变更了                          │
│    → 对比当前应用版本与新版本                               │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 选择重载策略                                              │
│    根据变更项类型决定:                                      │
│    ├─ 模型参数等 → 热重载(不中断服务)                    │
│    ├─ channel 配置 → channel 重启                          │
│    ├─ 核心配置 → 完整 restart(中断服务)                  │
│    └─ secrets 变更 → 重新加载 secrets                      │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 执行重载 + 失败回滚                                       │
│    → 执行选定策略                                           │
│    → 如失败:回滚到 last-known-good                         │
│    → 记录已应用版本                                         │
└──────────────────────────────────────────────────────────────┘
```

### CLI Setup 作为公共 API 的契约

```
    外部依赖路径
    ════════════

    外部 docs          外部 installers       外部 integrations
         │                    │                     │
         │      可能复制       │      可能复制       │
         └──────────┬─────────┴──────────┬──────────┘
                    │                     │
                    ▼                     ▼
              ┌──────────────────────────────────┐
              │  CLI Setup 流程(公共 API 契约)  │
              │                                  │
              │  • onboard 命令的 flags          │
              │  • configure 命令的 flags        │
              │  • 非交互行为                    │
              │  • 生成的 config 形状            │
              └──────────────────────────────────┘

    变更约束:
    ┌────────────────────────────────────────────────────────┐
    │  变更需:                                               │
    │   ✓ additive flags / aliases(向后兼容)              │
    │   ✓ 弃号窗口(deprecation window)                    │
    │   ✓ 向后兼容迁移                                      │
    │                                                        │
    │  禁止:                                                 │
    │   ✗ 破坏现有 snippets                                 │
    │   ✗ 不加弃号窗口直接删除 flags                        │
    │   ✗ 改变生成的 config 形状而不迁移                   │
    └────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 核心只读 canonical config

- **为什么**:防止旧/畸形 key 在 runtime 散落兼容分支,导致行为不可预测
- **怎么做**:runtime 只读最新 shape;旧 shape 由迁移器/Doctor 处理;不读 retired keys
- **影响**:配置不匹配时启动失败并提示运行 Doctor,而非静默降级

### 2. 配置变更需配套 Doctor 迁移

- **为什么**:配置变更可能使现有文件失效,需有可执行迁移路径
- **怎么做**:core/auth 修复在 core doctor;plugin 拥有的修复在 plugin doctor contract
- **影响**:用户升级时总能通过 Doctor 迁移到新 shape,runtime 无需兼容旧格式

### 3. 配置表面门槛高

- **为什么**:`openclaw.json` + env vars 已很大,继续膨胀会难以简化
- **怎么做**:新增 config option / env var 前,需先证明现有产品行为 / provider selection / defaults / doctor migration 无法解决;优先移除/合并现有 option
- **影响**:配置项难以简化,新增需高门槛证明

### 4. CLI Setup 是公共 API

- **为什么**:外部 docs/installers/integrations 可能复制 CLI setup 流程
- **怎么做**:变更需 additive flags/aliases + 弃号窗口 + 向后兼容迁移,而非破坏现有 snippets
- **影响**:长期演进受限,无法轻易 breaking change

### 5. 热重载不做 freshness polling

- **为什么**:Gateway/plugin 元数据 process-stable,不需要实时校验;freshness polling 浪费 CPU 且引入 race condition
- **怎么做**:热重载靠显式 trigger(configure 命令 / doctor --fix / gateway reload);runtime hot path 不 stat / realpath / JSON reread / hash
- **影响**:元数据变更需 restart 或显式 owner reload/install/doctor flow

### 6. 配置契约对齐

- **为什么**:导出类型、schema/help、metadata、baselines、docs 必须一致,否则用户和工具会依赖不一致信息
- **怎么做**:retired public keys 永久退役,只在 raw migration/doctor 中兼容;不允许 runtime 读取已退役 keys
- **影响**:配置契约变更需全链路对齐,单点修改不足

## 设计观察

### 为什么不做 runtime shim / alias

```
错误设计(runtime 兼容旧 shape):
   配置加载器 ──读取──► raw config(可能含旧 shape)
   runtime ──发现旧 key──► 用 shim 转换
                         ──发现 retired key──► 用 alias 映射
                         ──发现畸形 key──► 静默 fallback

   后果:
   • 兼容分支散落,行为不可预测
   • 旧 key 永远无法真正退役
   • 用户不知道配置已过时
   • 测试需覆盖所有历史 shape 组合

正确设计(只读 canonical config):
   配置加载器 ──读取──► 迁移器 ──► 校验器 ──► LoadedConfig(最新 shape)
   runtime ──只读 LoadedConfig

   好处:
   • runtime 单一读取路径,行为确定
   • 旧 shape 只在迁移器一处兼容
   • 配置过时 → 启动失败 → 提示运行 Doctor
   • retired keys 永久退役,runtime 不读
```

### 为什么热重载不做 freshness polling

```
错误设计(freshness polling):
   runtime hot path 每次请求:
   ├─ stat 配置文件看是否变更
   ├─ realpath 解析路径
   ├─ JSON reread 比较内容
   └─ hash 比较判断 freshness

   后果:
   • 浪费 CPU(每次请求都校验)
   • 引入 race condition(校验与读取之间文件可能再变)
   • 元数据本就 process-stable,polling 毫无意义

正确设计(显式 trigger):
   元数据 process-stable
   ├─ 变更需 restart 或显式 owner reload/install/doctor flow
   └─ runtime hot path 复用 current snapshots

   重载触发:
   ├─ 用户调用 configure 命令
   ├─ 用户运行 doctor --fix
   └─ 用户执行 gateway reload

   好处:
   • hot path 零开销
   • 无 race condition
   • 重载时机可控、可观测
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/00-overview.md) | 总览与索引 |
| [01-positioning.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01-openclaw-architecture/01-positioning.md) | 顶层定位与技术栈 |
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
| 配置加载(三步入口) | [src/config/io.load.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/config/io.load.ts) |
| 配置迁移器 | [src/config/migrate.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/config/migrate.ts) |
| 配置校验器 | [src/config/validate.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/config/validate.ts) |
| 热重载入口 | [src/gateway/config-reload.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/config-reload.ts) |
| 热重载计划 | [src/gateway/config-reload-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/config-reload-plan.ts) |
| 配置 diff | [src/gateway/config-diff.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/config-diff.ts) |
| 热重载执行(hot) | [src/gateway/server-reload-hot.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-reload-hot.ts) |
| Channel 重启执行 | [src/gateway/server-reload-channel-restart.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-reload-channel-restart.ts) |
| 完整重启执行 | [src/gateway/server-reload-restart.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-reload-restart.ts) |
| 重载失败恢复 | [src/gateway/config-reload-recovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/config-reload-recovery.ts) |
| 已应用版本记录 | [src/gateway/config-applied-revision.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/config-applied-revision.ts) |
| AGENTS.md 硬约束来源 | [AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/AGENTS.md) "Architecture" 段 |
