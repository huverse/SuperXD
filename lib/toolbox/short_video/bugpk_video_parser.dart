import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_http.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

class BugpkVideoParser implements ParseProvider {
  BugpkVideoParser({
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) : _http = ParseHttp(client: client, timeout: timeout);
  final ParseHttp _http;
  @override
  final source = const ParseSource(
    id: 'bugpk',
    name: 'BugPK',
    host: 'api.bugpk.com',
    version: '2',
    consentVersion: 'bugpk-short-video-1',
  );
  @override
  bool supports(Uri uri) => const {'http', 'https'}.contains(uri.scheme);

  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async {
    toolboxPublicUrl(uri.toString());
    final douyin = uri.host == 'douyin.com' || uri.host.endsWith('.douyin.com');
    final paths = [if (douyin) '/api/douyin', '/api/short_videos'];
    for (var index = 0; index < paths.length; index++) {
      final watch = Stopwatch()..start();
      try {
        final data = await _http.get(
          Uri.https(source.host, paths[index], {'url': uri.toString()}),
          cancellation,
        );
        if (data['code'].toString() != '200') {
          throw const ParseFailure(
            ParseFailureCode.provider,
            '该作品暂时无法解析，请检查链接或稍后重试',
          );
        }
        if (data['data'] is! Map<String, dynamic>) {
          throw const ParseFailure(ParseFailureCode.provider, '解析结果格式不正确');
        }
        return normalize(data['data'] as Map<String, dynamic>, uri);
      } on ParseFailure catch (error, stack) {
        if (index == paths.length - 1 ||
            error.code == ParseFailureCode.cancelled ||
            error.code == ParseFailureCode.rateLimited ||
            error.code == ParseFailureCode.timeout) {
          rethrow;
        }
        campusLog(
          '[BugPK] action=aggregate_fallback errorType=${error.runtimeType}\n$stack',
        );
        final delay = source.interval - watch.elapsed;
        if (delay > Duration.zero) {
          await Future.any([Future<void>.delayed(delay), cancellation.signal]);
        }
        if (cancellation.isCancelled) {
          throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
        }
      }
    }
    throw const ParseFailure(ParseFailureCode.provider, '来源未返回结果');
  }

  ParseResult normalize(Map<String, dynamic> data, Uri sourceUrl) {
    final resources = <MediaResource>[];
    final seen = <String>{};
    void append(
      Object? raw,
      MediaKind kind,
      String id,
      String label, {
      String? pairedImageId,
    }) {
      if (raw is! String || raw.trim().isEmpty) return;
      final uri = toolboxPublicUrl(raw, httpsOnly: true);
      if (RegExp(r'\.(m3u8|mpd)$', caseSensitive: false).hasMatch(uri.path)) {
        return;
      }
      if (seen.add('${kind.name}\u0000$uri')) {
        resources.add(
          MediaResource(
            id: id,
            kind: kind,
            url: uri,
            label: label,
            pairedImageId: pairedImageId,
          ),
        );
      }
    }

    String text(Object? value, int length) => value is String
        ? value.substring(0, value.length.clamp(0, length))
        : '';
    final type = text(data['type'], 20).toLowerCase();
    if (type != 'image' && type != 'live') {
      append(data['url'], MediaKind.video, 'video', '视频');
    }
    final backups = data['video_backup'];
    if (backups is List) {
      for (var index = 0; index < backups.length.clamp(0, 9); index++) {
        final entry = backups[index];
        append(
          entry is Map ? entry['url'] : entry,
          MediaKind.video,
          'backup_$index',
          '备用${index + 1}',
        );
      }
    }
    final images = data['images'];
    if (images is List) {
      if (images.length > 100) {
        throw const ParseFailure(
          ParseFailureCode.unsupported,
          '图集超过100项，请缩小范围',
        );
      }
      for (var index = 0; index < images.length; index++) {
        final entry = images[index];
        append(
          entry is Map ? entry['url'] : entry,
          MediaKind.image,
          'image_$index',
          '图片${index + 1}',
        );
      }
    }
    final live = data['live_photo'];
    if (live is List) {
      if (live.length > 100) {
        throw const ParseFailure(ParseFailureCode.unsupported, '实况图集超过100项');
      }
      for (var index = 0; index < live.length; index++) {
        final entry = live[index];
        if (entry is! Map) continue;
        final imageUrl = entry['image'];
        append(
          imageUrl,
          MediaKind.image,
          'live_image_$index',
          '实况图片${index + 1}',
        );
        final paired = resources
            .where(
              (item) =>
                  item.kind == MediaKind.image &&
                  item.url.toString() == imageUrl,
            )
            .firstOrNull;
        append(
          entry['video'],
          MediaKind.video,
          'live_video_$index',
          '实况片段${index + 1}',
          pairedImageId: paired?.id,
        );
      }
    }
    if (resources.where((item) => item.kind == MediaKind.image).length > 100) {
      throw const ParseFailure(ParseFailureCode.unsupported, '图集超过100项');
    }
    if (!resources.any((item) => item.kind != MediaKind.audio)) {
      throw const ParseFailure(
        ParseFailureCode.unsupported,
        '未取得可保存媒体，暂不支持分段或受保护内容',
      );
    }
    MediaResource? cover;
    if (data['cover'] case final String value when value.isNotEmpty) {
      cover = MediaResource(
        id: 'cover',
        kind: MediaKind.image,
        url: toolboxPublicUrl(value, httpsOnly: true),
        label: '封面',
      );
    }
    final music = data['music'];
    if (music is Map) append(music['url'], MediaKind.audio, 'music', '音乐');
    final author = data['author'];
    final rawId = data['aweme_id'] ?? data['video_id'];
    return ParseResult(
      sourceUrl: sourceUrl,
      providerId: source.id,
      title: text(data['title'] ?? data['desc'], 500),
      author: text(
        author is Map ? author['name'] ?? author['nickname'] : author,
        100,
      ),
      resources: List.unmodifiable(resources),
      cover: cover,
      platform:
          sourceUrl.host == 'douyin.com' ||
              sourceUrl.host.endsWith('.douyin.com')
          ? 'douyin'
          : '',
      contentId: rawId is String && RegExp(r'^\d{5,30}$').hasMatch(rawId)
          ? rawId
          : null,
    );
  }

  @override
  void close() => _http.close();
}
