import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:superxd/toolbox/short_video/media_json.dart';
import 'package:superxd/toolbox/short_video/parse_http.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

class BugpkVideoParser implements ParseProvider {
  BugpkVideoParser({
    http.Client? client,
    Duration timeout = const Duration(seconds: 25),
  }) : _http = ParseHttp(client: client, timeout: timeout);
  final ParseHttp _http;
  @override
  final source = const ParseSource(
    id: 'bugpk',
    name: 'BugPK',
    host: 'api.bugpk.com',
    version: '2',
    consentVersion: 'bugpk-short-video-1',
  );
  @override
  bool supports(Uri uri) => const {'http', 'https'}.contains(uri.scheme);

  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async {
    toolboxPublicUrl(uri.toString());
    final douyin = uri.host == 'douyin.com' || uri.host.endsWith('.douyin.com');
    final paths = [if (douyin) '/api/douyin', '/api/short_videos'];
    for (var index = 0; index < paths.length; index++) {
      final watch = Stopwatch()..start();
      try {
        final data = await _http.get(
          Uri.https(source.host, paths[index], {'url': uri.toString()}),
          cancellation,
        );
        if (data['code'].toString() != '200') {
          throw const ParseFailure(
            ParseFailureCode.provider,
            '该作品暂时无法解析，请检查链接或稍后重试',
          );
        }
        if (data['data'] is! Map<String, dynamic>) {
          throw const ParseFailure(ParseFailureCode.provider, '解析结果格式不正确');
        }
        return normalize(data['data'] as Map<String, dynamic>, uri);
      } on ParseFailure catch (error, stack) {
        if (index == paths.length - 1 ||
            error.code == ParseFailureCode.cancelled ||
            error.code == ParseFailureCode.rateLimited ||
            error.code == ParseFailureCode.timeout) {
          rethrow;
        }
        campusLog(
          '[BugPK] action=aggregate_fallback errorType=${error.runtimeType}\n$stack',
        );
        final delay = source.interval - watch.elapsed;
        if (delay > Duration.zero) {
          await Future.any([Future<void>.delayed(delay), cancellation.signal]);
        }
        if (cancellation.isCancelled) {
          throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
        }
      }
    }
    throw const ParseFailure(ParseFailureCode.provider, '来源未返回结果');
  }

  ParseResult normalize(Map<String, dynamic> data, Uri sourceUrl) => normalizeMediaJson(data, sourceUrl, source.id);

  @override
  void close() => _http.close();
}
