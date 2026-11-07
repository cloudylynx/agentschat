import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import 'avatar_view.dart';
import '../services/api.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// 一条消息（含头像、气泡、思考链、附件）
class MessageBubble extends StatelessWidget {
  final Message msg;
  final String effectiveRole;
  /// 思考中：气泡显示三点跳动动画，而不是静态文字
  final bool isThinking;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.effectiveRole,
    this.isThinking = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isMe = msg.isMe;

    // 错误消息：居中提示条
    if (msg.isError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            msg.text,
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (msg.thought.isNotEmpty) ThoughtCard(thought: msg.thought),
        Padding(
          padding: EdgeInsets.only(
            left: isMe ? 48 : 12,
            right: isMe ? 12 : 48,
            bottom: 6,
          ),
          child: Row(
            mainAxisAlignment:
                isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMe) ...[
                AvatarView(role: effectiveRole, size: 34),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              msg.name,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (msg.mentions.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _Badge(text: '单聊'),
                            ],
                          ],
                        ),
                      ),
                    _BubbleBody(msg: msg, effectiveRole: effectiveRole, isThinking: isThinking),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 6, right: 6),
                      child: Text(
                        _fmtTime(msg.time),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                          color: scheme.onSurfaceVariant.withValues(alpha: .65),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (isMe) ...[
                const SizedBox(width: 8),
                AvatarView(role: 'user', size: 34),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _fmtTime(int ms) {
    if (ms == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _BubbleBody extends StatelessWidget {
  final Message msg;
  final String effectiveRole;
  final bool isThinking;

  const _BubbleBody({
    required this.msg,
    required this.effectiveRole,
    this.isThinking = false,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = msg.isMe;

    // 用户气泡统一走 RoleColors.user，agent 走自己的 id（设置页可覆盖）。
    //   现在统一走 bubbleFor/textFor，两者都查 SettingsStore 的自定义值。
    final roleForColor = isMe ? 'user' : effectiveRole;
    final bg = RoleColors.bubbleFor(roleForColor);
    final fg = RoleColors.textFor(roleForColor);

    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isThinking)
            _TypingDots(color: fg)
          else if (msg.text.length > 3000)
            _LongText(text: msg.text, color: fg, isMe: isMe)
          else
            SelectableText.rich(
              TextSpan(
                children: _spans(msg.text, fg, isMe),
              ),
              style: TextStyle(
                color: fg,
                fontSize: 14,
                height: 1.5,
                letterSpacing: 0.25,
              ),
            ),
          if (msg.files.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...msg.files.map((f) => _AttachmentTile(a: f, isMe: isMe, fg: fg)),
          ],
        ],
      ),
    );
  }

  /// @提及高亮
  static List<TextSpan> _spans(String text, Color fg, bool isMe) {
    final re = RegExp(r'@[\w\u4e00-\u9fa5]+');
    final out = <TextSpan>[];
    int last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        out.add(TextSpan(text: text.substring(last, m.start)));
      }
      out.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: isMe
              ? const Color(0xFF5C4A00)          // 淡黄底上：深金棕
              : const Color(0xFFCFBCFF),
          backgroundColor: isMe
              ? const Color(0xFF000000).withValues(alpha: .08)   // 淡黄底上：淡黑
              : const Color(0xFFCFBCFF).withValues(alpha: .14),
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      out.add(TextSpan(text: text.substring(last)));
    }
    return out.isEmpty ? [TextSpan(text: text)] : out;
  }
}

class _AttachmentTile extends StatelessWidget {
  final Attachment a;
  final bool isMe;
  final Color fg;

  const _AttachmentTile({
    required this.a,
    required this.isMe,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (a.isImage) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _ImageAttachment(a: a, scheme: scheme),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final u = Uri.parse(ApiService.fileUrl(a.disk));
          if (await canLaunchUrl(u)) launchUrl(u);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isMe
                ? const Color(0xFF000000).withValues(alpha: .07)   // 淡黄底上：淡黑
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined,
                  size: 18,
                  color: isMe ? fg : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  a.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isMe ? fg : scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                a.sizeText,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: (isMe ? fg : scheme.onSurfaceVariant)
                      .withValues(alpha: .75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 思考链折叠卡（MD3 Expressive Card）
class ThoughtCard extends StatefulWidget {
  final String thought;
  const ThoughtCard({super.key, required this.thought});

  @override
  State<ThoughtCard> createState() => _ThoughtCardState();
}

class _ThoughtCardState extends State<ThoughtCard> {
  // 思考链默认展开，用户可在设置里切换。
  //   原来是 false（折叠），要点一下才看得到，等于藏起来了。
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(left: 54, right: 48, bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.psychology_outlined,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      '思考',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      child: SelectableText(
                        widget.thought,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          letterSpacing: 0.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 图片附件：自己下载再 Image.memory
///
/// 不用 Image.network 的原因：Linux 桌面版对 http 明文 URL 的处理不一致，
/// 而且 Image.network 的 errorBuilder 不给我们看真实原因。
/// 自己 http.get 能拿到 status / body，出错能显示具体原因。
class _ImageAttachment extends StatefulWidget {
  final Attachment a;
  final ColorScheme scheme;

  const _ImageAttachment({required this.a, required this.scheme});

  @override
  State<_ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<_ImageAttachment> {
  Uint8List? _bytes;
  String? _err;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final url = ApiService.fileUrl(widget.a.disk);
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw 'HTTP ${r.statusCode}';
      }
      if (r.bodyBytes.isEmpty) {
        throw '文件是空的';
      }
      if (!mounted) return;
      setState(() {
        _bytes = r.bodyBytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;

    if (_loading) {
      return Container(
        width: 240,
        height: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_err != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _load,
        child: Container(
          width: 240,
          height: 90,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined,
                  size: 22, color: scheme.error),
              const SizedBox(height: 6),
              Text(
                '图片加载失败：$_err',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
              const SizedBox(height: 4),
              Text(
                '点我重试',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () async {
        final u = Uri.parse(ApiService.fileUrl(widget.a.disk));
        if (await canLaunchUrl(u)) launchUrl(u);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
          child: Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              padding: const EdgeInsets.all(12),
              color: scheme.surfaceContainerHighest,
              child: Text('图片解码失败',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 三个跳动的点 —— 表示「正在想」
class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});

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
    return SizedBox(
      height: 21,   // 和一行文字差不多高，避免气泡跳动
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final phase = (_c.value + i * 0.16) % 1.0;
              final dy = phase < 0.32
                  ? -5 * (phase / 0.32)
                  : phase < 0.64
                      ? -5 * (1 - (phase - 0.32) / 0.32)
                      : 0.0;
              return Transform.translate(
                offset: Offset(0, dy),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2.5),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: .7),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// 超长文本折叠（超过 3000 字）
/// 防止一条消息把整个界面撑爆
class _LongText extends StatefulWidget {
  final String text;
  final Color color;
  final bool isMe;

  const _LongText({
    required this.text,
    required this.color,
    required this.isMe,
  });

  @override
  State<_LongText> createState() => _LongTextState();
}

class _LongTextState extends State<_LongText> {
  bool _expanded = false;
  static const _previewLen = 800;

  @override
  Widget build(BuildContext context) {
    final shown = _expanded
        ? widget.text
        : '${widget.text.substring(0, _previewLen)}…';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(
          shown,
          style: TextStyle(
            color: widget.color,
            fontSize: 14,
            height: 1.5,
            letterSpacing: 0.25,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              _expanded
                  ? '收起（共 ${widget.text.length} 字）'
                  : '展开全文（共 ${widget.text.length} 字）',
              style: TextStyle(
                color: widget.color.withValues(alpha: .75),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
                decorationColor: widget.color.withValues(alpha: .4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
