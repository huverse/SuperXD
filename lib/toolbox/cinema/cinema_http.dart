import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

// 电影院对外请求的封装（经共用内核 CampusHttp，请求记录的模块名 cinema）：手机直连片源接口与 CDN，不经自建中转；
// 国内连不上的源的接口请求经开发者的境外转发（规则里 forward，人工决策见 cinema_rule.dart 的 CinemaRule.forward）。
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

// 片源回这些状态码算「拒绝访问」（CinemaFailureKind.refused）：要登录、被禁、要代理认证、限流、按法律屏蔽。
const cinemaRefusedStatuses = {401, 403, 407, 429, 451};

class CinemaHttpException implements Exception {
  const CinemaHttpException(this.message, {this.status, this.refused = false, this.challenge = false, this.stage});
  final String message;
  final int? status;
  // 超时卡在哪一步，只进开发者模式的日志：CampusHttpTimeout 的 stage，或 forward（境外转发那头取片源超时）。
  final String? stage;
  // 片源自己拒绝了这次请求（cinemaRefusedStatuses 或人机验证）；转发服务自己出的错不算。
  final bool refused;
  // 片源回的是 Cloudflare 人机验证页（日志单独记 failed_challenge）。
  final bool challenge;
  @override
  String toString() => 'CinemaHttpException($message, status=$status)';
}

// Cloudflare 的人机验证页：直连时回复头带 cf-mitigated: challenge；经境外转发时回复头不带过来，按页面里的 _cf_chl_opt 或「Just a moment」认。
bool cinemaChallenge(http.Response response) {
  if (response.headers['cf-mitigated'] == 'challenge') return true;
  final body = utf8.decode(response.bodyBytes, allowMalformed: true);
  return body.contains('_cf_chl_opt') || body.contains('<title>Just a moment');
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

// 第三方给的媒体地址只认公网（11-22 Codex 复核 P1：外部清单能让手机去取 127.0.0.1 上的服务，签名的规则包与本机代理的口令都挡不住，
// 因为清单、选集与跳转都不签名；同主流客户端核对外部媒体引用的网络边界）：本机、内网、单段主机名、.local 一律不认，端口不限。
// 本机代理取清单、密钥与探测时每一跳都看它，连接时另按真实地址再核一次（CampusHttp.publicOnly，挡住域名解析成本机的）；
// 交给播放器的分片、初始化段与直链也看它（cinema_proxy.dart、CinemaService.playable）。本机代理自己生成的 127.0.0.1 地址不经这里。
// 播放器取分片时自己跟的跳转管不到（ExoPlayer 与 libmpv 自己的网络栈），是已知边界。家庭 NAS 这类内网片源不支持。
bool cinemaPublicUrl(Uri uri) {
  try {
    toolboxPublicUrl(uri.toString(), anyPort: true);
    return true;
  } on ToolboxException {
    return false;
  }
}

class CinemaHttp {
  // 测试注入的客户端两路共用（MockClient 不经真的连接，只靠每一跳的地址核对）。
  // 接口请求按主机记新连接（CampusHttp.traced）：11-24 用户手机上有的源时好时坏、卡满 15 秒，用户选先取证，超时的日志写清卡在哪一步。
  CinemaHttp({http.Client? client}) : _http = client == null ? CampusHttp.traced('cinema') : CampusHttp('cinema', client: client), _media = client == null ? CampusHttp.publicOnly('cinema') : CampusHttp('cinema', client: client);
  // 接口（签名规则包里写的站点、境外转发、中转）与本机代理替第三方地址取东西的（只连公网）。
  final CampusHttp _http, _media;

  // 发一次接口请求，回复按 UTF-8 解成文字（容错坏字节）；非 2xx、超时、连不上都抛 CinemaHttpException（给用户看的原因）。
  // forward 不为空时发给境外转发，原地址放在查询串 u 里，请求头原样带上；转发服务自己出的错写在回复头 x-forward-error，
  // 按直连时的原因报（超时、回复太大、连不上），页面与日志的分类不变，别的一律算转发不可用。
  Future<String> text(CinemaPreparedRequest request, {required String userAgent, required String referer, Duration timeout = cinemaApiTimeout, Future<void>? cancel, Uri? forward}) async {
    final http.Response response;
    try {
      response = await _http.send(
        request.method,
        forward == null ? request.uri : forward.replace(queryParameters: {'u': request.uri.toString()}),
        timeout: timeout,
        limit: cinemaApiMaxBytes,
        headers: {...cinemaHeaders(userAgent, referer), ...cinemaApiHeaders, ...request.headers},
        body: request.body,
        cancel: cancel,
      );
    } on TimeoutException catch (error) {
      throw CinemaHttpException('超时', stage: error is CampusHttpTimeout ? error.stage : null);
    } on CampusHttpTooLarge {
      throw const CinemaHttpException('回复太大');
    } on http.RequestAbortedException {
      rethrow;
    } catch (error, stack) {
      campusLog('[Cinema] action=request errorType=${error.runtimeType}\n$stack');
      throw const CinemaHttpException('连不上');
    }
    final forwardError = forward == null ? null : response.headers['x-forward-error'];
    if (forwardError != null) {
      throw switch (forwardError) {
        'timeout' => const CinemaHttpException('超时', stage: 'forward'),
        'too_large' => const CinemaHttpException('回复太大'),
        'unreachable' => const CinemaHttpException('连不上'),
        _ => CinemaHttpException('转发不可用（HTTP ${response.statusCode}）', status: response.statusCode),
      };
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final challenge = cinemaChallenge(response);
      throw CinemaHttpException(
        challenge ? '暂不可用（HTTP ${response.statusCode}，人机验证）' : '暂不可用（HTTP ${response.statusCode}）',
        status: response.statusCode,
        refused: challenge || cinemaRefusedStatuses.contains(response.statusCode),
        challenge: challenge,
      );
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  // 本机代理取播放清单、密钥或探一下分片：自己跟跳转、每一跳只认公网（cinemaPublicUrl），返回最终地址与状态码（不因 4xx 抛错，调用方自己看）。
  // timeout 是整串跳转共用的总时限；cancel 完成即中断，抛 http.RequestAbortedException。
  Future<CinemaFetched> fetch(Uri uri, Map<String, String> headers, {int limit = cinemaPlaylistMaxBytes, Duration timeout = cinemaPlaylistTimeout, String? range, Future<void>? cancel}) async {
    final watch = Stopwatch()..start();
    var current = uri;
    for (var hop = 0; hop <= cinemaRedirectLimit; hop++) {
      if (!cinemaPublicUrl(current)) {
        campusLog('[Cinema] action=fetch blocked=private hop=$hop');
        throw const CinemaHttpException('地址不对');
      }
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero) throw const CinemaHttpException('超时');
      final http.Response response;
      try {
        response = await _media.send('GET', current, timeout: left, limit: limit, followRedirects: false, headers: {...headers, 'range': ?range}, cancel: cancel);
      } on TimeoutException {
        throw const CinemaHttpException('超时');
      } on CampusHttpTooLarge {
        throw const CinemaHttpException('回复太大');
      } on CampusHttpPrivateAddress {
        campusLog('[Cinema] action=fetch blocked=private_address hop=$hop');
        throw const CinemaHttpException('地址不对');
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

  void close() {
    _http.close();
    _media.close();
  }
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
