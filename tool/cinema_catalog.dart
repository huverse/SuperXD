import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pool/pool.dart';

import 'package:superxd/toolbox/cinema/cinema_catalog_file.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';

import 'cinema_rules.dart';

// 电影院片名目录的底包（人工决策见 lib/toolbox/cinema/cinema_catalog.dart 文件头）：维护者本机按私有规则包里这个源的 update 请求，
// 把 @hours 填成很大的数（采集站的 ?ac=list&h= 按小时往回取，给够大就是全部）一页页抓完，写成底包文件；之后由 tool/cinema_publish.sh 签进规则包并上传。
// 每页 20 条，十几万条约六七千页，默认 4 路并行、每页最多试 3 次（这是维护者手动跑的工具，不受应用「不自动重试」的约束），抓不全就停、不写半份。
// 抓取起点（开始时刻）写进首行：手机从这一刻起直接向这个源补增量。
// 运行：dart run tool/cinema_catalog.dart --rule <规则 id> [--in <规则包>] [--out <底包>] [--hours 200000] [--concurrency 4]
//   底包默认 ~/.local/share/superxd-cinema/<规则 id>.tsv.gz；私有规则包里这条的 catalog.path 写同一个路径。
Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final ruleId = option('--rule');
  final hours = int.tryParse(option('--hours') ?? '200000'), concurrency = int.tryParse(option('--concurrency') ?? '4');
  if (ruleId == null || hours == null || concurrency == null || concurrency < 1 || concurrency > 8) {
    stderr.writeln('usage: dart run tool/cinema_catalog.dart --rule <id> [--in <rules.json>] [--out <file.tsv.gz>] [--hours 200000] [--concurrency 1-8]');
    exitCode = 64;
    return;
  }
  final source = option('--in') ?? defaultCinemaSource();
  final out = option('--out') ?? '${Platform.environment['HOME']}/.local/share/superxd-cinema/$ruleId.tsv.gz';
  final raw = jsonDecode(await File(source).readAsString());
  final entry = raw is Map && raw['catalogRules'] is List ? (raw['catalogRules'] as List).whereType<Map<String, Object?>>().where((rule) => rule['id'] == ruleId).firstOrNull : null;
  if (entry == null) {
    stderr.writeln('规则包里没有片名目录型的源 $ruleId');
    exitCode = 1;
    return;
  }
  final update = (entry['catalog'] as Map)['update'] as Map;
  final config = CinemaCatalogConfig(
    file: 'cinema-$ruleId-local.tsv.gz',
    sha256: '0' * 64,
    bytes: 1,
    builtAt: DateTime.utc(2000),
    update: CinemaRequest.decode(update['request'], 'update.request'),
    listPath: update['listPath'] as String,
    idPath: update['idPath'] as String,
    namePath: update['namePath'] as String,
    pageCountPath: update['pageCountPath'] as String,
  );
  final userAgent = (entry['userAgent'] as String?) ?? '';
  final client = http.Client();
  final started = DateTime.now().toUtc();

  Future<({List<(String, String)> entries, int pageCount})> page(int number) async {
    final request = prepareCinemaRequest(config.update, {'hours': '$hours', 'page': '$number'});
    for (var attempt = 1;; attempt++) {
      try {
        final response = await client.get(request.uri, headers: {...cinemaHeaders(userAgent, ''), ...request.headers}).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
        return parseCinemaCatalogPage(utf8.decode(response.bodyBytes, allowMalformed: true), config);
      } catch (error) {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  try {
    final first = await page(1);
    final entries = <String, String>{for (final (id, name) in first.entries) id: name};
    final pool = Pool(concurrency);
    var done = 1;
    await Future.wait([
      for (var number = 2; number <= first.pageCount; number++)
        pool.withResource(() async {
          for (final (id, name) in (await page(number)).entries) {
            entries.putIfAbsent(id, () => name);
          }
          if (++done % 200 == 0) stdout.writeln('[CinemaCatalog] action=progress pages=$done/${first.pageCount} entries=${entries.length}');
        }),
    ]);
    await pool.close();
    if (entries.length > cinemaCatalogEntryLimit) throw StateError('条数 ${entries.length} 超过上限 $cinemaCatalogEntryLimit');
    final bytes = encodeCinemaCatalog(started, [for (final item in entries.entries) (item.key, item.value)]);
    await File(out).parent.create(recursive: true);
    await File(out).writeAsBytes(bytes, flush: true);
    stdout.writeln('[CinemaCatalog] action=build rule=$ruleId pages=${first.pageCount} entries=${entries.length} bytes=${bytes.length} builtAt=${started.toIso8601String()} out=$out');
  } finally {
    client.close();
  }
}
