import 'package:http/http.dart' as http;

import 'package:superxd/toolbox/short_video/media_json.dart';
import 'package:superxd/toolbox/short_video/parse_http.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

// svparse 的密钥只在构建时经 --dart-define=SUPERXD_SVPARSE_KEY 注入（发版流水线取 release 环境的机密），不进公开仓库；没带的包不登记这个来源。
const svparseKey = String.fromEnvironment('SUPERXD_SVPARSE_KEY');

// 「BugPK 新版」来源：BugPK 开放平台 api-new.ifphp.com 的短视频解析聚合（svparse，33 个以上平台），回同一种统一 JSON 格式（见 media_json.dart）。
// [人工决策-2026-10-28 23:14:14] 用户选定接入：密钥构建时注入（安装包里能被拆出来，客户端内置密钥都这样）、作为新来源排在 BugPK 前面
// （自动解析先试它）、第一次用单独同意（授权版本 svparse-video-1）、隐私政策写明新域名并加修订号。
class SvparseVideoParser implements ParseProvider {
  SvparseVideoParser({
    required this.key,
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) : _http = ParseHttp(client: client, timeout: timeout);
  final String key;
  final ParseHttp _http;
  @override
  final source = const ParseSource(
    id: 'svparse',
    name: 'BugPK 新版',
    host: 'api-new.ifphp.com',
    version: '1',
    consentVersion: 'svparse-video-1',
  );
  @override
  bool supports(Uri uri) => const {'http', 'https'}.contains(uri.scheme);

  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async {
    toolboxPublicUrl(uri.toString());
    final body = await _http.get(
      Uri.https(source.host, '/api/svparse', {'key': key, 'url': uri.toString()}),
      cancellation,
    );
    // 业务结果看 JSON 里的 code：HTTP 200 不代表解析成功，失败时 data 是空数组。
    final code = body['code'].toString();
    if (code == '200' && body['data'] is Map<String, dynamic>) {
      return normalizeMediaJson(body['data'] as Map<String, dynamic>, uri, source.id);
    }
    campusLog('[Svparse] action=resolve errorType=BusinessCode code=$code');
    throw switch (code) {
      '429' => const ParseFailure(ParseFailureCode.rateLimited, '解析服务限流，请稍后再试', retryAfter: Duration(seconds: 30)),
      '401' => const ParseFailure(ParseFailureCode.provider, '解析来源暂不可用'),
      _ => const ParseFailure(ParseFailureCode.provider, '该作品暂时无法解析，请检查链接或稍后重试'),
    };
  }

  @override
  void close() => _http.close();
}
