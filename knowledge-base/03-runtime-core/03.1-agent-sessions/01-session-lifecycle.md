# 01 — 会话生命周期层

> 读完本章你将理解:一次 Agent 会话如何被创建、执行、检视、提示并导航,以及为什么用"基类→特化"的分层继承组织这 15+ 个会话类文件。

## 一句话定位

会话生命周期层把一次会话的所有行为拆成**垂直继承栈**:
- 最底层持有配置与依赖,每往上一层增加一类能力(模型/检视/压缩/扩展/执行/树导航)
- 顶层会话类只负责组装,模式特定 I/O(交互/打印/RPC)留在调用方
- 共享同一会话状态,无跨对象同步问题

## 全局协作图

下图展示会话生命周期层的分层继承栈,以及它如何被调用方使用。**框里是组件名+职责,不是函数名**。

```
                 调用方(交互模式 / 打印模式 / RPC 模式)
                              │
                              │ 创建会话对象
                              ▼
        ┌─────────────────────────────────────────────────┐
        │  顶层会话类(组装)                              │
        │  • 订阅 agent 事件                              │
        │  • 安装工具 Hook                                │
        │  • 构建运行时能力表                             │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  树导航层                                        │
        │  • 会话树节点跳转(同文件内,非 fork)          │
        │  • 分支摘要(总结被放弃的分支)                 │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  执行层                                          │
        │  • 可重试错误判定(过载/限流/服务器错误)        │
        │  • 指数退避重试                                  │
        │  • bash 命令执行接入                             │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  扩展集成层                                      │
        │  • 扩展运行器生命周期管理                        │
        │  • 扩展工具与事件接入                            │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  压缩层                                          │
        │  • 上下文超阈值压缩                              │
        │  • 手动/阈值/溢出三种触发                        │
        │  • 摘要生成 + 历史裁剪                           │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  检视层                                          │
        │  • 会话统计(上下文用量)                        │
        │  • 会话条目管理                                  │
        │  • 诊断信息导出                                  │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  模型处理层                                      │
        │  • 模型变更                                      │
        │  • 思考级别切换                                  │
        └────────────────────┬────────────────────────────┘
                             │ extends
                             ▼
        ┌─────────────────────────────────────────────────┐
        │  基类(配置与依赖)                              │
        │  • 注入 logger / store / agent 运行时            │
        │  • 持有会话管理器与设置管理器                    │
        │  • 系统提示构建选项                              │
        └─────────────────────────────────────────────────┘
```

## 组件清单

会话生命周期层由 8 个继承层 + 多个支撑文件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **顶层会话类** | 组装各层,订阅事件,安装工具 Hook | 唯一具体类,其余为抽象层 |
| **树导航层** | 同文件内节点跳转,分支摘要 | fork 创建新文件,导航不创建 |
| **执行层** | 可重试判定,指数退避,bash 接入 | 上下文溢出不可重试(交给压缩) |
| **扩展集成层** | 扩展运行器生命周期与事件接入 | 工具调用/结果拦截由 agent-core Hook 处理 |
| **压缩层** | 上下文压缩,三种触发模式 | 压缩委托共享 agent-core |
| **检视层** | 会话统计,条目管理,诊断导出 | 上下文用量估算 |
| **模型处理层** | 模型变更,思考级别切换 | 思考级别有固定枚举 |
| **基类** | 注入依赖,持有管理器 | 依赖注入便于测试替换 |
| **类型定义** | 会话配置与事件类型 | 模式特定 I/O 不在此定义 |
| **工具集** | 提示构建辅助与文本提取 | 纯函数,无状态 |

## 关联关系

### 继承栈与支撑模块

```
   ┌──────────────────────────────────────────┐
   │  继承栈(垂直分层)                      │
   │                                          │
   │  顶层会话                                │
   │    ↑ 树导航                              │
   │      ↑ 执行                              │
   │        ↑ 扩展集成                        │
   │          ↑ 压缩                          │
   │            ↑ 检视                        │
   │              ↑ 模型处理                  │
   │                ↑ 基类                    │
   └──────────────────┬───────────────────────┘
                      │ 持有 / 调用
                      ▼
   ┌──────────────────────────────────────────┐
   │  支撑模块(水平协作)                    │
   │                                          │
   │  • 会话管理器(分支/持久化)             │
   │  • 设置管理器(重试/压缩设置)           │
   │  • 模型注册表运行时                      │
   │  • 系统提示构建器                        │
   │  • 事件总线                              │
   │  • 认证引导文案                          │
   └──────────────────────────────────────────┘
```

### 三种调用模式共用同一继承栈

```
   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
   │ 交互模式    │  │ 打印模式    │  │ RPC 模式    │
   │ (TUI 渲染)  │  │ (单次输出)  │  │ (远程调用)  │
   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
          │                │                │
          │   模式特定 I/O 留在各自调用方
          └────────────────┼────────────────┘
                           │ 共用
                           ▼
              ┌────────────────────────┐
              │  会话生命周期继承栈    │
              │  (行为层,无 I/O)      │
              └────────────────────────┘

   反例:把 TUI 渲染逻辑塞进继承栈
        → 打印模式被迫加载 TUI 依赖
        → RPC 模式无法复用会话行为
```

## 协作流程

### 一次会话创建到执行的接力

下面追踪会话对象从构造到执行一轮 turn 的全过程。

```
调用方请求创建会话
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 基类初始化                                                 │
│    → 注入依赖(logger / store / agent 运行时)               │
│    → 持有会话管理器与设置管理器引用                          │
│    → 准备系统提示构建选项                                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 顶层会话类构造                                            │
│    → 订阅 agent 事件 → 转发到会话事件监听器                  │
│    → 安装工具 Hook(agent 工具接入会话)                     │
│    → 构建运行时能力表(活跃工具名 + 全部扩展工具)           │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 执行一轮 turn                                             │
│    → 调 LLM 流式接收                                         │
│    → 收到错误?                                              │
│        ├─ 上下文溢出 → 交给压缩层处理                        │
│        └─ 过载/限流 → 执行层指数退避重试                     │
│    → 收到 tool call?                                         │
│        ├─ bash → 执行层接入 bash 执行器                      │
│        └─ 其他 → 扩展集成层分发到扩展工具                    │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. 上下文管理(按需)                                        │
│    → 检视层估算上下文用量                                    │
│    → 超阈值?压缩层触发压缩(摘要 + 裁剪)                   │
│    → 用户切换分支?树导航层跳转节点 + 分支摘要               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 模型变更(按需)                                          │
│    → 模型处理层切换模型 / 思考级别                           │
│    → 写入会话条目(模型变更记录)                            │
└──────────────────────────────────────────────────────────────┘
```

### 可重试错误 vs 上下文溢出的分流

为什么要把上下文溢出排除在重试之外?用反例说明。

```
场景:LLM 返回错误,原因是上下文太长

错误做法(一律重试):
   错误 → 重试 → 还是上下文太长 → 再重试 → 死循环
   → 浪费配额,用户等待

正确做法(分流):
   错误 → 判定类型
          ├─ 过载/限流/服务器错误 → 执行层重试(退避)
          └─ 上下文溢出 → 压缩层处理(摘要+裁剪后重发)
   → 限流错误重试有意义,溢出错误重试无意义
```

## 关键设计约束

### 1. 继承栈共享同一会话状态

- **为什么**:避免多个对象持有同一会话状态导致同步问题
- **怎么做**:所有层通过继承访问同一基类持有的会话管理器与设置管理器
- **影响**:状态变更立即可见,无需跨对象通知

### 2. 模式特定 I/O 不进继承栈

- **为什么**:交互/打印/RPC 三种模式共用行为层,I/O 差异大
- **怎么做**:继承栈只提供行为,事件通过监听器接口外发;调用方各自实现渲染
- **影响**:打印模式不会被迫加载 TUI 依赖,RPC 模式可远程复用

### 3. 上下文溢出不重试

- **为什么**:溢出是确定性错误,重试只会浪费配额
- **怎么做**:执行层判定时把溢出排除出可重试集合,交给压缩层
- **影响**:溢出触发压缩,压缩后重发而非重试

### 4. 树导航与 fork 的边界

- **为什么**:导航(同文件跳转)和 fork(新建文件)是两种不同操作,混淆会破坏会话树
- **怎么做**:树导航层只做同文件节点跳转;fork 由会话管理器创建新 transcript
- **影响**:导航不产生新会话文件,fork 产生新文件

### 5. 依赖注入便于测试

- **为什么**:单元测试要隔离,不能启动整个运行时
- **怎么做**:基类从参数接收 logger/store 等,测试时替换为 stub
- **影响**:会话行为可独立测试,无需真实 LLM 调用

## 设计观察

### 为什么用继承而非组合

```
组合方案:
   会话 = 执行器 + 压缩器 + 检视器 + 树导航器 + ...
   • 每个组件独立对象 → 需要共享会话状态的协议
   • 跨对象状态同步 → 复杂,易错
   • 每个组件都要注入相同依赖 → 重复

继承方案(当前):
   基类(状态) → 特化(能力) → 特化(能力) → ... → 顶层
   • 共享同一状态,无同步问题
   • 依赖只注入一次
   • 每层职责单一,可独立阅读
   代价:继承栈较深,但会话行为高度内聚,收益大于成本
```

### 为什么扩展工具拦截由 agent-core Hook 处理

```
错误设计:
   扩展集成层 ──自己实现──► 工具调用拦截 + 结果拦截
   → 与 agent-core 的拦截逻辑重复
   → 两套拦截逻辑可能不一致

正确设计:
   扩展集成层 ──► 包装扩展工具为 agent 工具
                  (实际拦截由 agent-core Hook 统一处理)
   → 单一拦截路径,行为一致
   → 扩展层只负责"把扩展工具接入",不负责拦截语义
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/00-overview.md) | 总览与索引 |
| [01-session-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/01-session-lifecycle.md) | 本文件 — 会话生命周期层 |
| [02-session-manager.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/02-session-manager.md) | 会话管理器 |
| [03-prompt-model.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/03-prompt-model.md) | 提示词与模型 |
| [04-auth-execution.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/04-auth-execution.md) | 认证与执行 |
| [05-compaction-extensions.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.1-agent-sessions/05-compaction-extensions.md) | 压缩与扩展 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| 顶层会话类 | [src/agents/sessions/agent-session.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session.ts) |
| 基类(配置与依赖) | [src/agents/sessions/agent-session-base.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-base.ts) |
| 模型处理层 | [src/agents/sessions/agent-session-models.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-models.ts) |
| 检视层 | [src/agents/sessions/agent-session-inspection.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-inspection.ts) |
| 压缩层 | [src/agents/sessions/agent-session-compaction.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-compaction.ts) |
| 扩展集成层 | [src/agents/sessions/agent-session-extensions.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-extensions.ts) |
| 执行层 | [src/agents/sessions/agent-session-execution.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-execution.ts) |
| 树导航层 | [src/agents/sessions/agent-session-tree.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-tree.ts) |
| 提示构建层 | [src/agents/sessions/agent-session-prompting.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-prompting.ts) |
| 会话类型定义 | [src/agents/sessions/agent-session-types.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-types.ts) |
| 会话工具集 | [src/agents/sessions/agent-session-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/agent-session-utils.ts) |
| 会话 SDK 入口 | [src/agents/sessions/sdk.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/sdk.ts) |
| 会话默认值 | [src/agents/sessions/defaults.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/defaults.ts) |
| 诊断导出 | [src/agents/sessions/diagnostics.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/diagnostics.ts) |
| 事件总线 | [src/agents/sessions/event-bus.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/event-bus.ts) |
| 会话消息类型 | [src/agents/sessions/messages.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/messages.ts) |
| 设置管理器 | [src/agents/sessions/settings-manager.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/settings-manager.ts) |
| 手动压缩预检 | [src/agents/sessions/manual-compaction-preflight.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/sessions/manual-compaction-preflight.ts) |
