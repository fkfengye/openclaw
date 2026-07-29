# 01 — 文件系统 / 路径 / 环境

> 读完本章你将理解:OpenClaw 如何安全地读写文件、解析路径、处理符号链接,以及环境变量与 dotenv 如何注入到运行时。

## 一句话定位

这一层是基础设施的最底层,负责所有本地 IO 原语:
- 路径解析(含符号链接归一、越界校验、平台分隔符)
- JSON 文件原子读写
- 环境变量、shell 环境、dotenv 注入
- 只依赖 Node.js 标准库,不被任何上层模块依赖

## 全局协作图

下图展示文件系统/路径/环境层内部组件如何协作,以及如何被上层消费。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       上层消费者                                     │
│   Gateway 配置加载    Agent 状态库    插件加载    备份归档          │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               │ 通过文件系统/路径/环境原语
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       分层 1:文件系统 / 路径 / 环境                 │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│   │ 文件安全工具 │  │ JSON 文件    │  │ 路径工具                 │  │
│   │              │  │ 读写器       │  │                          │  │
│   │ • 读写       │  │              │  │ • 安全边界校验           │  │
│   │ • 删除       │  │ • 原子写入   │  │ • 前缀注入               │  │
│   │ • 默认值     │  │ • UTF-8 字节 │  │ • 别名守卫               │  │
│   │ • 高级操作   │  │ • 多文件聚合 │  │ • 环境路径               │  │
│   └──────────────┘  └──────────────┘  └──────────────────────────┘  │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│   │ 主目录解析器 │  │ Shell 环境   │  │ Dotenv 注入器            │  │
│   │              │  │              │  │                          │  │
│   │ • 跨平台     │  │ • 登录 shell │  │ • 工作区黑名单           │  │
│   │   HOME       │  │   环境采集   │  │ • 全局 dotenv            │  │
│   │ • 状态目录   │  │ • PATH 拼接 │  │ • 与环境变量归一         │  │
│   └──────────────┘  └──────────────┘  └──────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────┐
                  │  Node.js fs / path   │
                  │  / os 模块           │
                  └──────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **文件安全工具** | 安全读写、删除、默认值、高级文件操作 | 路径越界强校验;删除走受控通道 |
| **JSON 文件读写器** | JSON 文件原子读写、UTF-8 字节处理、多文件聚合 | 原子写入避免半写状态;UTF-8 字节边界处理 |
| **路径工具** | 安全边界、前缀注入、别名守卫、环境路径 | 跨平台路径分隔符;别名不允许逃逸 |
| **主目录解析器** | 跨平台 HOME / 状态目录解析 | 不假设 HOME 一定存在;状态目录可被环境覆盖 |
| **Shell 环境采集器** | 登录 shell 环境采集、PATH 拼接 | 不执行任意 shell;PATH 合并去重 |
| **Dotenv 注入器** | dotenv 解析、工作区黑名单、全局 dotenv、与环境变量归一 | 工作区级 dotenv 可被黑名单屏蔽;不覆盖已有环境变量 |

## 关联关系

### 路径解析与符号链接归一

```
   输入路径(可能是符号链接或相对路径)
         │
         ▼
   ┌──────────────────────────┐
   │  路径工具                │
   │                          │
   │  ① 边界校验             │ ── 越界?── 拒绝
   │  ② 前缀注入             │
   │  ③ 符号链接归一         │ ── macOS /var → /private/var
   │  ④ 平台分隔符归一       │ ── Windows \ → /
   └────────────┬─────────────┘
                │
                ▼
        规范化后的绝对路径
        (可被上层安全使用)
```

### 环境变量的多源归一

```
   进程启动时的环境来源:
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │  系统环境    │  │  Shell 环境  │  │  Dotenv 文件 │
   │  (process)  │  │  (登录 shell)│  │  (.env)      │
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
          │                 │                 │
          └────────────────┬┴─────────────────┘
                           ▼
              ┌─────────────────────────┐
              │  归一化后的运行时环境   │
              │                         │
              │  规则:                  │
              │  • 系统环境优先          │
              │  • dotenv 不覆盖已有    │
              │  • 工作区黑名单屏蔽      │
              └─────────────────────────┘
```

### 错误对比:符号链接是否归一

```
错误做法(直接用临时目录路径断言):
   os.tmpdir()  →  /var/folders/xxx
   写入文件后断言路径在 /var/folders/xxx 下
   → macOS CI 失败:实际路径是 /private/var/folders/xxx

正确做法(先 realpath 归一):
   tmpRoot = fs.realpath(mkdtemp(...))
   断言路径在 realpath 后的根下
   → macOS / Linux 一致通过
```

## 协作流程

### 一次配置文件加载的完整旅程

```
上层请求:读取配置目录下的 JSON
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 主目录解析器                                               │
│    → 跨平台解析 HOME / 状态目录                              │
│    → 状态目录可被环境变量覆盖                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 路径工具                                                   │
│    → 拼接配置目录 + 文件名                                   │
│    → 边界校验:确保路径不逃逸出状态目录                      │
│    → 符号链接归一(macOS /var → /private/var)               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 文件安全工具                                               │
│    → 探测文件存在性                                           │
│    → 受控读取(权限/编码处理)                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. JSON 文件读写器                                            │
│    → 解析 JSON(UTF-8 字节边界处理)                         │
│    → 校验结构                                                 │
│    → 返回归一化对象                                           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
                  上层获得配置对象
```

### Dotenv 注入到运行时的流程

```
进程启动
     │
     ▼
┌──────────────────────────────────────────────────────┐
│ 1. 采集系统环境变量                                  │
│    → process.env 作为基底                           │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 2. Shell 环境采集器                                  │
│    → 启动登录 shell 读取环境                         │
│    → 合并 PATH(去重)                               │
└────────────────────────────┬─────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────┐
│ 3. Dotenv 注入器                                     │
│    → 解析工作区 .env                                │
│    → 工作区黑名单校验(可屏蔽)                      │
│    → 解析全局 dotenv                                │
│    → 注入规则:不覆盖已有系统环境变量                │
└────────────────────────────┬─────────────────────────┘
                             ▼
                  归一化后的运行时环境
                  供上层所有组件使用
```

## 关键设计约束

### 1. 符号链接必须归一

- **为什么**:macOS 的 `/var` 是 `/private/var` 的符号链接,生产解析器返回规范路径,raw 临时目录断言在 macOS 会失败
- **怎么做**:路径解析走 `realpath` 归一;测试断言路径归属前先 realpath 临时根
- **影响**:Linux CI 通过但 macOS 本地失败的路径 bug 被消除

### 2. 路径越界强校验

- **为什么**:防止配置/状态目录被路径穿越(`../`)逃逸到任意位置读写
- **怎么做**:边界校验 + 前缀注入 + 别名守卫,所有路径必须在受控根下
- **影响**:插件/外部输入不能触达非授权目录

### 3. JSON 原子写入

- **为什么**:进程崩溃时半写文件会让下次启动加载失败
- **怎么做**:写入临时文件后原子重命名;UTF-8 字节边界处理避免截断字符
- **影响**:配置/状态文件即使中途崩溃也保持完整

### 4. 环境变量优先级固定

- **为什么**:防止 dotenv 静默覆盖系统配置导致行为不可预测
- **怎么做**:系统环境变量优先;dotenv 只填充未设置的键;工作区级 dotenv 可被黑名单屏蔽
- **影响**:运维可通过系统环境变量强制覆盖 dotenv

### 5. 状态目录可被环境覆盖

- **为什么**:测试与多实例部署需要隔离状态目录
- **怎么做**:主目录解析器优先读环境变量指定的状态目录
- **影响**:同一机器可跑多套隔离实例

## 设计观察

### 为什么不直接用 Node.js 原生 fs

```
错误设计:
   上层各处直接调用 Node.js fs API
   → 符号链接、越界、编码、原子性各做一遍 → 不一致

正确设计:
   文件安全工具(统一封装)
        ↑
   上层只通过统一封装访问文件
   → 行为一致,可审计,可替换实现
```

### 为什么 dotenv 不覆盖已有环境变量

```
错误设计:
   dotenv 直接覆盖 process.env
   → 运维设置的紧急环境变量被 .env 静默改写

正确设计:
   系统环境变量(基底)
        └── dotenv 只填空缺键
   → 运维配置永远优先,dotenv 只是默认值来源
```

### 为什么 Shell 环境采集要谨慎

```
错误设计:
   直接执行用户 shell 任意命令采集环境
   → 安全风险:可能执行恶意命令

正确设计:
   只读取登录 shell 的环境变量
   不执行任意命令
   PATH 合并时去重
   → 拿到 nvm/pyenv 等环境,又不引入执行风险
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/00-overview.md) | 基础设施总览 |
| [01-fs-path-env.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/01-fs-path-env.md) | 本文件 — 文件系统 / 路径 / 环境 |
| [02-net-tls.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/02-net-tls.md) | 网络 / TLS |
| [03-exec-process.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/03-exec-process.md) | 执行 / 进程 |
| [04-platform-specific.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/02-foundation-layer/02.3-infra/04-platform-specific.md) | 平台特定 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 文件安全工具 | [src/infra/fs-safe.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe.ts) |
| 文件安全高级 | [src/infra/fs-safe-advanced.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe-advanced.ts) |
| 文件安全默认值 | [src/infra/fs-safe-defaults.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe-defaults.ts) |
| 文件安全删除 | [src/infra/fs-safe-remove.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/fs-safe-remove.ts) |
| JSON 文件读写 | [src/infra/json-file.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/json-file.ts) |
| JSON 多文件 | [src/infra/json-files.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/json-files.ts) |
| JSON UTF-8 字节 | [src/infra/json-utf8-bytes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/json-utf8-bytes.ts) |
| 路径安全边界 | [src/infra/path-safety.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-safety.ts) |
| 路径前缀注入 | [src/infra/path-prepend.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-prepend.ts) |
| 路径守卫 | [src/infra/path-guards.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-guards.ts) |
| 路径环境 | [src/infra/path-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-env.ts) |
| 路径别名守卫 | [src/infra/path-alias-guards.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/path-alias-guards.ts) |
| 主目录解析 | [src/infra/home-dir.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/home-dir.ts) |
| Shell 环境 | [src/infra/shell-env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/shell-env.ts) |
| Dotenv 解析 | [src/infra/dotenv.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/dotenv.ts) |
| Dotenv 全局 | [src/infra/dotenv-global.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/dotenv-global.ts) |
| 环境变量 | [src/infra/env.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/infra/env.ts) |
