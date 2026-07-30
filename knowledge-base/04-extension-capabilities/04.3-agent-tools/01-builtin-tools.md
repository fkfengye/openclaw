# 01 — 内置工具集

> 读完本章你将理解:Agent 内置工具由哪些组件构成、可变编码与只读发现两套集合如何划分、共享设施如何承载输出截断与文件变更排队,以及为何所有内置工具走同一注册边界。

## 一句话定位

内置工具集是 Agent 会话的**基础能力底座**:
- 提供 bash 执行、文件读写、查找检索共 7 类原子能力
- 按"可变编码"与"只读发现"两套集合对外暴露,匹配不同会话权限
- 输出截断、文件变更排队、路径工具、私有临时文件等共享设施统一承载

## 全局协作图

下图展示内置工具集在 Agent 工具集中的位置,以及 7 类工具与共享设施如何协作。

```
                    Agent Runner
                        │
                        │ 请求工具表
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              内置工具集(本章范围)                                │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  工具定义包装层                                          │  │
│   │  (统一形状 / 公开 barrel / 按名构造)                    │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 分两套集合对外                      │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  可变编码集                只读发现集                      │  │
│   │  (本地 agent 会话)        (受限会话)                      │  │
│   │                                                            │  │
│   │  • bash 执行              • read 读文件                   │  │
│   │  • edit 编辑              • grep 内容检索                  │  │
│   │  • write 写文件           • find 文件查找                  │  │
│   │  • read 读文件            • ls 目录列表                    │  │
│   └────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│                            │ 共享基础设施                        │
│                            ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  输出截断  │  文件变更排队  │  路径工具  │  私有临时文件    │  │
│   │  渲染工具  │  工具契约      │  限额      │                  │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  本地文件系统           │
                  │  (cwd 作用域内)        │
                  └────────────────────────┘
```

## 组件清单

内置工具集由 7 类工具 + 7 类共享设施构成:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **bash 执行** | 在 cwd 作用域内执行 shell 命令,捕获 stdout/stderr | 超时可控,长输出落临时文件 |
| **edit 编辑** | 对文件做精确字符串替换,产出 diff 与 patch | 受文件变更排队串行化,避免写竞争 |
| **write 写文件** | 整文件写入,覆盖或新建 | 受文件变更排队串行化 |
| **read 读文件** | 读取文件内容,带行号 | 输出超长时走截断 |
| **grep 内容检索** | 基于 ripgrep 的内容搜索 | 流式错误处理,不因 stderr 中断 |
| **find 文件查找** | 基于文件名模式查找 | 跨平台 fallback |
| **ls 目录列表** | 列出目录内容 | 按修改时间排序 |
| **输出截断** | 按字节 / 行数截断,保留头尾 | 头尾保留保证可读 |
| **文件变更排队** | 同文件写操作串行化 | 防止并发写竞争 |
| **路径工具** | cwd 解析、相对路径计算 | 受会话 cwd 作用域约束 |
| **私有临时文件** | 长输出落临时文件,返回引用 | 私有路径,不暴露全局 |
| **渲染工具** | 工具结果的可视化渲染 | 与工具契约对齐 |
| **工具契约** | 统一输入 / 详情类型 | 工具实现与调用方对齐 |
| **限额** | 工具执行的资源上限 | 防止单工具耗尽资源 |

## 关联关系

### 可变编码集与只读发现集

```
   ┌─────────────────────────────────────────────┐
   │ 可变编码集(本地 agent 会话)               │
   │                                             │
   │  read ── bash ── edit ── write              │
   │                                             │
   │  特点:可改变文件系统状态                   │
   │  用途:代码会话 / 自动化任务                │
   └─────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────┐
   │ 只读发现集(受限会话)                       │
   │                                             │
   │  read ── grep ── find ── ls                 │
   │                                             │
   │  特点:不改变文件系统状态                   │
   │  用途:检索 / 调查 / 受权限约束的场景       │
   └─────────────────────────────────────────────┘

   两套集合都包含 read,因为读是基础能力
```

### 文件变更排队的作用域

```
   错误设计:
      edit 工具 ──直接写──► 文件
      write 工具 ──直接写──► 同一文件
      → 并发写竞争 → 内容损坏

   正确设计:
      edit 工具 ─┐
                  ├──► 文件变更排队 ──► 串行写 ──► 文件
      write 工具 ─┘
      → 同文件写操作串行化 → 内容一致
```

### 输出截断与临时文件

```
   工具产生长输出
         │
         ▼
   ┌─────────────────────────────────┐
   │ 输出截断                        │
   │ • 按字节上限截断                │
   │ • 保留头部 + 尾部               │
   │ • 超出部分落私有临时文件        │
   └──────────────┬──────────────────┘
                  │
                  ▼
   ┌─────────────────────────────────┐
   │ 返回 LLM 的结果                 │
   │ • 截断后的预览                  │
   │ • 临时文件引用(供后续 read)   │
   └─────────────────────────────────┘
```

## 协作流程

### 一次 bash 工具调用的旅程

下面追踪 LLM 调用 bash 执行一条命令到结果回送的全过程。

```
LLM 调用 bash 工具,传入命令
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 工具查找                                                  │
│    按名在已注册工具表中命中 bash 工具                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 命令执行                                                  │
│    → 在会话 cwd 作用域内 spawn shell                         │
│    → 捕获 stdout / stderr                                    │
│    → 应用超时控制                                            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 输出处理                                                  │
│    → 短输出:直接返回                                        │
│    → 长输出:走截断,超出部分落私有临时文件                  │
│    → 返回截断预览 + 临时文件引用                             │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 结果回送 LLM                                              │
│    → LLM 看到预览,如需完整输出可再调用 read 读临时文件      │
└──────────────────────────────────────────────────────────────┘
```

### 一次 edit 工具调用的旅程

```
LLM 调用 edit 工具,传入文件路径与替换内容
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 进入文件变更队列                                          │
│    → 同文件写操作串行化,等待前序写完成                      │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 读取并校验文件                                            │
│    → 读取原文件                                              │
│    → 校验待替换字符串是否存在且唯一                          │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 应用替换                                                  │
│    → 生成 diff 与 patch                                      │
│    → 写回文件                                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 返回变更详情                                              │
│    → 变更标记 / diff / patch / 首行变更位置                  │
│    → 离开文件变更队列                                        │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. 工具按名构造,统一形状

- **为什么**:调用方需要按工具名动态构造工具,且所有工具形状一致
- **怎么做**:通过工具定义包装层提供按名构造入口,所有工具走同一接口
- **影响**:新增内置工具只需在包装层注册,调用方无需改造

### 2. 可变编码与只读发现两套集合

- **为什么**:受限会话需要禁用变更能力,而按名单过滤易遗漏且破坏排序稳定性
- **怎么做**:预定义两套集合,可变编码集含 bash/edit/write/read,只读发现集含 read/grep/find/ls
- **影响**:会话按权限直接挂载对应集合,边界清晰,排序稳定

### 3. 文件变更排队串行化

- **为什么**:edit 与 write 可能并发操作同一文件,导致内容损坏
- **怎么做**:同文件写操作进入排队,串行执行
- **影响**:工具实现无需关心并发,排队层保证一致性

### 4. 输出截断保护 LLM 上下文

- **为什么**:bash / grep 等可能产生超长输出,直接回送会撑爆 LLM 上下文
- **怎么做**:按字节与行数双上限截断,保留头尾,超出部分落私有临时文件并返回引用
- **影响**:LLM 拿到可读预览,需要完整内容时再通过 read 工具读取

### 5. 工具契约统一输入与详情类型

- **为什么**:工具实现方、渲染方、调用方需对齐 payload 形状
- **怎么做**:工具契约模块统一定义每类工具的输入与详情类型
- **影响**:新增工具不影响既有类型,跨方协作有契约保障

### 6. cwd 作用域约束

- **为什么**:工具不应越界访问会话工作目录之外的文件
- **怎么做**:路径工具统一在会话 cwd 作用域内解析
- **影响**:不同会话的工具调用相互隔离

## 设计观察

### 为什么 grep 工具需要流式错误处理

```
错误设计:
   grep 执行中 stderr 输出错误
   → 立即中断 → 已收集的 stdout 结果丢失

正确设计:
   grep 流式收集 stdout
   → stderr 错误单独累积,不中断 stdout
   → 执行结束后合并返回
   → 部分结果仍可用
```

### 为什么共享设施集中而非散落各工具

```
散落设计:
   bash 工具自带截断
   grep 工具自带截断
   read 工具自带截断
   → 三份截断逻辑 → 行为不一致 → 维护负担

集中设计:
   截断共享设施 ──► bash / grep / read 共用
   → 一份逻辑 → 行为一致 → 维护集中
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/00-overview.md) | 工具集总览与策略 |
| [01-builtin-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/01-builtin-tools.md) | 本文件 — 内置工具集 |
| [02-web-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/02-web-tools.md) | Web 工具:fetch / search / guarded-fetch / shared |
| [03-sessions-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/03-sessions-tools.md) | 会话工具:list / history / search / send / spawn / yield / access |
| [04-media-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/04-media-tools.md) | 媒体生成工具:image / music / video / pdf |
| [05-other-tools.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/04-extension-capabilities/04.3-agent-tools/05-other-tools.md) | 其他工具:computer / terminal / tts / dashboard / goal / nodes / message 等 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 内置工具公开 barrel | [src/agents/sessions/tools/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/index.ts) |
| bash 执行 | [src/agents/sessions/tools/bash.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/bash.ts) |
| bash 操作 | [src/agents/sessions/tools/bash-operations.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/bash-operations.ts) |
| edit 编辑 | [src/agents/sessions/tools/edit.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/edit.ts) |
| edit diff | [src/agents/sessions/tools/edit-diff.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/edit-diff.ts) |
| write 写文件 | [src/agents/sessions/tools/write.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/write.ts) |
| read 读文件 | [src/agents/sessions/tools/read.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/read.ts) |
| grep 内容检索 | [src/agents/sessions/tools/grep.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/grep.ts) |
| find 文件查找 | [src/agents/sessions/tools/find.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/find.ts) |
| ls 目录列表 | [src/agents/sessions/tools/ls.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/ls.ts) |
| 输出截断 | [src/agents/sessions/tools/truncate.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/truncate.ts) |
| 文件变更排队 | [src/agents/sessions/tools/file-mutation-queue.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/file-mutation-queue.ts) |
| 路径工具 | [src/agents/sessions/tools/path-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/path-utils.ts) |
| 私有临时文件 | [src/agents/sessions/tools/private-temp-file.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/private-temp-file.ts) |
| 渲染工具 | [src/agents/sessions/tools/render-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/render-utils.ts) |
| 工具契约 | [src/agents/sessions/tools/tool-contracts.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/tool-contracts.ts) |
| 工具定义包装 | [src/agents/sessions/tools/tool-definition-wrapper.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/tool-definition-wrapper.ts) |
| 限额 | [src/agents/sessions/tools/limits.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/limits.ts) |
| 输出累积器 | [src/agents/sessions/tools/output-accumulator.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/tools/output-accumulator.ts) |
