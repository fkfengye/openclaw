# 05 — Control UI 后端

> 读完本章你将理解:Gateway 内部如何为 Control UI 提供后端能力、CSP 如何保护渲染、路由层如何解析视图、Session PRS 如何加载会话、GitHub 预览如何安全嵌入、插件 Tab 如何沙箱隔离。

## 一句话定位

Control UI 后端是 Gateway 内部的"管理控制台后端":
- CSP 策略严格保护渲染,防 XSS 与数据注入
- 路由层解析当前视图,支持会话/设置/插件等视图
- Session PRS 加载会话列表与详情,支持本地 Git 集成
- GitHub 预览安全嵌入 PR/Issue 视图
- 插件 Tab 沙箱隔离,插件 UI 不污染主界面

## 全局协作图

下图展示 Control UI 后端组件如何为浏览器客户端提供渲染所需的所有后端能力。

```
┌──────────────────────────────────────────────────────────────────────┐
│                       聊天显示(已在 04 讲述)                         │
│                                                                      │
│   可见消息(交付客户端)                                            │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ 客户端同时拉取 UI 元数据
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       Control UI 后端面                              │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  CSP 策略器                                                  │   │
│  │                                                              │   │
│  │  • 严格内容安全策略                                          │   │
│  │  • 限制脚本/样式/图片来源                                   │   │
│  │  • 防 XSS 与数据注入                                         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ 路由层       │  │ 静态资源     │  │ HTTP 工具                │  │
│  │              │  │              │  │                          │  │
│  │ 解析当前视图 │  │ 提供 UI 静态 │  │ 通用 HTTP 处理工具       │  │
│  │ 会话/设置/   │  │ 资源(HTML / │  │                          │  │
│  │ 插件/仪表盘  │  │ JS / CSS)   │  │                          │  │
│  └──────┬───────┘  └──────────────┘  └──────────────────────────┘  │
│         │                                                            │
│         ▼                                                            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  视图服务面                                                  │   │
│  │                                                              │   │
│  │  ┌────────────────┐  ┌────────────────┐                     │   │
│  │  │ Session PRS    │  │ GitHub 预览    │                     │   │
│  │  │                │  │                │                     │   │
│  │  │ 会话列表/详情  │  │ PR/Issue 嵌入  │                     │   │
│  │  │ 本地 Git 集成  │  │ 安全渲染       │                     │   │
│  │  └────────────────┘  └────────────────┘                     │   │
│  │                                                              │   │
│  │  ┌────────────────┐  ┌────────────────┐                     │   │
│  │  │ 插件 Tab       │  │ 链接处理       │                     │   │
│  │  │                │  │                │                     │   │
│  │  │ 沙箱隔离渲染   │  │ 安全链接展开   │                     │   │
│  │  │ 插件 UI 不污染 │  │                │                     │   │
│  │  └────────────────┘  └────────────────┘                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  契约与共享面                                                │   │
│  │  • 契约定义(UI 与后端的接口契约)                          │   │
│  │  • 共享工具(通用辅助)                                     │   │
│  │  • 插件认证 cookie                                          │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
                  浏览器渲染 Control UI
```

## 组件清单

Control UI 后端由 8 类核心组件协作:

| 组件 | 职责 | 关键约束 |
|---|---|---|
| **CSP 策略器** | 严格内容安全策略,限制脚本/样式/图片来源 | 默认拒绝,显式允许 |
| **路由层** | 解析当前视图(会话/设置/插件/仪表盘) | 路由与 API 物理分离 |
| **静态资源器** | 提供 UI 静态资源(HTML/JS/CSS) | 静态资源不可执行后端逻辑 |
| **Session PRS** | 会话列表/详情加载,支持本地 Git 集成 | 只读会话数据,不改状态 |
| **GitHub 预览器** | 安全嵌入 PR/Issue 视图 | 沙箱渲染,防注入 |
| **插件 Tab 器** | 沙箱隔离渲染插件 UI | 插件 UI 不污染主界面 |
| **链接处理器** | 安全链接展开与跳转 | 外链显式确认 |
| **契约与共享面** | UI 与后端接口契约,通用辅助 | 契约变更需双方同步 |

## 关联关系

### CSP 策略器的防御边界

```
   浏览器请求 Control UI 页面
            │
            ▼
   ┌──────────────────────────────────────────────┐
   │  CSP 策略器                                  │
   │                                              │
   │  产出内容安全策略头:                        │
   │  • 脚本来源:仅允许同源                      │
   │  • 样式来源:仅允许同源 + 受信 CDN          │
   │  • 图片来源:同源 + 数据引用                │
   │  • 连接来源:仅允许 Gateway WS/HTTP         │
   │  • 框架来源:插件 Tab 沙箱单独允许          │
   └──────────────────────────────────────────────┘
            │
            ▼
   浏览器执行 CSP 策略
   • 违规资源被拒绝加载
   • 违规脚本不执行
   • 违规连接被阻断

   反例(错误设计):
   CSP 过宽(允许 *) → XSS 攻击面大
   → 必须默认拒绝,显式允许
```

### 路由层与视图服务

```
   ┌──────────────────────────────────────────────┐
   │  路由层                                      │
   │                                              │
   │  解析 URL → 视图类型                         │
   │                                              │
   │  • /sessions/*       → 会话视图              │
   │  • /settings/*       → 设置视图              │
   │  • /plugins/*        → 插件视图              │
   │  • /dashboard/*      → 仪表盘视图            │
   │  • /github/*         → GitHub 预览视图       │
   └────────────────────────┬─────────────────────┘
                            │ 视图类型
                            ▼
   ┌──────────────────────────────────────────────┐
   │  视图服务面                                  │
   │                                              │
   │  按视图类型调用对应服务:                    │
   │  • 会话视图 → Session PRS                   │
   │  • GitHub 视图 → GitHub 预览器              │
   │  • 插件视图 → 插件 Tab 器                   │
   └──────────────────────────────────────────────┘

   关键:路由与 API 物理分离
   • UI 路由不与通用 API 混在一起
   • 专用 CSP / 沙箱策略
```

### Session PRS 与本地 Git 集成

```
   ┌──────────────────────────────────────────────┐
   │  Session PRS                                 │
   │                                              │
   │  职责:                                      │
   │  • 加载会话列表(分页/过滤)                │
   │  • 加载会话详情(消息历史)                 │
   │  • 本地 Git 集成(读取仓库信息)            │
   │  • 会话落地页(新建会话入口)               │
   └──────────────────────────────────────────────┘

   本地 Git 集成用途:
   • 在会话中引用本地仓库状态
   • 展示仓库分支/提交信息
   • 不修改仓库(只读)

   反例(错误设计):
   Session PRS 可修改 Git 仓库
   → UI 后端有写权限 → 安全风险
   → 必须只读
```

### 插件 Tab 沙箱隔离

```
   ┌──────────────────────────────────────────────────────┐
   │  Control UI 主界面                                   │
   │                                                      │
   │  ┌──────────────────────────────────────────────┐   │
   │  │  主界面区域(同源)                          │   │
   │  │  • 会话 / 设置 / 仪表盘                      │   │
   │  └──────────────────────────────────────────────┘   │
   │                                                      │
   │  ┌──────────────────────────────────────────────┐   │
   │  │  插件 Tab 区域(沙箱)                       │   │
   │  │                                              │   │
   │  │  ┌────────────┐  ┌────────────┐             │   │
   │  │  │ 插件 A UI  │  │ 插件 B UI  │  ...        │   │
   │  │  │ (隔离)    │  │ (隔离)    │             │   │
   │  │  └────────────┘  └────────────┘             │   │
   │  └──────────────────────────────────────────────┘   │
   └──────────────────────────────────────────────────────┘

   关键:插件 Tab 沙箱
   • 插件 UI 不污染主界面 DOM
   • 插件 UI 不能访问主界面数据
   • 插件 UI 通过契约通信(不直接访问)
   • CSP 对插件 Tab 单独允许框架来源

   反例(错误设计):
   插件 UI 直接嵌入主界面 DOM
   → 插件可访问主界面数据 → 安全风险
   → 插件 Bug 影响主界面 → 稳定性风险
```

### GitHub 预览器的安全嵌入

```
   用户在 Control UI 查看 PR 链接
         │
         ▼
   ┌──────────────────────────────────────────────┐
   │  GitHub 预览器                               │
   │                                              │
   │  • 通过 GitHub API 拉取 PR 数据             │
   │  • 不直接嵌入 GitHub 页面(防注入)          │
   │  • 渲染为 OpenClaw 自有视图                 │
   │  • 链接展开需显式确认                       │
   └──────────────────────────────────────────────┘

   反例(错误设计):
   直接 iframe 嵌入 GitHub 页面
   → GitHub 可注入脚本 → XSS 风险
   → 必须用 API 拉数据 + 自有渲染
```

## 协作流程

### 用户打开 Control UI 看会话列表

下面追踪用户打开 Control UI 并查看会话列表的全过程。

```
用户在浏览器打开 Control UI URL
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 静态资源器                                                │
│    • 返回 Control UI 主 HTML                                 │
│    • CSP 策略器附加 CSP 头                                   │
│    • 浏览器开始加载 JS / CSS                                 │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 浏览器初始化                                              │
│    • 建立 WS 连接到 Gateway                                  │
│    • 走认证内部(认证面)                                    │
│    • 客户端注册表注册                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 路由层解析视图                                            │
│    • 默认路由到会话视图                                      │
│    • 调用 Session PRS                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Session PRS 加载会话列表                                  │
│    • 从状态层查询会话列表                                    │
│    • 分页返回                                                │
│    • 本地 Git 集成附加仓库信息                               │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 浏览器渲染                                                │
│    • CSP 保护渲染过程                                        │
│    • 会话列表展示                                            │
│    • 用户点击某会话 → 加载详情                              │
└──────────────────────────────────────────────────────────────┘
```

### 用户查看插件 Tab 场景

```
用户点击某插件的 Tab
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 路由层解析到插件视图                                      │
│    • 调用插件 Tab 器                                         │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 插件 Tab 器准备沙箱                                      │
│    • 创建隔离的渲染容器                                      │
│    • CSP 单独允许该插件的来源                                │
│    • 加载插件 UI 资源                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 插件 UI 在沙箱内渲染                                      │
│    • 插件 UI 不能访问主界面 DOM                              │
│    • 插件 UI 通过契约通信                                    │
│    • 插件认证 cookie 隔离                                    │
└──────────────────────────────────────────────────────────────┘
                             │
                             ▼
                  插件 Tab 展示插件功能
                  (主界面不受影响)
```

### 用户查看 GitHub PR 预览场景

```
用户在会话中收到 PR 链接,点击预览
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. 链接处理器                                                │
│    • 识别为 GitHub PR 链接                                   │
│    • 显式确认是否预览                                        │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. GitHub 预览器                                             │
│    • 通过 GitHub API 拉取 PR 数据                            │
│    • 不直接嵌入 GitHub 页面                                  │
│    • 渲染为 OpenClaw 自有视图                                │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 浏览器渲染                                                │
│    • CSP 保护渲染                                            │
│    • PR 视图展示(标题/描述/文件/评论)                      │
└──────────────────────────────────────────────────────────────┘
```

## 关键设计约束

### 1. CSP 默认拒绝显式允许

- **为什么**:过宽的 CSP 会让 XSS 攻击面大
- **怎么做**:默认拒绝所有来源,显式允许所需来源
- **影响**:新增资源来源需更新 CSP,有审计痕迹

### 2. 路由与 API 物理分离

- **为什么**:UI 路由与 API 混在一起会让 CSP/沙箱策略无法专门强化
- **怎么做**:Control UI 后端独立子面,专用路由层
- **影响**:UI 后端可独立强化安全策略

### 3. 插件 Tab 沙箱隔离

- **为什么**:插件 UI 直接嵌入主界面会让插件可访问主界面数据
- **怎么做**:插件 Tab 器创建隔离容器,CSP 单独允许
- **影响**:插件 Bug 不影响主界面,插件不能窃取主界面数据

### 4. GitHub 预览不直接嵌入

- **为什么**:直接 iframe 嵌入 GitHub 会让 GitHub 可注入脚本
- **怎么做**:用 GitHub API 拉数据 + OpenClaw 自有渲染
- **影响**:预览视图安全,但需维护渲染逻辑

### 5. Session PRS 只读

- **为什么**:UI 后端有写权限会扩大安全风险
- **怎么做**:Session PRS 只查询会话数据,不改状态;写操作走对话面
- **影响**:会话变更统一走对话面,审计清晰

### 6. 契约变更需双方同步

- **为什么**:UI 与后端契约不同步会导致渲染错乱
- **怎么做**:契约定义集中管理,变更需 UI 与后端同步
- **影响**:契约变更有评审痕迹,避免单方修改

## 设计观察

### 为什么 Control UI 后端独立成面

```
错误设计:
   把 UI 后端逻辑塞进通用 HTTP 处理器
   → UI 路由与 API 路由混在一起
   → CSP / 沙箱策略无法专门强化
   → 插件 Tab 隔离缺失

正确设计:
   Control UI 后端独立子面
   → 专用 CSP 策略
   → 专用路由层(支持 PRS / GitHub 预览)
   → 插件 Tab 沙箱隔离
   → 与通用 API 物理分离
```

### 为什么插件 Tab 用沙箱而非直接嵌入

```
错误设计:
   插件 UI 直接嵌入主界面 DOM
   → 插件可访问主界面数据(会话/凭据)
   → 插件 Bug 影响主界面稳定性
   → 插件可注入恶意脚本

正确设计:
   插件 Tab 器创建沙箱容器
   → 插件 UI 隔离渲染
   → 通过契约通信(不直接访问)
   → CSP 单独允许插件来源
   → 插件认证 cookie 隔离
```

### 为什么 GitHub 预览用 API 而非 iframe

```
错误设计:
   直接 iframe 嵌入 GitHub 页面
   → GitHub 可注入脚本(XSS)
   → GitHub 可访问主界面数据
   → 渲染风格不一致

正确设计:
   GitHub 预览器用 API 拉数据
   → OpenClaw 自有渲染
   → 风格一致
   → 安全(无第三方脚本)
   → 但需维护渲染逻辑(代价)
```

## 章节索引

| 文件 | 主题 |
|---|---|
| [00-overview.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/00-overview.md) | 内部编排总览与索引 |
| [01-boot-lifecycle.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/01-boot-lifecycle.md) | 启动与生命周期、配置热重载 |
| [02-auth-internal.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/02-auth-internal.md) | 认证内部:归一、限速、表面解析 |
| [03-client-conversation.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/03-client-conversation.md) | 客户端与对话:Turn、列表、读取 |
| [04-chat-display.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/04-chat-display.md) | 聊天显示:投影、附件、中止、清洗 |
| [05-control-ui-backend.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/05-control-ui-backend.md) | 本文件 — Control UI 后端:CSP、路由、PRS、插件 Tab |
| [06-credentials-monitoring.md](file:///d:/DevSpace/person/ai_space/openclaw/knowledge-base/03-runtime-core/03.2-gateway-internal/06-credentials-monitoring.md) | 凭据与监控:规划、健康、定时流、审批 |

## 源码索引

> 以下为本章涉及的关键源码位置,供深入查阅使用。

| 组件 | 源码位置 |
|---|---|
| Control UI 后端主入口 | [src/gateway/control-ui.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui.ts) |
| CSP 策略器 | [src/gateway/control-ui-csp.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-csp.ts) |
| 路由层 | [src/gateway/control-ui-routing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-routing.ts) |
| 静态资源器 | [src/gateway/control-ui-static.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-static.ts) |
| Session PRS 主入口 | [src/gateway/control-ui-session-prs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-session-prs.ts) |
| Session PRS 落地页 | [src/gateway/control-ui-session-prs-landing.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-session-prs-landing.ts) |
| Session PRS 本地 Git | [src/gateway/control-ui-session-prs-local-git.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-session-prs-local-git.ts) |
| GitHub API | [src/gateway/control-ui-github-api.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-github-api.ts) |
| GitHub 预览器 | [src/gateway/control-ui-github-preview.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-github-preview.ts) |
| 插件 Tab 器 | [src/gateway/control-ui-plugin-tabs.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-plugin-tabs.ts) |
| 插件认证 cookie | [src/gateway/control-ui-plugin-auth-cookie.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-plugin-auth-cookie.ts) |
| 链接处理器 | [src/gateway/control-ui-links.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-links.ts) |
| HTTP 工具 | [src/gateway/control-ui-http-utils.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-http-utils.ts) |
| 契约定义 | [src/gateway/control-ui-contract.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-contract.ts) |
| 共享工具 | [src/gateway/control-ui-shared.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/control-ui-shared.ts) |
| Control UI 根 | [src/gateway/server-control-ui-root.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/server-control-ui-root.ts) |
| 托管插件表面 URL | [src/gateway/hosted-plugin-surface-url.ts](file:///d:/DevSpace/person/ai_space/openclaw/src/gateway/hosted-plugin-surface-url.ts) |
