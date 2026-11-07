# AgentsChat

一个可以自己部署的多 agent 群聊工具。

你在一个聊天界面里说话，几个 AI agent 一起看见、一起回答。每个 agent 独立运行，各自有自己的会话历史和上下文；它们之间不共享记忆，只共享这一个聊天窗口。

后端是单文件 Python，只用标准库，不需要 pip 装任何东西。前端是 Flutter，能跑在桌面和移动端。

## 它能做什么

- **群聊**：不 @ 任何人时，消息广播给所有 agent，各自回复
- **定向**：`@agent1` 只发给那一个，其他 agent 看不到
- **别名**：给 agent 配多个名字，`@小助手` 和 `@agent1` 效果一样
- **思考过程**：agent 返回的思考链单独存一栏，可以和正文分开看
- **两种接入方式**：agent 可以是本地 ACP 桥后面的进程，也可以是远程会话服务里的一个会话

## 快速开始

### 1. 装依赖

只需要 Python 3.9 以上。后端主体**零第三方依赖**——`server.py` 和
`acp_bridge.py` 只用标准库，不用 pip 装任何东西。

唯一的例外是 `dsh_http` 类型（可选）：它要订阅 WebSocket，需要装一个：

```bash
python3 --version              # 确认 >= 3.9
pip install websockets         # 只有用 dsh_http 类型时才需要
```

不用这个类型就完全不用装。缺了它也能启动，只是那个 agent 会报
「DSH 通道不可用」。

前端如果要自己编译，需要 Flutter SDK（见 `app/pubspec.yaml`）。

### 2. 配 config.json

```bash
cd server
cp config.example.json config.json
```

打开 `config.json`，把 `agents` 改成你自己的。最少改两个地方：`id` 和接入地址。

```json
{
  "server": { "host": "0.0.0.0", "port": 8765, "token": "" },
  "user":   { "id": "user", "name": "用户", "avatar": "user.png" },
  "agents": [
    {
      "id": "agent1",
      "name": "Agent 1",
      "type": "acp",
      "bridge": "http://127.0.0.1:18081"
    }
  ]
}
```

字段含义、两种 `type` 的区别、常见错误，都在 [CONFIG.md](CONFIG.md)。

### 3. 起一个 agent（ACP 桥）

服务端自己不会跑 agent，它只是个传话的。`type: "acp"` 的 agent 要有一个
**ACP 桥**在本机跑着，服务端通过 HTTP 调它：

```bash
cd server
python3 acp_bridge.py --port 18081 --name "Agent 1" --profile acp
```

看到这行就说明桥活了：

```
[Agent 1] 就绪 http://127.0.0.1:18081  session=xxxxxxxx
```

验证一下：

```bash
curl http://127.0.0.1:18081/status
# {"ok": true, "name": "Agent 1", "sessionId": "..."}

curl -X POST http://127.0.0.1:18081/chat \
  -H 'Content-Type: application/json' \
  -d '{"text": "你好，用一句话介绍你自己"}'
# {"reply": "...", "thought": "", "sessionId": "..."}
```

有两个 agent 就起两个桥（端口不同、`--name` 不同）。

#### 重要：别让桥继承你的人格文件

桥会启动一个 `dsh --profile <名字>` 子进程。如果那个 profile 会自动加载
`$DSH_HOME/AGENTS.md` 或记忆插件，agent 就会带着**你本机的私人设定**说话——
这既是串味，也可能把私人内容说出去。

干净做法是给开源版单独建一个中性 profile，并且关掉这两处：

```yaml
# ~/.dsh/profiles/<你的profile>/cordis.patch.yml
- id: system-prompt
  name: '@deepseek-ai/dsh-system-prompt'
  config:
    personaPrefix: ""          # 不写任何人设
    personaSuffix: ""

- id: agent-instructions
  name: '@deepseek-ai/dsh-agent-instructions'
  disabled: true               # 不加载 AGENTS.md / CLAUDE.md
```

同时把 `package.json` 的 `dsh.profile.bundles` 里任何记忆插件（例如
`dsh-mnemon`）去掉——它们会把你的长期记忆作为上下文注入进去。

改完拿这句验证，agent 应该**说不出任何特定身份**：

```bash
curl -X POST http://127.0.0.1:18081/chat \
  -H 'Content-Type: application/json' \
  -d '{"text": "你叫什么名字？用一句话回答。"}'
```

如果它报出一个你认识的名字，说明还有地方在注入，回去再查。

### 4. 跑起来

```bash
python3 server.py
```

看到这行就成功了：

```
AgentsChat → http://0.0.0.0:8765
  Agent 1              (agent1) → http://127.0.0.1:18081
```

浏览器打开 `http://127.0.0.1:8765`（或者用 Flutter 客户端连这个地址），就能说话了。

想确认后端活着：

```bash
curl http://127.0.0.1:8765/api/health
# {"ok": true, "agents": 1}
```

## 状态说明

这个项目在早期阶段，请先看清哪些已经能用、哪些还没有：

| 功能 | 状态 |
|---|---|
| 群聊 / 定向 / 别名 | ✅ 可用 |
| 同步回复（`/api/send`） | ✅ 可用 |
| 消息持久化 | ✅ 可用 |
| 头像服务 | ✅ 可用 |
| Flutter 客户端 | ✅ 可用 |
| 流式回复（`/api/send_stream`） | ✅ 可用（SSE，边收边显示） |
| 文件上传 / 会话管理 / 导入导出 | ⚠️ 客户端有界面，服务端接口未实现 |
| 内置网页界面 | ❌ 没有。后端只提供 JSON 接口 |

## 目录结构

```
.
├── app/                  Flutter 客户端
│   └── lib/
│       ├── main.dart     入口
│       ├── models/       数据模型
│       ├── screens/      界面（聊天 / 文件 / 设置）
│       ├── services/     API 封装与本地设置
│       ├── widgets/      可复用组件（气泡、输入框、头像）
│       └── theme/        配色
├── server/
│   ├── server.py         后端主程序（单文件，零依赖）
│   ├── acp_bridge.py     ACP 桥（给 acp 类型的 agent 用）
│   ├── config.example.json
│   └── avatars/          占位头像
└── docs/
    ├── CONFIG.md         配置详解
    ├── protocol.md       协议笔记
    └── CONTRIBUTING.md   怎么参与
```

## 文档

| 文档 | 内容 |
|---|---|
| [CONFIG.md](CONFIG.md) | 配置文件每个字段的含义、agent 增删改、别名、排错 |
| [protocol.md](protocol.md) | 两种接入方式的协议细节、字段结构、踩过的坑 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 怎么参与 |

## 已知限制

- **消息存在单个 JSON 文件里**，全部读进内存再写回。几千条以内没问题，再多要换存储
- **没有历史分页**：`GET /api/messages` 一次返回全部
- **同一个 agent 同一时刻只能处理一条消息**，并发请求会排队
- **token 是可选的明文比对**，只适合内网或本机。要暴露到公网请套反向代理加 TLS
- **agent 之间不会互相看见对方的回复**，除非你在下一轮把内容带进去
## 许可

MIT，见 [LICENSE](LICENSE)。
