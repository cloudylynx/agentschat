# AgentsChat

一个可以自己部署的**多 agent 群聊**工具。

你在一个聊天界面里说话，几个 AI agent 一起看见、一起回答。每个 agent 独立运行，
各自有自己的会话历史和上下文；它们之间不共享记忆，只共享这一个聊天窗口。

后端是单文件 Python，只用标准库。前端是 Flutter，能跑在桌面和移动端。

---

## 特性

- **群聊**：不 @ 任何人时，消息广播给所有 agent，各自回复
- **定向**：`@agent1` 只发给那一个，其他 agent 看不到
- **别名**：给 agent 配多个名字，`@小助手` 和 `@agent1` 效果一样
- **思考过程**：agent 返回的思考链单独存一栏，可以和正文分开看
- **流式显示**：SSE 边收边显示，不用等整段生成完
- **两种接入方式**：本地 ACP 桥后面的进程，或远程会话服务里的一个会话
- **零依赖后端**：`server.py` 和 `acp_bridge.py` 只用 Python 标准库

## 快速开始

```bash
# 1. 配好 agent 列表
cd server
cp config.example.json config.json
#    编辑 config.json，把 agents 改成你自己的

# 2. 给 acp 类型的 agent 起一个桥（每个 agent 一个端口）
python3 acp_bridge.py --port 18081 --name "Agent 1" --profile acp

# 3. 起后端
python3 server.py
```

看到这行就成功了：

```
AgentsChat → http://0.0.0.0:8765
  Agent 1              (agent1) → http://127.0.0.1:18081
```

浏览器或 Flutter 客户端连 `http://127.0.0.1:8765` 就能说话。

详细步骤见 **[docs/README.md](docs/README.md)**。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 完整上手流程、状态表、已知限制 |
| [docs/CONFIG.md](docs/CONFIG.md) | 配置每个字段、agent 增删改、排错 |
| [docs/protocol.md](docs/protocol.md) | 两种接入方式的协议细节、踩过的坑 |
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | 怎么参与 |

## 目录

```
server/    Python 后端（server.py / acp_bridge.py / dsh_client.py）
app/       Flutter 客户端
docs/      文档
```

## 已知限制

- 消息存在单个 JSON 文件里，全部读进内存再写回，几千条以内没问题
- 没有历史分页，`GET /api/messages` 一次返回全部
- 同一个 agent 同一时刻只能处理一条消息，并发请求会排队
- `token` 是可选的明文比对，只适合内网或本机
- agent 之间不会互相看见对方的回复，除非下一轮手动带进去

## 许可

[MIT](LICENSE)
