#!/usr/bin/env python3
"""
AgentsChat Server — 多 agent 群聊后端

从 config.json 读取 agent 列表，支持任意增删改。
每个 agent 通过 ACP 桥或 DSH HTTP 接口对话。

用法:
    cp config.example.json config.json
    vim config.json          # 配置你的 agent
    python3 server.py        # 默认读 ./config.json
    python3 server.py --config /path/to/config.json --port 8765
"""

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# ── 全局状态 ──────────────────────────────────────────────
CONFIG = {}
AGENTS = {}          # id -> agent dict
USER = {}            # 用户信息
MESSAGES_FILE = ''
AVATARS_DIR = ''
TOKEN = ''
HOST = '0.0.0.0'
PORT = 8765

_lock = threading.Lock()
INFLIGHT = {}        # agent_id -> {'reply': str, 'thought': str, 'startedAt': ms}


# ── 配置加载 ──────────────────────────────────────────────
def load_config(path):
    """读配置并校验"""
    global CONFIG, AGENTS, USER, MESSAGES_FILE, AVATARS_DIR, TOKEN, HOST, PORT

    if not os.path.exists(path):
        print(f'[config] 找不到 {path}', file=sys.stderr)
        print(f'[config] 先复制模板: cp config.example.json config.json', file=sys.stderr)
        sys.exit(1)

    with open(path, encoding='utf-8') as f:
        CONFIG = json.load(f)

    base = os.path.dirname(os.path.abspath(path))

    # 服务设置
    srv = CONFIG.get('server') or {}
    HOST = srv.get('host', '0.0.0.0')
    PORT = int(srv.get("port", 8765))
    TOKEN = str(srv.get('token') or '')

    # 用户
    USER = CONFIG.get('user') or {'id': 'user', 'name': '用户', 'avatar': 'user.png'}

    # agent 列表
    agents = CONFIG.get('agents') or []
    if not agents:
        print('[config] agents 列表为空，至少配一个', file=sys.stderr)
        sys.exit(1)

    seen = set()
    AGENTS = {}
    for i, a in enumerate(agents):
        aid = str(a.get('id') or '').strip()
        if not aid:
            print(f'[config] 第 {i+1} 个 agent 缺 id', file=sys.stderr)
            sys.exit(1)
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,31}', aid):
            print(f'[config] agent id「{aid}」不合法（字母开头，只含字母数字下划线，最长32）', file=sys.stderr)
            sys.exit(1)
        if aid in seen:
            print(f'[config] agent id「{aid}」重复', file=sys.stderr)
            sys.exit(1)
        seen.add(aid)

        typ = a.get('type', 'acp')
        if typ == 'acp' and not a.get('bridge'):
            print(f'[config] agent「{aid}」类型 acp 但没配 bridge', file=sys.stderr)
            sys.exit(1)
        if typ == 'dsh_http' and not a.get('session'):
            print(f'[config] agent「{aid}」类型 dsh_http 但没配 session', file=sys.stderr)
            sys.exit(1)

        AGENTS[aid] = {
            'id': aid,
            'name': a.get('name') or aid,
            'avatar': a.get('avatar') or f'{aid}.png',
            'color': a.get('color') or '#6366f1',
            'type': typ,
            'bridge': a.get('bridge'),
            'session': a.get('session'),
            'dsh_host': a.get('dsh_host') or '127.0.0.1:8080',
            'aliases': a.get('aliases') or [],     # 额外 @ 名字
        }

    # 消息存储
    MESSAGES_FILE = srv.get('messages_file') or os.path.join(base, 'messages.json')
    AVATARS_DIR = srv.get('avatars_dir') or os.path.join(base, 'avatars')

    print(f'[config] 已加载 {len(AGENTS)} 个 agent: {", ".join(AGENTS.keys())}', flush=True)


def load_messages():
    if not os.path.exists(MESSAGES_FILE):
        return []
    try:
        with open(MESSAGES_FILE, encoding='utf-8') as f:
            return json.load(f).get('messages') or []
    except Exception:
        return []


def save_messages(msgs):
    os.makedirs(os.path.dirname(MESSAGES_FILE), exist_ok=True)
    with open(MESSAGES_FILE, 'w', encoding='utf-8') as f:
        json.dump({'messages': msgs}, f, ensure_ascii=False, indent=2)


def append_message(m):
    with _lock:
        msgs = load_messages()
        msgs.append(m)
        save_messages(msgs)
    return m


# ── @ 解析 ────────────────────────────────────────────────
def parse_mentions(text):
    """返回被 @ 的 agent id 列表

    按名字长度降序匹配，长的先占位，
    这样 @agent10 不会同时匹配 agent1。
    """
    cands = []
    for aid, a in AGENTS.items():
        names = [a['name'], aid] + list(a.get('aliases') or [])
        for n in names:
            if n:
                cands.append((n, aid))
    cands.sort(key=lambda x: len(x[0]), reverse=True)

    hits, consumed = [], []
    for name, aid in cands:
        pat = '@' + re.escape(name)
        for m in re.finditer(pat, text):
            start, end = m.start(), m.end()
            if any(s <= start and end <= e for s, e in consumed):
                continue
            consumed.append((start, end))
            if aid not in hits:
                hits.append(aid)
            break
    return hits


# ── 调 agent ──────────────────────────────────────────────
def call_agent(aid, text, sender_id='user', timeout=300):
    """同步调一个 agent"""
    a = AGENTS.get(aid)
    if not a:
        return {'error': f'unknown agent {aid}'}

    if a['type'] == 'dsh_http':
        return _dsh_chat(a, text, timeout)

    body = json.dumps({
        'text': text, 'from': sender_id, 'group': True,
        'peers': [v['name'] for v in AGENTS.values()],
        'timeout': timeout,
    }).encode()
    req = urllib.request.Request(
        a['bridge'] + '/chat', data=body, method='POST',
        headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout + 30) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {'error': f'{a["name"]} 没回应：{str(e)[:150]}'}


def stream_agent(aid, text, sender_id='user', timeout=300):
    """流式调一个 agent，yield (kind, data)"""
    a = AGENTS.get(aid)
    if not a:
        yield ('error', f'unknown agent {aid}')
        return

    if a['type'] == 'dsh_http':
        yield from _dsh_stream(a, text, timeout)
        return

    body = json.dumps({
        'text': text, 'from': sender_id, 'group': True,
        'peers': [v['name'] for v in AGENTS.values()],
        'timeout': timeout,
    }).encode()
    req = urllib.request.Request(
        a['bridge'] + '/chat_stream', data=body, method='POST',
        headers={'Content-Type': 'application/json',
                 'Accept': 'text/event-stream'})
    try:
        with urllib.request.urlopen(req, timeout=timeout + 30) as r:
            while True:
                raw = r.readline()
                if not raw:
                    break
                line = raw.decode('utf-8', 'replace').strip()
                if not line.startswith('data: '):
                    continue
                try:
                    d = json.loads(line[6:])
                except Exception:
                    continue
                kind = d.get('kind', '')
                data = d.get('data', '')
                # 桥可能用 'end'（文档写法）或 'done'（本仓库 acp_bridge.py 的写法），
                # 两种都当结束处理，避免多等一个超时。
                if kind in ('end', 'done'):
                    yield ('done', '')
                    return
                yield (kind, data)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # 桥没有 /chat_stream，降级到 /chat
            try:
                body2 = json.dumps({
                    'text': text, 'from': sender_id, 'group': True,
                    'peers': [v['name'] for v in AGENTS.values()],
                    'timeout': timeout,
                }).encode()
                req2 = urllib.request.Request(
                    a['bridge'] + '/chat', data=body2, method='POST',
                    headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(req2, timeout=timeout + 30) as r2:
                    d2 = json.loads(r2.read().decode())
                if d2.get('reply'):
                    yield ('reply', d2['reply'])
                if d2.get('thought'):
                    yield ('thought', d2['thought'])
                if d2.get('error'):
                    yield ('error', str(d2['error'])[:200])
            except Exception as e2:
                yield ('error', f'降级 /chat 也失败：{str(e2)[:150]}')
        else:
            yield ('error', f'HTTP {e.code}: {str(e)[:150]}')
    except Exception as e:
        yield ('error', str(e)[:200])
    yield ('done', '')


# ── DSH 直连（可选，需要 dsh_client.py）──────────────────
_DSH_CLIENTS = {}
_DSH_LOCK = threading.Lock()


def get_dsh_client(host):
    with _DSH_LOCK:
        if host not in _DSH_CLIENTS:
            try:
                from dsh_client import DshClient
                _DSH_CLIENTS[host] = DshClient(host=host)
            except Exception as e:
                print(f'[dsh] 初始化失败: {e}', flush=True)
                _DSH_CLIENTS[host] = None
        return _DSH_CLIENTS[host]


def _dsh_chat(a, text, timeout):
    c = get_dsh_client(a['dsh_host'])
    if c is None:
        return {'error': 'DSH 通道不可用'}
    if not c.prompt(a['session'], text):
        return {'error': 'DSH 发送失败'}
    try:
        from dsh_client import follow_stream
        think, reply = [], []
        for kind, data in follow_stream(c, a['session'], timeout=timeout):
            if kind == 'thought':
                think.append(data)
            elif kind == 'reply':
                reply.append(data)
            elif kind == 'done':
                break
            elif kind == 'error':
                return {'error': data}
        if reply or think:
            return {'reply': ''.join(reply), 'thought': ''.join(think),
                    'sessionId': a['session']}
        return {'reply': '', 'thought': '', 'queued': True,
                'note': '消息已送达，但会话正忙，回复排进下一轮'}
    except Exception as e:
        return {'error': f'{type(e).__name__}: {str(e)[:120]}'}


def _dsh_stream(a, text, timeout):
    c = get_dsh_client(a['dsh_host'])
    if c is None:
        yield ('error', 'DSH 通道不可用')
        return
    if not c.prompt(a['session'], text):
        yield ('error', 'DSH 发送失败')
        return
    try:
        from dsh_client import follow_stream
        for kind, data in follow_stream(c, a['session'], timeout=timeout):
            yield (kind, data)
            if kind in ('done', 'error'):
                return
    except Exception as e:
        yield ('error', f'{type(e).__name__}: {str(e)[:120]}')


# ── HTTP 处理 ─────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _authed(self):
        if not TOKEN:
            return True
        h = self.headers.get('Authorization') or ''
        if h.startswith('Bearer '):
            return h[7:].strip() == TOKEN
        if self.headers.get('X-Token') == TOKEN:
            return True
        qs = parse_qs(urlparse(self.path).query)
        return (qs.get('token') or [''])[0] == TOKEN

    def _send(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        n = int(self.headers.get('Content-Length', 0))
        return self.rfile.read(n) if n else b''

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Token')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path

        if path.startswith('/avatars/'):
            name = os.path.basename(path)
            fp = os.path.join(AVATARS_DIR, name)
            if os.path.isfile(fp):
                with open(fp, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                ext = os.path.splitext(name)[1].lower()
                mime = {'.png': 'image/png', '.jpg': 'image/jpeg',
                        '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml',
                        '.webp': 'image/webp'}.get(ext, 'application/octet-stream')
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'public, max-age=3600')
                self.end_headers()
                self.wfile.write(data)
                return
            return self._send(404, {'error': 'avatar not found'})

        if not self._authed():
            return self._send(401, {'error': 'unauthorized'})

        if path == '/api/messages':
            return self._send(200, {'messages': load_messages()})

        if path == '/api/agents':
            return self._send(200, {
                'user': USER,
                'agents': list(AGENTS.values()),
            })

        if path == '/api/inflight':
            with _lock:
                return self._send(200, {'inflight': dict(INFLIGHT)})

        if path == '/api/health':
            return self._send(200, {'ok': True, 'agents': len(AGENTS)})

        return self._send(404, {'error': 'not found'})

    def do_POST(self):
        try:
            self._do_post_inner()
        except (ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            try:
                self._send(500, {'error': f'{type(e).__name__}: {str(e)[:200]}'})
            except Exception:
                pass

    def _do_post_inner(self):
        u = urlparse(self.path)
        path = u.path

        if not self._authed():
            return self._send(401, {'error': 'unauthorized'})

        if path == '/api/send':
            try:
                body = json.loads(self._read_body() or b'{}')
            except Exception:
                return self._send(400, {'error': 'bad json'})

            text = str(body.get('text', '')).strip()
            if not text:
                return self._send(400, {'error': 'empty text'})
            if len(text) > 5000:
                return self._send(400, {'error': 'too long (max 5000)'})

            sender_id = str(body.get('from') or USER['id'])
            mentions = parse_mentions(text)

            user_msg = {
                'id': uuid.uuid4().hex[:12],
                'role': sender_id,
                'name': USER['name'] if sender_id == USER['id'] else sender_id,
                'text': text,
                'mentions': mentions,
                'time': int(time.time() * 1000),
            }
            append_message(user_msg)

            # 定目标
            has_at = '@' in text
            if mentions:
                targets = mentions
            elif has_at:
                targets = []
            else:
                targets = list(AGENTS.keys())
            # 断自环：自己发的不回给自己
            if sender_id in targets:
                targets = [k for k in targets if k != sender_id]

            replies = []
            for aid in targets:
                try:
                    r = call_agent(aid, text, sender_id)
                except Exception as e:
                    r = {'error': f'{AGENTS[aid]["name"]} 调用失败：{type(e).__name__}: {str(e)[:120]}'}
                if not isinstance(r, dict):
                    r = {'error': 'unexpected response'}

                a = AGENTS[aid]
                if r.get('queued'):
                    txt = '（消息已送达，但该 agent 正忙，回复排进下一轮）'
                    is_err = False
                else:
                    txt = r.get('reply') or r.get('error') or '（没有回复）'
                    is_err = bool(r.get('error'))

                m = {
                    'id': uuid.uuid4().hex[:12],
                    'role': aid,
                    'name': a['name'],
                    'text': txt,
                    'thought': r.get('thought') or '',
                    'isError': is_err,
                    'time': int(time.time() * 1000),
                }
                append_message(m)
                replies.append(m)

            return self._send(200, {'ok': True,
                                    'replies': replies,
                                    'mentions': mentions})

        if path == '/api/send_stream':
            # 流式群聊：每个 agent 一个线程并发跑，边收边推（SSE）
            try:
                body = json.loads(self._read_body() or b'{}')
            except Exception:
                return self._send(400, {'error': 'bad json'})

            text = str(body.get('text', '')).strip()
            if not text:
                return self._send(400, {'error': 'empty text'})
            if len(text) > 5000:
                return self._send(400, {'error': 'too long (max 5000)'})

            sender_id = str(body.get('from') or USER['id'])
            files = body.get('files') or []
            mentions = parse_mentions(text)

            user_msg = {
                'id': uuid.uuid4().hex[:12],
                'role': sender_id,
                'name': USER['name'] if sender_id == USER['id'] else sender_id,
                'text': text,
                'files': files,
                'mentions': mentions,
                'time': int(time.time() * 1000),
            }
            append_message(user_msg)

            has_at = '@' in text
            if mentions:
                targets = mentions
            elif has_at:
                targets = []      # @ 了但没匹配到 → 不发给任何人
            else:
                targets = list(AGENTS.keys())
            if sender_id in targets:      # 断自环
                targets = [k for k in targets if k != sender_id]

            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'keep-alive')
            self.send_header('X-Accel-Buffering', 'no')
            self.end_headers()

            wlock = threading.Lock()

            def emit(obj):
                with wlock:
                    try:
                        payload = f'data: {json.dumps(obj, ensure_ascii=False)}\n\n'.encode()
                        self.wfile.write(payload)
                        self.wfile.flush()
                    except Exception as e:
                        print(f'[emit] write failed {type(e).__name__}: {e} '
                              f'(kind={obj.get("kind")})', flush=True)

            emit({'kind': 'start', 'targets': targets, 'userMsg': user_msg})

            result_lock = threading.Lock()
            collected = {}

            def run_one(key):
                acc_r, acc_t = [], []
                INFLIGHT[key] = {'reply': '', 'thought': '',
                                 'startedAt': int(time.time() * 1000)}
                try:
                    for kind, data in stream_agent(key, text, sender_id):
                        if kind == 'reply':
                            acc_r.append(data)
                            INFLIGHT[key] = {'reply': ''.join(acc_r),
                                             'thought': ''.join(acc_t),
                                             'startedAt': INFLIGHT.get(key, {}).get('startedAt', 0)}
                            emit({'kind': 'chunk', 'agent': key,
                                  'field': 'reply', 'data': data})
                        elif kind == 'thought':
                            acc_t.append(data)
                            INFLIGHT[key] = {'reply': ''.join(acc_r),
                                             'thought': ''.join(acc_t),
                                             'startedAt': INFLIGHT.get(key, {}).get('startedAt', 0)}
                            emit({'kind': 'chunk', 'agent': key,
                                  'field': 'thought', 'data': data})
                        elif kind == 'error':
                            emit({'kind': 'agent_error', 'agent': key, 'data': data})
                        elif kind == 'done':
                            break
                except Exception as e:
                    emit({'kind': 'agent_error', 'agent': key,
                          'data': f'{type(e).__name__}: {str(e)[:200]}'})
                finally:
                    reply, thought = ''.join(acc_r), ''.join(acc_t)
                    with result_lock:
                        collected[key] = {'reply': reply, 'thought': thought}
                    INFLIGHT[key] = {'reply': reply, 'thought': thought,
                                     'done': True,
                                     'finishedAt': int(time.time() * 1000)}
                    threading.Timer(
                        60.0, lambda k=key: INFLIGHT.pop(k, None)).start()

                    a = AGENTS.get(key) or {'name': key}
                    m = {
                        'id': uuid.uuid4().hex[:12],
                        'role': key,
                        'name': a['name'],
                        'text': reply or '（没有收到回复，可能超时或出错了）',
                        'thought': thought,
                        'isError': not (reply or thought),
                        'time': int(time.time() * 1000),
                    }
                    append_message(m)
                    emit({'kind': 'agent_done', 'agent': key, 'msg': m})

            # ★ 串行且不开线程：BaseHTTPRequestHandler 的 self.wfile 不是
            #   线程安全的，在子线程里写会静默丢数据（表现为 agent 秒回空内容）。
            #   而且群聊本来就该「你一句我一句」，串行语义更对。
            for k in targets:
                run_one(k)
            emit({'kind': 'end'})
            return

        if path == '/api/messages':
            # 清空
            with _lock:
                save_messages([])
            return self._send(200, {'ok': True})

        return self._send(404, {'error': 'not found'})

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description='AgentsChat server')
    ap.add_argument('--config', default='config.json')
    ap.add_argument('--port', type=int)
    ap.add_argument('--host')
    args = ap.parse_args()

    load_config(args.config)
    if args.port:
        globals()['PORT'] = args.port
    if args.host:
        globals()['HOST'] = args.host

    print(f'AgentsChat → http://{HOST}:{PORT}', flush=True)
    if TOKEN:
        print(f'  token required', flush=True)
    for aid, a in AGENTS.items():
        tgt = a['bridge'] if a['type'] == 'acp' else f"dsh:{a['dsh_host']}"
        print(f'  {a["name"]:20s} ({aid}) → {tgt}', flush=True)

    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()
