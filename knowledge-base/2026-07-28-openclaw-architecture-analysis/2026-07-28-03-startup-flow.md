# 03 — CLI → Gateway 启动流程

启动分两层:**进程入口**(entry.ts / index.ts)和 **Gateway 启动**(server-start.ts)。

## 3.1 进程入口

[src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts) 是真正的 Node 进程入口(被 `openclaw.mjs` wrapper 调用)。

### 入口守卫与基础设置(L100-L130)

```typescript
if (!isMainModule({ currentFile, wrapperEntryPairs: [...ENTRY_WRAPPER_PAIRS] })) {
  // 被当依赖 import — 跳过所有 entry 副作用
} else {
  const entryFile = fileURLToPath(import.meta.url);
  const installRoot = resolveEntryInstallRoot(entryFile);
  process.title = "openclaw";
  ensureOpenClawExecMarkerOnProcess();
  installProcessWarningFilter();
  normalizeEnv();
  process.argv = normalizeWindowsArgv(process.argv);
  // ... profile / runtime guard
  assertSupportedRuntime();
}
```

`isMainModule` 守卫(L102-107)防止 bundler 把 entry.js 当 shared dep 时重复启动 gateway(否则会撞 lock/port)。

### Fast-path 拦截(L195-L281)

按顺序尝试三个 fast path,不命中再走完整 CLI:

1. `tryHandleRootVersionFastPath(process.argv)` — `--version` 直接输出
2. `tryHandleRootHelpFastPath(argv)` — 无参数或 `--help` 时输出根帮助(优先用 precomputed text,避免加载完整 CLI)
3. `tryHandlePrecomputedCommandHelpFastPath(argv)` — 子命令 `--help` 用预计算文本

```typescript
if (!tryHandleRootVersionFastPath(process.argv)) {
  await runMainOrRootHelp(process.argv);
}

async function runMainOrRootHelp(argv: string[]) {
  await runCliWithExitFinalization({
    run: async () => {
      if (await tryHandleRootHelpFastPath(argv)) { ... return; }
      if (await tryHandlePrecomputedCommandHelpFastPath(argv)) { ... return; }
      const { runCli } = await gatewayEntryStartupTrace.measure(
        "run-main-import",
        () => import("./cli/run-main.js"),
      );
      await runCli(argv, { additionalStartupTrace: gatewayEntryStartupTrace });
    },
    ...
  });
}
```

**目的**:`--version`、`--help` 这类零成本调用直接拦截,避免触发完整 CLI 模块加载(包含 gateway、plugins、channels 等重量级 import)。

### 全局错误兜底

见 [src/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/index.ts#L91-L139):

- `installUnhandledRejectionHandler()` — 安装 unhandled rejection handler
- `process.on("uncaughtException", ...)` — 区分 benign(警告继续)与 fatal(格式化输出 + fatal hooks + restore terminal + exit 1)
- `runCliWithExitFinalization` 包装执行,`onError` 时格式化失败信息

### 启动 trace

[src/entry.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/entry.ts#L95) 创建 `gatewayEntryStartupTrace`,mark 点:`bootstrap`、`argv`、`run-main-import`。可在调试时开启输出。

## 3.2 Gateway 启动序列

[src/gateway/server-start.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-start.ts#L100-L201) 的 `startGatewayServer(port = 18789, opts)`:

```typescript
export async function startGatewayServer(port = 18789, opts: GatewayServerOptions = {}) {
  const bootstrap = await prepareGatewayServerBootstrap({...});
  const runtime = await prepareGatewayRuntimeState({...});
  const lifecycleRuntime = await prepareGatewayLifecycle({...});
  try {
    const coreRuntime = await startGatewayCoreRuntime({...});
    await finishGatewayStartup({...});
  } catch (err) {
    await closeOnStartupFailure();
    throw err;
  }
  const close = createCloseHandler();
  return { close: async (optsLocal) => { ... } };
}
```

### 阶段职责

| 阶段 | 入口文件 | 职责 |
|---|---|---|
| Bootstrap | `server-startup-bootstrap.ts` | env、worker environment、auth token 警告、diagnostics |
| Runtime State | `server-runtime-state-prepare.ts` | 创建 runtime state、channel runtime、worker 环境/placement |
| Lifecycle | `server-lifecycle.ts` | 绑定 close handler、sidecar、terminal sessions、close prelude |
| Core Runtime | `server-core-runtime.ts` | 启动早期服务、插件 bootstrap、model catalog |
| Finish | `server-startup-finish.ts` | HTTP/WS server、hooks、channels、cron、tailscale |

### 启动失败处理(L172-L175)

```typescript
} catch (err) {
  await closeOnStartupFailure();
  throw err;
}
```

任何阶段失败都会触发 `closeOnStartupFailure()`,清理已启动的资源(避免半启动状态)。

### Close handler(L177-L200)

返回的 `GatewayServer.close` 按序执行:
1. `beginClosePrelude()` — 开始关闭前奏
2. `terminalSessions.disposeAll()` — 杀掉所有活跃 operator shells(在 socket 层 tear down 之前)
3. `stopRegisteredGatewayLifetimeSidecars()` / `stopRegisteredPostReadySidecars()` — 停止 sidecar
4. `runGlobalGatewayStopSafely(...)` — 运行 `gateway_stop` plugin hook(动态 import `../plugins/hook-runner-global.js`)
5. `runClosePrelude()` + `close(optsLocal)` — 完成关闭
6. `clearFallbackGatewayContextForServer.get()()` — finally 清理 fallback context

### 懒加载贯穿(server-start.ts L15-23, L33-39, L46-50, L68-70)

```typescript
const loadGatewayModelCatalogModule = createLazyRuntimeModule(
  () => import("./server-model-catalog.js"),
);
const loadWorkerEnvironmentStartupModule = createLazyRuntimeModule(
  () => import("./server-worker-environment-startup.js"),
);
const loadGatewayStartupEarlyModule = createLazyRuntimeModule(
  () => import("./server-startup-early.js"),
);
const loadGatewayStartupPostAttachModule = createLazyRuntimeModule(
  () => import("./server-startup-post-attach.js"),
);
const getChannelRuntime = createLazyRuntimeModule(() =>
  import("../plugins/runtime/runtime-channel.js").then(({ createRuntimeChannel }) =>
    createRuntimeChannel(),
  ),
);
```

model catalog、worker、startup early/post-attach、channel runtime 都是懒加载,只在首次使用时 import。

### 文件拆分粒度

`server-startup-*.ts` 单独文件:bootstrap、early、post-attach、finish、log、memory、outcomes、plugins、handler-prewarm、session-migration、secret-surfaces、secret-diagnostics、config。AGENTS.md 规则:"Split files around ~700 LOC when clarity/testability improves"。实际拆分远小于 700 LOC,目的是单文件单职责 + 测试隔离。

## 3.3 关键观察

- **Fast-path 设计**:把零成本调用从完整 CLI 路径剥离,降低常见调用成本。
- **懒加载贯穿**:从 entry 到 gateway 启动到插件加载,处处 `createLazyRuntimeModule`。
- **失败安全**:任何启动阶段失败都触发 `closeOnStartupFailure`,不留半启动状态。
- **关闭有序**:先杀 operator shells(防止 socket tear down 后僵尸),再 sidecar,再 plugin hook,再 socket,最后清理 fallback context。

## 架构图与流程图

### entry.ts Fast-path 决策流程图

```
                    进程启动(process.argv)
                           │
                           ▼
                ┌─────────────────────┐
                │ isMainModule 守卫?   │
                └─────────┬───────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
              ▼ No                    ▼ Yes
        ┌──────────────┐      ┌──────────────────────────┐
        │ 跳过所有 entry │      │ 设置 process.title        │
        │ 副作用        │      │ ensureOpenClawExecMarker │
        │ (被当依赖)    │      │ installProcessWarningFilter│
        └──────────────┘      │ normalizeEnv             │
                              │ normalizeWindowsArgv    │
                              │ parseCliProfileArgs     │
                              │ assertSupportedRuntime  │
                              └────────────┬─────────────┘
                                           │
                                           ▼
                              ┌─────────────────────────┐
                              │ tryHandleRootVersion    │
                              │ FastPath(--version)     │
                              └────────────┬────────────┘
                                           │
                              ┌────────────┴────────────┐
                              │ 命中?                   │
                              │                         │
                          Yes │                     No │
                              ▼                         │
                        ┌─────────┐                    │
                        │ 输出版本 │                    │
                        │ 退出    │                    │
                        └─────────┘                    │
                                                     ▼
                              ┌─────────────────────────┐
                              │ runMainOrRootHelp(argv) │
                              └────────────┬────────────┘
                                           │
                                           ▼
                              ┌─────────────────────────┐
                              │ tryHandleRootHelp       │
                              │ FastPath(--help/无参)   │
                              └────────────┬────────────┘
                                           │
                              ┌────────────┴────────────┐
                              │ 命中?                   │
                              │                         │
                          Yes │                     No │
                              ▼                         │
                        ┌─────────────┐                 │
                        │ precomputed │                 │
                        │ text 输出   │                 │
                        │ 退出        │                 │
                        └─────────────┘                 │
                                                     ▼
                              ┌─────────────────────────┐
                              │ tryHandlePrecomputed    │
                              │ CommandHelpFastPath     │
                              │ (子命令 --help)         │
                              └────────────┬────────────┘
                                           │
                              ┌────────────┴────────────┐
                              │ 命中?                   │
                              │                         │
                          Yes │                     No │
                              ▼                         │
                        ┌─────────────┐                 │
                        │ precomputed │                 │
                        │ command help│                 │
                        │ 退出        │                 │
                        └─────────────┘                 │
                                                     ▼
                              ┌─────────────────────────┐
                              │ import("./cli/run-main  │
                              │ .js")                   │
                              │ runCli(argv)             │
                              │ (完整 CLI 加载)         │
                              └─────────────────────────┘
```

### Gateway 启动 5 阶段时序图

```
    startGatewayServer(port=18789, opts)
                    │
                    ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 1: prepareGatewayServerBootstrap                    │
    │ 文件:server-startup-bootstrap.ts                         │
    │ ├─ env 准备                                              │
    │ ├─ worker environment 准备                               │
    │ ├─ auth token 警告                                       │
    │ └─ diagnostics 初始化                                    │
    │ 懒加载:createLazyRuntimeModule                           │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 2: prepareGatewayRuntimeState                       │
    │ 文件:server-runtime-state-prepare.ts                     │
    │ ├─ 创建 runtime state                                    │
    │ ├─ channel runtime(懒加载 getChannelRuntime)            │
    │ ├─ worker 环境                                           │
    │ └─ worker placement                                      │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 3: prepareGatewayLifecycle                          │
    │ 文件:server-lifecycle.ts                                 │
    │ ├─ 绑定 close handler                                    │
    │ ├─ sidecar 注册                                          │
    │ ├─ terminal sessions                                    │
    │ └─ close prelude                                        │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 4: startGatewayCoreRuntime                          │
    │ 文件:server-core-runtime.ts                              │
    │ ├─ 启动早期服务(server-startup-early.ts)                │
    │ ├─ 插件 bootstrap(server-plugin-bootstrap.ts)           │
    │ ├─ model catalog(懒加载 server-model-catalog.ts)        │
    │ └─ post-attach(server-startup-post-attach.ts)           │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
    ┌──────────────────────────────────────────────────────────┐
    │ 阶段 5: finishGatewayStartup                             │
    │ 文件:server-startup-finish.ts                            │
    │ ├─ HTTP/WS server 启动                                   │
    │ ├─ hooks 注册                                            │
    │ ├─ channels 启动                                         │
    │ ├─ cron 启动                                             │
    │ └─ tailscale(可选)                                     │
    └──────────────────────┬───────────────────────────────────┘
                           │
                           ▼
                    返回 GatewayServer
                    { close: async }
                           │
              ┌────────────┴────────────┐
              │ 任何阶段失败?           │
              └────────────┬────────────┘
                           │ Yes
                           ▼
                ┌─────────────────────┐
                │ closeOnStartup     │
                │ Failure()          │
                │ (清理已启动资源)   │
                │ throw err         │
                └─────────────────────┘
```

### Close Handler 顺序图

```
    GatewayServer.close(opts)
           │
           ▼
    ┌──────────────────────────────────────────────┐
    │ 1. beginClosePrelude()                        │
    │    开始关闭前奏(标记正在关闭)                │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 2. terminalSessions.disposeAll()             │
    │    杀掉所有活跃 operator shells              │
    │    (必须在 socket tear down 之前!)           │
    │    原因:防止 socket 关闭后僵尸 shell 进程   │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 3. stopRegisteredGatewayLifetimeSidecars()   │
    │    stopRegisteredPostReadySidecars()         │
    │    停止所有 sidecar 进程                      │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 4. runGlobalGatewayStopSafely(...)           │
    │    动态 import ../plugins/hook-runner-global │
    │    运行 gateway_stop plugin hook             │
    │    (让插件做清理)                           │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 5. runClosePrelude() + close(optsLocal)      │
    │    完成关闭(socket tear down)               │
    └──────────────────┬───────────────────────────┘
                       │
                       ▼
    ┌──────────────────────────────────────────────┐
    │ 6. finally:                                  │
    │    clearFallbackGatewayContextForServer      │
    │    .get()()                                  │
    │    清理 fallback context                     │
    └──────────────────────────────────────────────┘

    顺序原因(关键):
    ┌────────────────────────────────────────────────────────┐
    │ 为什么先杀 shells 再 tear down socket?                 │
    │ → 如果先关 socket,operator shells 会变僵尸,           │
    │   继续运行但无人管理,可能泄露资源或继续输出            │
    │                                                        │
    │ 为什么 sidecar 在 plugin hook 之前?                    │
    │ → sidecar 是插件启动的辅助进程,                       │
    │   先停 sidecar 再让 plugin hook 做清理,                │
    │   避免 plugin hook 还在用已停 sidecar                  │
    └────────────────────────────────────────────────────────┘
```
