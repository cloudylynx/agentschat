"""
dsh_client.py —— 会话服务直连客户端

让 AgentsChat 直接和一个正在运行的会话服务对话，共用同一段对话历史。

协议来源：逆向 + 原型验证，细节见 docs/protocol.md 第二部分。
  · 认证:   GET /?token=<token> → 303 + Set-Cookie: dsh-auth-*
  · 发消息: POST /api/session/prompt (HTTP RPC)
  · 收流式: ws://<host>/api/remote.mux, endpoint=session/follow

注意：这是逆向出来的私有协议，服务端升级可能失效。
"""

import asyncio
import json
import os
import subprocess
import threading
import time
import uuid
import urllib.error
import urllib.request

# 默认地址只是占位，实际由 config.json 的 dsh_host 传入
DSH_HOST = '127.0.0.1:8080'
DSH_BASE = f'http://{DSH_HOST}'


# ── 认证 ──────────────────────────────────────────────────────
def fetch_token():
    """从 dsh-web 启动日志里取当前 token"""
    try:
        out = subprocess.run(
            ['journalctl', '-u', 'dsh-web', '-n', '500', '--no-pager'],
            capture_output=True, text=True, timeout=10).stdout
        for line in reversed(out.splitlines()):
            if 'dsh web: http' in line and 'token=' in line:
                return line.split('token=')[1].split()[0].strip(')')
    except Exception:
        pass
    try:
        out = subprocess.run(
            ['sudo', '-n', 'journalctl', '-u', 'dsh-web', '-n', '500', '--no-pager'],
            capture_output=True, text=True, timeout=10).stdout
        for line in reversed(out.splitlines()):
            if 'dsh web: http' in line and 'token=' in line:
                return line.split('token=')[1].split()[0].strip(')')
    except Exception:
        pass
    return ''


def exchange_cookie(token):
    """用 token 换 cookie。必须手动处理 303，否则丢 Set-Cookie。"""
    if not token:
        return ''

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **kw):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    url = f'{DSH_BASE}/?token={token}'
    for attempt in (opener.open, None):
        try:
            r = attempt(url, timeout=10) if attempt else None
            cookies = r.headers.get_all('Set-Cookie') or []
        except urllib.error.HTTPError as e:
            cookies = e.headers.get_all('Set-Cookie') or []
        except Exception:
            continue
        for c in cookies:
            if c.startswith('dsh-auth-'):
                return c.split(';')[0]
        break
    return ''


# ── RPC ───────────────────────────────────────────────────────
class DshClient:
    def __init__(self, token=None, host=DSH_HOST):
        self.host = host
        self.base = f'http://{host}'
        self.token = token or fetch_token()
        self.cookie = exchange_cookie(self.token)
        self._lock = threading.Lock()

    def ensure_auth(self):
        """cookie 失效时自动重换"""
        if self.cookie:
            return True
        self.token = fetch_token()
        self.cookie = exchange_cookie(self.token)
        return bool(self.cookie)

    def _post(self, method, args, timeout=60):
        if not self.ensure_auth():
            return {'ok': False, 'error': 'auth failed'}
        body = json.dumps({
            'type': 'client-request',
            'rpcId': str(uuid.uuid4()),
            'method': method,
            'payload': {'args': args},
        }).encode()
        req = urllib.request.Request(
            f'{self.base}/api/{method}', data=body, method='POST',
            headers={'Content-Type': 'application/json', 'Cookie': self.cookie})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 401:
                # cookie 过期，重换一次
                self.cookie = ''
                if self.ensure_auth():
                    req.add_header('Cookie', self.cookie)
                    try:
                        with urllib.request.urlopen(req, timeout=timeout) as r:
                            return json.loads(r.read().decode())
                    except Exception as e2:
                        return {'ok': False, 'error': str(e2)[:200]}
            return {'ok': False, 'error': f'HTTP {e.code}'}
        except Exception as e:
            return {'ok': False, 'error': str(e)[:200]}

    def create_session(self, cwd=None):
        cwd = cwd or os.path.expanduser('~')
        r = self._post('session/create', {'request': {'cwd': cwd}})
        val = (r.get('result') or {}).get('value') or {}
        return val.get('sessionId')

    def list_sessions(self):
        # ★ session/list 用 _request（不是 request），跟 session/prompt 不一样
        r = self._post('session/list', {'_request': {}})
        val = (r.get('result') or {}).get('value') or {}
        return val.get('items') or []

    def prompt(self, session_id, text, source_kind='user'):
        """发消息。返回 True/False。

        ★ 2026-11-07 修回环：必须带 source 字段标明「这是谁发的」。
          抓包对比（浏览器实际发的）：
            {"content":[...], "source":{"kind":"user","rpcId":"...","clientTimeZone":"UTC"}}
          原来我只发 content，DSH 可能把消息当成别的来源，
          导致 agent 回复后又被当新消息投递回来（踩过的坑：会表现为同一句话被投递两次）。
        """
        rpc_id = str(uuid.uuid4())
        r = self._post('session/prompt', {'request': {
            'requestId': str(uuid.uuid4()),
            'sessionId': session_id,
            'mode': 'queue',
            'content': [{
                'type': 'text',
                'text': text,
            }],
            'source': {
                'kind': source_kind,
                'rpcId': rpc_id,
                'clientTimeZone': 'Asia/Shanghai',
            },
            'clientTimeZone': 'Asia/Shanghai',
        }})
        val = (r.get('result') or {}).get('value') or {}
        return bool(val.get('accepted'))


# ── 流式订阅（同步生成器，方便塞进现有代码）───────────────
def follow_stream(client, session_id, timeout=300):
    """订阅会话，yield ('thought'|'reply'|'done'|'error', 文本)

    用独立的 asyncio 事件循环跑，调用方可以当普通生成器用。
    """
    try:
        import websockets
    except ImportError:
        yield ('error', '缺 websockets 库，pip install websockets')
        return

    frames = []
    done_flag = threading.Event()
    error_box = []

    async def _run():
        try:
            uri = f'ws://{client.host}/api/remote.mux'
            async with websockets.connect(
                uri,
                additional_headers={
                    'Cookie': client.cookie,
                    'Host': client.host,
                    'Origin': f'http://{client.host}',
                },
                max_size=None,
            ) as ws:
                await ws.send(json.dumps({
                    'type': 'open',
                    'streamId': str(uuid.uuid4()),
                    'endpoint': 'session/follow',
                    'payload': {'args': {'request': {
                        'address': {'kind': 'session', 'sessionId': session_id},
                        'assistantStream': True,
                        'maxMessages': 500,
                    }}},
                }))
                t0 = time.time()
                # ★ 2026-11-07 修重复投递：用 attemptId 锁定「本次请求的那一次回复」
                #   主会话在执行任务期间会产生多个 assistant-stream（我的思考、
                #   我跑命令的输出被再读一遍等），原来无差别全收，
                #   导致回复被拼接成重复内容。
                my_attempt = None
                while time.time() - t0 < timeout:
                    try:
                        raw = await asyncio.wait_for(ws.recv(), timeout=3)
                    except asyncio.TimeoutError:
                        continue
                    f = json.loads(raw)
                    if f.get('type') != 'item':
                        continue
                    v = f.get('value') or {}
                    if v.get('type') != 'assistant-stream':
                        continue
                    fr = v.get('frame') or {}
                    ch = fr.get('chunk') or {}
                    ct = ch.get('type')
                    aid = fr.get('attemptId') or ch.get('attemptId')

                    # 第一个带 attemptId 的 chunk 定下这次盯谁
                    if my_attempt is None and aid:
                        my_attempt = aid
                    elif aid and my_attempt and aid != my_attempt:
                        continue      # 不是这次的，跳过

                    if ct == 'reasoning-delta':
                        frames.append(('thought', ch.get('text', '')))
                    elif ct == 'text-delta':
                        frames.append(('reply', ch.get('text', '')))
                    elif ct == 'finish':
                        frames.append(('done', ''))
                        break
        except Exception as e:
            error_box.append(str(e)[:200])
        finally:
            done_flag.set()

    t = threading.Thread(target=lambda: asyncio.run(_run()), daemon=True)
    t.start()

    idx = 0
    t0 = time.time()
    while True:
        while idx < len(frames):
            yield frames[idx]
            idx += 1
            if frames[idx - 1][0] == 'done':
                return
        if done_flag.is_set() and idx >= len(frames):
            if error_box:
                yield ('error', error_box[0])
            return
        if time.time() - t0 > timeout:
            yield ('error', '订阅超时')
            return
        time.sleep(0.05)


if __name__ == '__main__':
    print('=== dsh_client 自检 ===')
    c = DshClient()
    print(f'token: {c.token[:30] if c.token else "FAIL"}...')
    print(f'cookie: {c.cookie[:40] if c.cookie else "FAIL"}...')

    sessions = c.list_sessions()
    print(f'会话数: {len(sessions)}')
    for s in sessions[:3]:
        print(f"  {s.get('sessionId','')[:25]}  {s.get('cwd','')}  running={s.get('running')}")
