import 'dart:convert';

// HLS 播放清单的改写（纯计算，本机代理 cinema_proxy.dart 调用；规则来自交接的 server/proxy.py）：
// - 子清单（主清单里的码率、EXT-X-MEDIA 的音轨字幕）与 AES 密钥（EXT-X-KEY，16 字节）改成回到本机代理的地址，分片与初始化段（EXT-X-MAP）改成绝对地址，
//   播放器直连 CDN 取（服务器与本机代理都不过视频字节）；相对地址按清单自己的地址补全（AES 密钥常是相对路径，交接踩坑第 4 条）。
//   密钥走本机代理：11-19 模拟器上 libmpv 自己取密钥偶发 I/O 错误（同一地址 curl 与本机代理都取得到），一取不到整集就「认不出文件格式」。
// - [人工决策-2026-11-21 11:33:05] 不删任何分片（Codex 复核，用户选「全部源停用时长猜测过滤，保留原始清单」）：原来规则开了 adBlocker 就按
//   不连续分段的时长猜广告删掉，可正片也常用 EXT-X-DISCONTINUITY（RFC 8216 4.3.2.3），无水印的一部电影 5210 个分片被删 789 个、约 26 分钟，
//   剩下分片自带的时间戳对不上删短的清单，点 1:58:24 实际到约 2:19。片源自带的广告会留在片里。旧规则包里的 adBlocker 照样能解，只是不再看它。

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
String cinemaRewritePlaylist(String text, Uri base, {required String Function(Uri) playlist, required String Function(Uri) media, String Function(Uri)? key}) {
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
  return '${rewritten.join('\n')}\n';
}

// 主清单（只列各码率的子清单，没有分片）。
bool cinemaMasterPlaylist(String text) => text.contains('#EXT-X-STREAM-INF');

// 内容不会再变的清单（点播的分片清单写了 #EXT-X-ENDLIST，或主清单）：本机代理可以短时缓存；直播的分片清单一直在变，不缓存。
bool cinemaStaticPlaylist(String text) => cinemaMasterPlaylist(text) || text.contains('#EXT-X-ENDLIST');

// 主清单里各码率子清单的地址（EXT-X-STREAM-INF 下面那一行），按出现的先后；打开前预取用（见 cinema_proxy.dart 文件头）。
List<Uri> cinemaVariants(String text, Uri base) {
  final variants = <Uri>[];
  var next = false;
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
      next = true;
    } else if (next && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      variants.add(base.resolve(trimmed));
      next = false;
    }
  }
  return variants;
}

// 分片清单里第一把网络地址的 AES 密钥（EXT-X-KEY 的 URI；METHOD=NONE、skd:// 之类不算），没有为空；打开前预取用。
Uri? cinemaFirstKey(String text, Uri base) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('#EXT-X-KEY') || trimmed.contains('METHOD=NONE')) continue;
    final uri = RegExp(r'URI="([^"]*)"').firstMatch(trimmed)?.group(1);
    if (uri == null) continue;
    final target = base.resolve(uri);
    if (target.isScheme('http') || target.isScheme('https')) return target;
  }
  return null;
}

// 第一个分片的原始地址（决定要不要换域名前置的主机时探一次）；主清单里是第一个码率的子清单地址。
Uri? cinemaFirstSegment(String text, Uri base) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) return base.resolve(trimmed);
  }
  return null;
}
