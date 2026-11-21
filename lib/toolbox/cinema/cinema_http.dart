import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';

// 电影院对外请求的封装（经共用内核 CampusHttp，请求记录的模块名 cinema）：手机直连片源接口与 CDN，不经自建中转。
// 片源的 CDN 按 UA 掐断非浏览器请求，所以默认带桌面浏览器 UA；一律不带 Referer，除非规则自己写了（交接踩坑第 1、2 条）。
// 不自动重试（跨模块不变量 9）：一个源失败就记进失败列表，换别的源。

const cinemaDefaultUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

// 接口回复（采集站一次最多 20 条带全部字段，几百 KB）与播放清单的上限。
const cinemaApiMaxBytes = 2 * 1024 * 1024;
const cinemaPlaylistMaxBytes = 8 * 1024 * 1024;
const cinemaApiTimeout = Duration(seconds: 15);
const cinemaParseTimeout = Duration(seconds: 30);
const cinemaPlaylistTimeout = Duration(seconds: 25);
// 本机代理自己跟跳转（要拿到最终地址补全清单里的相对路径），最多跳这么多次；各跳共用一个总时限（timeout 管整串，不是每跳重新计）。
const cinemaRedirectLimit = 5;

class CinemaHttpException implements Exception {
  const CinemaHttpException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'CinemaHttpException($message, status=$status)';
}

class CinemaFetched {
  const CinemaFetched({required this.uri, required this.status, required this.bytes, required this.contentType});
  // 跟完跳转后的最终地址。
  final Uri uri;
  final int status;
  final List<int> bytes;
  final String? contentType;
}

Map<String, String> cinemaHeaders(String userAgent, String referer) => {
  'user-agent': userAgent.isEmpty ? cinemaDefaultUserAgent : userAgent,
  if (referer.isNotEmpty) 'referer': referer,
};

// 接口请求另带浏览器取数据时常见的两个头（11-21 DeepSeek 建议）：声称是桌面浏览器却不带它们，部分站点前面的防火墙会判成脚本。
// 只给接口请求，播放清单、密钥与分片照旧（CDN 不看，少一个变量）；规则自己写了同名头时以规则为准。
const cinemaApiHeaders = {'accept': 'application/json, text/plain, */*', 'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8'};

class CinemaHttp {
  CinemaHttp({http.Client? client, this.kind = 'dart'}) : _http = CampusHttp('cinema', client: client);
  final CampusHttp _http;
  // 底下用的是哪个客户端（dart、cronet、urlsession），开发者模式的诊断带上它（原生网络栈对比试验，见 domain/feature_flags.dart）。
  final String kind;

  // 发一次接口请求，回复按 UTF-8 解成文字（容错坏字节）；非 2xx、超时、连不上都抛 CinemaHttpException（给用户看的原因）。
  Future<String> text(CinemaPreparedRequest request, {required String userAgent, required String referer, Duration timeout = cinemaApiTimeout, Future<void>? cancel}) async {
    final http.Response response;
    try {
      response = await _http.send(
        request.method,
        request.uri,
        timeout: timeout,
        limit: cinemaApiMaxBytes,
        headers: {...cinemaHeaders(userAgent, referer), ...cinemaApiHeaders, ...request.headers},
        body: request.body,
        cancel: cancel,
      );
    } on TimeoutException {
      throw const CinemaHttpException('超时');
    } on CampusHttpTooLarge {
      throw const CinemaHttpException('回复太大');
    } on http.RequestAbortedException {
      rethrow;
    } catch (error, stack) {
      campusLog('[Cinema] action=request errorType=${error.runtimeType}\n$stack');
      throw const CinemaHttpException('连不上');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) throw CinemaHttpException('暂不可用（HTTP ${response.statusCode}）', status: response.statusCode);
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  // 本机代理取播放清单或探一下分片：自己跟跳转、只认 http(s)，返回最终地址与状态码（不因 4xx 抛错，调用方自己看）。
  // timeout 是整串跳转共用的总时限；cancel 完成即中断，抛 http.RequestAbortedException。
  Future<CinemaFetched> fetch(Uri uri, Map<String, String> headers, {int limit = cinemaPlaylistMaxBytes, Duration timeout = cinemaPlaylistTimeout, String? range, Future<void>? cancel}) async {
    final watch = Stopwatch()..start();
    var current = uri;
    for (var hop = 0; hop <= cinemaRedirectLimit; hop++) {
      if (!(current.isScheme('http') || current.isScheme('https')) || current.host.isEmpty) throw const CinemaHttpException('地址不对');
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero) throw const CinemaHttpException('超时');
      final http.Response response;
      try {
        response = await _http.send('GET', current, timeout: left, limit: limit, followRedirects: false, headers: {...headers, 'range': ?range}, cancel: cancel);
      } on TimeoutException {
        throw const CinemaHttpException('超时');
      } on CampusHttpTooLarge {
        throw const CinemaHttpException('回复太大');
      } on http.RequestAbortedException {
        rethrow;
      } catch (error, stack) {
        campusLog('[Cinema] action=fetch errorType=${error.runtimeType}\n$stack');
        throw const CinemaHttpException('连不上');
      }
      final location = response.headers['location'];
      if (response.statusCode >= 300 && response.statusCode < 400 && location != null) {
        current = current.resolve(location);
        continue;
      }
      return CinemaFetched(uri: current, status: response.statusCode, bytes: response.bodyBytes, contentType: response.headers['content-type']);
    }
    throw const CinemaHttpException('跳转太多');
  }

  void close() => _http.close();
}

// 几处共用的一次请求（同一部片的选集、同一份播放清单、同一个主机的探测）：每个消费者各自可以不等了（自己的 cancel 完成即抛
// http.RequestAbortedException，不影响别的消费者）；所有消费者都不等了才中断底层请求（run 拿到的 abort 完成），只剩一个页面在等时不会被别的页面误伤。
class CinemaShared<T> {
  CinemaShared(Future<T> Function(Future<void> abort) run) {
    _future = run(_abort.future)..ignore();
  }
  final _abort = Completer<void>();
  late final Future<T> _future;
  var _waiting = 0;

  // 还能接着等：没人等了（被放弃或已经结束）就别再接，另起一次（结束的结果调用方已经缓存了）。
  bool get live => !_abort.isCompleted;

  // 请求结束（成败都算），调用方据此把它从「正在取」里拿掉。
  Future<void> get settled => _future.then((_) {}, onError: (Object _) {});

  Future<T> wait(Future<void>? cancel) async {
    _waiting++;
    try {
      if (cancel == null) return await _future;
      return await Future.any([_future, cancel.then<T>((_) => throw http.RequestAbortedException())]);
    } finally {
      _waiting--;
      if (_waiting == 0 && !_abort.isCompleted) _abort.complete();
    }
  }
}
