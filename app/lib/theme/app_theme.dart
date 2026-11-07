import 'package:flutter/material.dart';
import '../services/settings_store.dart';

/// MD3 主题：从 Python 那边的配色 seed 生成完整 tonal palette。
///
/// 用 Material You 的动态取色算法，不是手写一堆颜色值——
/// 这样每个色彩角色（primary/on-primary/container/...）都是同一 seed 的
/// 不同色调，对比度自动符合 MD3 无障碍要求。
class AppTheme {
  /// 群聊的 seed（紫色，和原网页一致）
  static const seed = Color(0xFF8B5CF6);

  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final scheme = _schemeFromSeed(seed, brightness);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'Noto Sans CJK SC',
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,

      // ── Top App Bar ──
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
        ),
      ),

      // ── 导航栏（MD3 NavigationBar 规范：80dp 高，无阴影）──
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            letterSpacing: 0.5,
            color: selected
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          );
        }),
      ),

      // ── Filled Button ──
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ),

      // ── Chip（@ 快捷栏用 FilterChip）──
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: scheme.secondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        labelStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: scheme.onSecondaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        showCheckmark: true,
        checkmarkColor: scheme.onSecondaryContainer,
      ),

      // ── TextField ──
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(28)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(28)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(28)),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),

      // ── Dialog ──
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w400,
        ),
        contentTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 14,
          height: 1.5,
        ),
      ),

      // ── Snackbar（MD3 inverse 反色）──
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: scheme.onInverseSurface,
          fontSize: 14,
          letterSpacing: 0.25,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 3,
      ),

      // ── 分割线 ──
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // ── Card ──
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),

      // ── Switch ──
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
      ),
    );
  }

  /// 从 seed 生成完整 MD3 色彩方案。
  ///
  /// SchemeTonalSpot 是 MD3 默认的配色算法（最接近 Material You 默认效果）。
  static ColorScheme _schemeFromSeed(Color seed, Brightness brightness) {
    final variant = brightness == Brightness.light
        ? DynamicSchemeVariant.tonalSpot
        : DynamicSchemeVariant.tonalSpot;

    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: variant,
    );
  }
}

/// 三个人的角色色（不跟随主题，固定视觉身份）。
class RoleColors {
    // 用户气泡 = 淡黄（暖色，和其他 agent 区分）
    static const user = Color(0xFFF5E6A8);
    static const userText = Color(0xFF3D3520);

    // agent 默认配色（后端 config.json 里可覆盖）
    static const agent1 = Color(0xFF1D4ED8);
    static const agent1Text = Color(0xFFFFFFFF);
    static const agent2 = Color(0xFF047857);
    static const agent2Text = Color(0xFFFFFFFF);
    static const agent3 = Color(0xFFB45309);
    static const agent3Text = Color(0xFFFFFFFF);

    // 未知 agent 兜底（agent 数量超过 3 个时用）
    static const fallback = Color(0xFF6B7280);
    static const fallbackText = Color(0xFFFFFFFF);

  /// 气泡底色：优先用设置页自定义的，否则用默认
  static Color bubbleFor(String role) {
    final custom = SettingsStore.colorFor(role);
    if (custom != null) return Color(custom);
    return switch (role) {
      'user' => user,
      'agent1' => agent1,
      'agent2' => agent2,
      'agent3' => agent3,
      _ => fallback,
    };
  }

  /// 气泡文字色：自定义底色时按亮度自动选黑白，否则用默认配对
  static Color textFor(String role) {
    final custom = SettingsStore.colorFor(role);
    if (custom != null) return Color(SettingsStore.textColorFor(custom));
    return switch (role) {
      'user' => userText,
      'agent1' => agent1Text,
      'agent2' => agent2Text,
      'agent3' => agent3Text,
      _ => fallbackText,
    };
  }
}
