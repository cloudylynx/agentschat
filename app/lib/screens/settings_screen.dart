import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/message.dart';
import '../services/settings_store.dart';
import '../services/api.dart';
import '../widgets/avatar_view.dart';

/// 设置页：服务器、头像、主题、会话
class SettingsScreen extends StatefulWidget {
  final void Function(String) onThemeChanged;
  final Future<void> Function() onNeedRefresh;

  const SettingsScreen({
    super.key,
    required this.onThemeChanged,
    required this.onNeedRefresh,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _testing = false;
  String _testResult = '';
  bool _importing = false;


  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveServer() async {
    await SettingsStore.setServerUrl(_urlCtrl.text.trim());
    await SettingsStore.setToken(_tokenCtrl.text.trim());
    ApiService.baseUrl = _urlCtrl.text.trim();
    ApiService.token = _tokenCtrl.text.trim();
    await widget.onNeedRefresh();
    if (!mounted) return;
    _snack('已保存');
  }

  Future<void> _testConn() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final oldUrl = ApiService.baseUrl;
    final oldTok = ApiService.token;
    ApiService.baseUrl = _urlCtrl.text.trim();
    ApiService.token = _tokenCtrl.text.trim();
    final ok = await ApiService.ping();
    setState(() {
      _testing = false;
      _testResult = ok ? '连接成功' : '连接失败';
    });
    if (!ok) {
      ApiService.baseUrl = oldUrl;
      ApiService.token = oldTok;
    }
  }

  Future<void> _pickAvatar(String role) async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (r == null || r.files.isEmpty) return;
    final p = r.files.first.path;
    if (p == null) return;

    await SettingsStore.setAvatar(role, p);
    if (!mounted) return;
    setState(() {});
    await widget.onNeedRefresh();   // ★ 通知壳层，聊天页头像跟着重建
    _snack('头像已更新');
  }

  Future<void> _resetAvatar(String role) async {
    await SettingsStore.setAvatar(role, '');
    if (!mounted) return;
    setState(() {});
    await widget.onNeedRefresh();
    _snack('已恢复默认头像');
  }

  /// 选一个 DSH 会话绑定
  Future<void> _pickSession() async {
    List<Map<String, dynamic>> list = [];
    try {
      list = await ApiService.listSessions(_firstAgentId);
    } catch (e) {
      if (mounted) _snack('读取会话列表失败：$e');
      return;
    }

    if (list.isEmpty) {
      _snack('没有找到会话');
      return;
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        final sc = Theme.of(c).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          builder: (c2, scrollCtrl) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: [
                    Text(
                      '选择要绑定的会话',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: sc.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${list.length} 个',
                      style: TextStyle(
                        fontSize: 12,
                        color: sc.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c3, i) {
                    final it = list[i];
                    final sid = it['sessionId']?.toString() ?? '';
                    final mt = (it['mtime'] as num?)?.toInt() ?? 0;
                    final sz = (it['size'] as num?)?.toInt() ?? 0;
                    final d = DateTime.fromMillisecondsSinceEpoch(mt);
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: sc.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.history,
                            size: 20, color: sc.onSurfaceVariant),
                      ),
                      title: Text(
                        sid.length > 12 ? sid.substring(0, 12) : sid,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: sc.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        '${d.month}/${d.day} '
                        '${d.hour.toString().padLeft(2, '0')}:'
                        '${d.minute.toString().padLeft(2, '0')} · '
                        '${(sz / 1024).toStringAsFixed(0)} KB',
                        style: TextStyle(
                            fontSize: 12, color: sc.onSurfaceVariant),
                      ),
                      onTap: () => Navigator.pop(c, sid),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (picked == null || !mounted) return;

    try {
      final ok = await ApiService.bindSession(_firstAgentId, picked);
      if (!mounted) return;
      _snack(ok ? '已绑定到 ${picked.substring(0, 8)}' : '绑定失败');
    } catch (e) {
      if (!mounted) return;
      _snack('绑定失败：$e');
    }
  }

  /// 导入历史摘要：从本机 DSH 会话说生成摘要，喂给 agent
  Future<void> _importHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入历史？'),
        content: const Text(
          '会从 DSH 会话里提取摘要（约 3500 字），'
          '喂给 agent 当前会话，让它记得之前干过什么。\n\n'
          '这一步会消耗一次模型调用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _importing = true);
    try {
      final r = await ApiService.importHistory(_firstAgentId);
      if (!mounted) return;
      final reply = r['reply']?.toString() ?? '';
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('导入完成'),
          content: SingleChildScrollView(
            child: Text(reply.isEmpty ? '读完了。' : reply),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _newSession() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('开新会话？'),
        content: const Text('当前聊天记录会清空，各 agent 的记忆也会重置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ApiService.newSession();
      await widget.onNeedRefresh();
      if (!mounted) return;
      _snack('新会话已开');
    } catch (e) {
      if (!mounted) return;
      _snack('失败：$e');
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  // 从后端拉到的 agent 列表（头像/配色按它渲染）
  List<Agent> _agents = [];

  @override
  void initState() {
    super.initState();
    // 把已保存的服务器地址/令牌填进输入框（否则打开设置页是空的）
    _urlCtrl.text = SettingsStore.serverUrl;
    _tokenCtrl.text = SettingsStore.token;
    _loadAgents();
  }

  /// DSH 绑定/导入只作用于第一个 agent（历史功能）
  String get _firstAgentId => _agents.isNotEmpty ? _agents.first.id : 'agent1';

  /// '#rrggbb' → Color
  static Color _hexColor(String hex) {
    var h = hex.replaceAll('#', '').trim();
    if (h.length == 6) h = 'ff$h';
    final v = int.tryParse(h, radix: 16);
    return v == null ? const Color(0xFF6B7280) : Color(v);
  }

  Future<void> _loadAgents() async {
    try {
      final list = await ApiService.agents();
      if (mounted) {
        setState(() {
          _agents = list;
        });
      }
    } catch (_) {
      // 拿不到就显示本地缓存
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        // ══ 头像（用户 + 每个 agent，数量任意）══
        _SectionHeader(title: '头像', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _AvatarCard(
                role: 'user',
                label: SettingsStore.userName,
                onPick: () => _pickAvatar('user'),
                onReset: () => _resetAvatar('user'),
                scheme: scheme,
              ),
              ..._agents.map((a) => _AvatarCard(
                    role: a.id,
                    label: a.name,
                    onPick: () => _pickAvatar(a.id),
                    onReset: () => _resetAvatar(a.id),
                    scheme: scheme,
                  )),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ══ 主题 ══
        _SectionHeader(title: '外观', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto, size: 18)),
              ButtonSegment(value: 'light', label: Text('浅色'),
                  icon: Icon(Icons.light_mode, size: 18)),
              ButtonSegment(value: 'dark', label: Text('深色'),
                  icon: Icon(Icons.dark_mode, size: 18)),
            ],
            selected: {SettingsStore.themeMode},
            onSelectionChanged: (s) {
              widget.onThemeChanged(s.first);
              setState(() {});
            },
          ),
        ),

        const SizedBox(height: 24),

        // ══ 聊天配色 ══
        _SectionHeader(title: '聊天配色', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _ColorRow(
                role: 'user',
                label: SettingsStore.userName,
                scheme: scheme,
                defaultColor: const Color(0xFFF5E6A8),
                custom: SettingsStore.colorOf('user'),
                onPick: (c) async {
                  await SettingsStore.setColor('user', c);
                  setState(() {});
                },
              ),
              // 每个 agent 一行配色（数量任意）
              ..._agents.expand((a) => [
                    const SizedBox(height: 10),
                    _ColorRow(
                      role: a.id,
                      label: a.name,
                      scheme: scheme,
                      defaultColor: _hexColor(a.color),
                      custom: SettingsStore.colorOf(a.id),
                      onPick: (c) async {
                        await SettingsStore.setColor(a.id, c);
                        setState(() {});
                      },
                    ),
                  ]),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ══ 服务器 ══
        _SectionHeader(title: '服务器', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: 'http://192.168.1.100:8765',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenCtrl,
                decoration: const InputDecoration(
                  labelText: 'Token',
                  prefixIcon: Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _testConn,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering, size: 18),
                      label: Text(_testing ? '测试中…' : '测试连接'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saveServer,
                      icon: const Icon(Icons.save, size: 18),
                      label: const Text('保存'),
                    ),
                  ),
                ],
              ),
              if (_testResult.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _testResult,
                    style: TextStyle(
                      fontSize: 13,
                      color: _testResult.contains('成功')
                          ? const Color(0xFF7EE2B8)
                          : scheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ══ 会话 ══
        _SectionHeader(title: '会话', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.tonalIcon(
            onPressed: _newSession,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('开新会话'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ),

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _pickSession,
            icon: const Icon(Icons.link, size: 18),
            label: const Text('绑定会话'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '把第一个 agent 接到某个已有的 DSH 会话上。绑定后，'
            'AgentsChat 里说的话会写进那个会话，她也带着那个会话的完整记忆。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _importHistory,
            icon: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file, size: 18),
            label: Text(_importing ? '导入中…' : '导入历史摘要'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '把 DSH 里的历史会话摘要喂给 agent，让它「记得」之前干过什么。'
            '不是复制原文，是压缩过的要点。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),

        const SizedBox(height: 24),

        // ══ 关于 ══
        _SectionHeader(title: '关于', scheme: scheme),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AgentsChat  v1.0.0',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Material Design 3 · Flutter Linux Desktop\n'
                'AgentsChat',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 96),   // 给底部导航栏留空间
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme scheme;
  const _SectionHeader({required this.title, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _AvatarCard extends StatelessWidget {
  final String role;
  final String label;
  final VoidCallback onPick;
  final VoidCallback onReset;
  final ColorScheme scheme;

  const _AvatarCard({
    required this.role,
    required this.label,
    required this.onPick,
    required this.onReset,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    // ★ 注意：这个卡片是被 Wrap 布局的（见上面「头像」那一段）。
    //   所以这里**不能**返回 Expanded / Flexible —— Wrap 用的是 WrapParentData，
    //   而 Expanded 要求 FlexParentData，会抛
    //   "type 'WrapParentData' is not a subtype of type 'FlexParentData'"
    //   并把整个设置页渲染崩掉。固定宽度即可。
    return SizedBox(
      width: 96,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPick,
            child: Stack(
              children: [
                AvatarView(role: role, size: 72),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.surface,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.edit,
                      size: 12,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '默认',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行配色选择：预览 + 一排色块 + 恢复默认
class _ColorRow extends StatelessWidget {
  final String role;
  final String label;
  final ColorScheme scheme;
  final Color defaultColor;
  final int? custom;
  final void Function(int?) onPick;

  const _ColorRow({
    required this.role,
    required this.label,
    required this.scheme,
    required this.defaultColor,
    required this.custom,
    required this.onPick,
  });

  /// MD3 tonal palette 精选色板（覆盖冷暖 + 深浅）
  static const palette = <int>[
    0xFFF5E6A8, // 淡黄
    0xFFFFD8E4, // 淡粉
    0xFFD0E4FF, // 淡蓝
    0xFFC8E6C9, // 淡绿
    0xFFE1D5F5, // 淡紫
    0xFFFFE0B2, // 淡橙
    0xFF8C4A5F, // 玫瑰红
    0xFF4A4458, // 灰紫
    0xFF4F378B, // 深紫
    0xFF1F6FEB, // 蓝
    0xFF2E7D32, // 绿
    0xFF6D4C41, // 棕
  ];

  @override
  Widget build(BuildContext context) {
    final current = custom != null ? Color(custom!) : defaultColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 预览气泡
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: current,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(3),
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(SettingsStore.textColorFor(current.toARGB32())),
                  ),
                ),
              ),
              const Spacer(),
              if (custom != null)
                TextButton(
                  onPressed: () => onPick(null),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '默认',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 色板
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final argb in palette)
                _Swatch(
                  color: Color(argb),
                  selected: custom == argb,
                  scheme: scheme,
                  onTap: () => onPick(argb),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 16,
                color: Color(SettingsStore.textColorFor(color.toARGB32())),
              )
            : null,
      ),
    );
  }
}
