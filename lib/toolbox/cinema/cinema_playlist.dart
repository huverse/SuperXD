import 'dart:convert';

// HLS 播放清单的改写（纯计算，本机代理 cinema_proxy.dart 调用；规则来自交接的 server/proxy.py 与 Kazumi 的 M3u8AdFilter）：
// - 子清单（主清单里的码率、EXT-X-MEDIA 的音轨字幕）与 AES 密钥（EXT-X-KEY，16 字节）改成回到本机代理的地址，分片与初始化段（EXT-X-MAP）改成绝对地址，
//   播放器直连 CDN 取（服务器与本机代理都不过视频字节）；相对地址按清单自己的地址补全（AES 密钥常是相对路径，交接踩坑第 4 条）。
//   密钥走本机代理：11-19 模拟器上 libmpv 自己取密钥偶发 I/O 错误（同一地址 curl 与本机代理都取得到），一取不到整集就「认不出文件格式」。
// - 开了 adBlocker 时按不连续分段（EXT-X-DISCONTINUITY）去掉广告段：最长的一段是正片，比它短很多、首尾不到 30 秒或不到 10 秒的算广告。

bool cinemaLooksLikePlaylist(List<int> head, String? contentType) {
  if ((contentType ?? '').toLowerCase().contains('mpegurl')) return true;
  final text = utf8.decode(head.take(64).toList(), allowMalformed: true).replaceFirst('﻿', '').trimLeft();
  return text.startsWith('#EXTM3U');
}

// 腾讯 CDN 的域名前置：分片地址的主机是边缘节点，真正签名的域名嵌在路径第一段（https://边缘/defaultts.tc.qq.com/xx.ts），直连必回 418。
// 路径第一段像域名（有点、只含字母数字点横线、不等于当前主机）时，把它提出来当主机；不像就原样返回。只在原样取失败时才换用（交接踩坑第 3 条）。
Uri cinemaUnwrapHost(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2) return uri;
  final head = segments.first;
  if (head == uri.host || !head.contains('.') || head.length > 253 || !RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(head)) return uri;
  return Uri(scheme: uri.scheme, host: head, pathSegments: segments.skip(1), query: uri.hasQuery ? uri.query : null);
}

// 改写一份清单：playlist 把子清单地址变成本机代理地址，media 把分片、密钥地址变成最终给播放器的地址（域名前置时换主机）。
String cinemaRewritePlaylist(String text, Uri base, {required String Function(Uri) playlist, required String Function(Uri) media, String Function(Uri)? key, bool adBlocker = false}) {
  final lines = const LineSplitter().convert(text.replaceFirst('﻿', ''));
  final master = lines.any((line) => line.startsWith('#EXT-X-STREAM-INF'));
  final rewritten = <String>[];
  var nextIsVariant = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) {
      final isMedia = trimmed.startsWith('#EXT-X-MEDIA:') || trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF');
      final isKey = trimmed.startsWith('#EXT-X-KEY') || trimmed.startsWith('#EXT-X-SESSION-KEY');
      rewritten.add(trimmed.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (match) {
        final target = base.resolve(match.group(1)!);
        // 不是网络地址的密钥（如 skd:// 之类的 DRM 标识）原样留着。
        if (isKey && !(target.isScheme('http') || target.isScheme('https'))) return match.group(0)!;
        return 'URI="${isMedia ? playlist(target) : (isKey ? (key ?? media)(target) : media(target))}"';
      }));
      if (trimmed.startsWith('#EXT-X-STREAM-INF')) nextIsVariant = true;
      continue;
    }
    final target = base.resolve(trimmed);
    rewritten.add(master && nextIsVariant ? playlist(target) : media(target));
    nextIsVariant = false;
  }
  final body = adBlocker && !master ? _filterAds(rewritten) : rewritten;
  return '${body.join('\n')}\n';
}

// 主清单（只列各码率的子清单，没有分片）。
bool cinemaMasterPlaylist(String text) => text.contains('#EXT-X-STREAM-INF');

// 内容不会再变的清单（点播的分片清单写了 #EXT-X-ENDLIST，或主清单）：本机代理可以短时缓存；直播的分片清单一直在变，不缓存。
bool cinemaStaticPlaylist(String text) => cinemaMasterPlaylist(text) || text.contains('#EXT-X-ENDLIST');

// 第一个分片的原始地址（决定要不要换域名前置的主机时探一次）；主清单里是第一个码率的子清单地址。
Uri? cinemaFirstSegment(String text, Uri base) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) return base.resolve(trimmed);
  }
  return null;
}

class _Block {
  _Block(this.group, this.tags, this.uri, this.duration);
  final int group;
  final List<String> tags;
  final String uri;
  final double duration;
}

// 跟着下一个分片走的标签（其余的在第一个分片之前算清单头）。
bool _segmentTag(String line) =>
    line.startsWith('#EXTINF') || line == '#EXT-X-DISCONTINUITY' || line.startsWith('#EXT-X-KEY') || line.startsWith('#EXT-X-MAP') || line.startsWith('#EXT-X-BYTERANGE') || line.startsWith('#EXT-X-PROGRAM-DATE-TIME');

List<String> _filterAds(List<String> lines) {
  final header = <String>[];
  final trailer = <String>[];
  final blocks = <_Block>[];
  var pending = <String>[];
  var group = 0;
  var started = false;
  for (final line in lines) {
    if (line.startsWith('#')) {
      if (line == '#EXT-X-ENDLIST') {
        trailer.add(line);
      } else if (!started && !_segmentTag(line)) {
        header.add(line);
      } else {
        if (line == '#EXT-X-DISCONTINUITY') group++;
        pending.add(line);
      }
      continue;
    }
    started = true;
    final extinf = pending.where((tag) => tag.startsWith('#EXTINF:')).firstOrNull;
    final duration = double.tryParse(extinf?.substring(8).split(',').first.trim() ?? '') ?? 0;
    blocks.add(_Block(group, pending, line, duration));
    pending = <String>[];
  }
  final durations = <int, double>{};
  for (final block in blocks) {
    durations[block.group] = (durations[block.group] ?? 0) + block.duration;
  }
  if (durations.length <= 1) return lines;
  final longest = durations.values.reduce((a, b) => a > b ? a : b);
  final groups = durations.keys.toList()..sort();
  final ads = {
    for (final id in groups)
      if (durations[id]! != longest &&
          (durations[id]! < longest * 0.3 || durations[id]! < 10 || ((id == groups.first || id == groups.last) && durations[id]! < 30)))
        id,
  };
  if (ads.isEmpty) return lines;
  // 去掉的段里可能带着之后正片要用的 EXT-X-KEY、EXT-X-MAP：按到每个分片为止「当时生效的那一行」补上，不改正片的解密与初始化。
  // 初始化段按 EXT-X-MAP 出现时生效的 EXT-X-KEY 解密（RFC 8216 4.3.2.4；明文初始化段配加密分片时 MAP 写在 KEY 前面）：
  // MAP 记下自己那时的密钥（null 是还没有密钥，即明文），补 MAP 前先把密钥换成那时的、写完再换回分片当前的，顺序颠倒会把明文初始化段当密文解。
  final out = [...header];
  String? key, map, mapKey, emittedKey, emittedMap, emittedMapKey;
  void useKey(String? target) {
    if (target == emittedKey) return;
    out.add(target ?? '#EXT-X-KEY:METHOD=NONE');
    emittedKey = target;
  }

  for (final block in blocks) {
    for (final tag in block.tags) {
      if (tag.startsWith('#EXT-X-KEY')) key = tag;
      if (tag.startsWith('#EXT-X-MAP')) (map, mapKey) = (tag, key);
    }
    if (ads.contains(block.group)) continue;
    if (map != null && (map != emittedMap || mapKey != emittedMapKey)) {
      useKey(mapKey);
      out.add(map);
      (emittedMap, emittedMapKey) = (map, mapKey);
    }
    useKey(key);
    out.addAll(block.tags.where((tag) => !tag.startsWith('#EXT-X-KEY') && !tag.startsWith('#EXT-X-MAP')));
    out.add(block.uri);
  }
  return [...out, ...pending, ...trailer];
}
