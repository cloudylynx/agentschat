import 'dart:convert';
import 'settings_store.dart';
import 'package:http/http.dart' as http;
import '../models/message.dart';

/// AgentsChat 后端 API 封装
class ApiService {
  /// Windows/本机调试默认；设置页可改
  static String baseUrl = 'http://127.0.0.1:8765';
  static String token = '';

  static Uri _u(String path, [Map<String, String>? q]) {
    final params = <String, String>{...?q};
    if (token.isNotEmpty) params['token'] = token;
    return Uri.parse('$baseUrl$path').replace(queryParameters: params);
  }

  static Map<String, String> get _jsonHeaders => {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'X-AgentsChat-Token': token,
      };

  /// 健康检查
  static Future<bool> ping() async {
    try {
      final r = await http
          .get(_u('/api/agents'))
          .timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 获取 agent 列表
  static Future<List<Agent>> agents() async {
    final r = await http
        .get(_u('/api/agents'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException('获取 agent 列表失败', r.statusCode);
    }
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final list = (d['agents'] as List?) ?? [];
    return list.map((e) => Agent.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 拉取消息（after=0 拿全部）
  static Future<List<Message>> messages({int after = 0}) async {
    final r = await http
        .get(_u('/api/messages', {'after': '$after'}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw ApiException('拉取消息失败', r.statusCode);
    }
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final list = (d['messages'] as List?) ?? [];
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 发消息。返回服务器给出的回复列表
  static Future<Map<String, dynamic>> send(
    String text, {
    List<Attachment> files = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final body = jsonEncode({
      'text': text,
      'files': files.map((f) => f.toJson()).toList(),
      // ★ 2026-11-06 彻底分开：以当前选定的身份发言
      'from': SettingsStore.senderRole,
    });
    final r = await http
        .post(_u('/api/send'), headers: _jsonHeaders, body: body)
        .timeout(timeout);
    if (r.statusCode != 200) {
      throw ApiException('发送失败', r.statusCode);
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// 上传文件
  static Future<List<Attachment>> upload(List<String> paths) async {
    final req = http.MultipartRequest('POST', _u('/api/upload'));
    if (token.isNotEmpty) req.headers['X-AgentsChat-Token'] = token;
    for (final p in paths) {
      req.files.add(await http.MultipartFile.fromPath('files', p));
    }
    final streamed = await req.send().timeout(const Duration(minutes: 3));
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 200) {
      throw ApiException('上传失败', r.statusCode);
    }
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final list = (d['files'] as List?) ?? [];
    return list
        .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 文件下载 URL
  static String fileUrl(String disk) =>
      _u('/files/$disk').toString();

  /// 头像 URL（服务器版）
  static String avatarUrl(String name) =>
      '$baseUrl/avatars/$name';

  /// 开新会话
  static Future<Map<String, dynamic>> newSession() async {
    final r = await http
        .post(_u('/api/new'), headers: _jsonHeaders, body: '{}')
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) {
      throw ApiException('开新会话失败', r.statusCode);
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> importHistory(
    String agent, {
    String? summary,
  }) async {
    String text = summary ?? '';
    // 没传摘要就从本机 DSH 会话现生成
    if (text.isEmpty) {
      
    }
    final r = await http
        .post(_u('/api/import'),
            headers: _jsonHeaders,
            body: jsonEncode({'agent': agent, 'summary': text}))
        .timeout(const Duration(minutes: 6));
    if (r.statusCode != 200) {
      throw ApiException('导入失败', r.statusCode);
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// 列出某个 agent 的 DSH 会话
  static Future<List<Map<String, dynamic>>> listSessions(String agent) async {
    final r = await http
        .get(_u('/api/sessions', {'agent': agent}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw ApiException('获取会话列表失败', r.statusCode);
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return ((d['sessions'] as List?) ?? [])
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  /// 绑定到指定会话
  static Future<bool> bindSession(String agent, String sessionId) async {
    final r = await http
        .post(_u('/api/bind'),
            headers: _jsonHeaders,
            body: jsonEncode({'agent': agent, 'sessionId': sessionId}))
        .timeout(const Duration(seconds: 60));
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return d['ok'] == true;
  }


  /// 流式发消息：逐块回调
  ///
  /// onChunk(agent, field, text)  field = reply | thought
  /// onAgentDone(agent, Message)  某个 agent 说完了
  static Future<void> sendStream(
    String text, {
    List<Attachment> files = const [],
    required void Function(String agent, String field, String text) onChunk,
    required void Function(String agent, Message msg) onAgentDone,
    required void Function(List<String> targets) onStart,
    Duration timeout = const Duration(minutes: 6),
  }) async {
    final req = http.Request('POST', _u('/api/send_stream'));
    req.headers.addAll(_jsonHeaders);
    req.headers['Accept'] = 'text/event-stream';
    req.body = jsonEncode({
      'text': text,
      'files': files.map((f) => f.toJson()).toList(),
      // ★ 2026-11-06 彻底分开：以当前选定的身份发言
      'from': SettingsStore.senderRole,
    });

    final client = http.Client();
    try {
      final resp = await client.send(req).timeout(timeout);
      if (resp.statusCode != 200) {
        throw ApiException('发送失败', resp.statusCode);
      }
      final buf = StringBuffer();
      await for (final chunk in resp.stream.timeout(timeout)) {
        buf.write(utf8.decode(chunk, allowMalformed: true));
        var content = buf.toString();
        while (true) {
          final i = content.indexOf('\n\n');
          if (i < 0) break;
          final evt = content.substring(0, i).trim();
          content = content.substring(i + 2);
          buf.clear();
          buf.write(content);
          if (!evt.startsWith('data: ')) continue;
          Map<String, dynamic> d;
          try {
            d = jsonDecode(evt.substring(6)) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          final kind = d['kind']?.toString() ?? '';
          if (kind == 'start') {
            onStart(((d['targets'] as List?) ?? []).map((e) => e.toString()).toList());
          } else if (kind == 'chunk') {
            onChunk(
              d['agent']?.toString() ?? '',
              d['field']?.toString() ?? 'reply',
              d['data']?.toString() ?? '',
            );
          } else if (kind == 'agent_done') {
            final m = d['msg'];
            if (m is Map<String, dynamic>) {
              onAgentDone(m['role']?.toString() ?? '', Message.fromJson(m));
            }
          } else if (kind == 'agent_error') {
            onChunk(d['agent']?.toString() ?? '', 'error',
                d['data']?.toString() ?? '');
          } else if (kind == 'end') {
            return;
          }
        }
      }
    } finally {
      client.close();
    }
  }


  /// 补拉「正在生成中」的内容（切后台回来用）
  static Future<Map<String, Map<String, dynamic>>> inflight() async {
    final r = await http
        .get(_u('/api/inflight'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return {};
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final raw = (d['inflight'] as Map?) ?? {};
    return raw.map((k, v) =>
        MapEntry(k.toString(), (v as Map).cast<String, dynamic>()));
  }

}

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, [this.status]);

  @override
  String toString() =>
      status == null ? message : '$message（HTTP $status）';

  /// 导入历史摘要到某个 agent 的会话



}
