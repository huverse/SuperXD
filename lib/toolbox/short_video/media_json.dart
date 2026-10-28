import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

final _streamPath = RegExp(r'\.(m3u8|mpd)$', caseSensitive: false);
final _lines = RegExp(r'^(\d{3,4})p$', caseSensitive: false);
final _numericId = RegExp(r'^\d{5,30}$');

// 画质说明只认看得懂的几种：original 是原画，1080p、720p 这类与 2K、4K 照写；其余档名（如 normal_720_0）不展示。
String? _quality(Object? value) => switch (value) {
  'original' => '原画',
  String text when _lines.hasMatch(text) => '${_lines.firstMatch(text)![1]}p',
  String text when const {'2k', '4k'}.contains(text.toLowerCase()) => text.toUpperCase(),
  _ => null,
};

// 外部输入：只认范围内的正数，不对就当没给。
num? _positive(Object? value, num max) => value is num && value > 0 && value <= max ? value : null;

// BugPK 两个接口（api.bugpk.com 的抖音接口与 api-new.ifphp.com 的 svparse）共用的「统一 JSON 格式」归一化：
// 顶层 type/title/desc/author/cover/url/quality/duration/size/width/height 说的是主视频，video_backup 每项带自己的
// url/quality/size/width/height，另有 images、live_photo（图与视频配对）与 music。媒体地址只认公网 https，流媒体清单不收。
ParseResult normalizeMediaJson(Map<String, dynamic> data, Uri sourceUrl, String providerId) {
  final resources = <MediaResource>[];
  final seen = <String>{};
  void append(
    Object? raw,
    MediaKind kind,
    String id,
    String label, {
    String? pairedImageId,
    Map<Object?, Object?> info = const {},
  }) {
    if (raw is! String || raw.trim().isEmpty) return;
    final uri = toolboxPublicUrl(raw, httpsOnly: true);
    if (_streamPath.hasMatch(uri.path)) return;
    if (seen.add('${kind.name}\u0000$uri')) {
      final seconds = _positive(info['duration'], 86400);
      resources.add(
        MediaResource(
          id: id,
          kind: kind,
          url: uri,
          label: label,
          pairedImageId: pairedImageId,
          quality: _quality(info['quality']),
          bytes: _positive(info['size'], 1 << 40)?.round(),
          duration: seconds == null ? null : Duration(milliseconds: (seconds * 1000).round()),
          width: _positive(info['width'], 20000)?.round(),
          height: _positive(info['height'], 20000)?.round(),
        ),
      );
    }
  }

  String text(Object? value, int length) => value is String
      ? value.substring(0, value.length.clamp(0, length))
      : '';
  final type = text(data['type'], 20).toLowerCase();
  if (type != 'image' && type != 'live') {
    append(data['url'], MediaKind.video, 'video', '视频', info: data);
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
        info: entry is Map ? entry : const {},
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
    providerId: providerId,
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
    contentId: rawId is String && _numericId.hasMatch(rawId)
        ? rawId
        : null,
  );
}
