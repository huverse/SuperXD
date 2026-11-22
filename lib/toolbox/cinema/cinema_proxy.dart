import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:quiver/collection.dart';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_playlist.dart';

// 手机上的播放清单代理（人工决策见 cinema_service.dart 文件头：取流全在手机上，不经自建中转）：只监听 127.0.0.1 的随机端口，
// 路径带一次性随机令牌（同一台手机上别的应用猜不到、借不了它去取别的地址）。只改写 m3u8 文本与转交 AES 密钥（见 cinema_playlist.dart），
// 分片由播放器带着规则的 UA 直连 CDN 取，本机代理与服务器都不过视频字节。
// - 清单里的子清单、密钥、分片与跳转目标都是第三方给的，只认公网（cinema_http.dart 的 cinemaPublicUrl）：取的时候每一跳核对、连接按真实地址再核，
//   交给播放器的分片有一个指向本机或内网就整份清单不给（回 502）。
// - 每一路播放（open 登记）在换集、换源、离开时交回 release：这一路还在等的清单与密钥请求随之不等了，几路共用的请求没人等了才中断（CinemaShared）。
// - 腾讯 CDN 的域名前置：分片清单里第一个分片的路径首段像域名时，原地址与换成那个域名的地址同时各探一次（只要状态与两个字节），
//   原地址取得到就不换（原地址优先，免得把正常的地址改坏），取不到而换过去取得到才换；两路共用 probeBudget（默认 6 秒，弱网下也够拿到响应头）。
//   结论按「主机、换成的主机、UA 与 Referer」记 probeKnownFor，超时、被取消这类没定论的只记 probeUnsureFor，一次网络抖动不会误判一整晚。
// - 内容不会变的清单（点播与主清单，cinemaStaticPlaylist）按地址加请求头缓存 playlistLifetime，预取（warm）取过的直接用；直播清单每次现取。
//   缓存与探测结论只让当前有效的那次写，旧的晚回来不覆盖新的。
// - [人工决策-2026-11-21 14:01:18] 先备好再交给播放器（11-21 Codex 总交接第 7.8 节，用户说按最佳实践做）：media_kit 给 mpv 设了 network-timeout=5，
//   一次读 5 秒没数据就放弃，而这里向上游取清单最多 25 秒、取密钥 15 秒、分片清单还要先探 6 秒，上游慢一点播放器就先报错了（本机代理还在等）。
//   所以打开前 CinemaService.playable 先等 warm 把主清单、各码率子清单（最多 warmVariants 个）、第一把密钥与探测都备好（这段由 Dart 的时限与
//   「打开中」管），播放器来取时都命中缓存；分片照旧由 mpv 直连、5 秒加重试快速失败，不把超时一律拉长（那样坏源要更久才失败）。
//   「重新载入」的预取（fresh）不用缓存、不接正在取的、重新探测（分片签名可能已经失效），取到的照样进缓存给播放器用。
//   播放器在我们回复之前断开了（等不及）记 client_gone，用来在手机上核对还有没有这种情况。

class CinemaStream {
  const CinemaStream({required this.headers});
  final Map<String, String> headers;
}

class _Stream {
  _Stream(this.stream);
  final CinemaStream stream;
  final released = Completer<void>();
}

class CinemaProxy {
  CinemaProxy(this._http, {DateTime Function()? now, this.probeBudget = defaultProbeBudget}) : _now = now ?? DateTime.now;
  final CinemaHttp _http;
  final DateTime Function() _now;
  // 一次探测（原地址与替代地址两路）共用的时间预算；测试里调短。
  final Duration probeBudget;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final String _token = base64UrlNoPad(secureRandomBytes(16));
  // 正在播的几路（换集、换源时新登记一路，旧的交回或按先后挤掉）。
  final _streams = <String, _Stream>{};
  var _nextStream = 0;
  // 探测的结论（见文件头）与正在探的。
  final _unwrap = LruMap<String, (DateTime, bool)>(maximumSize: probeLimit);
  final _probing = <String, CinemaShared<bool>>{};
  // 缓存的清单与正在取的。
  final _playlists = LruMap<String, (DateTime, CinemaFetched)>(maximumSize: playlistLimit);
  final _fetching = <String, CinemaShared<CinemaFetched>>{};
  // 取过的密钥（同一集的分片共用一把）：按地址加请求头记（同清单缓存的 _playlistKey），keyLifetime 内有效、最多 _keyLimit 把。
  // 11-22 Codex 复核：原来只按地址记、不过期，同一地址按请求条件给不同密钥时，后一路会拿到前一路的那把、解不开。
  final _keys = LruMap<String, (DateTime, List<int>)>(maximumSize: _keyLimit);
  // 开发者模式的诊断（11-21 Codex 总交接第 7.6、8 节：先量预取命中率再定预取策略）：预取取过的清单与时刻，播放器来取时记一条用上了没有。
  final _warmed = LruMap<String, DateTime>(maximumSize: playlistLimit);

  static const _streamLimit = 8;
  static const _keyLimit = 64;
  // AES-128 的密钥是 16 字节，留些余量；大于它的不是密钥。
  static const _keyMaxBytes = 1024;
  static const defaultProbeBudget = Duration(seconds: 6);
  static const probeKnownFor = Duration(minutes: 30);
  static const probeUnsureFor = Duration(minutes: 1);
  static const probeLimit = 64;
  // 探测只要状态：带 Range 只要两个字节，对方不理 Range 时读到这么多就停（算取得到）。
  static const _probeBytes = 4 * 1024;
  static const playlistLifetime = Duration(minutes: 5);
  static const playlistLimit = 16;
  static const keyLifetime = Duration(minutes: 5);
  // 预取主清单里的子清单最多几个（码率）：播放器打开时会读各码率的子清单。
  static const warmVariants = 4;

  // 登记一路播放，返回交给播放器的本机地址（先 warm 备好，见文件头）。
  Future<Uri> open(Uri playlist, CinemaStream stream) async {
    final server = await (_starting ??= _start());
    final id = '${_nextStream++}';
    _streams[id] = _Stream(stream);
    while (_streams.length > _streamLimit) {
      _drop(_streams.keys.first);
    }
    return _link(server, id, playlist);
  }

  // 交回一路（open 给的地址）：这一路还在等的请求不等了，之后再来的回 404。
  void release(Uri link) {
    if (link.queryParameters['s'] case final id?) _drop(id);
  }

  void _drop(String id) {
    final entry = _streams.remove(id);
    if (entry != null && !entry.released.isCompleted) entry.released.complete();
  }

  // 预取一份清单（打开前与 CinemaService.warm）：主清单再取各码率的子清单（最多 warmVariants 个，同时取），
  // 第一个分片清单再取第一把密钥、探好域名前置。出错只记日志。cancel 完成时这次预取不等了（别处还在等同一份就不中断）；fresh 见文件头。
  Future<void> warm(Uri playlist, CinemaStream stream, {Future<void>? cancel, bool fresh = false}) async {
    try {
      _warmed[_playlistKey(playlist, stream.headers)] = _now();
      var fetched = await _playlist(playlist, stream.headers, cancel, fresh: fresh);
      if (!cinemaLooksLikePlaylist(fetched.bytes, fetched.contentType)) return;
      var text = utf8.decode(fetched.bytes, allowMalformed: true);
      if (cinemaMasterPlaylist(text)) {
        final variants = cinemaVariants(text, fetched.uri).take(warmVariants).toList();
        if (variants.isEmpty) return;
        for (final variant in variants) {
          _warmed[_playlistKey(variant, stream.headers)] = _now();
        }
        final all = await Future.wait([
          for (final variant in variants) _playlist(variant, stream.headers, cancel, fresh: fresh).then<CinemaFetched?>((value) => value, onError: (Object error) => error is http.RequestAbortedException ? throw error : null),
        ]);
        final first = all.first;
        if (first == null || !cinemaLooksLikePlaylist(first.bytes, first.contentType)) return;
        fetched = first;
        text = utf8.decode(fetched.bytes, allowMalformed: true);
      }
      final key = cinemaFirstKey(text, fetched.uri);
      if (key != null && (fresh || _knownKey(key, stream.headers) == null)) await _fetchKey(key, stream.headers, cancel ?? Completer<void>().future);
      await _shouldUnwrap(cinemaFirstSegment(text, fetched.uri), stream.headers, cancel, fresh: fresh);
      campusLog('[CinemaProxy] action=warm fresh=$fresh');
    } on http.RequestAbortedException {
      campusLog('[CinemaProxy] action=warm cancelled=true');
    } on CinemaHttpException catch (error) {
      campusLog('[CinemaProxy] action=warm errorType=CinemaHttpException message=${error.message}');
    } catch (error, stack) {
      campusLog('[CinemaProxy] action=warm errorType=${error.runtimeType}\n$stack');
    }
  }

  Uri _link(HttpServer server, String stream, Uri upstream, {String kind = 'p'}) => Uri(scheme: 'http', host: '127.0.0.1', port: server.port, pathSegments: [_token, kind], queryParameters: {'s': stream, 'u': upstream.toString()});

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_serve(server, request)), onError: (Object error, StackTrace stack) => campusLog('[CinemaProxy] action=listen errorType=${error.runtimeType}\n$stack'));
    campusLog('[CinemaProxy] action=start');
    return server;
  }

  Future<void> _serve(HttpServer server, HttpRequest request) async {
    final response = request.response;
    final streamId = request.uri.queryParameters['s'];
    final watch = Stopwatch()..start();
    try {
      final segments = request.uri.pathSegments;
      final entry = _streams[streamId];
      final upstream = Uri.tryParse(request.uri.queryParameters['u'] ?? '');
      if (segments.length != 2 || segments[0] != _token || (segments[1] != 'p' && segments[1] != 'k') || entry == null || upstream == null || streamId == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final stream = entry.stream, released = entry.released.future;
      if (segments[1] == 'k') {
        final known = _knownKey(upstream, stream.headers);
        final watch = Stopwatch()..start();
        final key = known ?? await _fetchKey(upstream, stream.headers, released);
        if (campusDiagnostics) campusLog('[CinemaProxy] action=key stream=$streamId cached=${known != null} ok=${key != null} ms=${watch.elapsedMilliseconds}');
        if (key == null) {
          response.statusCode = HttpStatus.badGateway;
          return;
        }
        response.headers.contentType = ContentType.binary;
        response.add(key);
        return;
      }
      final cacheKey = _playlistKey(upstream, stream.headers);
      final cached = _playlists[cacheKey]?.$1.isAfter(_now()) ?? false;
      final warmedAt = _warmed.remove(cacheKey);
      final fetched = await _playlist(upstream, stream.headers, released);
      if (campusDiagnostics) {
        campusLog('[CinemaProxy] action=playlist stream=$streamId cache=${cached ? 'hit' : 'miss'} warmed=${warmedAt == null ? 'no' : 'yes'} warmAgeMs=${warmedAt == null ? '-' : _now().difference(warmedAt).inMilliseconds} redirected=${fetched.uri != upstream} status=${fetched.status} ms=${watch.elapsedMilliseconds}');
      }
      if (fetched.status >= 400) {
        campusLog('[CinemaProxy] action=playlist status=${fetched.status}');
        response.statusCode = HttpStatus.badGateway;
        return;
      }
      if (!cinemaLooksLikePlaylist(fetched.bytes, fetched.contentType)) {
        // 地址写着 m3u8 实际给的是媒体本身：原样交回。
        response.headers.contentType = ContentType.parse(fetched.contentType ?? 'application/octet-stream');
        response.add(fetched.bytes);
        return;
      }
      final text = utf8.decode(fetched.bytes, allowMalformed: true);
      // 主清单里没有分片（第一个非注释行是子清单），不探。
      final unwrap = !cinemaMasterPlaylist(text) && await _shouldUnwrap(cinemaFirstSegment(text, fetched.uri), stream.headers, released);
      // 播放器直连的分片与初始化段只认公网（见 cinema_http.dart 的 cinemaPublicUrl）：有一个指向本机或内网就整份不给，不交出半份清单。
      var private = false;
      final body = cinemaRewritePlaylist(
        text,
        fetched.uri,
        playlist: (target) => _link(server, streamId, target).toString(),
        media: (target) {
          final direct = unwrap ? cinemaUnwrapHost(target) : target;
          if (!cinemaPublicUrl(direct)) private = true;
          return direct.toString();
        },
        key: (target) => _link(server, streamId, target, kind: 'k').toString(),
      );
      if (private) {
        campusLog('[CinemaProxy] action=playlist blocked=private');
        response.statusCode = HttpStatus.badGateway;
        return;
      }
      response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(body);
    } on http.RequestAbortedException {
      // 这一路已经交回（换集、换源、离开），播放器也不要这个回复了。
      response.statusCode = HttpStatus.notFound;
    } on CinemaHttpException catch (error) {
      campusLog('[CinemaProxy] action=playlist errorType=CinemaHttpException message=${error.message}');
      response.statusCode = HttpStatus.badGateway;
    } catch (error, stack) {
      campusLog('[CinemaProxy] action=serve errorType=${error.runtimeType}\n$stack');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      // 写回复时播放器已经断开（等不及先放弃了）：记下这一路、哪一类与等了多久（见文件头），不算我们的错误。
      await response.close().catchError((Object error) => campusLog('[CinemaProxy] action=client_gone stream=${streamId ?? '-'} kind=${request.uri.pathSegments.lastOrNull ?? '-'} ms=${watch.elapsedMilliseconds} errorType=${error.runtimeType}'));
    }
  }

  // 取一份清单：缓存里有没过期的直接用，同一份正在取就一起等（fresh 都不用，另起一次，取到的照样进缓存）；cancel 是这一处不等了。
  String _playlistKey(Uri upstream, Map<String, String> headers) => '$upstream\u0000${headers['user-agent'] ?? ''}\u0000${headers['referer'] ?? ''}';

  Future<CinemaFetched> _playlist(Uri upstream, Map<String, String> headers, Future<void>? cancel, {bool fresh = false}) {
    final key = _playlistKey(upstream, headers);
    final cached = _playlists[key];
    if (!fresh && cached != null && _now().isBefore(cached.$1)) return Future.value(cached.$2);
    final fetching = _fetching[key];
    if (!fresh && fetching != null && fetching.live) return fetching.wait(cancel);
    late final CinemaShared<CinemaFetched> shared;
    shared = _fetching[key] = CinemaShared((abort) async {
      final fetched = await _http.fetch(upstream, headers, cancel: abort);
      // 只有当前有效的那次写缓存：重新载入另起的一次先回来、旧的后回来时，不让旧的盖掉新的。
      if (identical(_fetching[key], shared) && fetched.status < 400 && cinemaLooksLikePlaylist(fetched.bytes, fetched.contentType) && cinemaStaticPlaylist(utf8.decode(fetched.bytes, allowMalformed: true))) {
        _playlists[key] = (_now().add(playlistLifetime), fetched);
      }
      return fetched;
    });
    unawaited(shared.settled.then((_) {
      if (identical(_fetching[key], shared)) _fetching.remove(key);
    }));
    return shared.wait(cancel);
  }

  Future<List<int>?> _fetchKey(Uri upstream, Map<String, String> headers, Future<void> cancel) async {
    final fetched = await _http.fetch(upstream, headers, limit: _keyMaxBytes, timeout: const Duration(seconds: 15), cancel: cancel);
    if (fetched.status >= 400) {
      campusLog('[CinemaProxy] action=key status=${fetched.status}');
      return null;
    }
    _keys[_playlistKey(upstream, headers)] = (_now().add(keyLifetime), fetched.bytes);
    return fetched.bytes;
  }

  List<int>? _knownKey(Uri upstream, Map<String, String> headers) {
    final known = _keys[_playlistKey(upstream, headers)];
    return known != null && _now().isBefore(known.$1) ? known.$2 : null;
  }

  // 要不要把这份清单的分片换成路径里的域名（见文件头）。cancel 是这一处不等了；fresh 不用记住的结论、重新探。
  Future<bool> _shouldUnwrap(Uri? segment, Map<String, String> headers, Future<void>? cancel, {bool fresh = false}) {
    if (segment == null) return Future.value(false);
    final alternate = cinemaUnwrapHost(segment);
    if (alternate == segment) return Future.value(false);
    final key = '${segment.host}\u0000${alternate.host}\u0000${headers['user-agent'] ?? ''}\u0000${headers['referer'] ?? ''}';
    final known = _unwrap[key];
    if (!fresh && known != null && _now().isBefore(known.$1)) return Future.value(known.$2);
    final probing = _probing[key];
    if (!fresh && probing != null && probing.live) return probing.wait(cancel);
    late final CinemaShared<bool> shared;
    shared = _probing[key] = CinemaShared((abort) => _probe(key, segment, alternate, headers, abort, current: () => identical(_probing[key], shared)));
    unawaited(shared.settled.then((_) {
      if (identical(_probing[key], shared)) _probing.remove(key);
    }));
    return shared.wait(cancel);
  }

  // current 为假时（已经有更新的一次探测）结论不记，只交给这次在等的。
  Future<bool> _probe(String key, Uri segment, Uri alternate, Map<String, String> headers, Future<void> abort, {required bool Function() current}) async {
    final stop = Completer<void>();
    var abandoned = false;
    unawaited(abort.then((_) {
      abandoned = true;
      if (!stop.isCompleted) stop.complete();
    }));
    // 取得到为真、明确取不到（4xx、5xx、连不上）为假，超时或被取消没定论为空。
    Future<bool?> reachable(Uri uri) async {
      try {
        return (await _http.fetch(uri, headers, limit: _probeBytes, timeout: probeBudget, range: 'bytes=0-1', cancel: stop.future)).status < 400;
      } on CinemaHttpException catch (error) {
        // 分片比上限大说明对方没理 Range、直接给了整段：取得到。
        if (error.message == '回复太大') return true;
        return error.message == '超时' ? null : false;
      } on http.RequestAbortedException {
        return null;
      }
    }

    final original = reachable(segment), other = reachable(alternate);
    final first = await original;
    final second = first == true ? null : await other;
    if (!stop.isCompleted) stop.complete();
    await other;
    // 没人等了才停下的：结论不可信，不记。
    if (abandoned) throw http.RequestAbortedException(segment);
    final unwrap = first != true && second == true;
    final sure = first == true || (first == false && second != null);
    if (current()) _unwrap[key] = (_now().add(sure ? probeKnownFor : probeUnsureFor), unwrap);
    campusLog('[CinemaProxy] action=probe unwrap=$unwrap sure=$sure');
    return unwrap;
  }

  Future<void> close() async {
    for (final id in [..._streams.keys]) {
      _drop(id);
    }
    _keys.clear();
    _playlists.clear();
    _warmed.clear();
    _unwrap.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }
}
