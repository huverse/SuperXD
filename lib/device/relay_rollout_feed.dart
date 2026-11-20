import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/device/signed_content.dart';

// 配置最多 rolloutRuleLimit 个开关、每个最多 rolloutStageLimit 档，明文加签名载荷两份也远不到 64KB；中转与 tool/rollout_config.dart 同一上限。
const rolloutResponseMaxBytes = 64 * 1024;

// 灰度配置的自建中转实现（人工决策见 domain/rollout.dart）：GET /v1/app/flags（第 2 版，没有时退回 /v1/app/rollout），请求免设备签名、不带任何标识，单次 15 秒超时、不自动重试。
// 经共用请求内核 CampusHttp 发（请求记录在内核里记，模块 rollout）。只认验签通过的内容（device/signed_content.dart 的 rollout 类）。
// 11-20 起第 2 版认条件请求（人工决策见 domain/rollout.dart 的 RolloutSignals）：带上次的版本号来，没变中转回 304，这里给出 config 为空。
class RelayRolloutFeed implements RolloutFeed {
  RelayRolloutFeed(this.baseUrl, {this.keys = trustedSigningKeys, http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('rollout', client: client);
  final String baseUrl;
  final List<TrustedSigningKey> keys;
  final Duration timeout;
  final CampusHttp _http;

  // 先拉第 2 版（/v1/app/flags，开关带条件与参数，人工决策见 domain/rollout.dart 文件头 11-16 那条）；中转还没放第 2 版（信封为空）
  // 或是还没部署这个接口的旧中转（404）时退回第 1 版 /v1/app/rollout。
  @override
  Future<RolloutFetch> fetch({String? etag}) async {
    final reply = await _get('/v1/app/flags', accept404: true, etag: etag);
    if (reply?.status == 304) return RolloutFetch(null, etag: reply!.etag ?? etag);
    final flags = reply?.body;
    if (reply != null) {
      // 不签名的 paused（自动暂停的分批更新）只拿来少提示，签名载荷里的不认。
      final paused = flags is Map ? decodeRolloutPaused(flags['paused']) : const <String>{};
      if (flags case {'version': 2, 'envelope': final Object envelope}) {
        return RolloutFetch(await _decode(() async => decodeRolloutConfig(jsonDecode(utf8.decode(await openSignedEnvelope(envelope, SignedContent.rollout, keys: keys)))).withPaused(paused)), etag: reply.etag);
      }
      if (flags case {'version': 2, 'envelope': null}) {
        campusLog('[Rollouts] action=feed source=legacy');
        final legacy = await _get('/v1/app/rollout');
        return RolloutFetch(await _decode(() async => (await decodeSignedRolloutConfig(legacy!.body, keys: keys)).withPaused(paused)), etag: reply.etag);
      } else {
        campusLog('[Rollouts] action=feed errorType=FormatException message=第 2 版回复不合法');
        throw const RolloutException('配置格式不对');
      }
    }
    final legacy = await _get('/v1/app/rollout');
    return RolloutFetch(await _decode(() => decodeSignedRolloutConfig(legacy!.body, keys: keys)));
  }

  // 取一份 JSON；accept404 为真时 404 返回空（旧中转没有这个接口）；带 etag 时中转没变回 304（body 为空）。
  Future<({int status, Object? body, String? etag})?> _get(String path, {bool accept404 = false, String? etag}) async {
    final http.Response response;
    try {
      response = await _http.send('GET', Uri.parse('$baseUrl$path'), timeout: timeout, limit: rolloutResponseMaxBytes, headers: {if (etag != null) 'if-none-match': '"$etag"'});
    } catch (error, stack) {
      campusLog('[Rollouts] action=feed errorType=${error.runtimeType}\n$stack');
      throw const RolloutException('连不上服务器');
    }
    if (accept404 && response.statusCode == 404) return null;
    final current = rolloutEtagOf(response.headers['etag']);
    if (etag != null && response.statusCode == 304) return (status: 304, body: null, etag: current);
    if (response.statusCode != 200) {
      campusLog('[Rollouts] action=feed status=${response.statusCode}');
      throw RolloutException('服务器回了 ${response.statusCode}');
    }
    try {
      return (status: 200, body: jsonDecode(utf8.decode(response.bodyBytes)), etag: current);
    } on FormatException catch (error, stack) {
      campusLog('[Rollouts] action=feed errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const RolloutException('配置格式不对');
    }
  }

  Future<RolloutConfig> _decode(Future<RolloutConfig> Function() decode) async {
    try {
      return await decode();
    } on SignedEnvelopeException catch (error, stack) {
      campusLog('[Rollouts] action=feed errorType=${error.runtimeType} reason=${error.reason}\n$stack');
      throw const RolloutException('配置没通过校验');
    } on FormatException catch (error, stack) {
      campusLog('[Rollouts] action=feed errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const RolloutException('配置格式不对');
    }
  }
}

// 中转的返回：明文 flags 一律不用，只取 envelope 验签。中转上还没放过配置时给空列表、不带信封，和扣下内容等效（签名挡不住扣下），按空配置处理。
Future<RolloutConfig> decodeSignedRolloutConfig(Object? response, {List<TrustedSigningKey> keys = trustedSigningKeys}) async {
  if (response is! Map) throw const FormatException('不是灰度配置');
  if (response['envelope'] == null && response['flags'] is List && (response['flags'] as List).isEmpty) return RolloutConfig.empty;
  final payload = await openSignedEnvelope(response['envelope'], SignedContent.rollout, keys: keys);
  return decodeRolloutConfig(jsonDecode(utf8.decode(payload)));
}
