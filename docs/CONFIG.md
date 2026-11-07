# 配置详解

所有配置都在一个 `config.json` 里。从 `config.example.json` 复制一份再改。

```bash
cp config.example.json config.json
```

以 `_` 开头的键（`_comment`、`_agent_types`、`_dsh_http_example`）是给人看的说明，程序读的时候会忽略。你可以整段删掉，不影响运行。

---

## 一、顶层结构

```json
{
  "server": { ... },
  "user":   { ... },
  "agents": [ ... ]
}
```

`agents` 是唯一必填的。为空会直接退出并报错。

---

## 二、`server` — 服务设置

```json
"server": {
  "host": "0.0.0.0",
  "port": 8765,
  "token": "",
  "messages_file": "messages.json",
  "avatars_dir": "avatars"
}
```

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `host` | string | `0.0.0.0` | 监听地址。`0.0.0.0` 表示所有网卡都能连；只想本机用就写 `127.0.0.1` |
| `port` | int | `8765` | 监听端口 |
| `token` | string | 空 | 访问令牌。留空表示不校验。填了之后所有 `/api/*` 请求都要带 |
| `messages_file` | string | `<config 同目录>/messages.json` | 消息存哪。相对路径按 `config.json` 所在目录算 |
| `avatars_dir` | string | `<config 同目录>/avatars` | 头像目录。`GET /avatars/<文件名>` 从这里读 |

### `token` 怎么带

服务端接受三种写法，任选其一：

```
Authorization: Bearer <token>
X-Token: <token>
?token=<token>          # 查询参数
```

**注意**：Flutter 客户端发的是 `X-AgentsChat-Token` 头和 `?token=` 查询参数。服务端不认 `X-AgentsChat-Token`，所以实际生效的是查询参数那一份。如果你自己写客户端，用上面三种之一就好。

### 关于暴露到公网

`token` 是明文字符串比对，没有签名、没有过期、没有速率限制。**只适合内网或本机。** 真要放到公网，请在前面套一层反向代理做 TLS 和访问控制，别让这个服务直接面对外网。

---

## 三、`user` — 用户自己

```json
"user": {
  "id": "user",
  "name": "用户",
  "avatar": "user.png"
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `id` | `user` | 用户标识。发消息时如果没带 `from`，就用这个 |
| `name` | `用户` | 显示名 |
| `avatar` | `user.png` | 头像文件名 |

`id` 不要和任何 agent 的 `id` 重名，否则消息的 `role` 字段会混淆。

---

## 四、`agents` — agent 列表

一个数组，每项是一个 agent。

```json
{
  "id": "agent1",
  "name": "Agent 1",
  "avatar": "agent1.png",
  "color": "#6366f1",
  "type": "acp",
  "bridge": "http://127.0.0.1:18081",
  "aliases": ["小助手"]
}
```

### 通用字段

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `id` | ✅ | — | 内部标识。规则见下 |
| `name` | ❌ | 同 `id` | 显示名，同时也是 `@` 的默认触发词 |
| `avatar` | ❌ | `<id>.png` | 头像文件名 |
| `color` | ❌ | `#6366f1` | 界面上的标识色 |
| `type` | ❌ | `acp` | `acp` 或 `dsh_http`，见下文 |
| `aliases` | ❌ | `[]` | 额外的 `@` 触发词数组 |

### `id` 的规则

- 字母开头
- 只含字母、数字、下划线
- 最长 32 字符
- 全部 agent 之间不能重复

正则是 `[A-Za-z][A-Za-z0-9_]{0,31}`。不符合会在启动时报错退出，不会带着坏配置跑起来。

### `aliases` 怎么用

给同一个 agent 配多个触发词。

```json
{
  "id": "agent1",
  "name": "Agent 1",
  "aliases": ["小助手", "assistant", "A1"]
}
```

这四种写法效果完全一样：

```
@agent1 帮我看看
@Agent 1 帮我看看
@小助手 帮我看看
@A1 帮我看看
```

注意 `@Agent 1` 中间有空格——匹配时按完整名字走，不会在空格处断开。

**匹配是按名字长度从长到短排的**，长的先占位。所以配了 `agent1` 和 `agent10` 两个 agent 时，`@agent10` 不会被误认成 `@agent1` 加一个 `0`。

---

## 五、两种 `type` 的区别

### `acp` — 通过本地桥

```json
{
  "id": "agent1",
  "type": "acp",
  "bridge": "http://127.0.0.1:18081"
}
```

后端把消息 `POST` 到 `bridge + /chat`，桥再把消息喂给它后面的 agent 进程。

| 字段 | 必填 | 说明 |
|---|---|---|
| `bridge` | ✅ | 桥的地址，带协议和端口 |

**适合**：agent 跑在本机、由你自己启动和管理。
**优点**：完全本地，不依赖任何外部服务。
**缺点**：要自己把桥和 agent 进程拉起来。

桥的接口约定见 [protocol.md](protocol.md#一acp-桥)。

### `dsh_http` — 直连会话服务

```json
{
  "id": "agent2",
  "type": "dsh_http",
  "session": "session-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "dsh_host": "127.0.0.1:8080"
}
```

后端直接对会话服务发 HTTP RPC 投递消息，再用 WebSocket 订阅回复。

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `session` | ✅ | — | 目标会话 ID，形如 `session-<uuid>` |
| `dsh_host` | ❌ | `127.0.0.1:8080` | 会话服务地址，**不带协议前缀** |

**前置条件**：

1. 需要 `server/dsh_client.py`（已随仓库提供）
2. 需要 `websockets` 库：`pip install websockets`
3. 对方的令牌要从它的启动日志里取——`dsh_client.py` 的 `fetch_token()`
   读的是 systemd 单元日志，服务名和输出格式可能要按你的安装改

缺任何一个都会得到「DSH 通道不可用」，服务本身仍能正常启动。

**适合**：agent 是一个已经在跑的远程会话，你想从手机上也接进去。
**优点**：和那个会话共用同一段历史，两边看到的是同一份对话。
**缺点**：依赖对方的私有协议，对方升级可能失效；需要额外的客户端模块。

协议细节见 [protocol.md](protocol.md#二会话服务直连)。

### 选哪个

```
agent 在本机、你自己管  →  acp
想接进一个已经存在的会话  →  dsh_http
```

一个 `config.json` 里可以两种混着用，互不影响。

---

## 六、增删改 agent

### 加一个

往 `agents` 数组里追加一项，重启服务。

```json
"agents": [
  { "id": "agent1", "type": "acp", "bridge": "http://127.0.0.1:18081" },
  { "id": "agent2", "type": "acp", "bridge": "http://127.0.0.1:18082" }
]
```

启动日志会列出所有已加载的 agent，确认一眼就知道有没有生效：

```
[config] 已加载 2 个 agent: agent1, agent2
```

### 删一个

从数组里删掉那一项，重启。历史消息里那个 agent 说过的话仍然保留，只是它不再回应了。

### 改一个

改完重启。**配置只在启动时读一次，没有热重载。**

### 只想临时让它闭嘴

不用删配置，改名就行——把 `name` 和 `aliases` 都改掉，`@` 不到它。广播时它还是会回。

---

## 七、常见错误排查

### 启动就退出，报「找不到 config.json」

```
[config] 找不到 config.json
[config] 先复制模板: cp config.example.json config.json
```

在 `server/` 目录下跑，或者用 `--config` 指定绝对路径：

```bash
python3 server.py --config /path/to/config.json
```

### 报「agents 列表为空，至少配一个」

`agents` 是空数组或者键名拼错了（比如写成 `agent`）。必须至少有一个。

### 报「agent id 不合法」

`id` 用了中文、横线、点，或者数字开头。改成字母开头的字母数字下划线组合。

### 报「agent id 重复」

两个 agent 用了同一个 `id`。

### 报「类型 acp 但没配 bridge」

`type` 是 `acp` 就必须有 `bridge`，且要带协议前缀（`http://` 或 `https://`）。

### 报「类型 dsh_http 但没配 session」

`type` 是 `dsh_http` 就必须有 `session`，形如 `session-<uuid>`。

### 服务起来了，但发消息没反应

按顺序查：

**① 端口通不通**

```bash
curl http://127.0.0.1:8765/api/health
```

返回 `{"ok": true, "agents": N}` 说明后端活着。连不上就是没起来或端口被占。

**② agent 那边活不活**

`acp` 类型直接打桥：

```bash
curl -X POST http://127.0.0.1:18081/chat \
  -H 'Content-Type: application/json' \
  -d '{"text":"ping"}'
```

有回复说明桥和 agent 都正常。报连接拒绝就是桥没起来。

**③ 是不是 `@` 写错了**

消息里只要出现 `@` 字符，就会被当作「想 @ 某人」。

- `@agent1 在吗` → 只发给 agent1
- `@agent9 在吗` → agent9 不存在，**谁都不发**，只留一条消息在记录里
- `在吗 @` → 有 `@` 但没匹配到任何 agent，**谁都不发**

想广播就别在正文里带 `@`。

**④ 回复是「没回应」**

```
Agent 1 没回应：<urlopen error ...>
```

桥连上了但 agent 没在超时内回。看桥那边的日志。

### 头像不显示

`GET /avatars/<name>` 会去 `avatars_dir` 里找文件。确认：

- 文件名和配置里的 `avatar` 字段一致（含扩展名）
- 路径没写错（相对路径按 `config.json` 所在目录算）

扩展名只影响 `Content-Type`，不影响能否取到文件。有映射的是 `.png`
`.jpg` `.jpeg` `.svg` `.webp` 五种，其他扩展名会用
`application/octet-stream` 返回——浏览器可能直接下载而不是显示，
所以头像还是用 `.png` 最稳。

### 消息发不出去，报 401

配了 `token` 但请求没带。三种带法任选，见[上文](#token-怎么带)。

### 消息太长发不出去

单条上限 5000 字符，超了返回 400。这个值写死在代码里，不是配置项。

---

## 八、命令行参数

配置里的 `host` 和 `port` 可以被命令行覆盖，调试时方便：

```bash
python3 server.py --config config.json --port 8080 --host 127.0.0.1
```

优先级：命令行 > 配置文件 > 内置默认值。
