#!/usr/bin/env python3
"""
通用 ACP 桥 —— 把一个 ACP agent 进程包成常驻 HTTP 服务。

一个进程服务一个 agent。AgentsChat 服务端通过 HTTP 调它：

    POST /chat          {"text": "...", "from": "user", "group": true,
                         "peers": ["Agent 1"], "timeout": 300}
                        → {"reply": "...", "thought": "...", "sessionId": "..."}
    POST /chat_stream   同样的 body，返回 SSE：data: {"kind":"reply","data":"..."}
                        kind 取值：thought | reply | done | error
    POST /new           强制开新会话 → {"sessionId": "..."}
    GET  /status        → {"ok": true, "name": "...", "sessionId": "...", "events": 0}

用法：
    python3 acp_bridge.py --port 18081 --name "Agent 1" \\
                          --profile acp --dsh-home ~/.dsh

    # 想固定用某个已有会话：
    python3 acp_bridge.py --port 18081 --name "Agent 1" \\
                          --profile acp --dsh-home ~/.dsh \\
                          --session-id <uuid>

`--profile` 对应 DSH 的 profile 名；如果你的 ACP agent 不是 DSH，
把 _spawn() 里的启动命令换成自己的即可（约定：stdio 上跑 JSON-RPC）。
"""
import argparse
import glob
import json
import os
import queue
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ARGS = None
BRIDGE = None


def _group_marker(sender, group, peers, self_name, sender_names):
    """拼一句上下文提示，告诉 agent 这条消息谁发的、群里还有谁。

    sender_names 把 id 映射成显示名；没配到的就用 id 本身。
    这只影响提示词，不改变 agent 的身份设定。
    """
    if not sender:
        return ''
    sender_cn = sender_names.get(sender, sender)
    marker = f'（这条消息是{sender_cn}发的'
    if group:
        others = [sender_names.get(p, p) for p in (peers or []) if p != self_name]
        if others:
            marker += f'。这是群聊，在场的有：{sender_cn}、' + '、'.join(others) + '。'
        else:
            marker += '。这是群聊。'
        marker += '如果消息 @ 了你，请完整处理并回复；没 @ 你就简短参与，别抢话。）'
    else:
        marker += '。）'
    return marker


class ACPBridge:
    def __init__(self, profile, dsh_home, name, sessions_root,
                 force_session_id='', sender_names=None, cwd=None,
                 bin_path='dsh', api_key_env='DSH_JUNIOR_API_KEY',
                 api_key_file=''):
        self.profile = profile
        self.dsh_home = dsh_home
        self.name = name
        self.sessions_root = sessions_root
        self.force_session_id = force_session_id
        self.sender_names = sender_names or {}
        self.cwd = cwd or os.path.expanduser('~')
        self.bin_path = bin_path
        self.api_key_env = api_key_env
        self.api_key_file = api_key_file
        self.q = queue.Queue()
        self.next_id = [0]
        self.lock = threading.Lock()
        self.sid = None
        self.events = []
        self.proc = None
        self._spawn()

    # ── 进程 ────────────────────────────────────────────────
    def _spawn(self):
        env = dict(os.environ)
        if self.dsh_home:
            env['DSH_HOME'] = self.dsh_home

        # 模型凭据：优先用环境变量；没有就从 DSH 的 settings.json 里借。
        # 不同安装方式位置不一样，所以做成 --api-key-file 可指定，默认按常见路径找。
        if self.api_key_env and not env.get(self.api_key_env):
            key = self._read_api_key()
            if key:
                env[self.api_key_env] = key

        cmd = [self.bin_path] + ['--profile', self.profile]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env, bufsize=1, text=True, cwd=self.cwd,
        )
        threading.Thread(target=self._reader, daemon=True).start()
        self._init()

    def _read_api_key(self):
        """从 DSH 的 settings.json 里找出模型 key。

        按顺序试：--api-key-file 指定的 → 各 profile 目录下的 settings.json。
        找到第一个形如 ...relay.key 或 chanGateway 里的 key 就用它。
        这是「省得让用户重新填一遍」的便利逻辑，找不到就返回空。
        """
        cands = []
        if self.api_key_file:
            cands.append(self.api_key_file)
        if self.dsh_home:
            base = os.path.join(self.dsh_home, 'our-free-model', 'settings.json')
            cands.append(base)
            for p in sorted(glob.glob(os.path.join(self.dsh_home, 'profiles', '*',
                                                   'settings.json'))):
                cands.append(p)
        for path in cands:
            try:
                with open(path) as f:
                    cfg = json.load(f)
            except Exception:
                continue
            key = ((cfg.get('chanGateway') or {}).get('relay') or {}).get('key') or ''
            if not key:
                key = (cfg.get('relay') or {}).get('key') or ''
            if not key:
                key = cfg.get('apiKey') or ''
            if key:
                return key
        return ''

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if line:
                self.q.put(line)

    def _send(self, obj):
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + '\n')
        self.proc.stdin.flush()

    def _wait(self, rid, timeout=60):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                line = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get('id') == rid:
                return m
        return None

    # ── 会话 ────────────────────────────────────────────────
    def _init(self):
        self.next_id[0] += 1
        rid = self.next_id[0]
        self._send({"jsonrpc": "2.0", "id": rid, "method": "initialize",
                    "params": {"protocolVersion": 1, "clientCapabilities": {}}})
        self._wait(rid, 60)

        sid = self.force_session_id or self._latest_session()
        if sid and sid.startswith('session-'):
            sid = sid[len('session-'):]
        if sid:
            if self._resume(sid):
                return
        self.new_session()

    def _resume(self, sid):
        self.next_id[0] += 1
        rid = self.next_id[0]
        self._send({"jsonrpc": "2.0", "id": rid, "method": "session/resume",
                    "params": {"sessionId": sid, "cwd": self.cwd,
                               "mcpServers": []}})
        r = self._wait(rid, 30)
        if r and 'result' in r:
            self.sid = sid
            print(f'[{self.name}] resumed {sid[:8]}', flush=True)
            return True
        return False

    def _latest_session(self):
        """没指定会话时，挑最近改过的那个（可选行为，用 --sessions-root 开启）。"""
        if not self.sessions_root or not os.path.isdir(self.sessions_root):
            return None
        best, bestm = None, 0
        for d in glob.glob(os.path.join(self.sessions_root, '*')):
            f = os.path.join(d, 'session.v4.jsonl.zstd')
            if os.path.exists(f):
                m = os.path.getmtime(f)
                if m > bestm:
                    best, bestm = os.path.basename(d), m
        return best

    def new_session(self):
        self.next_id[0] += 1
        rid = self.next_id[0]
        self._send({"jsonrpc": "2.0", "id": rid, "method": "session/new",
                    "params": {"cwd": self.cwd, "mcpServers": []}})
        r = self._wait(rid, 60)
        if not r or 'result' not in r:
            raise RuntimeError(f'session/new failed: {str(r)[:200]}')
        self.sid = r['result']['sessionId']
        print(f'[{self.name}] new session {self.sid[:8]}', flush=True)
        return self.sid

    # ── 对话 ────────────────────────────────────────────────
    def _prompt(self, text, sender, group, peers):
        marker = _group_marker(sender, group, peers, self.name, self.sender_names)
        if marker:
            text = marker + '\n\n' + text
        with self.lock:
            self.next_id[0] += 1
            rid = self.next_id[0]
            self._send({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                        "params": {"sessionId": self.sid,
                                   "prompt": [{"type": "text", "text": text}]}})
            return rid

    def chat(self, text, timeout=300, sender=None, group=False, peers=None):
        """发一条消息，等完整回复，返回 (reply, thought)。"""
        rid = self._prompt(text, sender, group, peers)
        rep, think = [], []
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                line = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get('id') == rid:
                return ''.join(rep), ''.join(think)
            if m.get('method') == 'session/update':
                u = (m.get('params') or {}).get('update') or {}
                self.events.append({'at': time.time(), 'update': u})
                st = u.get('sessionUpdate')
                c = u.get('content') or {}
                if isinstance(c, dict):
                    if st == 'agent_message_chunk':
                        rep.append(c.get('text', ''))
                    elif st == 'agent_thought_chunk':
                        think.append(c.get('text', ''))
        return ''.join(rep), ''.join(think)

    def chat_stream(self, text, timeout=300, sender=None, group=False, peers=None):
        """流式版，逐块 yield (kind, chunk)，kind: thought|reply|done|error。"""
        rid = self._prompt(text, sender, group, peers)
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                line = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get('id') == rid:
                yield ('done', '')
                return
            if m.get('method') == 'session/update':
                u = (m.get('params') or {}).get('update') or {}
                self.events.append({'at': time.time(), 'update': u})
                st = u.get('sessionUpdate')
                c = u.get('content') or {}
                if isinstance(c, dict):
                    t = c.get('text', '')
                    if not t:
                        continue
                    if st == 'agent_message_chunk':
                        yield ('reply', t)
                    elif st == 'agent_thought_chunk':
                        yield ('thought', t)
        yield ('done', '')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass  # 别把每条请求刷到 stdout，会和 JSON-RPC 日志混在一起

    def _json(self, data, code=200):
        b = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get('Content-Length', 0))
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ('/status', '/health'):
            self._json({'ok': True, 'name': ARGS.name,
                        'sessionId': BRIDGE.sid, 'events': len(BRIDGE.events)})
        else:
            self._json({'error': 'not found'}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        body = self._body()

        if u.path == '/chat':
            try:
                reply, thought = BRIDGE.chat(
                    body.get('text', ''),
                    int(body.get('timeout', 300)),
                    body.get('from'),
                    bool(body.get('group')),
                    body.get('peers'),
                )
                self._json({'reply': reply, 'thought': thought,
                            'sessionId': BRIDGE.sid})
            except Exception as e:
                self._json({'error': f'{type(e).__name__}: {str(e)[:300]}'}, 500)

        elif u.path == '/new':
            try:
                self._json({'sessionId': BRIDGE.new_session()})
            except Exception as e:
                self._json({'error': f'{type(e).__name__}: {str(e)[:300]}'}, 500)

        elif u.path == '/chat_stream':
            text = body.get('text', '')
            sender = body.get('from')
            group = bool(body.get('group'))
            peers = body.get('peers')
            timeout = int(body.get('timeout', 300))
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('X-Accel-Buffering', 'no')
                self.end_headers()

                def emit(kind, data):
                    payload = json.dumps({'kind': kind, 'data': data},
                                         ensure_ascii=False)
                    self.wfile.write(f'data: {payload}\n\n'.encode())
                    self.wfile.flush()

                for kind, chunk in BRIDGE.chat_stream(text, timeout, sender,
                                                      group, peers):
                    emit(kind, chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass  # 客户端断开，正常
            except Exception as e:
                try:
                    emit('error', f'{type(e).__name__}: {str(e)[:200]}')
                except Exception:
                    pass
        else:
            self._json({'error': 'not found'}, 404)


def main():
    global ARGS, BRIDGE
    ap = argparse.ArgumentParser(description='ACP 桥：把一个 ACP agent 包成 HTTP 服务')
    ap.add_argument('--port', type=int, default=18081)
    ap.add_argument('--host', default='127.0.0.1',
                    help='默认只听本机；要跨机访问填 0.0.0.0（注意加防火墙）')
    ap.add_argument('--name', default='Agent',
                    help='这个 agent 的显示名，会写进群聊提示里')
    ap.add_argument('--profile', default='acp',
                    help='DSH profile 名（默认 acp）')
    ap.add_argument('--bin', default='dsh',
                    help='agent 可执行文件（默认 PATH 里的 dsh）')
    ap.add_argument('--dsh-home', default=os.environ.get('DSH_HOME', ''),
                    help='DSH_HOME，默认继承环境变量')
    ap.add_argument('--session-id', default='',
                    help='固定 resume 这个会话；不给就挑最近的、或开新的')
    ap.add_argument('--sessions-root', default='',
                    help='会话目录，给了才会去挑「最近改过的会话」')
    ap.add_argument('--cwd', default=os.path.expanduser('~'),
                    help='agent 的工作目录')
    ap.add_argument('--api-key-env', default='DSH_JUNIOR_API_KEY',
                    help='模型 key 放哪个环境变量（默认 DSH_JUNIOR_API_KEY）')
    ap.add_argument('--api-key-file', default='',
                    help='要从哪个 settings.json 里借 key；不给就按 DSH 常见路径找')
    ap.add_argument('--sender-names', default='',
                    help='发送者 id 到显示名的映射，JSON，例如 '
                         '\'{"user":"用户","agent1":"Agent 1"}\'')
    ARGS = ap.parse_args()

    sender_names = {}
    if ARGS.sender_names:
        try:
            sender_names = json.loads(ARGS.sender_names)
        except Exception as e:
            print(f'--sender-names 解析失败：{e}', file=sys.stderr)
            sys.exit(2)

    print(f'[{ARGS.name}] 启动 ACP 桥 :{ARGS.port} '
          f'(profile={ARGS.profile}, bin={ARGS.bin})', flush=True)
    BRIDGE = ACPBridge(
        profile=ARGS.profile,
        dsh_home=ARGS.dsh_home,
        name=ARGS.name,
        sessions_root=ARGS.sessions_root,
        force_session_id=ARGS.session_id,
        sender_names=sender_names,
        cwd=ARGS.cwd,
        bin_path=ARGS.bin,
        api_key_env=ARGS.api_key_env,
        api_key_file=ARGS.api_key_file,
    )
    srv = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    print(f'[{ARGS.name}] 就绪 http://{ARGS.host}:{ARGS.port}  '
          f'session={BRIDGE.sid}', flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print(f'[{ARGS.name}] 退出', flush=True)


if __name__ == '__main__':
    main()
