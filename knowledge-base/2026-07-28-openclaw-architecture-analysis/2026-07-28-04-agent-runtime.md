# 04 — Agent 运行时流程

入口在 [src/agents/agent-command.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-command.ts) 的 `agentCommandInternal`。

## 4.1 主流程阶段

按代码顺序(基于会话总结中分析的源码):

1. **trace 初始化** — `createAgentCommandTrace(runId, agentId, sessionKey)`,记录每个阶段 mark(start → ... → end)。
2. **依赖解析** — `resolveAgentCommandDeps(deps)`,注入式依赖(便于测试 stub)。
3. **agent 配置加载** — 加载 agent 配置、模型选择、auth profile 解析。
4. **session 准备** — 基于 `sessionKey`,与状态库 `agents/<agentId>/agent/openclaw-agent.sqlite` 绑定。
5. **LLM 请求构造** — 走插件 provider runtime,注入工具表(来自插件注册的 tools)。
6. **流式接收** — 流式接收 LLM 输出,处理 tool calls(同步执行插件 tool hook)。
7. **终态归一化** — 走 [src/agents/agent-run-terminal-outcome.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/agents/agent-run-terminal-outcome.ts)。
8. **落库 + 回复分发** — 状态写入 SQLite,回复分发到 channel。

## 4.2 终态归一化(硬约束)

AGENTS.md "Architecture" 段明确:

> Agent run terminal state: normalize/merge via `src/agents/agent-run-terminal-outcome.ts`; do not rederive timeout/cancel precedence in projections.

即所有 agent run 的终态(timeout/cancel/normal completion)必须经此模块归一化,**不允许在 projections 中重新推导优先级**。这是为了避免散落的优先级判断逻辑产生不一致。

## 4.3 Lane 并发控制

[src/gateway/server-lanes.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-lanes.ts) 管理 agent 任务并发 lane。

AGENTS.md "Concurrency Control" 段(conversation 总结提及):

- Lane-based concurrency management for agent tasks
- 避免单 agent 多任务竞争
- 跨 lane 任务调度算法的具体实现细节未在本次深入(待后续精读)

## 4.4 依赖注入

`agentCommandInternal(opts: AgentCommandInternalOptions, deps: AgentCommandDeps)`:

- opts 包含 `runId`、`agentId`、`sessionKey`、`storePath`
- deps 包含 `logger` 等可注入依赖

这种注入式设计便于测试时 stub(AGENTS.md "Tests" 段:"Prefer injection and narrow `*.runtime.ts` mocks over broad barrels or `openclaw/plugin-sdk/*`")。

## 4.5 关键观察

- **trace 贯穿**:从 start 到 end 每阶段都有 mark,便于性能分析与调试。
- **终态归一化硬约束**:防止 projections 重复推导 timeout/cancel 优先级。
- **依赖注入**:便于测试隔离。
- **与状态库绑定**:session 与 per-agent SQLite 绑定,所有状态落库,无内存态泄漏。

## 4.6 待精读项(不臆测)

以下细节本次未深入,需后续单独精读:

- `agent-run-terminal-outcome.ts` 的具体归一化算法(优先级表、合并规则)
- Lane 调度算法的具体实现
- Tool call 执行的同步/异步边界
- Auth profile 解析的 fallback 策略
- 流式输出的 backpressure 处理

## 架构图与流程图

### agentCommandInternal 主流程图

```
    agentCommandInternal(opts, deps)
    opts: { runId, agentId, sessionKey, storePath }
    deps: { logger, ... }
              │
              ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 1. trace 初始化                                          │
    │    createAgentCommandTrace(runId, agentId, sessionKey)   │
    │    trace.mark('start')                                   │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 2. 依赖解析                                              │
    │    resolveAgentCommandDeps(deps)                        │
    │    (注入式:便于测试 stub)                              │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 3. agent 配置加载                                        │
    │    ├─ 加载 agent 配置                                    │
    │    ├─ 模型选择(model selection)                        │
    │    └─ auth profile 解析                                  │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 4. session 准备                                          │
    │    基于 sessionKey                                      │
    │    绑定:agents/<agentId>/agent/openclaw-agent.sqlite    │
    │    (per-agent SQLite)                                   │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 5. LLM 请求构造                                         │
    │    ├─ 走插件 provider-runtime.ts                         │
    │    ├─ 注入工具表(来自 plugins/tools.ts)               │
    │    └─ prompt cache 友好(确定性排序)                    │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 6. 流式接收 LLM 输出                                     │
    │    ┌──────────────────────────────────────────────┐     │
    │    │  循环:                                        │     │
    │    │  ├─ 接收 chunk                                │     │
    │    │  ├─ 是 tool call?                             │     │
    │    │  │   ├─ Yes → 同步执行 plugin tool hook       │     │
    │    │  │   │         ↓                             │     │
    │    │  │   │         把结果送回 LLM                 │     │
    │    │  │   │         ↓                             │     │
    │    │  │   │         继续接收                       │     │
    │    │  │   └─ No  → 累积到回复                       │     │
    │    │  └─ 直到 LLM 完成(finish_reason)             │     │
    │    └──────────────────────────────────────────────┘     │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 7. 终态归一化(硬约束!)                                 │
    │    走 src/agents/agent-run-terminal-outcome.ts          │
    │                                                        │
    │    输入:各种终态信号                                    │
    │    ├─ normal completion                                │
    │    ├─ timeout                                           │
    │    ├─ cancel                                            │
    │    └─ error                                             │
    │                                                        │
    │    输出:单一归一化终态                                  │
    │                                                        │
    │    ⚠️ 禁止:在 projections 中重新推导                    │
    │       timeout/cancel 优先级                             │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 8. 落库 + 回复分发                                       │
    │    ├─ 状态写入 per-agent SQLite                         │
    │    └─ 回复分发到 channel                                │
    │       (走 wired-hooks-reply-dispatch.ts)                 │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
                ┌─────────────────────┐
                │ trace.mark('end')   │
                │ return result       │
                └─────────────────────┘
```

### Lane 并发控制示意图

```
    Agent 任务到达
          │
          ▼
    ┌──────────────────────────────────────────────┐
    │ Lane 调度器(server-lanes.ts)               │
    │                                              │
    │  按 agentId / sessionKey 分配 lane           │
    └──────────────────┬───────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   ┌─────────┐    ┌─────────┐    ┌─────────┐
   │ Lane 1  │    │ Lane 2  │    │ Lane 3  │
   │ agentA  │    │ agentB  │    │ agentA  │
   │ sess-1  │    │ sess-1  │    │ sess-2  │
   └────┬────┘    └────┬────┘    └────┬────┘
        │              │              │
        ▼              ▼              ▼
   [执行 agent]   [执行 agent]   [排队等待]
   (并发)         (并发)         (同 agent 不同 session
                                  可并发;同 session 串行)

    设计目的:
    ┌────────────────────────────────────────────────────────┐
    │ • 避免单 agent 多任务竞争(同 session 串行)            │
    │ • 跨 agent 可并发(不同 agent 独立 lane)               │
    │ • 防止资源耗尽(lane 数有上限)                         │
    │ • 任务隔离(lane 间不互相阻塞)                         │
    └────────────────────────────────────────────────────────┘

    ⚠️ 待精读:
    │ • Lane 调度算法的具体实现(队列?优先级?)
    │ • Lane 数上限配置
    │ • 跨 lane 任务的协调机制
    │ (见 11-assessment.md 待精读项清单)
```

### 终态归一化决策图(推断,待精读)

```
    Agent run 结束信号
    ┌─────────────────────────────────────────────┐
    │                                             │
    │  ┌─────────────┐  ┌─────────────┐           │
    │  │ 正常完成    │  │ 超时        │           │
    │  │ (finish)   │  │ (timeout)  │           │
    │  └──────┬─────┘  └──────┬─────┘           │
    │         │               │                   │
    │  ┌─────────────┐  ┌─────────────┐           │
    │  │ 用户取消    │  │ 错误        │           │
    │  │ (cancel)   │  │ (error)    │           │
    │  └──────┬─────┘  └──────┬─────┘           │
    │         │               │                   │
    └─────────┴───────────────┴───────────────────┘
                          │
                          ▼
            ┌─────────────────────────┐
            │ agent-run-terminal-     │
            │ outcome.ts              │
            │                         │
            │ (单一归一化入口)        │
            └────────────┬────────────┘
                         │
                         ▼
            ┌─────────────────────────┐
            │ 归一化终态(单一类型)   │
            │                         │
            │ • 终态类型              │
            │ • 原因                  │
            │ • 可观测指标            │
            │ • 是否可重试            │
            └─────────────────────────┘

    ⚠️ 关键约束(AGENTS.md 明确):
    ┌────────────────────────────────────────────────────────┐
    │ 不允许在 projections 中重新推导 timeout/cancel 优先级  │
    │                                                        │
    │ 原因:                                                  │
    │   如果 projections 各自判断优先级,                     │
    │   会出现不一致(如 timeout 和 cancel 同时发生时,       │
    │   不同 projection 可能给出不同结果)                    │
    │                                                        │
    │   归一化入口单一 → 优先级表只在一处定义 → 一致性保证    │
    └────────────────────────────────────────────────────────┘

    ⚠️ 待精读:具体优先级表与合并规则
```
