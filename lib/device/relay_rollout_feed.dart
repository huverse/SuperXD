import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/device/signed_content.dart';

// 配置最多 rolloutRuleLimit 个开关、每个最多 rolloutStageLimit 档，明文加签名载荷两份也远不到 64KB；中转与 tool/rollout_config.dart 同一上限。
const rolloutResponseMaxBytes = 64 * 1024;

// 灰度配置的自建中转实现（人工决策见 domain/rollout.dart）：GET /v1/app/rollout，请求免设备签名、不带任何标识，单次 15 秒超时、不自动重试。
// 经共用请求内核 CampusHttp 发（请求记录在内核里记，模块 rollout）。只认验签通过的内容（device/signed_content.dart 的 rollout 类）。
class RelayRolloutFeed implements RolloutFeed {
  RelayRolloutFeed(this.baseUrl, {this.keys = trustedSigningKeys, http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('rollout', client: client);
  final String baseUrl;
  final List<TrustedSigningKey> keys;
  final Duration timeout;
  final CampusHttp _http;

  @override
  Future<RolloutConfig> fetch() async {
    final http.Response response;
    try {
      response = await _http.send('GET', Uri.parse('$baseUrl/v1/app/rollout'), timeout: timeout, limit: rolloutResponseMaxBytes);
    } catch (error, stack) {
      campusLog('[Rollouts] action=feed errorType=${error.runtimeType}\n$stack');
      throw const RolloutException('连不上服务器');
    }
    if (response.statusCode != 200) {
      campusLog('[Rollouts] action=feed status=${response.statusCode}');
      throw RolloutException('服务器回了 ${response.statusCode}');
    }
    try {
      return await decodeSignedRolloutConfig(jsonDecode(utf8.decode(response.bodyBytes)), keys: keys);
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
