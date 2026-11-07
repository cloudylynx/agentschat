import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地设置。
///
/// agent 列表由后端 /api/agents 提供（见 [AgentConfig]），
/// 这里只存本地 UI 偏好：头像、颜色、主题等。
class SettingsStore {
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── 服务端地址 ────────────────────────────────────────────
  static String get serverUrl =>
      _prefs.getString('serverUrl') ?? 'http://127.0.0.1:8765';

  static Future<void> setServerUrl(String v) async {
    await _prefs.setString('serverUrl', v);
  }

  /// 别名，保持向后兼容
  static String get baseUrl => serverUrl;

  // ── 上次停留的 Tab / 区域 ─────────────────────────────────
  static int get activeTab => _prefs.getInt('activeTab') ?? 0;

  static Future<void> setActiveTab(int v) async {
    await _prefs.setInt('activeTab', v);
  }

  static String get activeRegion =>
      _prefs.getString('activeRegion') ?? 'all';

  static Future<void> setActiveRegion(String v) async {
    await _prefs.setString('activeRegion', v);
  }

  // ── 发言身份（开源版已移除，保留 getter 避免旧代码报错）──
  static String get senderRole => _prefs.getString('senderRole') ?? 'user';

  static Future<void> setSenderRole(String v) async {
    await _prefs.setString('senderRole', v);
  }

  // ── 访问令牌 ──────────────────────────────────────────────
  static String get token => _prefs.getString('token') ?? '';

  static Future<void> setToken(String v) async {
    await _prefs.setString('token', v);
  }

  // ── 头像（按 agent id 存）────────────────────────────────
  static String avatarOf(String id) =>
      _prefs.getString('avatar_$id') ?? '';

  static Future<void> setAvatar(String id, String path) async {
    await _prefs.setString('avatar_$id', path);
  }

  /// 取头像：自定义优先，否则用本地占位图
  static String avatarFor(String id) {
    final custom = avatarOf(id);
    if (custom.isNotEmpty) return custom;
    return 'assets/avatars/$id.png';
  }

  // ── 颜色（按 agent id 存，后端配置里有默认色）────────────
  static int? colorOf(String id) {
    final v = _prefs.getInt('color_$id');
    return v;
  }

  static Future<void> setColor(String id, int? color) async {
    if (color == null) {
      await _prefs.remove('color_$id');
    } else {
      await _prefs.setInt('color_$id', color);
    }
  }

  /// 取气泡颜色（自定义优先，否则 null 表示用主题默认）
  static int? colorFor(String id) => colorOf(id);

  /// 气泡上的文字颜色：底色亮就用深色字，暗就用白字。
  ///
  /// 接受 ARGB 整数（由调用方传 Color.toARGB32()）。
  static int textColorFor(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    // 感知亮度（ITU-R BT.601）
    final lum = 0.299 * r + 0.587 * g + 0.114 * b;
    return lum > 160 ? 0xFF1F2937 : 0xFFFFFFFF;
  }

  // ── 后端上次下发的 agent 快照（离线时展示用）────────────
  static List<AgentConfig> get cachedAgents {
    final raw = _prefs.getString('cachedAgents');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => AgentConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> setCachedAgents(List<AgentConfig> agents) async {
    await _prefs.setString(
      'cachedAgents',
      jsonEncode(agents.map((a) => a.toJson()).toList()),
    );
  }

  // ── 用户名（后端配置里有，这里缓存一份）──────────────────
  static String get userName => _prefs.getString('userName') ?? '用户';

  static Future<void> setUserName(String v) async {
    await _prefs.setString('userName', v);
  }

  // ── 是否显示思考链 / 是否默认展开 ────────────────────────
  static bool get showThought =>
      _prefs.getBool('showThought') ?? true;

  static Future<void> setShowThought(bool v) async {
    await _prefs.setBool('showThought', v);
  }

  static bool get thoughtExpanded =>
      _prefs.getBool('thoughtExpanded') ?? true;

  static Future<void> setThoughtExpanded(bool v) async {
    await _prefs.setBool('thoughtExpanded', v);
  }

  // ── 深色模式：跟随系统 / 亮 / 暗 ─────────────────────────
  static String get themeMode =>
      _prefs.getString('themeMode') ?? 'system';

  static Future<void> setThemeMode(String v) async {
    await _prefs.setString('themeMode', v);
  }
}

/// 一个 agent 的配置，来自后端 /api/agents。
class AgentConfig {
  final String id;
  final String name;
  final String avatar;
  final String color;
  final String type;

  const AgentConfig({
    required this.id,
    required this.name,
    required this.avatar,
    required this.color,
    required this.type,
  });

  factory AgentConfig.fromJson(Map<String, dynamic> j) => AgentConfig(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        avatar: j['avatar']?.toString() ?? '',
        color: j['color']?.toString() ?? '#6366f1',
        type: j['type']?.toString() ?? 'acp',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar': avatar,
        'color': color,
        'type': type,
      };
}
