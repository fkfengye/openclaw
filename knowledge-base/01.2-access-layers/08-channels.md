# 08 — Channel 渠道接入(25+ 渠道)

> 读完本章你将理解:25+ 外部消息平台如何通过"transport-only"渠道插件接入 OpenClaw,以及为什么渠道插件只做传输与格式转换、绝不持有业务逻辑。

## 一句话定位

渠道插件是外部消息平台(Telegram / Slack / Discord / WhatsApp 等 25+)与 OpenClaw 之间的"transport-only"适配层:把平台原生消息转成内部 InboundEvent 提交 Channel Turn 内核,把回复转回平台格式发出去;渠道插件只做传输、渲染展示、动作映射、传输限制、回调映射,**绝不持有产品命令树、provider policy、feature 菜单**。

## 全局协作图

下图展示一条外部平台消息如何经渠道插件进入内核再回到平台。**先看这张图建立心智模型,再读细节**。

```
              外部消息平台
        (Telegram / Slack / Discord / WhatsApp / ...)
                    │
                    │ 用户发消息
                    │
   ┌────────────────┼────────────────┐
   │                │                │
   ▼                ▼                ▼
 HTTP Polling   Webhook(HTTP)    WebSocket / Bot API
 (Telegram)    (LINE/SMS/Slack/  (WhatsApp/Discord/
                Google Chat)     Slack/IRC/Matrix)
   │                │                │
   └────────────────┼────────────────┘
                    │
                    ▼
   ┌───────────────────────────────────────┐
   │      渠道插件(transport-only)        │
   │      (extensions/<id>/)               │
   │                                       │
   │  职责:                                │
   │  • 平台原生格式解析                   │
   │  • 平台签名验证(LINE HMAC/Twilio等)│
   │  • 转成内部 InboundEvent              │
   │  • 渲染展示(markdown → 平台格式)    │
   │  • 动作映射(按钮回调 → 统一 action)│
   │  • 传输限制(长度/媒体类型)          │
   │                                       │
   │  禁止:产品命令树/provider policy/    │
   │       feature 菜单                    │
   └───────────────────┬───────────────────┘
                       │ InboundEvent
                       ▼
   ┌───────────────────────────────────────┐
   │      Channel Turn 内核                │
   │      (见架构章 06)                    │
   │                                       │
   │  • Admission 策略:                    │
   │    ├─ dispatch    → 走 Agent          │
   │    ├─ observeOnly → 仅观察            │
   │    ├─ handled     → 插件已处理        │
   │    └─ drop        → 丢弃              │
   │  • 持久化投递(防丢失)               │
   │  • 防死循环(bot-loop-protection)    │
   └───────────────────┬───────────────────┘
                       │
                       ▼
   ┌───────────────────────────────────────┐
   │      Lane 调度 → Agent Runner         │
   └───────────────────┬───────────────────┘
                       │
                       ▼
   ┌───────────────────────────────────────┐
   │      回复分发器                       │
   │      → 渠道插件收到回复               │
   │      → 转成平台格式发回用户           │
   └───────────────────────────────────────┘
```

## 组件清单

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **渠道插件** | transport-only 适配,平台消息 ↔ 内部格式 | 禁止持有业务逻辑 |
| **平台签名验证器** | 校验各平台 webhook 签名(LINE HMAC / Twilio / Slack 等) | 每个渠道自己负责,互不干扰 |
| **InboundEvent 转换器** | 平台原生消息 → 内部 InboundEvent | 统一格式,内核不感知具体平台 |
| **Channel Turn 内核** | Admission 策略 + 持久化投递 + 防死循环 | 4 种 Admission kind |
| **回复分发器** | 回复派发到原渠道插件 | 走 Hook,不直接调 channel |

## 关联关系

### 渠道插件的 transport-only 边界

```
   ┌──────────────────────────────────────────────────────┐
   │              渠道插件职责边界                         │
   │                                                      │
   │  允许(transport-only):                              │
   │  • 传输(收发消息)                                  │
   │  • 渲染展示(markdown → 平台格式)                  │
   │  • 动作映射(按钮回调 → 统一 action)               │
   │  • 传输限制(长度/媒体类型)                        │
   │  • 回调映射(native callback envelope)             │
   │                                                      │
   │  禁止(业务逻辑):                                   │
   │  • 产品命令树(如 /help 命令树)                    │
   │  • provider policy(模型选择策略)                  │
   │  • feature-specific 菜单                            │
   │  • agent 路由                                       │
   └──────────────────────────────────────────────────────┘
```

### 渠道接入协议的多样性

```
   各平台接入协议不同,但都汇聚到渠道插件:

   ┌────────────┬─────────────────────┬──────────────────┐
   │ Telegram   │ HTTP polling        │ bot token 认证   │
   ├────────────┼─────────────────────┼──────────────────┤
   │ WhatsApp   │ WebSocket           │ WhatsApp Web     │
   ├────────────┼─────────────────────┼──────────────────┤
   │ LINE       │ Webhook(HTTP+HMAC)  │ HMAC-SHA256      │
   ├────────────┼─────────────────────┼──────────────────┤
   │ SMS/Twilio │ Webhook(HTTP+签名)  │ HMAC-SHA1        │
   ├────────────┼─────────────────────┼──────────────────┤
   │ Slack      │ Web API + Events    │ HMAC-SHA256      │
   ├────────────┼─────────────────────┼──────────────────┤
   │ Discord    │ REST Bot API        │ Bot token        │
   ├────────────┼─────────────────────┼──────────────────┤
   │ Google Chat│ Webhook             │ Bearer token     │
   ├────────────┼─────────────────────┼──────────────────┤
   │ IRC        │ IRC 协议            │ -                │
   ├────────────┼─────────────────────┼──────────────────┤
   │ Matrix     │ Client-Server API   │ -                │
   ├────────────┼─────────────────────┼──────────────────┤
   │ ...15+     │ 各自协议            │ 各自认证         │
   └────────────┴─────────────────────┴──────────────────┘
                        │
                        ▼
              统一转为 InboundEvent
              内核不感知具体平台
```

### Admission 策略的 4 种 kind

```
   InboundEvent 到达 Channel Turn 内核
        │
        ▼
   ┌──────────────────────────────────────┐
   │ Admission 策略判断                    │
   │                                      │
   │  ┌─ dispatch    → 走 Agent           │
   │  │   (正常消息,交给 Agent 处理)     │
   │  │                                  │
   │  ├─ observeOnly → 仅观察            │
   │  │   (记录但不处理,如观察模式)     │
   │  │                                  │
   │  ├─ handled     → 插件已处理        │
   │  │   (插件自己处理了,内核不介入)   │
   │  │                                  │
   │  └─ drop        → 丢弃              │
   │      (不处理,如垃圾/限流)          │
   └──────────────────────────────────────┘
```

## 协作流程

### 一次 Telegram 消息接入的完整旅程

下面追踪一条 Telegram 用户消息从 Bot 平台到回复的全过程,标注每步由哪个组件负责。

```
用户在 Telegram 发 "帮我写代码"
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Telegram Bot 平台推送                                      │
│    • 通过 webhook/polling 推到 Telegram 插件                  │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Telegram 插件(transport-only)                            │
│    • 平台原生格式解析                                         │
│    • 平台签名/bot token 验证                                 │
│    • 转成内部 InboundEvent                                   │
│    (插件不做业务决策,只做转换)                              │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Channel Turn 内核                                          │
│    • Admission 策略:dispatch → 走 Agent                     │
│    • 持久化投递(防丢失)                                    │
│    • 防死循环(bot-loop-protection)                         │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Lane 调度 → Agent Runner                                  │
│    • 分配 lane                                               │
│    • Agent run 处理消息(LLM + 工具)                        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 回复分发                                                   │
│    • 回复派发 Hook 触发                                       │
│    • Telegram 插件收到回复                                   │
│    • 渲染展示:markdown → Telegram 格式                      │
│    • 动作映射:按钮 → Telegram inline keyboard               │
│    • 传输限制:超长截断/分片                                 │
│    • 发回用户                                                │
└──────────────────────────────────────────────────────────────┘
```

### 平台签名验证的差异

| 平台 | 签名机制 |
|---|---|
| LINE | X-Line-Signature(HMAC-SHA256,channel secret + body) |
| Twilio(SMS) | X-Twilio-Signature(HMAC-SHA1,Auth Token + URL + body) |
| Slack | X-Slack-Signature(HMAC-SHA256,Signing Secret + v0:timestamp:body) |
| Google Chat | Bearer token in Authorization header |
| Telegram(polling) | 无需签名(polling 模式,bot token 认证) |
| Discord(Bot API) | Bot token in Authorization header |

## 关键设计约束

### 1. 渠道插件只能 transport-only

- **为什么**:核心保持渠道无关,新增渠道不改核心;业务逻辑集中在 Gateway 一致
- **怎么做**:渠道插件只做传输、渲染展示、动作映射、传输限制、回调映射
- **影响**:产品命令树、provider policy、feature 菜单必须在核心,不在渠道

### 2. 便携命令 UI 用类型化展示动作

- **为什么**:不让渠道猜测 `value` 以 `/` 开头就是命令;渠道不应特判产品字符串
- **怎么做**:核心/owner 插件声明命令动作,渠道映射时区分 approval/command/url/web-app/select
- **影响**:原始回调数据是 transport/private,各动作在编码前必须可区分

### 3. 统一 InboundEvent 格式

- **为什么**:内核不感知具体平台,新增渠道不改内核
- **怎么做**:所有渠道转成统一 InboundEvent,内核只处理内部格式
- **影响**:新渠道接入成本 = 实现插件 + 平台 API 适配,不改内核

### 4. 签名验证插件本地化

- **为什么**:每个平台签名机制不同,集中实现会耦合
- **怎么做**:每个渠道插件自己负责平台签名验证
- **影响**:实现复杂度分散在各插件,各插件质量需独立评估

### 5. 防死循环

- **为什么**:bot 回复触发 bot 回复会死循环
- **怎么做**:Channel Turn 内核有 bot-loop-protection
- **影响**:插件标记自己的出站消息,内核识别并跳过

## 设计观察

### 为什么渠道插件只能 transport-only

```
错误设计:
   Telegram 插件:
   • transport(收发消息)
   • 自己实现 /help 命令
   • 自己管理 agent 路由
   • 自己处理 provider 选择
   → 核心逻辑散落在各渠道 → 不一致,新增渠道要重做业务

正确设计:
   Telegram 插件:
   • transport(收发消息)
   • 渲染展示(markdown → Telegram 格式)
   • 动作映射(按钮回调 → 统一 action)
   • 不做任何业务决策
   → 核心逻辑集中在 Gateway → 一致,新增渠道只做适配
```

### 为什么所有渠道转成统一 InboundEvent

```
错误设计:
   内核直接处理各平台原生格式
   → 每新增一个渠道,内核都要改,耦合严重

正确设计:
   所有渠道转成统一 InboundEvent
   → 内核只处理内部格式,新增渠道不改内核
   → 渠道插件是适配层,内核是稳定层
```

### 为什么命令动作要类型化而非靠字符串推断

```
错误设计:
   渠道判断 value 以 "/" 开头就当命令处理
   → 用户消息内容含 "/" 误判为命令;渠道特判产品字符串

正确设计:
   核心/owner 插件声明类型化命令动作(approval/command/url/...)
   渠道在编码前区分动作类型,映射到平台能力
   → 不会误判,渠道不需猜产品语义
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/00-overview.md) | 接入层总览 |
| [01-gateway-http-ws.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/01-gateway-http-ws.md) | Gateway HTTP/WS Server(核心根) |
| [02-gateway-ws-protocol.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/02-gateway-ws-protocol.md) | Gateway WebSocket 协议 |
| [03-worker-admission.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/03-worker-admission.md) | Worker 接入(独立子协议) |
| [04-openai-openresponses.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/04-openai-openresponses.md) | OpenAI / OpenResponses REST API |
| [05-mcp.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/05-mcp.md) | MCP 接入(三个接入面) |
| [06-control-ui.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/06-control-ui.md) | Control UI 接入 |
| [07-plugin-http.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/07-plugin-http.md) | Plugin HTTP/Upgrade 接入 |
| [08-channels.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/08-channels.md) | 本文件 — Channel 渠道接入(25+) |
| [09-plugin-sdk.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/09-plugin-sdk.md) | Plugin SDK 接入 |
| [10-native-apps.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/10-native-apps.md) | 原生 App 接入 |
| [11-node-host-probe.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/11-node-host-probe.md) | Node Host + Probe 接入 |
| [12-auth-clients.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/01.2-access-layers/12-auth-clients.md) | 认证统一面 + ClientId 注册表 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Channel Turn 内核 | [src/channels/turn/kernel.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/kernel.ts) |
| Channel Turn 生命周期 | [src/channels/turn/lifecycle.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/turn/lifecycle.ts) |
| InboundEvent 类型 | [src/channels/inbound-event/kind.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/inbound-event/kind.ts) |
| 消息入口排空 | [src/channels/message/ingress-drain.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/channels/message/ingress-drain.ts) |
| 渠道入口契约 | [src/plugin-sdk/channel-entry-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/plugin-sdk/channel-entry-contract.ts) |
| Telegram 插件示例 | [extensions/telegram/index.ts](file:///d:/DevSpace/person/ai_space/openclaw/extensions/telegram/index.ts) |
| 渠道健康监控 | [src/gateway/channel-health-monitor.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/channel-health-monitor.ts) |
| 插件目录(25+ 渠道) | [extensions/](file:///d:/DevSpace/person/ai_space/openclaw/extensions/) |
