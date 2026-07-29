# 04 — 加载与发现

> 读完本章你将理解:OpenClaw 启动时如何发现已安装插件、如何加载 manifest、如何做 Schema 校验与诊断、如何用槽位机制选择激活的插件。

## 一句话定位

加载与发现是插件能力的"启动期生产线":
- 启动时扫描已安装插件,读取 manifest,做 Schema 校验
- 通过槽位(slot)机制选择哪些插件激活
- 产出候选插件清单,交给注册表核心登记
- 仅在启动期执行,运行时热路径不重新发现文件

## 全局协作图

下图展示加载与发现内部的组件协作。**先看这张图建立心智模型,再读细节**。

```
┌──────────────────────────────────────────────────────────────────────┐
│                  上游(状态层 + 配置层)                              │
│                                                                      │
│   SQLite 共享库 ──提供──► install 记录 / 元数据快照                 │
│   配置层 ──提供──►     openclaw.json(插件 enable / 槽位)            │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 启动阶段 5 触发
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  加载与发现(Loader & Discovery)                    │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  发现层                                                      │    │
│   │  • 扫描已安装插件目录(共享库 install 记录)              │    │
│   │  • 检查 manifest 文件存在                                   │    │
│   │  • 产出初步候选清单(含 provenance)                        │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 候选清单                            │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  加载层                                                      │    │
│   │  • 读取 manifest 内容                                        │    │
│   │  • 加载模块运行时(loader 模块运行时)                       │    │
│   │  • 产出加载记录(provenance + 元数据)                       │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 加载记录                            │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  校验与诊断层                                                │    │
│   │  • Schema 校验器(manifest 格式校验)                       │    │
│   │  • 诊断输出(失败原因 / 警告 / 修复提示)                   │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 通过校验的清单                      │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  槽位与选择层                                                │    │
│   │  • 槽位定义(每类能力允许的插件数)                         │    │
│   │  • 槽位选择(根据配置 + 优先级选择激活插件)                │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │ 激活清单                            │
│                                ▼                                     │
│   ┌────────────────────────────────────────────────────────────┐    │
│   │  工具层                                                      │    │
│   │  • 工具契约校验   • 工具描述符缓存   • 工具授权白名单       │    │
│   └────────────────────────────┬───────────────────────────────┘    │
│                                │                                     │
│                                ▼                                     │
│                  候选插件清单 → 注册表核心登记                       │
└──────────────────────────────────────────────────────────────────────┘
```

## 组件清单

加载与发现由 9 类组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **发现层** | 扫描已安装插件目录,产出初步候选清单 | 进程级执行一次;不重复扫描 |
| **加载层** | 读取 manifest,加载模块运行时 | 加载失败 fail closed,不影响其他插件 |
| **加载记录** | 记录 provenance 与加载元数据 | 写入 SQLite;不可变 |
| **Schema 校验器** | 校验 manifest 格式合规 | 启动期校验;失败即拒绝登记 |
| **诊断输出** | 输出失败原因、警告、修复提示 | 不影响其他插件登记 |
| **槽位定义** | 定义每类能力允许的插件数 | 配置驱动;有默认值 |
| **槽位选择** | 根据配置 + 优先级选择激活插件 | 选择确定性;同配置同结果 |
| **工具层** | 工具契约校验、描述符缓存、授权白名单 | 工具表确定排序(prompt cache 友好) |
| **加载缓存** | 缓存加载结果,避免重复扫描 | 进程级缓存;生命周期与进程绑定 |

## 关联关系

### 加载与发现与注册表核心

```
   ┌──────────────────┐
   │ 加载与发现       │
   │                  │
   │ • 发现           │
   │ • 加载           │
   │ • 校验           │
   │ • 槽位选择       │
   └────────┬─────────┘
            │
            │ 提交候选清单
            ▼
   ┌──────────────────┐
   │ 注册表核心       │
   │                  │
   │ • 接收清单       │
   │ • 各 registrar   │
   │   按类别登记     │
   └──────────────────┘
```

### 启动期与运行时的边界

```
   启动期(阶段 5)                  运行时
        │                              │
        ▼                              ▼
   ┌──────────┐                  ┌──────────┐
   │ 发现     │                  │ 注册表   │
   │ 加载     │ ──候选清单──►    │ 快照     │
   │ 校验     │                  │ (只读)   │
   │ 槽位选择 │                  └──────────┘
   └──────────┘                       ▲
                                      │
                              上层只读引用
                              (不再扫描文件)

   边界约束:
   • 运行时不重新发现文件
   • 修改能力走 install / uninstall / reload
   • reload 重新走加载与发现流程
```

### 错误的运行时重新发现(禁止)

```
   错误设计(运行时重新扫描):
        Agent Runner 调用时 → stat 检查文件 → 重读 manifest
        → I/O 抖动 / 不确定顺序 / 缓存失效

   正确设计(快照稳定):
        启动期一次性加载 → 进程内不可变快照
        运行时只读快照,不接触文件系统
```

## 协作流程

### 一次启动期插件加载的全过程

下面追踪 Gateway 启动阶段 5 从扫描到登记的全过程。

```
Gateway 启动到阶段 5(Plugins)
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 发现层执行                                                │
│    • 从 SQLite 共享库读 install 记录                          │
│    • 扫描每个 install 路径                                    │
│    • 检查 manifest 文件存在                                  │
│    • 产出初步候选清单(含 provenance:来源、版本)            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 加载层读取 manifest                                       │
│    • 逐个候选插件读取 manifest                                │
│    • 加载模块运行时(loader 模块运行时)                       │
│    • 产出加载记录(provenance + 元数据)                       │
│    • 加载缓存命中 → 直接复用                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Schema 校验器执行                                         │
│    • 校验 manifest 格式合规(字段、类型、必填)              │
│    • 失败 → 该插件拒绝登记,记录诊断                          │
│    • 通过 → 进入下一步                                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 诊断输出                                                  │
│    • 汇总所有失败原因 / 警告 / 修复提示                       │
│    • 输出到日志 / Doctor 报告                                 │
│    • 不影响其他插件继续登记                                   │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 槽位选择                                                  │
│    • 读取配置(openclaw.json + 默认值)                       │
│    • 检查每类能力的槽位约束(如 Provider 槽位数)             │
│    • 多个插件竞争同一槽位 → 按优先级选择                      │
│    • 产出激活清单                                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. 工具层处理                                                │
│    • 校验工具契约                                            │
│    • 工具描述符缓存构建                                       │
│    • 工具授权白名单检查                                       │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. 提交候选清单给注册表核心                                  │
│    • 注册表核心接收激活清单                                   │
│    • 各 registrar 按类别登记                                  │
│    • 注册表状态构建不可变快照                                 │
└──────────────────────────────────────────────────────────────┘
```

### 槽位冲突的解决过程

```
场景:多个 Provider 插件竞争同一槽位

   候选清单到达槽位选择
         │
         ▼
   ┌──────────────────────────────────┐
   │ 检查槽位定义                     │
   │ • Provider 槽位数 = N            │
   │ • 候选数 > N → 需选择            │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 读取配置优先级                   │
   │ • 用户配置的优先级               │
   │ • 默认优先级                     │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 按优先级选择                     │
   │ • 选择前 N 个                     │
   │ • 其余标记为"未激活"             │
   └────────────────┬─────────────────┘
                    ▼
   ┌──────────────────────────────────┐
   │ 产出激活清单                     │
   │ • 激活的插件 → 提交注册表        │
   │ • 未激活的插件 → 记录但跳过      │
   └──────────────────────────────────┘
```

## 关键设计约束

### 1. 启动期一次性执行

- **为什么**:运行时热路径若重新发现文件,会引入 I/O 抖动、不确定顺序、缓存失效
- **怎么做**:加载与发现在启动阶段 5 执行一次;产出进程内不可变快照
- **影响**:运行时修改能力必须走 install / uninstall / reload 流程

### 2. 加载失败 fail closed,不影响其他插件

- **为什么**:一个插件加载失败不应导致整个 Gateway 启动失败
- **怎么做**:每个插件独立加载;失败记录诊断,跳过该插件,继续其他
- **影响**:用户能看到失败原因;其他插件正常工作

### 3. Schema 校验严格

- **为什么**:不合规 manifest 会导致运行时崩溃;校验是第一道防线
- **怎么做**:Schema 校验器在加载后立即执行;失败即拒绝登记
- **影响**:插件作者必须遵循 manifest 契约;Doctor 提供修复提示

### 4. 槽位选择确定性

- **为什么**:同配置多次启动得到相同激活清单;prompt cache 友好
- **怎么做**:槽位选择按确定顺序(配置优先级 + 默认值);不引入随机性
- **影响**:同一台机器多次启动加载相同插件集

### 5. 工具表确定排序

- **为什么**:prompt cache 对工具表顺序敏感;不确定顺序导致 cache miss
- **怎么做**:工具层对工具表做确定性排序(map / set 在序列化前排序)
- **影响**:相同插件集产生相同工具表顺序

### 6. 加载缓存进程级

- **为什么**:避免重复扫描与解析;启动后文件系统状态稳定
- **怎么做**:加载缓存进程级,生命周期与进程绑定;不跨进程共享
- **影响**:reload 流程会重建缓存;不影响运行时实例

## 设计观察

### 为什么发现与加载分离

```
错误设计(发现 + 加载混在一起):
        扫描目录时同时读取 manifest
        → 一个目录读取失败影响整体扫描
        → manifest 解析慢时拖累发现

正确设计:
        发现层只检查文件存在,产出候选清单
        加载层逐个读取 manifest,失败可隔离
        → 发现快;加载可并行
        → 失败隔离到单插件
```

### 为什么槽位机制而非自由注册

```
错误设计(所有插件自由注册):
        已安装插件全部登记到注册表
        → 同类能力多个插件冲突(如多个 Provider)
        → Agent 不知道用哪个
        → 用户配置复杂

正确设计:
        槽位机制控制每类能力的插件数
        • 配置驱动,有默认值
        • 多个插件竞争 → 按优先级选择
        → 同类能力不冲突
        → 用户配置简单
```

### 为什么工具层独立于注册表登记

```
错误设计(工具表在注册表登记时构建):
        registrar 登记时同时构建工具表
        → 工具表包含运行时元数据,与注册表职责混淆
        → 工具描述符缓存与注册表快照生命周期不一致

正确设计:
        工具层独立于注册表登记
        • 工具契约校验
        • 工具描述符缓存(独立生命周期)
        • 工具授权白名单
        → 注册表只登记工具入口
        → 工具表运行时按需构建
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/00-overview.md) | 插件注册表总览 |
| [01-registry-core.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/01-registry-core.md) | 注册表核心 |
| [02-provider-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/02-provider-runtime.md) | Provider 运行时 |
| [03-plugin-runtime.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/03-plugin-runtime.md) | 插件运行时 |
| [04-loader-discovery.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/04-loader-discovery.md) | 本文件 — 加载与发现 |
| [05-web-session-catalog.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.3-plugin-registry/05-web-session-catalog.md) | Web 能力与会话目录 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 加载器入口 | [src/plugins/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader.ts) |
| 加载器类型 | [src/plugins/loader-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-types.ts) |
| 加载器共享 | [src/plugins/loader-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-shared.ts) |
| 加载器发现 | [src/plugins/loader-discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-discovery.ts) |
| 加载器运行时加载 | [src/plugins/loader-runtime-load.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-runtime-load.ts) |
| 加载器运行时注册 | [src/plugins/loader-runtime-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-runtime-registry.ts) |
| 加载器运行时候选 | [src/plugins/loader-runtime-candidate.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-runtime-candidate.ts) |
| 加载器注册计划 | [src/plugins/loader-registration-plan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-registration-plan.ts) |
| 加载器记录 | [src/plugins/loader-records.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-records.ts) |
| 加载器 provenance | [src/plugins/loader-provenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-provenance.ts) |
| 加载器模块运行时 | [src/plugins/loader-module-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-module-runtime.ts) |
| 加载器加载上下文 | [src/plugins/loader-load-context.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-load-context.ts) |
| 加载器缓存 | [src/plugins/loader-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cache.ts) |
| 加载器缓存状态 | [src/plugins/loader-cache-state.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cache-state.ts) |
| 加载器缓存实例 | [src/plugins/loader-cache-instances.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cache-instances.ts) |
| 加载器渠道运行时 | [src/plugins/loader-channel-runtime.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-channel-runtime.ts) |
| 加载器渠道设置 | [src/plugins/loader-channel-setup.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-channel-setup.ts) |
| 加载器 CLI 注册 | [src/plugins/loader-cli-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cli-registry.ts) |
| 发现入口 | [src/plugins/discovery.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/discovery.ts) |
| installs 入口 | [src/plugins/installs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/installs.ts) |
| install 入口 | [src/plugins/install.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/install.ts) |
| install 包 | [src/plugins/install-package.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/install-package.ts) |
| install 持久化 | [src/plugins/install-persistence.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/install-persistence.ts) |
| install provenance | [src/plugins/install-provenance.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/install-provenance.ts) |
| Schema 校验器 | [src/plugins/schema-validator.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/schema-validator.ts) |
| 校验诊断 | [src/plugins/validation-diagnostics.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/validation-diagnostics.ts) |
| 槽位 | [src/plugins/slots.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/slots.ts) |
| 槽位选择 | [src/plugins/slot-selection.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/slot-selection.ts) |
| 工具类型 | [src/plugins/tool-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tool-types.ts) |
| 工具契约 | [src/plugins/tool-contracts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tool-contracts.ts) |
| 工具描述符缓存 | [src/plugins/tool-descriptor-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tool-descriptor-cache.ts) |
| 工具授权白名单 | [src/plugins/tool-grant-allowlist.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/tool-grant-allowlist.ts) |
| 已安装插件索引 | [src/plugins/installed-plugin-index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/installed-plugin-index.ts) |
| 已安装插件索引存储 | [src/plugins/installed-plugin-index-store.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/installed-plugin-index-store.ts) |
| 已安装插件索引注册 | [src/plugins/installed-plugin-index-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/installed-plugin-index-registry.ts) |
| Manifest | [src/plugins/manifest.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/manifest.ts) |
| Manifest Registry | [src/plugins/manifest-registry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/manifest-registry.ts) |
| Manifest 类型 | [src/plugins/manifest-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/manifest-types.ts) |
| Manifest 元数据扫描 | [src/plugins/manifest-metadata-scan.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/manifest-metadata-scan.ts) |
