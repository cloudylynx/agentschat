import 'package:flutter/material.dart';
import '../models/message.dart';

/// 顶部区域选择：全部 / 各 agent（数量由后端配置决定）
///
/// 用 MD3 FilterChip（single-select 语义）
class RegionSelector extends StatelessWidget {
  final String value;
  final List<Agent> agents;
  final void Function(String) onChanged;

  const RegionSelector({
    super.key,
    required this.value,
    required this.agents,
    required this.onChanged,
  });

  /// 把 '#rrggbb' 或 '#aarrggbb' 解析成 Color
  static Color? _parseHex(String hex) {
    var h = hex.replaceAll('#', '').trim();
    if (h.length == 6) h = 'ff$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 从传入的 agent 列表动态生成，数量任意
    final items = <_RegionItem>[
      const _RegionItem(key: 'all', label: '全部', color: null),
      ...agents.map((a) => _RegionItem(
            key: a.id,
            label: a.name,
            color: _parseHex(a.color),
          )),
    ];

    return Container(
      height: 56,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final it = items[i];
          final selected = value == it.key;
          return FilterChip(
            selected: selected,
            showCheckmark: selected,
            checkmarkColor: scheme.onSecondaryContainer,
            avatar: it.color == null
                ? null
                : CircleAvatar(
                    radius: 6,
                    backgroundColor: it.color,
                  ),
            label: Text(it.label),
            labelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
            backgroundColor: Colors.transparent,
            selectedColor: scheme.secondaryContainer,
            side: BorderSide(
              color: selected ? Colors.transparent : scheme.outlineVariant,
            ),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            onSelected: (_) => onChanged(it.key),
          );
        },
      ),
    );
  }
}

class _RegionItem {
  final String key;
  final String label;
  final Color? color;
  const _RegionItem({
    required this.key,
    required this.label,
    required this.color,
  });
}
