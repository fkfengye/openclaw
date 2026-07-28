# 05 — 插件系统

## 5.1 加载链路

[src/plugins/loader.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader.ts) 仅是 **stable public facade**,真正逻辑分散在多个文件:

```typescript
// loader.ts 实际只是 re-export
export { loadOpenClawPluginCliRegistry } from "./loader-cli-registry.js";
export { resolveRuntimePluginRegistry, ... } from "./loader-runtime-registry.js";
export { loadOpenClawPlugins, ... } from "./loader-runtime-load.js";
```

完整加载链路:

| 文件 | 职责 |
|---|---|
| `loader-discovery.ts` | 发现(bundled + 外部 `extensions/*`) |
| `loader-runtime-load.ts` | `loadOpenClawPlugins` 主入口 |
| `loader-runtime-registry.ts` | `resolveRuntimePluginRegistry` |
| `loader-cli-registry.ts` | CLI 命令组注册 |
| `loader-cache.ts` | 进程级缓存 |
| `loader-provenance.ts` | 来源追溯(trusted vs untrusted) |
| `loader-records.ts` | 安装记录 |
| `loader-registration-plan.ts` | 注册计划 |
| `loader-module-runtime.ts` | 模块运行时 |
| `loader-load-context.ts` | 加载上下文 |
| `loader-channel-setup.ts` / `loader-channel-runtime.ts` | 通道相关加载 |

## 5.2 注册边界

`registry.ts` + `registry-registrars-*.ts` 按能力分:

| Registrar | 能力 |
|---|---|
| `registry-registrars-tools-hooks.ts` | 工具与 hook |
| `registry-registrars-providers.ts` | Provider |
| `registry-registrars-operations.ts` | 操作 |
| `registry-registrars-network.ts` | 网络(含 MCP resolver) |
| `registry-registrars-memory.ts` | 内存 |
| `registry-registrars-host.ts` | 宿主 |
| `registry-registrars-capabilities.ts` | 能力声明 |

AGENTS.md 边界规则(src/plugins/AGENTS.md):

> Keep control-plane and runtime-plane concerns separate: discovery, manifest parsing, config validation, setup/onboarding hints, and activation planning belong to the control plane; actual plugin execution belongs to runtime resolution.

## 5.3 缓存策略

[src/plugins/loader-cache.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/loader-cache.ts) 提供:

- `clearPluginRegistryLoadCache`
- `isPluginRegistryLoadInFlight`
- `resolvePluginRegistryLoadCacheKey`

AGENTS.md "Cache concept" 规则:

> Gateway plugin metadata is stable while gateway runs. Reuse current snapshots, install records, discovery, lookup tables, and bounded process caches; avoid per-call stat/read/hash freshness. Plugin metadata changes require restart or explicit plugin owner reload/install/doctor flow.

**关键约束**:运行时不做 freshness polling(`stat`/`realpath`/JSON reread/hash)。插件元数据变更需要 restart 或显式 owner reload/install/doctor flow。

## 5.4 Hook 体系

`wired-hooks-*.ts` 覆盖完整生命周期:

| Hook 文件 | 触发点 |
|---|---|
| `wired-hooks-message.ts` | 消息收发 |
| `wired-hooks-llm.ts` | LLM 调用前后 |
| `wired-hooks-session.ts` | 会话生命周期 |
| `wired-hooks-compaction.ts` | 上下文压缩 |
| `wired-hooks-inbound-claim.ts` | 入站消息认领 |
| `wired-hooks-reply-dispatch.ts` | 回复派发 |
| `wired-hooks-reply-payload-sending.ts` | 回复 payload 发送 |
| `wired-hooks-gateway.ts` | Gateway 生命周期 |
| `wired-hooks-subagent.ts` | 子 agent |
| `wired-hooks-after-tool-call.e2e.test.ts` | 工具调用后(E2E 测试) |

Hook 的全局运行通过 `hook-runner-global.ts`(在 [server-start.ts L188](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts#L188) 调用 `runGlobalGatewayStopSafely`)。

## 5.5 Provider 系统

| 文件 | 职责 |
|---|---|
| `provider-runtime.ts` | Provider 运行时入口 |
| `provider-runtime.types.ts` | 类型定义 |
| `provider-runtime-model.types.ts` | 模型类型 |
| `provider-runtime.runtime.ts` | 运行时实现 |
| `provider-model-routes.ts` | 模型路由 |
| `provider-model-primary.ts` | 主模型选择 |
| `provider-thinking.ts` | 思考层级控制 |
| `provider-thinking-active.ts` | 激活的思考层级 |
| `provider-oauth-flow.ts` | OAuth 流程 |
| `provider-openai-chatgpt-oauth.ts` | OpenAI ChatGPT OAuth |
| `provider-openai-chatgpt-oauth-tls.ts` | OAuth TLS |
| `provider-self-hosted-setup.ts` | 自托管设置 |
| `provider-replay-helpers.ts` | 重放助手 |
| `provider-policy-surface.ts` | 策略表面 |
| `provider-public-artifacts.ts` | 公共工件 |
| `provider-plugin.types.ts` | 插件类型 |
| `provider-transport.types.ts` | 传输类型 |

AGENTS.md 明确:**OpenAI Codex 已折叠入 `openai`**,不再有 `openai-codex` 独立 provider/plugin/auth/model 路由,只作为 legacy 输入处理。

## 5.6 Tool 系统

| 文件 | 职责 |
|---|---|
| `tools.ts` | Tool 注册入口 |
| `tool-contracts.ts` | 工具契约 |
| `tool-types.ts` | 类型 |
| `tool-descriptor-cache.ts` | 描述符缓存(prompt cache 友好) |
| `tool-grant-allowlist.ts` | 授权白名单 |
| `trusted-tool-policy.ts` | 信任策略 |
| `tool-payload.ts` | payload 处理 |

AGENTS.md "Prompt cache" 规则:

> Prompt cache: deterministic ordering for maps/sets/registries/plugin lists/files/network results before model/tool payloads. Preserve old transcript bytes when possible.

工具描述符缓存(`tool-descriptor-cache.ts`)是为了让 prompt cache 命中率稳定。

## 5.7 公共表面

- `public-surface-loader.ts` — 加载侧公共表面
- `public-surface-runtime.ts` — 运行时公共表面
- `provider-public-artifacts.ts` / `web-provider-public-artifacts.ts` — 公共工件

[src/plugins/AGENTS.md](file:///d:/DevSpace/person/ai_space/openclaw/src/plugins/AGENTS.md) 边界规则:

> Preserve laziness in discovery and activation flows. Loader, registry, and public-artifact changes must not eagerly import bundled plugin runtime barrels when metadata, light exports, or typed contracts are sufficient.

> If a plugin exposes separate light and heavy runtime surfaces, keep discovery, inventory, and setup-state checks on the light path until actual execution needs the heavy module.

## 5.8 关键观察

- **facade 模式**:`loader.ts` 仅是 re-export,真正逻辑分文件,降低单文件复杂度。
- **control/runtime 分离**:discovery/manifest/setup 属 control plane,execution 属 runtime plane。
- **进程级缓存**:gateway 元数据 process-stable,无需 stat 实时校验,但变更需 restart。
- **Hook 全覆盖**:从 message 到 llm 到 session 到 reply dispatch 全链路 hook。
- **Codex 折叠**:`openai-codex` 已 legacy,统一走 `openai`。

## 架构图与流程图

### 插件加载链路图

```
    外部触发(Gateway 启动 / 命令调用)
           │
           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ loader.ts(stable public facade)                         │
    │ (仅 re-export,真正逻辑在以下文件)                      │
    └──────────────────────┬───────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────────────┐
        │                  │                          │
        ▼                  ▼                          ▼
    ┌──────────┐    ┌──────────────┐          ┌──────────────┐
    │ discovery│    │ runtime-load │          │ cli-registry  │
    │  .ts     │    │   .ts       │          │   .ts        │
    │          │    │              │          │              │
    │ 发现     │    │ loadOpenClaw │          │ CLI 命令组   │
    │ bundled +│    │ Plugins()    │          │ 注册         │
    │ external │    │ (主入口)     │          │              │
    └────┬─────┘    └──────┬───────┘          └──────────────┘
         │                 │
         │                 │
         ▼                 ▼
    ┌──────────┐    ┌──────────────────┐
    │ provenance│    │ runtime-registry │
    │   .ts    │    │    .ts           │
    │          │    │                  │
    │ 来源追溯 │    │ resolveRuntime   │
    │ trusted  │    │ PluginRegistry()│
    │ vs       │    │                  │
    │ untrusted│    └────────┬─────────┘
    └────┬─────┘             │
         │                   │
         │                   ▼
         │            ┌──────────────┐
         │            │ cache .ts    │
         │            │              │
         │            │ 进程级缓存   │
         │            │ (process-    │
         │            │  stable)     │
         │            └──────┬──────┘
         │                   │
         ▼                   ▼
    ┌──────────────────────────────────────────────┐
    │ 注册到 registry.ts                            │
    │                                              │
    │ 按能力分(registry-registrars-*.ts):         │
    │ ├─ tools-hooks                               │
    │ ├─ providers                                 │
    │ ├─ operations                                │
    │ ├─ network(含 MCP resolver)                 │
    │ ├─ memory                                    │
    │ ├─ host                                      │
    │ └─ capabilities                              │
    └──────────────────────────────────────────────┘

    关键约束:
    ┌────────────────────────────────────────────────────┐
    │ Control plane vs Runtime plane 分离:               │
    │                                                    │
    │ Control plane(轻):                                │
    │   discovery + manifest 解析 + config 校验 +        │
    │   setup/onboarding hints + activation planning    │
    │   (不 eager import runtime barrels)               │
    │                                                    │
    │ Runtime plane(重):                                │
    │   实际插件执行                                     │
    │   (只在需要时才加载)                              │
    └────────────────────────────────────────────────────┘
```

### Hook 触发时序图

```
    消息生命周期
    ═══════════
          │
          ▼
    ┌─────────────────────────────────────┐
    │ 消息入站                            │
    │ wired-hooks-inbound-claim.ts        │
    │ (插件认领消息,决定是否走 agent)    │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 会话开始                            │
    │ wired-hooks-session.ts             │
    │ (session 生命周期 hook)            │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 消息处理                            │
    │ wired-hooks-message.ts              │
    │ (消息收发 hook)                     │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 上下文压缩(如需要)                │
    │ wired-hooks-compaction.ts          │
    │ (上下文压缩 hook)                  │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ LLM 调用前                         │
    │ wired-hooks-llm.ts                 │
    │ (LLM 调用前后 hook)                │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ LLM 调用                            │
    │ (provider-runtime.ts)              │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ LLM 调用后                         │
    │ wired-hooks-llm.ts                 │
    │ (LLM 调用后 hook)                  │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ Tool 调用(如有)                   │
    │ tools.ts + tool-contracts.ts        │
    │ └─ 同步执行 plugin tool hook        │
    │ └─ wired-hooks-after-tool-call.ts   │
    │    (工具调用后 hook)                │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 子 Agent(如有)                    │
    │ wired-hooks-subagent.ts            │
    │ (子 agent hook)                    │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 回复派发                            │
    │ wired-hooks-reply-dispatch.ts       │
    │ (回复派发 hook)                     │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 回复 payload 发送                   │
    │ wired-hooks-reply-payload-sending.ts│
    │ (回复 payload 发送 hook)            │
    └──────────────────┬──────────────────┘
                       │
                       ▼
    ┌─────────────────────────────────────┐
    │ 会话结束                            │
    │ wired-hooks-session.ts              │
    │ (session 结束 hook)                 │
    └─────────────────────────────────────┘

    全局 hook:
    ┌──────────────────────────────────────────────────┐
    │ Gateway 生命周期                                  │
    │ wired-hooks-gateway.ts                           │
    │ ├─ gateway_start(启动时)                        │
    │ └─ gateway_stop(关闭时,runGlobalGatewayStopSafely)│
    └──────────────────────────────────────────────────┘
```

### Provider 系统结构图

```
    LLM 调用请求
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ provider-runtime.ts(入口)                               │
    │                                                          │
    │  ├─ provider-runtime.types.ts       (类型)              │
    │  ├─ provider-runtime-model.types.ts (模型类型)           │
    │  └─ provider-runtime.runtime.ts     (实现)              │
    └──────────────────────┬───────────────────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐
    │ model-routes │ │ thinking     │ │ oauth-flow      │
    │   .ts        │ │   .ts        │ │   .ts           │
    │              │ │              │ │                  │
    │ 模型路由     │ │ 思考层级控制 │ │ OAuth 流程      │
    │ (选哪个模型)│ │ (thinking    │ │                  │
    │              │ │  high/low)   │ │ ├─ openai-       │
    └──────────────┘ └──────────────┘ │   chatgpt-oauth  │
                                      │   .ts           │
                                      │ ├─ openai-       │
                                      │   chatgpt-oauth  │
                                      │   -tls.ts        │
                                      │ └─ self-hosted-  │
                                      │   setup.ts       │
                                      └──────────────────┘

    其他支撑:
    ┌──────────────────────────────────────────────────────┐
    │ provider-model-primary.ts     — 主模型选择           │
    │ provider-thinking-active.ts   — 激活的思考层级       │
    │ provider-replay-helpers.ts    — 重放助手             │
    │ provider-policy-surface.ts    — 策略表面             │
    │ provider-public-artifacts.ts  — 公共工件             │
    │ provider-plugin.types.ts      — 插件类型             │
    │ provider-transport.types.ts   — 传输类型             │
    └──────────────────────────────────────────────────────┘

    ⚠️ Codex 已折叠:
    ┌──────────────────────────────────────────────────────┐
    │ openai-codex provider/plugin/auth/model 已 legacy   │
    │ 统一走 openai provider                              │
    │ doctor/migrations 修复 stale openai-codex/* 配置   │
    └──────────────────────────────────────────────────────┘
```

### Tool 系统与 Prompt Cache 关系图

```
    插件注册 tool
         │
         ▼
    ┌──────────────────────────────────────────────────────────┐
    │ tools.ts(注册入口)                                      │
    │   ├─ tool-contracts.ts     (工具契约)                   │
    │   ├─ tool-types.ts         (类型)                       │
    │   ├─ tool-grant-allowlist  (授权白名单)                 │
    │   ├─ trusted-tool-policy   (信任策略)                   │
    │   └─ tool-payload.ts       (payload 处理)               │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ tool-descriptor-cache.ts                                │
    │ (工具描述符缓存)                                        │
    │                                                          │
    │ 为什么缓存?                                            │
    │ → Prompt cache 友好                                     │
    │                                                          │
    │ AGENTS.md 规则:                                        │
    │   "Prompt cache: deterministic ordering for             │
    │    maps/sets/registries/plugin lists/files/network      │
    │    results before model/tool payloads.                 │
    │    Preserve old transcript bytes when possible."        │
    │                                                          │
    │ 即:工具描述符顺序必须确定性,                          │
    │    否则 prompt cache 命中率下降                         │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ LLM 请求 payload        │
              │ (tools 字段)           │
              │                        │
              │ 顺序确定性 →           │
              │ prompt cache 命中率高  │
              └────────────────────────┘
```
