import 'package:flutter/material.dart';
import '../models/message.dart';

/// 输入区：@ 快捷 chip + 附件预览 + 输入框 + 发送按钮
class Composer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Attachment> pending;
  final bool busy;
  final List<Agent> agents;
  final void Function(int) onRemovePending;
  final VoidCallback onPickFiles;
  final VoidCallback onSend;

  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.pending,
    required this.busy,
    required this.agents,
    required this.onRemovePending,
    required this.onPickFiles,
    required this.onSend,
  });

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  bool _groupSelected = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  /// 从当前的 agent 列表动态拼 @ 正则，agent 数量任意
  RegExp _mentionPattern() {
    final names = widget.agents
        .expand((a) => [a.name, a.id])
        .where((n) => n.isNotEmpty)
        .map(RegExp.escape)
        .toList();
    if (names.isEmpty) return RegExp(r'@(?!)');   // 永不匹配
    // 长的排前面，避免 @agent1 抢先匹配 @agent10
    names.sort((a, b) => b.length.compareTo(a.length));
    return RegExp('@(${names.join('|')})');
  }

  void _sync() {
    final has = _mentionPattern().hasMatch(widget.controller.text);
    if (has == _groupSelected) {
      setState(() => _groupSelected = !has);
    }
  }

  void _toggleGroup() {
    widget.controller.text =
        widget.controller.text.replaceAll(_mentionPattern(), '');
    setState(() => _groupSelected = true);
    widget.focusNode.requestFocus();
  }

  void _toggleAgent(String name) {
    final tag = '@$name ';
    final t = widget.controller.text;
    if (t.contains(tag)) {
      widget.controller.text = t.replaceAll(tag, '');
    } else {
      widget.controller.text = tag +
          t.replaceAll(_mentionPattern(), '');
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
    }
    setState(() => _groupSelected = false);
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── @ 快捷栏 ──
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _Chip(
                  label: '群聊',
                  selected: _groupSelected,
                  onTap: _toggleGroup,
                  scheme: scheme,
                ),
                const SizedBox(width: 8),
                ...widget.agents.map((a) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Chip(
                        label: '@${a.name}',
                        selected: !_groupSelected &&
                            widget.controller.text.contains('@${a.name}'),
                        onTap: () => _toggleAgent(
                          a.name,
                        ),
                        scheme: scheme,
                        dot: const Color(0xFF8C4A5F),
                      ),
                    )),
              ],
            ),
          ),

          // ── 附件预览 ──
          if (widget.pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (int i = 0; i < widget.pending.length; i++)
                  _PendingTile(
                    a: widget.pending[i],
                    scheme: scheme,
                    onRemove: () => widget.onRemovePending(i),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 8),

          // ── 输入行 ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '附件',
                icon: const Icon(Icons.attach_file),
                onPressed: widget.busy ? null : widget.onPickFiles,
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48, maxHeight: 140),
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                    decoration: const InputDecoration(
                      hintText: '说点什么…',
                      isDense: true,
                    ),
                    onSubmitted: (_) {
                      if (!widget.busy) widget.onSend();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(
                busy: widget.busy,
                onTap: widget.busy ? null : widget.onSend,
                scheme: scheme,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;
  final Color? dot;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.scheme,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? Colors.transparent : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.check,
                      size: 14, color: scheme.onSecondaryContainer),
                ),
              if (dot != null && !selected)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration:
                        BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                  color: selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  final Attachment a;
  final ColorScheme scheme;
  final VoidCallback onRemove;

  const _PendingTile({
    required this.a,
    required this.scheme,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 4),
      height: 32,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            a.name,
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 0.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            iconSize: 15,
            icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onTap;
  final ColorScheme scheme;

  const _SendButton({
    required this.busy,
    required this.onTap,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 48,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: scheme.onPrimary.withValues(alpha: .8),
                ),
              )
            : const Icon(Icons.arrow_upward, size: 22),
      ),
    );
  }
}
