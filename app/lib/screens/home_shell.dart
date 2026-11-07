import 'package:flutter/material.dart';
import '../services/settings_store.dart';
import '../services/api.dart';
import '../models/message.dart';
import 'chat_screen.dart';
import 'files_screen.dart';
import 'settings_screen.dart';
import '../widgets/region_selector.dart';
import '../widgets/avatar_view.dart';

/// 应用外壳：顶部区域选择器 + 中部内容 + 底部导航栏
class HomeShell extends StatefulWidget {
  final void Function(String) onThemeChanged;
  const HomeShell({super.key, required this.onThemeChanged});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  String _region = 'all';          // 'all' | <agent id>
  List<Agent> _agents = [];
  bool _online = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _tab = SettingsStore.activeTab.clamp(0, 2);
    _region = SettingsStore.activeRegion;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() => _checking = true);
    final ok = await ApiService.ping();
    List<Agent> ags = [];
    if (ok) {
      try {
        ags = await ApiService.agents();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _online = ok;
      _agents = ags;
      _checking = false;
    });
  }

  void _setTab(int v) {
    setState(() => _tab = v);
    SettingsStore.setActiveTab(v);
  }

  void _setRegion(String v) {
    setState(() => _region = v);
    SettingsStore.setActiveRegion(v);
  }

  /// 顶部标题根据当前页变化
  String get _title {
    switch (_tab) {
      case 0:
        return 'AgentsChat';
      case 1:
        return '文件';
      default:
        return '设置';
    }
  }

  String get _subtitle {
    if (_checking) return '连接中…';
    if (!_online) return '未连接';
    if (_tab == 0) {
      final r = _region == 'all'
          ? '群聊 · 全部'
          : '只看该 agent';
      return '$r · ${_agents.length} 个 agent';
    }
    return '已连接';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: _agents.isEmpty ? 56 : 92,
        leading: _agents.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12, top: 8, bottom: 8),
                child: Stack(
                  children: [
                    for (int i = 0; i < _agents.length; i++)
                      // ★ 用 Stack + Positioned 做头像重叠，不能用负 padding
                      //  （Flutter 的 EdgeInsets 不允许负值，会抛断言）
                      Padding(
                        padding: EdgeInsets.only(
                            left: i * 22.0),   // 每个头像向右偏移 22px
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: scheme.surfaceContainer,
                              width: 2,
                            ),
                          ),
                          child: AvatarView(
                            role: _agents[i].id,
                            size: 34,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_title),
            Row(
              children: [
                _StatusDot(
                  online: _online,
                  checking: _checking,
                  scheme: scheme,
                ),
                const SizedBox(width: 6),
                Text(
                  _subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _bootstrap,
          ),
          const SizedBox(width: 4),
        ],
        bottom: _tab == 0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: RegionSelector(
                  value: _region,
                  agents: _agents,
                  onChanged: _setRegion,
                ),
              )
            : null,
      ),

      body: IndexedStack(
        index: _tab,
        children: [
          ChatScreen(
            region: _region,
            agents: _agents,
            online: _online,
            onNeedRefresh: _bootstrap,
          ),
          const FilesScreen(),
          SettingsScreen(
            onThemeChanged: widget.onThemeChanged,
            onNeedRefresh: _bootstrap,
          ),
        ],
      ),

      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _setTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '文件',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool online;
  final bool checking;
  final ColorScheme scheme;

  const _StatusDot({
    required this.online,
    required this.checking,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final color = checking
        ? const Color(0xFFFFD54F)
        : online
            ? const Color(0xFF7EE2B8)
            : scheme.error;

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
