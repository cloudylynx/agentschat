import 'dart:io';
import 'package:flutter/material.dart';
import '../services/settings_store.dart';

/// 统一头像显示：支持内置资源、自定义本地文件、网络图片
///
/// 圆角 15%（对齐截图确认过的比例）
class AvatarView extends StatelessWidget {
  final String role;               // 'user' | <agent id>
  final double size;
  final double? radiusFactor;

  const AvatarView({
    super.key,
    required this.role,
    this.size = 34,
    this.radiusFactor,
  });

  @override
  Widget build(BuildContext context) {
    final src = SettingsStore.avatarFor(role);
    final radius = size * (radiusFactor ?? 0.15);

    Widget img;
    if (src.startsWith('assets/')) {
      img = Image.asset(src, fit: BoxFit.cover, width: size, height: size,
          errorBuilder: (_, __, ___) => _fallback(context));
    } else if (src.startsWith('http')) {
      img = Image.network(src, fit: BoxFit.cover, width: size, height: size,
          errorBuilder: (_, __, ___) => _fallback(context));
    } else {
      final f = File(src);
      if (f.existsSync()) {
        img = Image.file(f, fit: BoxFit.cover, width: size, height: size,
            errorBuilder: (_, __, ___) => _fallback(context));
      } else {
        img = _fallback(context);
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: img,
    );
  }

  Widget _fallback(BuildContext context) {
    final letter = switch (role) {
      'user' => 'U',
      _ => '?',
    };
    return Center(
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.45,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
