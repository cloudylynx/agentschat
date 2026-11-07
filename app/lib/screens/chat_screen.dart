import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/message.dart';
import '../services/api.dart';
import '../services/settings_store.dart';
import '../widgets/bubble.dart';
import '../widgets/composer.dart';

/// 聊天页
class ChatScreen extends StatefulWidget {
  final String region;          // 'all' | <agent id>
  final List<Agent> agents;
  final bool online;
  final Future<void> Function() onNeedRefresh;

  const ChatScreen({
    super.key,
    required this.region,
    required this.agents,
    required this.online,
    required this.onNeedRefresh,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  // 一键回底部：只有用户往上翻、不在底部时才显示按钮
  bool _atBottom = true;
  int _unreadWhileUp = 0;   // 往上翻的时候来了几条新消息
  final _focus = FocusNode();
  final _textCtrl = TextEditingController();

  List<Message> _messages = [];
  List<Attachment> _pending = [];
  /// 流式输出中的临时缓冲（key = agent key）
  final Map<String, _StreamBuf> _streams = {};

  /// 给 integration_test 读的内部状态（生产环境不用）
  List<Message> get debugMessages => _messages;
  Map<String, _StreamBuf> get debugStreams => _streams;
  bool _busy = false;
  bool _loading = true;
  String? _err;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScrollChanged);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _scroll.removeListener(_onScrollChanged);
    _scroll.dispose();
    _focus.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final msgs = await ApiService.messages();
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _loading = false;
        _err = null;
      });
      _jumpBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '$e';
      });
    }
  }

  Future<void> _silentRefresh() async {
    // ★ 2026-11-07 修：
    //   ① 原来 `if (_busy) return` 会挡住刷新，但切后台回来 _busy
    //      可能永远是真的（SSE 静默断开，finally 没跑）→ 永远不刷。
    //      现在：忙也刷，只是不清本地 _streams（避免流内容被打断）。
    //   ② 原来 `msgs.length == _messages.length` 就 return，
    //      数量相同但内容变了（比如空回复被补全）就永远不更新。
    //      现在：比 id 列表，不同才 setState。
    try {
      final msgs = await ApiService.messages();
      if (!mounted) return;
      // 比 id 序列，比长度可靠
      final sameIds = msgs.length == _messages.length &&
          List.generate(msgs.length,
              (i) => msgs[i].id == _messages[i].id).every((x) => x);
      if (sameIds) return;
      // ★ 关键：只在用户本来就在底部时才跟着滚。
      //   否则他在翻历史，新消息一来就把他顶走。
      final wasAtBottom = _isAtBottom();
      final added = msgs.length - _messages.length;
      setState(() {
        _messages = msgs;
        if (!_busy) _streams.clear();
        // 用户往上翻的时候来了新消息 → 累计未读
        if (!_atBottom && added > 0) _unreadWhileUp += added;
      });
      if (wasAtBottom) _jumpBottom();
    } catch (_) {}
  }

  /// ★ 2026-11-05 修「切后台丢思考链」：
  ///   App 切到后台时 SSE 连接被系统断掉，回来时 _streams 是空的，
  ///   于是思考链和回复都不显示，只能等 finally 重拉历史。
  ///   这里在回到前台时主动补拉后端 INFLIGHT 里的内容。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ★ 2026-11-07 修：切后台再回来对话消失
      //   根因：SSE 静默断开 → finally 不跑 → _busy 一直 true
      //        → _silentRefresh 被挡 → 等 20 秒定时器才恢复
      //   修法：回前台时无条件做两件事，不管 _busy
      _resumeFromBackground();
    }
  }

  /// 从后台回来：先补 inflight，再强制拉一次消息
  Future<void> _resumeFromBackground() async {
    // 1) 先试着补「正在生成」的内容（能补到最好，补不到也没关系）
    try {
      await _restoreInflight();
    } catch (_) {}

    // 2) ★ 关键：无条件拉一次落库的消息。
    //    以前这一步只在流正常结束时跑，切后台导致流静默断开时永远不跑。
    if (!mounted) return;
    try {
      final msgs = await ApiService.messages();
      if (!mounted) return;
      if (msgs.length >= _messages.length) {
        setState(() {
          _messages = msgs;
          // 落库的已经是完整的，本地流缓冲可以清了
          _streams.clear();
        });
        if (_isAtBottom()) _jumpBottom(immediate: true);
      }
    } catch (_) {}

    // 3) 如果还在 _busy 但什么都没在流，说明流已经死了，放开 busy
    if (mounted && _busy && _streams.isEmpty) {
      setState(() => _busy = false);
    }
  }

  /// 从后端补拉「正在生成中」的内容
  Future<void> _restoreInflight() async {
    // ★ 2026-11-07：去掉 `if (!_busy) return`
    //   原来只在「忙」的时候补，但切后台回来时 _busy 可能已经是 false
    //   （流静默断开但 finally 没跑），导致该补的时候不补。
    //   现在改成：有 inflight 就补，没有就什么都不做。
    try {
      final inf = await ApiService.inflight();
      if (!mounted || inf.isEmpty) return;
      setState(() {
        for (final e in inf.entries) {
          final key = e.key;
          final v = e.value;
          final b = _streams.putIfAbsent(
              key, () => _StreamBuf(key, _nameOf(key)));
          b.reply.clear();
          b.reply.write((v['reply'] ?? '').toString());
          b.thought.clear();
          b.thought.write((v['thought'] ?? '').toString());
        }
      });
      if (_isAtBottom()) _jumpBottom(immediate: true);
    } catch (_) {}
  }

  /// 滚动位置变化：更新「是否在底部」
  void _onScrollChanged() {
    final atBottom = _isAtBottom();
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _unreadWhileUp = 0;
      });
    }
  }

  /// 当前滚动位置是否已经贴底（留 60px 容差）
  bool _isAtBottom() {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels <= 60;
  }

  /// 滚到底。
  ///
  /// ★ 2026-11-05 修：原来只在一帧后跳一次，但 ListView 是懒构建的，
  ///   首帧的 maxScrollExtent 只是「已构建部分」的高度，后续 item 建完
  ///   高度会变大，于是停在半路，用户还得往下划。
  ///   改成多帧重试：立刻跳一次，再在 60/180/400ms 各补一次。
  void _jumpBottom({bool immediate = false}) {
    void doJump() {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (immediate) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      doJump();
      for (final delay in [60, 180, 400]) {
        Future.delayed(Duration(milliseconds: delay), () {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    });
  }

  /// 当前区域下这条消息该不该显示
  bool _visible(Message m) {
    if (widget.region == 'all') return true;
    if (m.isMe) return true;                 // 用户自己的消息永远显示
    return m.role == widget.region;
  }

  /// 一条 agent 消息用哪个角色色
  String _roleOf(Message m) => m.role;

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r == null || r.files.isEmpty) return;
    final paths = r.files
        .where((f) => f.path != null)
        .map((f) => f.path!)
        .toList();
    if (paths.isEmpty) return;

    setState(() => _busy = true);
    try {
      final ups = await ApiService.upload(paths);
      setState(() => _pending = [..._pending, ...ups]);
    } catch (e) {
      _snack('上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _busy) return;

    final files = _pending;
    _textCtrl.clear();
    setState(() {
      _pending = [];
      _busy = true;
      _messages = [
        ..._messages,
        Message(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          role: 'user',
          name: SettingsStore.userName,
          text: text,
          files: files,
          time: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    });
    _jumpBottom(immediate: true);

    // 流式状态：用 State 字段，让 build 能看到
    void ensureBuf(String key) {
      _streams.putIfAbsent(key, () => _StreamBuf(key, _nameOf(key)));
    }

    // ★ 立刻按 @ 规则预建占位气泡，用户马上能看到「思考中」
    //   （ACP 要等整条消息提交才推 thought，中间有几秒空白）
    final predict = _mentionsIn(text);
    final targets = predict.isEmpty ? widget.agents.map((a) => a.id).toList() : predict;
    setState(() {
      for (final k in targets) {
        ensureBuf(k);
      }
    });

    try {
      await ApiService.sendStream(
        text,
        files: files,
        onStart: (targets) {
          if (!mounted) return;
          setState(() {
            for (final t in targets) {
              ensureBuf(t);
            }
          });
        },
        onChunk: (agent, field, txt) {
          if (!mounted) return;
          setState(() {
            ensureBuf(agent);
            final b = _streams[agent]!;
            if (field == 'reply') {
              b.reply.write(txt);
            } else if (field == 'thought') {
              b.thought.write(txt);
            } else if (field == 'error') {
              b.error = txt;
            }
          });
          if (_isAtBottom()) _jumpBottom(immediate: true);
        },
        onAgentDone: (agent, msg) {
          if (!mounted) return;
          setState(() {
            _streams.remove(agent);
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = [
          ..._messages,
          Message(
            id: 'err-${DateTime.now().microsecondsSinceEpoch}',
            role: 'system',
            name: '系统',
            text: '$e',
            isError: true,
            time: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
        _streams.clear();
      });
      _jumpBottom(immediate: true);
    } finally {
      if (mounted) {
        // ★ 2026-11-05 修「切后台丢思考链」：
        //   App 切后台时 SSE 断了，_streams 里可能什么都没有，
        //   但后端 INFLIGHT 还留着（保留 60 秒）。
        //   这里在 clear 之前先补拉一次，把思考链和回复填回来。
        await _restoreInflight();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _streams.clear();
        });
        _jumpBottom(immediate: true);

        await Future.delayed(const Duration(milliseconds: 1200));
        if (!mounted) return;
        try {
          final msgs = await ApiService.messages();
          if (mounted && msgs.length >= _messages.length) {
            setState(() => _messages = msgs);
            _jumpBottom(immediate: true);
          }
        } catch (_) {}
      }
    }
  }

  /// 前端预判消息会发给谁（和后端 parse_mentions 保持一致）
  List<String> _mentionsIn(String text) {
    final hits = <String>[];
    // 动态匹配：遍历 agents 的名字和 id
    for (final a in widget.agents) {
      if (RegExp('@' + RegExp.escape(a.name)).hasMatch(text) ||
          RegExp('@' + RegExp.escape(a.id)).hasMatch(text)) {
        if (!hits.contains(a.id)) hits.add(a.id);
      }
    }
    return hits;
  }

  String _nameOf(String key) {
    for (final a in widget.agents) {
      if (a.id == key) return a.name;
    }
    return key;
  }


  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _messages.where(_visible).toList();

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_err != null) {
      return _ErrorView(error: _err!, onRetry: _load);
    }

    // 流式中的临时消息（按 agent 排）
    final streamList = _streams.values
        .where((b) => widget.region == 'all' || b.key == widget.region)
        .toList();

    final total = shown.length + streamList.length;

    return Stack(
      children: [
        Column(
      children: [
        Expanded(
          child: total == 0
              ? _EmptyView(region: widget.region)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  itemCount: total,
                  itemBuilder: (context, i) {
                    // 先渲染已落库的，再渲染流式中的
                    if (i < shown.length) {
                      final m = shown[i];
                      return MessageBubble(
                        msg: m,
                        effectiveRole: _roleOf(m),
                      );
                    }
                    final b = streamList[i - shown.length];
                    final replyText = b.reply.toString();
                    final thinkText = b.thought.toString();
                    return MessageBubble(
                      msg: Message(
                        id: 'stream-${b.key}',
                        role: b.key,
                        name: b.name,
                        text: b.error != null
                            ? '出错了：${b.error}'
                            : (replyText.isEmpty ? '思考中…' : replyText),
                        thought: thinkText,
                        isError: b.error != null,
                        time: DateTime.now().millisecondsSinceEpoch,
                      ),
                      effectiveRole: b.key,
                      isThinking: b.error == null &&
                          replyText.isEmpty &&
                          thinkText.isEmpty,
                    );
                  },
                ),
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Row(
              children: [
                _TypingDots(scheme: scheme),
                const SizedBox(width: 10),
                Text(
                  '正在思考…',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        Composer(
          controller: _textCtrl,
          focusNode: _focus,
          pending: _pending,
          busy: _busy,
          agents: widget.agents,
          onRemovePending: (i) =>
              setState(() => _pending = [..._pending]..removeAt(i)),
          onPickFiles: _pickFiles,
          onSend: _send,
        ),
      ],
        ),
        // 一键回底部：只有往上翻时出现
        if (!_atBottom)
          Positioned(
            right: 16,
            bottom: 96,
            child: _ScrollToBottomButton(
              unread: _unreadWhileUp,
              onTap: () {
                _jumpBottom();
                setState(() => _unreadWhileUp = 0);
              },
            ),
          ),
      ],
    );
  }
}

class _TypingDots extends StatefulWidget {
  final ColorScheme scheme;
  const _TypingDots({required this.scheme});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value + i * 0.16) % 1.0;
            final y = phase < 0.32
                ? -6 * (phase / 0.32)
                : phase < 0.64
                    ? -6 * (1 - (phase - 0.32) / 0.32)
                    : 0.0;
            return Transform.translate(
              offset: Offset(0, y),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: widget.scheme.onSurfaceVariant.withValues(alpha: .55),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _EmptyView extends StatelessWidget {
  final String region;
  const _EmptyView({required this.region});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = region == 'all'
        ? '三个人，一个群'
        : '只看该 agent';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined,
                size: 64, color: scheme.onSurfaceVariant.withValues(alpha: .35)),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w400,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '用户与 agent 的对话\n'
              '发消息就是群聊，@某人单独派活',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 56, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 流式输出时的临时缓冲
class _StreamBuf {
  final String key;
  final String name;
  final StringBuffer reply = StringBuffer();
  final StringBuffer thought = StringBuffer();
  String? error;

  _StreamBuf(this.key, this.name);
}

/// 一键回到底部的浮动按钮。
///
/// 只在用户向上翻阅历史时出现；有新消息进来会显示未读数。
/// 用标准 FAB 保证无障碍树里是可点按钮（手写 InkWell 实测点不动）。
class _ScrollToBottomButton extends StatelessWidget {
  final int unread;
  final VoidCallback onTap;

  const _ScrollToBottomButton({required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FloatingActionButton.small(
      heroTag: 'scroll-to-bottom',
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      elevation: 4,
      tooltip: unread > 0 ? '回到底部（$unread 条新消息）' : '回到底部',
      onPressed: onTap,
      child: unread > 0
          ? Badge(
              label: Text(unread > 99 ? '99+' : '$unread'),
              backgroundColor: scheme.error,
              textColor: scheme.onError,
              child: const Icon(Icons.arrow_downward, size: 20),
            )
          : const Icon(Icons.arrow_downward, size: 20),
    );
  }
}
