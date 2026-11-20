import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_playlist.dart';

// 手机上的播放清单代理（人工决策见 cinema_service.dart 文件头：取流全在手机上，不经自建中转）：只监听 127.0.0.1 的随机端口，
// 路径带一次性随机令牌（同一台手机上别的应用猜不到、借不了它去取别的地址）。只改写 m3u8 文本与转交 AES 密钥（见 cinema_playlist.dart），
// 分片由播放器带着规则的 UA 直连 CDN 取，本机代理与服务器都不过视频字节。
// 腾讯 CDN 的域名前置：第一次遇到某个主机的分片时探一次原地址，取不到而换成路径里的域名取得到，就把这一份清单的分片都换过去（记到这次代理关掉）。

class CinemaStream {
  const CinemaStream({required this.headers, required this.adBlocker});
  final Map<String, String> headers;
  final bool adBlocker;
}

class CinemaProxy {
  CinemaProxy(this._http);
  final CinemaHttp _http;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final String _token = base64UrlNoPad(secureRandomBytes(16));
  // 正在播的几路（换集、换源时新登记一路，旧的按先后挤掉）。
  final _streams = <String, CinemaStream>{};
  var _nextStream = 0;
  // 主机 → 要不要换成路径里的域名（探过的才有）。
  final _unwrap = <String, bool>{};
  // 取过的密钥（同一集的分片共用一把，按地址记，最多 _keyLimit 把）。
  final _keys = <String, List<int>>{};

  static const _streamLimit = 8;
  static const _keyLimit = 64;
  // AES-128 的密钥是 16 字节，留些余量；大于它的不是密钥。
  static const _keyMaxBytes = 1024;

  // 登记一路播放，返回交给播放器的本机地址。
  Future<Uri> open(Uri playlist, CinemaStream stream) async {
    final server = await (_starting ??= _start());
    final id = '${_nextStream++}';
    _streams[id] = stream;
    while (_streams.length > _streamLimit) {
      _streams.remove(_streams.keys.first);
    }
    return _link(server, id, playlist);
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
    try {
      final segments = request.uri.pathSegments;
      final streamId = request.uri.queryParameters['s'];
      final stream = _streams[streamId];
      final upstream = Uri.tryParse(request.uri.queryParameters['u'] ?? '');
      if (segments.length != 2 || segments[0] != _token || (segments[1] != 'p' && segments[1] != 'k') || stream == null || upstream == null || streamId == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (segments[1] == 'k') {
        final key = _keys[upstream.toString()] ?? await _fetchKey(upstream, stream.headers);
        if (key == null) {
          response.statusCode = HttpStatus.badGateway;
          return;
        }
        response.headers.contentType = ContentType.binary;
        response.add(key);
        return;
      }
      final fetched = await _http.fetch(upstream, stream.headers);
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
      final unwrap = await _shouldUnwrap(cinemaFirstSegment(text, fetched.uri), stream.headers);
      final body = cinemaRewritePlaylist(
        text,
        fetched.uri,
        playlist: (target) => _link(server, streamId, target).toString(),
        media: (target) => (unwrap ? cinemaUnwrapHost(target) : target).toString(),
        key: (target) => _link(server, streamId, target, kind: 'k').toString(),
        adBlocker: stream.adBlocker,
      );
      response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(body);
    } on CinemaHttpException catch (error) {
      campusLog('[CinemaProxy] action=playlist errorType=CinemaHttpException message=${error.message}');
      response.statusCode = HttpStatus.badGateway;
    } catch (error, stack) {
      campusLog('[CinemaProxy] action=serve errorType=${error.runtimeType}\n$stack');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close().catchError((Object error, StackTrace stack) => campusLog('[CinemaProxy] action=close errorType=${error.runtimeType}\n$stack'));
    }
  }

  Future<List<int>?> _fetchKey(Uri upstream, Map<String, String> headers) async {
    final fetched = await _http.fetch(upstream, headers, limit: _keyMaxBytes, timeout: const Duration(seconds: 15));
    if (fetched.status >= 400) {
      campusLog('[CinemaProxy] action=key status=${fetched.status}');
      return null;
    }
    _keys[upstream.toString()] = fetched.bytes;
    while (_keys.length > _keyLimit) {
      _keys.remove(_keys.keys.first);
    }
    return fetched.bytes;
  }

  // 分片地址的路径第一段像域名时探一次：原地址取得到就不换；取不到（4xx、5xx）而换过去取得到才换。探的结果按主机记住。
  Future<bool> _shouldUnwrap(Uri? segment, Map<String, String> headers) async {
    if (segment == null) return false;
    final alternate = cinemaUnwrapHost(segment);
    if (alternate == segment) return false;
    final known = _unwrap[segment.host];
    if (known != null) return known;
    Future<bool> reachable(Uri uri) async {
      try {
        return (await _http.fetch(uri, headers, limit: 64 * 1024, timeout: const Duration(seconds: 10), range: 'bytes=0-1')).status < 400;
      } on CinemaHttpException catch (error) {
        // 分片比上限大说明对方没理 Range、直接给了整段：能取到。
        return error.message == '回复太大';
      }
    }

    final unwrap = !await reachable(segment) && await reachable(alternate);
    _unwrap[segment.host] = unwrap;
    campusLog('[CinemaProxy] action=probe unwrap=$unwrap');
    return unwrap;
  }

  Future<void> close() async {
    _streams.clear();
    _keys.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }
}
