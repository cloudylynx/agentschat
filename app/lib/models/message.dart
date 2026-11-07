/// 一条消息
class Message {
  final String id;
  final String role;        // 'user' | <agent id> | 'system'
  final String name;
  final String text;
  final String thought;     // 思考链（可能为空）
  final List<Attachment> files;
  final List<String> mentions;
  final bool isError;
  final int time;           // 毫秒时间戳

  Message({
    required this.id,
    required this.role,
    required this.name,
    required this.text,
    this.thought = '',
    this.files = const [],
    this.mentions = const [],
    this.isError = false,
    required this.time,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id']?.toString() ?? '',
        role: j['role']?.toString() ?? 'unknown',
        name: j['name']?.toString() ?? '',
        text: j['text']?.toString() ?? '',
        thought: j['thought']?.toString() ?? '',
        files: (j['files'] as List?)
                ?.map((e) => Attachment.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        mentions: (j['mentions'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        isError: j['isError'] == true,
        time: (j['time'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'name': name,
        'text': text,
        'thought': thought,
        'files': files.map((f) => f.toJson()).toList(),
        'mentions': mentions,
        'isError': isError,
        'time': time,
      };

  bool get isMe => role == 'user';
}

/// 文件附件
class Attachment {
  final String name;
  final String disk;
  final int size;

  Attachment({required this.name, required this.disk, required this.size});

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        name: j['name']?.toString() ?? '',
        disk: j['disk']?.toString() ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'disk': disk, 'size': size};

  bool get isImage =>
      RegExp(r'\.(png|jpe?g|gif|webp|svg)$', caseSensitive: false)
          .hasMatch(name);

  String get sizeText {
    if (size < 1024) return '$size B';
    if (size < 1048576) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / 1048576).toStringAsFixed(1)} MB';
  }
}

/// 一个 agent。列表由后端 /api/agents 下发，数量任意。
class Agent {
  final String id;
  final String name;
  final String color;
  final String avatar;
  final String type;

  Agent({
    required this.id,
    required this.name,
    required this.color,
    required this.avatar,
    this.type = 'acp',
  });

  factory Agent.fromJson(Map<String, dynamic> j) => Agent(
        // 后端下发的是 id；兼容旧字段 key
        id: (j['id'] ?? j['key'] ?? '').toString(),
        name: j['name']?.toString() ?? '',
        color: j['color']?.toString() ?? '#6366f1',
        avatar: j['avatar']?.toString() ?? '',
        type: j['type']?.toString() ?? 'acp',
      );

  /// 本地占位资源（设置页可覆盖成自定义图片）
  String get assetPath => 'assets/avatars/$id.png';
}

/// 会话历史摘要
class SessionSummary {
  final String sessionId;
  final int mtime;
  final int size;

  SessionSummary({
    required this.sessionId,
    required this.mtime,
    required this.size,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
        sessionId: j['sessionId']?.toString() ?? '',
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  String get shortId => sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(mtime);
}
