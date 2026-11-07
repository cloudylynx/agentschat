# 协议笔记

这份文档记录两种接入方式背后的协议细节，包括字段结构和我实际踩过的坑。

内容分两部分：

- **第一部分**：ACP 桥 —— agent 跑在本地，通过 stdio 上的 JSON-RPC 通信
- **第二部分**：会话服务直连 —— 通过 HTTP RPC 投递消息，WebSocket 订阅回复

两种协议完全不同，别混着用。

---

# 一、ACP 桥

## 1.1 桥对外暴露什么

后端只认两个接口，都是 `POST`：

| 路径 | 用途 | 响应 |
|---|---|---|
| `/chat` | 同步要一条完整回复 | JSON |
| `/chat_stream` | 流式要回复 | SSE（`text/event-stream`） |

### 请求体（两个接口一样）

```json
{
  "text": "用户说的话",
  "from": "user",
  "group": true,
  "peers": ["Agent 1", "Agent 2"],
  "timeout": 300
}
```

| 字段 | 说明 |
|---|---|
| `text` | 消息正文 |
| `from` | 发送者 id |
| `group` | 是否群聊语境。`true` 时桥那边可能会调整提示词 |
| `peers` | 同群其他 agent 的显示名，用来告诉 agent「群里还有谁」 |
| `timeout` | 秒。桥应该在这个时间内返回，后端会多等 30 秒再放弃 |

### `/chat` 的响应

```json
{
  "reply": "回复正文",
  "thought": "思考过程（可选）",
  "error": "出错时的说明（可选）"
}
```

三个字段都可能缺席。后端取值顺序是 `reply` → `error` → 兜底字符串 `（没有回复）`。

### `/chat_stream` 的响应

SSE 流，每条 `data: ` 后面是一个 JSON 对象：

```json
{"kind": "thought", "data": "正在想……"}
{"kind": "reply",   "data": "第一段"}
{"kind": "reply",   "data": "第二段"}
{"kind": "done"}
```

| `kind` | 含义 |
|---|---|
| `thought` | 思考过程的一段增量 |
| `reply` | 回复正文的一段增量 |
| `error` | 出错，`data` 是说明 |
| `done` / `end` | 流结束（两个都认） |

收到 `done` 就停。没收到但连接断了，后端也会正常收尾（`stream_agent`
读到 EOF 时自己补一个结束）。

### ★ 坑：桥可能没有 `/chat_stream`

后端遇到 `404` 会自动降级：改成调 `/chat`，把整块结果当成一次性的 `reply` 和 `thought` 推出去。

所以如果你自己写桥，只实现 `/chat` 也能用，只是没有流式效果。

## 1.2 桥里面：ACP 本身

ACP 是一个基于 **JSON-RPC 2.0** 的协议，用来让「客户端」驱动「agent 运行时」。

### 传输

- 主传输是 **stdio**
- 消息用 JSON-RPC 2.0 编码，**必须 UTF-8**
- `stdout` 专门留给协议帧，诊断信息走 `stderr`

### 消息分类

| 形态 | 类型 |
|---|---|
| 有 `id` 和 `method` | 请求，期待一个响应 |
| 只有 `id` | 响应，对应某个先前的请求 |
| 只有 `method` | 通知，不需要响应 |

### 握手：`initialize`

```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocolVersion":1,"clientCapabilities":{}}}
```

响应里会宣告服务端能力，典型形状：

```json
{"jsonrpc":"2.0","id":1,"result":{
  "protocolVersion":1,
  "agentCapabilities":{...},
  "sessionCapabilities":{"close":{},"list":{},"resume":{}}
}}
```

`sessionCapabilities` 里出现哪几个键，就说明支持哪几个会话方法。**先看这个再决定能不能用 `session/list`。**

### 会话方法

| 方法 | 作用 | 方向 |
|---|---|---|
| `session/new` | 新建会话，返回 `sessionId` | 客户端 → agent |
| `session/load` | 载入已有会话 | 客户端 → agent |
| `session/resume` | 跨进程续接会话 | 客户端 → agent |
| `session/list` | 列出会话 | 客户端 → agent |
| `session/delete` | 删除会话 | 客户端 → agent |
| `session/prompt` | 发一轮对话 | 客户端 → agent |
| `session/cancel` | 取消进行中的操作 | 客户端 → agent（通知，无响应） |
| `session/update` | 实时推送（正文、思考、工具调用、用量） | agent → 客户端（通知） |
| `session/request_permission` | 请求用户授权 | agent → 客户端 |

`session/update` 的 `update.sessionUpdate` 字段区分推送类型，常见四种：

```
agent_message_chunk     正文增量
agent_thought_chunk     思考增量
tool_call               工具调用
usage_update            用量统计
```

### ★ 坑：`session/prompt` 不一定有真流式

某些实现会等整条 assistant 消息**提交之后**才生成 update。这种情况下你会看到思考和正文在同一时刻到达，中间没有任何增量。

这不是协议问题，是那个实现的选择。想要逐字流式，得看具体实现有没有在生成过程中就推 `session/update`。

判断方法：记录收到第一条 `agent_message_chunk` 的时间戳，和发出 `session/prompt` 的时间戳比。差几秒且两个 chunk 同时到，就是攒完才推。

### ★ 坑：v1 和 v2 不是一回事

- **v1**：`request id` 允许为 `null`，允许 JSON-RPC batch
- **v2（草稿）**：`request id` 不允许 `null`，不使用 batch，一次连接只讲一个协商好的版本

两版的 schema 不同，写客户端前先确认对面是哪版。

## 1.3 桥这一层要自己处理的事

后端不管这些，桥必须自己扛：

- **进程管理**：把 agent 进程拉起来，`stdin`/`stdout` 接上
- **帧编解码**：逐行读 `stdout`，每行一个 JSON
- **会话复用**：记住 `sessionId`，下次接着用；用不了就 `session/new`
- **并发**：同一时刻只处理一条消息，其余排队

---

# 二、会话服务直连

这条路径绕开桥，直接对一个正在运行的会话服务说话。

**它不是 ACP。** 它是两套不同的东西拼起来：

```
发消息 → HTTP RPC（一元请求）
收回复 → WebSocket（多路复用流）
```

## 2.1 认证

服务端启动时会打印一个带令牌的 URL。用它换 cookie：

```bash
curl -i "http://<host>:<port>/?token=<launch-token>"
```

响应是 **303**，`Set-Cookie` 里给一个 `dsh-auth-<hash>=<value>`。

### ★ 坑：必须处理 303

自动跟随重定向会**丢掉 `Set-Cookie`**。请求库默认都会跟随，要显式关掉：

```python
# 关掉自动重定向，手动读 Set-Cookie
```

拿到 cookie 之后，后续 HTTP 和 WebSocket 都带上它。

### ★ 坑：cookie 会过期

服务重启 → 令牌变 → cookie 失效。要写自动续期：遇到 401 就重新换一次 cookie 再重试。

## 2.2 发消息：HTTP RPC

```
POST http://<host>:<port>/api/session/prompt
Content-Type: application/json
Cookie: dsh-auth-<hash>=<value>
```

### 请求体

```json
{
  "type": "client-request",
  "rpcId": "25666c66-0f96-4e54-8886-d1e183a67558",
  "method": "session/prompt",
  "payload": {
    "args": {
      "request": {
        "requestId": "519eda6e-6147-49d8-a867-2f1e3fb458ca",
        "sessionId": "session-567f2575-01a1-45f7-9642-92b4b22f6c88",
        "mode": "queue",
        "content": [{"type": "text", "text": "要发的话"}],
        "clientTimeZone": "Asia/Shanghai"
      }
    }
  }
}
```

### 三个 UUID 各管什么

| 字段 | 谁生成 | 用途 |
|---|---|---|
| `rpcId` | 客户端 | 匹配响应。响应里会带回同一个值 |
| `requestId` | 客户端 | 这一次投递的标识 |
| `sessionId` | 服务端（先前创建） | 目标会话 |

### 响应

```json
{
  "type": "server-response",
  "rpcId": "25666c66-0f96-4e54-8886-d1e183a67558",
  "result": {"ok": true, "value": {"accepted": true}}
}
```

`accepted: true` 只代表**投递成功**，不代表已经回复。回复要从 WebSocket 那条流里收。

### `mode` 字段

| 值 | 行为 |
|---|---|
| `queue` | 会话正忙时排队，等这一轮结束后处理 |
| （其他） | 具体取值取决于服务端实现 |

用 `queue` 最安全：不会打断正在进行的一轮。

### 一元 RPC 的硬约束

| 约束 | 值 |
|---|---|
| 请求体上限 | 300 MiB，超了在缓冲完成前返回 `413` |
| `Content-Type` 必须是 | `application/json`，否则 `415` |
| 未注册的路径 | 直接 `404` |
| 鉴权失败 | `401` 或 `403`，不触碰任何业务逻辑 |

`415` 这条有额外意义：它挡住了跨站的「简单请求」——浏览器不发 CORS 预检的那种——让带副作用的 method 没法被盲执行。

## 2.3 收回复：WebSocket

```
ws://<host>:<port>/api/remote.mux
```

一条连接上多路复用多条流，每条流有自己的 `streamId`。

### 开一条流

```json
{
  "type": "open",
  "streamId": "412fdd07-24c6-4fe3-9b3c-bb451340ce33",
  "endpoint": "session/follow",
  "payload": {
    "args": {
      "request": {
        "address": {"kind": "session", "sessionId": "session-2adf470c-..."},
        "assistantStream": true,
        "maxMessages": 500,
        "turnWindow": {"minMessages": 50, "minTurns": 2}
      }
    }
  }
}
```

| 字段 | 说明 |
|---|---|
| `assistantStream` | `true` 才会推 token 级增量 |
| `maxMessages` | 最多回溯多少条历史 |
| `turnWindow` | 初始快照覆盖的窗口，太小会看不到前面的上下文 |

### ★ 关键：`session/follow` 是订阅，不是 resume

它**不抢会话写锁**。所以可以和别的客户端同时跟同一个会话。

这条性质是整个方案成立的基础——不用改服务端源码，不用抢占，只是多挂一个观察者。

### 已知 endpoint

| endpoint | 用途 | 可写 |
|---|---|---|
| `session/follow` | 跟随一段对话 | 只读 |
| `session/control` | 会话控制（基线 + 替换帧） | 读写 |
| `workspace/follow` | 跟随工作区 | 只读 |
| `$events` | 全局事件流 | 只读 |

## 2.4 服务端推下来的数据类型

外层都是 `{"type":"item","streamId":"...","value":{...}}`，`value.type` 区分种类。

### ① `assistant-stream` — 流式正文

```json
{"type":"item","streamId":"...","value":{
  "type":"assistant-stream",
  "frame":{"type":"chunk","attemptId":"session-xxx:1","revision":437,
           "index":435,"time":1793991782846,
           "chunk":{"type":"tool-call-delta","index":1,
                    "id":"call_00_xxx","name":"some_tool",
                    "argumentsDelta":" "}}}}
```

`chunk.type` 的子类型：

| 子类型 | 内容 |
|---|---|
| `tool-call-delta` | 工具调用参数，逐字推 |
| `usage` | token 统计 |
| `finish` | 结束原因 |

### ② `projection` — 会话状态投影

```json
{"type":"item","value":{
  "type":"projection","sessionId":"...","key":"tokenUsage",
  "value":{"uncachedInputTokens":6189,"outputTokens":494,
           "cacheReadTokens":238592,"cacheWriteTokens":0}}}
```

已知的 `key`：

| key | 内容 |
|---|---|
| `tokenUsage` | token 用量 |
| `contextPressure` | 上下文压力 |
| `contextBreakdown` | 上下文构成 |
| `sessionStats` | turns / steps / llmMs / ttftMs / decodeMs |

### ③ `event` — 领域事件

```json
{"type":"item","value":{
  "type":"event",
  "event":{"type":"tool/call","seq":18,"time":1793991783289,
           "data":{"turn":1,"step":1,"callId":"...","name":"some_tool",
                   "arguments":"{...}"}}}}
```

### ④ `waterfall` — 交互请求

```json
{"type":"item","value":{
  "type":"waterfall","event":"user-questions/request",
  "eventId":"72e8de12-...","agentId":"session-xxx",
  "request":{"questions":[...]}}}
```

收到这种帧说明 agent 在等用户回答。**不回答的话这一轮会卡住。**

### ⑤ 初始快照

```json
// session/follow 的第一帧
{"type":"item","value":{"type":"snapshot","header":{"version":4,"id":"session-xxx"}}}

// session/control 的第一帧
{"type":"item","value":{"type":"baseline","value":{"projections":{...}}}}
```

先把这一帧吃掉，再处理后续的增量。

### 心跳

服务端定期发 WebSocket **Ping**，间隔 **2000 ms**，用 pong 跟踪检测死连接。

客户端不需要主动发心跳，但**要能正确回 pong**——用现成的 WebSocket 库一般都自动处理，自己手写帧的要留意。

## 2.5 ★ 坑：不同 method 的 payload 结构不一样

这是最容易卡住的地方。

```json
// session/prompt
{"args": {"request": {...}}}

// session/list
{"args": {"_request": {...}}}
```

`session/list` 用 `_request`，不是 `request`。写错了会报 `missing "_request"`。

**不要假设同一个 API 下的所有 method 都用同一层包装。** 新接一个 method 时，先拿一个最小的错误请求探一下，看报错信息里缺的是哪个键。

## 2.6 ★ 坑：流式增量的字段名

推流里的正文/思考增量，字段名是 `text`，**不是** `reasoningDelta`。

按 `reasoningDelta` 去取会一直拿到 `undefined`，表现为「流开了但内容是空的」，很容易误判成协议没通。

**排查顺序**：先打印整帧原始 JSON，确认字段名，再写解析逻辑。别凭印象猜字段名。

## 2.7 这一层的完整流程

```
① GET /?token=<token>            → 303 + Set-Cookie（关掉自动重定向）
② ws /api/remote.mux             → 带上 Cookie
③ 发 {"type":"open", "endpoint":"session/follow", ...}
④ 收 {"type":"snapshot", ...}    → 吃掉初始快照
⑤ POST /api/session/prompt       → 投递消息，拿到 accepted:true
⑥ 继续读 WS                      → assistant-stream / projection / event
⑦ 读到结束信号                    → 收工
```

顺序上 ⑤ 和 ③ 谁先都行，但**③ 要先于 ⑤**——否则可能错过开头几帧。

---

# 三、两条路径对比

| | ACP 桥 | 会话服务直连 |
|---|---|---|
| 传输 | stdio | HTTP + WebSocket |
| 编码 | JSON-RPC 2.0 | JSON-RPC 2.0（HTTP）/ 自定义帧（WS） |
| 发消息 | `session/prompt` | `POST /api/session/prompt` |
| 收消息 | `session/update` 通知 | WS `item` 帧 |
| 会话锁 | 独占 | 订阅不抢锁 |
| 认证 | 无（本机进程） | cookie |
| 稳定性 | 标准协议 | 私有协议，升级会变 |
| 依赖 | 自己拉起进程 | 对方服务已在跑 |

## 为什么不统一

它们的所有权模型不同：一个是进程内通信，一个是浏览器与服务端之间的会话。硬统一只会让两边都变脆。

**按场景选，不按「哪个更先进」选。**

---

# 四、排错清单

## 桥这边

```
□ 桥的端口在监听吗         ss -ltn | grep <port>
□ /chat 直接打能回吗       curl -X POST .../chat -d '{"text":"ping"}'
□ agent 进程活着吗         看桥的日志
□ 超时是不是太短           默认 300 秒，长任务要调
```

## 直连这边

```
□ cookie 换到了吗          看 Set-Cookie，确认没跟随 303
□ WS 连上了吗              握手返回 101
□ 订阅开了吗               收到 snapshot 帧
□ 投递成功了吗             返回 accepted:true
□ 收到流式帧了吗           assistant-stream
□ 字段名对了吗             打印原始 JSON 确认
□ payload 包装对吗         request vs _request
```

## 两者都可能遇到的

```
□ 消息里有没有多余的 @      有 @ 但匹配不到人 → 谁都不发
□ 单条是不是超 5000 字符    超了 400
□ token 带了吗             配了 token 就必须带
```

---

# 五、版本与兼容

这两套协议都**没有稳定的兼容承诺**：

- ACP 的 v2 还是草稿，v1 和 v2 的 schema 不同
- 会话服务的直连协议是逆向出来的私有协议，服务端升级就可能变

建议做法：

1. 记录对接时的版本号或提交哈希
2. 关键字段缺失时**报错而不是静默降级**——静默降级会让问题延后暴露
3. 升级后先跑一遍上面的排错清单

---

# 六、安全提醒

- **cookie 就是凭证**，等同密码。别写进日志、别提交到仓库
- 直连方式**绕过了前端的审批界面**，agent 请求授权时没人能点确认。生产环境要自己想清楚这个边界
- 桥是**本机进程通信**，别把桥的端口暴露到公网
- 后端的 `token` 是明文比对，只适合内网
