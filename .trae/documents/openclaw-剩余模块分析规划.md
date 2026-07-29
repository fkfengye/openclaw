# OpenClaw 剩余模块分析规划

## 概述

基于现有知识库(01-openclaw-architecture + 01.1-external-entry-layer + 01.2-access-layers,共 33 章),规划剩余 10 个核心运行时模块的深入分析。

**范围**:核心运行时 10 模块(不包含 extensions/ 插件实现和 apps/ 原生 App)
**编号**:按架构层级分组(02/03/04 三大组)
**文件排序**:每个目录内按模块上下游递进关系组织
**风格**:沿用已重写的新风格(组件协作图 + 组件清单 + 关联关系 + 协作流程 + 关键约束 + 设计观察 + 源码索引)

## 当前状态分析

### 已覆盖(知识库现有)

| 目录 | 章节数 | 覆盖深度 |
|---|---|---|
| 01-openclaw-architecture/ | 11 章 | 整体架构(高层) |
| 01.1-external-entry-layer/ | 7 章 | CLI 启动链路(深入) |
| 01.2-access-layers/ | 12 章 | Gateway 接入面(深入) |

**特征**:都是"入口"和"接入"层面,核心运行时内部实现仅有高层概述。

### 未覆盖(本次规划目标)

10 个核心运行时模块,按上下游依赖关系分 3 层:

```
┌──────────────────────────────────────────────────────────────┐
│  04-extension-capabilities/(扩展点与能力层)                 │
│  依赖运行时核心,提供扩展能力                              │
│                                                              │
│  • 04.1-hooks(Hook 系统,依赖 plugins)                    │
│  • 04.2-cron(定时任务,依赖 state + agents)              │
│  • 04.3-agent-tools(Agent 工具集,依赖 agents + plugins)  │
└──────────────────────────────────────────────────────────────┘
                               ▲
                               │ 依赖
                               │
┌──────────────────────────────────────────────────────────────┐
│  03-runtime-core/(运行时核心层)                             │
│  依赖基础设施,提供运行时编排                              │
│                                                              │
│  • 03.1-agent-sessions(Agent 会话管理)                    │
│  • 03.2-gateway-internal(Gateway 内部编排)                │
│  • 03.3-plugin-registry(插件注册表)                       │
└──────────────────────────────────────────────────────────────┘
                               ▲
                               │ 依赖
                               │
┌──────────────────────────────────────────────────────────────┐
│  02-foundation-layer/(基础设施层)                           │
│  被所有上层依赖,提供数据/配置/工具/LLM 基础              │
│                                                              │
│  • 02.1-state(状态层,SQLite 双层)                        │
│  • 02.2-config(配置层,三步加载)                         │
│  • 02.3-infra(基础设施,110+ 工具)                       │
│  • 02.4-ai-providers(LLM Provider 抽象)                   │
└──────────────────────────────────────────────────────────────┘
```

## 规划变更

### 新增 3 个目录组,共 10 个子目录

#### 02-foundation-layer/(基础设施层,4 个子目录)

被所有上层依赖,提供数据/配置/工具/LLM 基础。

##### 02.1-state/(状态层)— 5 章

源码:`src/state/`(70+ 文件)
按上下游递进:契约 → 实现 → 演进 → 维护

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:SQLite 双层结构 + 状态层组件全景 | - |
| 01 | 01-shared-state-db.md | 共享状态库(state/openclaw.sqlite):契约、schema-helpers、permissions、readonly | SQLite/Kysely |
| 02 | 02-agent-state-db.md | Per-agent 状态库(agents/<id>/agent/openclaw-agent.sqlite):契约、lease、registry | 共享库 |
| 03 | 03-schema-evolution.md | Schema 演进:22 代版本管理、additive 变更、migration 策略 | 双层库 |
| 04 | 04-maintenance-leases.md | 维护与租约:lease、verify、operator-approval、restart-handoff、audit-migration | 双层库 |

##### 02.2-config/(配置层)— 4 章

源码:`src/config/`(55+ 文件)
按上下游递进:IO → 类型 → Schema → 变更

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:三步加载 + 配置层组件全景 | - |
| 01 | 01-io-operations.md | IO 操作:load、audit、context、factory、observe、recovery、snapshot、write | 文件系统 |
| 02 | 02-type-system.md | 类型系统:base、auth、acp、cron、hooks、mcp、queue、slack、tools、tts | IO |
| 03 | 03-schema-mutation.md | Schema 与变更:base schema、help、tags、mutate、materialize、merge-patch、validation、legacy | 类型系统 |

##### 02.3-infra/(基础设施)— 5 章

源码:`src/infra/`(110+ 文件)
按上下游递进:文件/路径 → 网络 → 进程/执行 → 平台特定

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:基础设施分类 + 组件全景 | - |
| 01 | 01-fs-path-env.md | 文件系统/路径/环境:fs-safe、json-file、path-*、home-dir、shell-env、dotenv | Node.js |
| 02 | 02-net-tls.md | 网络/TLS:net/(form-data、hostname、proxy-env、ssrf)、tls/、fetch、retry、ws | 文件系统 |
| 03 | 03-exec-process.md | 执行/进程:exec-*、file-lock、gateway-lock、restart、semver、backoff、dedupe | 网络 |
| 04 | 04-platform-specific.md | 平台特定:ssh-*、tailscale、wsl、brew、push-apns、push-web、voicewake、widearea-dns、node-pairing、node-shell | 执行 |

##### 02.4-ai-providers/(LLM Provider 抽象)— 5 章

源码:`packages/ai/`(130+ 文件)
按上下游递进:核心抽象 → Provider 实现 → 传输层 → 工具

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:Provider 抽象层 + 组件全景 | - |
| 01 | 01-provider-core.md | Provider 核心:api-registry、env-api-keys、host、provider-options、providers、session-resources、stream、types、validation | packages/llm-core |
| 02 | 02-provider-implementations.md | Provider 实现:anthropic、google、google-vertex、mistral、openai-completions、openai-responses、azure-openai-responses、cloudflare、github-copilot | Provider 核心 |
| 03 | 03-transports.md | 传输层:anthropic-transport-stream、openai-completions-transport、openai-responses-transport、provider-transport-stream | Provider 实现 |
| 04 | 04-utils-internal.md | 工具与内部:overflow、prompt-cache-stability、provider-error、streaming-byte-guard、system-prompt-cache-boundary、tls-certificate-errors、oauth、internal/ | 传输层 |

#### 03-runtime-core/(运行时核心层,3 个子目录)

依赖基础设施,提供运行时编排。

##### 03.1-agent-sessions/(Agent 会话管理)— 6 章

源码:`src/agents/sessions/`(100+ 文件)+ `src/agents/` 顶层会话相关
按上下游递进:会话生命周期 → 管理器 → 提示词/模型 → 执行 → 扩展 → 内置工具

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:Agent 会话组件全景 + 与 Agent Runner 关系 | 02.1-state、02.4-ai |
| 01 | 01-session-lifecycle.md | 会话生命周期:agent-session*.ts(15+ 文件)— lifecycle、execution、inspecting、prompting、tree、models | 状态层 |
| 02 | 02-session-manager.md | 会话管理器:session-manager-*.ts(10 文件)— branching、codec、core、entries、persistence | 生命周期 |
| 03 | 03-prompt-model.md | 提示词与模型:system-prompt、prompt-templates、model-resolver、model-registry、model-registry-runtime | 管理器 |
| 04 | 04-auth-execution.md | 认证与执行:auth-storage、auth-guidance、auth-storage-oauth-registry、bash-executor、exec | 模型 |
| 05 | 05-compaction-extensions.md | 压缩与扩展:compaction/(branch-summarization、compaction)、extensions/(loader、runner、wrapper) | 执行 |

##### 03.2-gateway-internal/(Gateway 内部编排)— 7 章

源码:`src/gateway/`(200+ 文件,除已覆盖的接入面)
按上下游递进:启动 → 认证 → 客户端 → 对话/聊天 → 配置重载 → 凭据 → 监控

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:Gateway 内部组件全景(除接入面) | 02.1-state、02.2-config |
| 01 | 01-boot-lifecycle.md | 启动与生命周期:boot、boot-echo-guard、client-bootstrap、client-start-readiness、config-reload-* | 状态层、配置层 |
| 02 | 02-auth-internal.md | 认证内部:auth-*.ts(15+ 文件)— rate-limit、mode-policy、install-policy、surface-resolution、token-resolution | 启动 |
| 03 | 03-client-conversation.md | 客户端与对话:client、conversation-*.ts(7 文件)— turn、send、list、read-origin、errors | 认证 |
| 04 | 04-chat-display.md | 聊天显示:chat-*.ts(10+ 文件)— display-projection、attachments、abort、queued-turns、sanitize | 对话 |
| 05 | 05-control-ui-backend.md | Control UI 后端:control-ui-*.ts(20+ 文件)— CSP、routing、session-prs、github-preview、plugin-tabs | 聊天 |
| 06 | 06-credentials-monitoring.md | 凭据与监控:credentials、credential-planner、device-auth、channel-health、cron-stream、exec-approval | Control UI |

##### 03.3-plugin-registry/(插件注册表)— 6 章

源码:`src/plugins/`(200+ 文件)
按上下游递进:注册表 → Provider 运行时 → 插件运行时 → 状态/更新 → Web Provider → 会话目录

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:插件注册表组件全景 | 02.1-state、02.2-config |
| 01 | 01-registry-core.md | 注册表核心:registry-*.ts(15+ 文件)— registrars-tools-hooks、providers、operations、network、memory、host、capabilities、lifecycle、refresh、empty、api、state | 状态层 |
| 02 | 02-provider-runtime.md | Provider 运行时:provider-runtime*.ts、provider-*.ts(30+ 文件)— oauth-flow、model-routes、model-primary、public-artifacts、policy-surface、replay-helpers、registry-shared、thinking、self-hosted-setup、validation、wizard、openai-chatgpt-oauth | 注册表 |
| 03 | 03-plugin-runtime.md | 插件运行时:runtime*.ts(10+ 文件)— runtime、runtime-state、runtime-channel-state、runtime-degraded-state、runtime-sidecar-paths、runtime-workspace-state;status、update、uninstall | Provider 运行时 |
| 04 | 04-loader-discovery.md | 加载与发现:loader、discovery、installs、tools、tool-*、schema-validator、validation-diagnostics、slots、slot-selection | 插件运行时 |
| 05 | 05-web-session-catalog.md | Web Provider 与会话目录:web-search-providers、web-fetch-providers、web-content-extractors、web-provider-*、setup-registry、session-catalog、session-discussion-registry、session-conversation-binding | 加载发现 |

#### 04-extension-capabilities/(扩展点与能力层,3 个子目录)

依赖运行时核心,提供扩展能力。

##### 04.1-hooks/(Hook 系统)— 4 章

源码:`src/hooks/`(25 文件)
按上下游递进:配置 → 加载 → 执行 → 平台集成

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:Hook 系统组件全景 | 03.3-plugin-registry |
| 01 | 01-config-policy.md | 配置与策略:config、configured、policy、frontmatter、hooks-status | 插件注册表 |
| 02 | 02-loader-install.md | 加载与安装:loader、install、installs、import-url、plugin-hooks、bundled-dir、workspace、update | 配置策略 |
| 03 | 03-gmail-platform.md | Gmail 平台集成:gmail-ops、gmail | 加载安装 |

##### 04.2-cron/(定时任务)— 5 章

源码:`src/cron/`(40+ 文件)
按上下游递进:调度 → 存储 → 投递 → 重试 → 工具

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:定时任务组件全景 | 02.1-state、03.1-agent-sessions |
| 01 | 01-schedule-service.md | 调度与服务:service/(jobs、locked、state、store、timer、wake)、schedule、parse、normalize、pacing、stagger、active-jobs | 状态层 |
| 02 | 02-store-schema.md | 存储与 Schema:store/(key、schema、types)、delivery-plan、run-id、run-log-types、scratch-store、tools-allow、webhook-url | 调度 |
| 03 | 03-delivery-retry.md | 投递与重试:delivery、delivery-plan、retry-hint | 存储 |
| 04 | 04-cron-exit-watchers.md | 退出监控:cron-exit-watchers、cron-stream-* | 投递 |

##### 04.3-agent-tools/(Agent 工具集)— 6 章

源码:`src/agents/tools/`(150+ 文件)+ `src/agents/sessions/tools/`(30 文件)
按上下游递进:基础 → 内置工具 → Web 工具 → 会话工具 → 媒体工具 → 其他工具

| 序号 | 文件 | 主题 | 上游依赖 |
|---|---|---|---|
| 00 | 00-overview.md | 总览:Agent 工具集全景 + 工具策略 | 03.1-agent-sessions、03.3-plugin-registry |
| 01 | 01-builtin-tools.md | 内置工具:sessions/tools/(bash、edit、find、grep、ls、read、write、limits、output-accumulator、path-utils、private-temp-file、render-utils、tool-contracts、tool-definition-wrapper、truncate) | Agent 会话 |
| 02 | 02-web-tools.md | Web 工具:web-fetch、web-search、web-guarded-fetch、web-shared、web-tools(15+ 文件) | 内置工具 |
| 03 | 03-sessions-tools.md | 会话工具:sessions-list、sessions-history、sessions-search、sessions-send、sessions-spawn、sessions-tool、sessions-yield、sessions-resolution、sessions-access(20+ 文件) | Web 工具 |
| 04 | 04-media-tools.md | 媒体生成工具:image-generate、image-tool、music-generate、video-generate、pdf-tool(20+ 文件) | 会话工具 |
| 05 | 05-other-tools.md | 其他工具:computer-tool、terminal-tool、tts-tool、dashboard-tool、goal-tools、nodes-tool、message-tool、mobile-ui-tool、ask-user-tool、subagents-tool、system-agent-tool、task-suggestion-tools、transcripts-tool、structured-output-tool、skill-workshop-tool、openclaw-delegate-tool、heartbeat-response-tool、poll-vote-echo、update-plan-tool、gateway-tool、session-status-tool、agents-list-tool、agents-wait-tool、conversation-tools、cron-tool | 媒体工具 |

### README 更新

更新 `knowledge-base/README.md`,在现有 3 大目录后追加 3 大组目录:

```
现有:
- 01-openclaw-architecture/(顶层,11 章)
  - 01.1-external-entry-layer/(7 章)
  - 01.2-access-layers/(12 章)

新增:
- 02-foundation-layer/(基础设施层,19 章)
  - 02.1-state/(5 章)
  - 02.2-config/(4 章)
  - 02.3-infra/(5 章)
  - 02.4-ai-providers/(5 章)
- 03-runtime-core/(运行时核心层,19 章)
  - 03.1-agent-sessions/(6 章)
  - 03.2-gateway-internal/(7 章)
  - 03.3-plugin-registry/(6 章)
- 04-extension-capabilities/(扩展点与能力层,15 章)
  - 04.1-hooks/(4 章)
  - 04.2-cron/(5 章)
  - 04.3-agent-tools/(6 章)

总计新增:10 个子目录,53 章
```

## 假设与决策

### 假设

1. **风格一致**:所有新章节沿用已重写的新风格(11 段固定结构:标题 → 引导句 → 一句话定位 → 全局协作图 → 组件清单 → 关联关系 → 协作流程 → 关键约束 → 设计观察 → 章节索引 → 源码索引)
2. **源码索引集中末尾**:正文不出现函数名/文件路径/行号,所有 file:/// 链接集中在末尾"源码索引"表
3. **图示为组件级别**:ASCII 图框内是组件名 + 职责,不是函数名/文件路径
4. **每个目录有 00-overview.md**:作为该目录的入口与索引

### 决策

1. **分组方式**:按架构层级分 3 组(02-foundation / 03-runtime-core / 04-extension-capabilities),而非平级递增
2. **目录内排序**:按上下游递进关系(上游在前,下游在后)
3. **章节粒度**:每个子目录 4-7 章,每章聚焦一个子领域,避免单章过载
4. **不覆盖范围**:extensions/ 插件实现、apps/ 原生 App、其他 packages/ 独立包(除 packages/ai 外)
5. **packages/ai 覆盖**:作为 LLM Provider 抽象层纳入 02.4,因为它是理解 Agent 调用 LLM 的关键基础

### 范围边界

**纳入**:
- src/state/、src/config/、src/infra/、packages/ai/(基础设施 4 模块)
- src/agents/sessions/、src/gateway/(内部)、src/plugins/(运行时核心 3 模块)
- src/hooks/、src/cron/、src/agents/tools/(扩展能力 3 模块)

**不纳入**:
- extensions/(80+ 插件实现,模式重复,可后续选代表分析)
- apps/(4 平台原生 App,已在接入层高层覆盖)
- src/cli/、src/commands/(命令实现,非核心运行时)
- src/daemon/、src/media/、src/logging/、src/acp/、src/claws/、src/auto-reply/(中等优先级,可后续补充)
- packages/(除 ai 外的其他 18 个独立包,可后续选关键包补充)

## 执行策略

### 阶段划分(3 阶段,与 3 大组对应)

#### 阶段 1:02-foundation-layer/(基础设施层,4 子目录 19 章)

按上下游递进顺序:
1. 02.1-state/(5 章)— 状态层是所有的基础
2. 02.2-config/(4 章)— 配置层依赖状态层
3. 02.3-infra/(5 章)— 基础设施依赖前两者
4. 02.4-ai-providers/(5 章)— LLM 抽象依赖基础设施

#### 阶段 2:03-runtime-core/(运行时核心层,3 子目录 19 章)

按上下游递进顺序:
1. 03.1-agent-sessions/(6 章)— Agent 会话依赖基础设施
2. 03.2-gateway-internal/(7 章)— Gateway 内部依赖 Agent 会话
3. 03.3-plugin-registry/(6 章)— 插件注册表依赖前两者

#### 阶段 3:04-extension-capabilities/(扩展点与能力层,3 子目录 15 章)

按上下游递进顺序:
1. 04.1-hooks/(4 章)— Hook 系统依赖插件注册表
2. 04.2-cron/(5 章)— 定时任务依赖 Agent 会话
3. 04.3-agent-tools/(6 章)— Agent 工具依赖 Agent 会话 + 插件

### 并行策略

每个阶段内的子目录可以并行启动 Task 子代理(每阶段 3-4 个并行),但阶段间必须串行(下游依赖上游的分析结果)。

### 验证策略

每个子目录完成后:
1. Grep 验证无函数名/行号残留(`\.ts#L\d`、`\.ts:L`、具体函数名)
2. 检查所有 file:/// 链接集中在末尾源码索引表
3. 检查每个文件包含 11 段固定结构
4. 更新 README.md 的目录索引

## 验证步骤

### 单文件验证

每个章节文件完成后:
- [ ] 包含 11 段固定结构(标题 → 引导句 → 定位 → 全局图 → 组件清单 → 关联关系 → 协作流程 → 关键约束 → 设计观察 → 章节索引 → 源码索引)
- [ ] 正文无函数名/常量名/文件路径/行号
- [ ] 图内框内仅含组件名 + 职责
- [ ] 所有 file:/// 链接集中在末尾源码索引表
- [ ] 无 emoji

### 单目录验证

每个子目录完成后:
- [ ] 00-overview.md 存在且为该目录入口
- [ ] 所有章节文件按上下游递进排序
- [ ] 章节索引表列出本目录所有文件
- [ ] Grep 验证无残留(`\.ts#L\d`、`\.ts:L`、具体函数名)

### 全局验证

所有阶段完成后:
- [ ] README.md 更新,包含全部 6 大组目录索引
- [ ] 全局架构图更新,标注新增覆盖范围
- [ ] 交叉引用检查(新目录与现有目录的链接)
- [ ] 总章节数:33(现有)+ 53(新增)= 86 章

## 风险与缓解

### 风险 1:章节粒度不均

- **问题**:某些子领域文件多(如 src/gateway/ 200+ 文件),单章可能过载或过细
- **缓解**:每章聚焦一个子领域,文件数超过 20 个时拆分为多章

### 风险 2:交叉依赖描述不一致

- **问题**:多个章节可能描述同一依赖关系,措辞可能不一致
- **缓解**:每个 00-overview.md 明确标注上下游依赖,后续章节引用该描述

### 风险 3:源码路径不准确

- **问题**:子代理可能引用不存在的源码路径
- **缓解**:每个子代理启动前先 LS 对应源码目录,确认路径存在

### 风险 4:工作量超预期

- **问题**:53 章工作量较大,可能需要多轮交付
- **缓解**:按 3 阶段交付,每阶段完成后可暂停确认
