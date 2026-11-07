import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api.dart';

/// 文件页：上传过的附件 + 往期会话
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  List<_FileItem> _files = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      // 附件来自消息里出现过的 file 引用
      final msgs = await ApiService.messages();
      final seen = <String>{};
      final items = <_FileItem>[];
      for (final m in msgs) {
        for (final f in m.files) {
          if (seen.add(f.disk)) {
            items.add(_FileItem(
              name: f.name,
              disk: f.disk,
              size: f.size,
              time: m.time,
              from: m.name,
            ));
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _files = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '$e';
      });
    }
  }

  Future<void> _open(_FileItem f) async {
    if (f.disk.startsWith('/')) {
      // 本地路径
      final u = Uri.file(f.disk);
      if (await canLaunchUrl(u)) {
        await launchUrl(u);
      } else {
        await Clipboard.setData(ClipboardData(text: f.disk));
        _snack('路径已复制：${f.disk}');
      }
      return;
    }
    final url = Uri.parse(ApiService.fileUrl(f.disk));
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      _snack('打不开：$url');
    }
  }

  Future<void> _download(_FileItem f) async {
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      _snack('下载到：${dir.path}/${f.name}');
      // 真的下载逻辑留给后续；这里先给出目标路径
    } catch (e) {
      _snack('$e');
    }
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

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: scheme.error),
              const SizedBox(height: 14),
              Text(_err!, textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final attach = _files.where((f) => !f.disk.startsWith('/')).toList();
    final sessions = _files.where((f) => f.disk.startsWith('/')).toList();

    return Column(
      children: [
        Container(
          color: scheme.surfaceContainer,
          child: TabBar(
            controller: _tabs,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(color: scheme.primary, width: 3),
              insets: const EdgeInsets.symmetric(horizontal: 32),
            ),
            tabs: [
              Tab(text: '附件 (${attach.length})'),
              Tab(text: '会话 (${sessions.length})'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _buildList(attach, empty: '还没有上传过文件'),
              _buildList(sessions, empty: '没有找到会话记录', isSession: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    List<_FileItem> items, {
    required String empty,
    bool isSession = false,
  }) {
    final scheme = Theme.of(context).colorScheme;

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open,
                size: 56, color: scheme.onSurfaceVariant.withValues(alpha: .35)),
            const SizedBox(height: 14),
            Text(
              empty,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 0),
        itemBuilder: (context, i) {
          final f = items[i];
          return ListTile(
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isSession ? Icons.history : _iconFor(f.name),
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
            ),
            title: Text(
              isSession ? f.name.substring(0, 8) : f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            subtitle: Text(
              '${f.from} · ${f.sizeText} · ${f.timeText}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            trailing: isSession
                ? null
                : IconButton(
                    icon: const Icon(Icons.download_outlined, size: 20),
                    onPressed: () => _download(f),
                  ),
            onTap: () => _open(f),
          );
        },
      ),
    );
  }

  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'\.(png|jpe?g|gif|webp|svg)$').hasMatch(n)) {
      return Icons.image_outlined;
    }
    if (RegExp(r'\.(mp4|mov|avi|mkv)$').hasMatch(n)) {
      return Icons.movie_outlined;
    }
    if (RegExp(r'\.(mp3|wav|flac|ogg)$').hasMatch(n)) {
      return Icons.audiotrack_outlined;
    }
    if (RegExp(r'\.(zip|tar|gz|7z|rar)$').hasMatch(n)) {
      return Icons.folder_zip_outlined;
    }
    if (RegExp(r'\.(dart|py|js|ts|java|c|cpp|rs|go)$').hasMatch(n)) {
      return Icons.code;
    }
    return Icons.insert_drive_file_outlined;
  }
}

class _FileItem {
  final String name;
  final String disk;
  final int size;
  final int time;
  final String from;

  _FileItem({
    required this.name,
    required this.disk,
    required this.size,
    required this.time,
    required this.from,
  });

  String get sizeText {
    if (size < 1024) return '$size B';
    if (size < 1048576) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / 1048576).toStringAsFixed(1)} MB';
  }

  String get timeText {
    final d = DateTime.fromMillisecondsSinceEpoch(time);
    return '${d.month}/${d.day} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}
