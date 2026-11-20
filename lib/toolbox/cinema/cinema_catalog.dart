import 'dart:async';
import 'dart:isolate';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog_file.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_store.dart';

// [人工决策-2026-11-20 15:38:08] 片名目录型的源（用户要求把交接里的 wsy 按最佳实践接上；政策补正文、不升修订号，用户选定）：
// wsy 的采集接口把关键字搜索关了，交接靠本机十几万条的片名目录先找编号。这里按「服务器只发一份底包、手机直连上游补增量」做：
// - 底包由维护者本机抓（tool/cinema_catalog.dart）、放中转发布目录，规则包（签名的）里写它的文件名、SHA-256、大小与抓取起点，手机核对过才用；
// - 第一次搜这个源时下载底包（约 2MB）进本机库，之后隔 catalogRefreshGap 直接向这个源取最近 @hours 小时更新的几页补上，中转不经手；
// - 片名只在本机找，发给这个源的只有找到的编号（比别的源发片名还少）；
// - 搜索、补增量都只在用户搜这个源时发生，没同意过这个源不下载。
// 底包格式见 cinema_catalog_file.dart。

// 补增量的间隔、一次最多补几页（每页 20 条），离上次超过 catalogIncrementalLimit 就不补了、等维护者换新底包。
const catalogRefreshGap = Duration(hours: 1);
const catalogUpdatePages = 50;
const catalogIncrementalLimit = Duration(days: 30);
// 底包下载整次最多这么久（同字体包）。
const catalogDownloadTimeout = Duration(minutes: 3);
// 本机目录里找到的最多取这么多条详情（与别的源每源 20 条一致）。
const catalogHitLimit = 20;

class CinemaCatalog {
  CinemaCatalog(this._store, this._http, {required this.relay, required this._now});
  final CinemaStore _store;
  final CinemaHttp _http;
  // 中转地址（底包从它的 /v1/app/files 下载）；没配中转为空，片名目录型的源用不了。
  final Uri? relay;
  final DateTime Function() _now;
  final _ensuring = <String, Future<void>>{};
  final _refreshing = <String, Future<void>>{};

  // 本机还没有这个源的目录，或规则包换了更新的底包（起点比本机补到的还新）时下载导入；同一个源同时只下一份。
  // 收尾用块体：remove 会把这个 Future 自己交回给 whenComplete，它再等自己就卡死了。
  Future<void> ensure(CinemaRule rule) => _ensuring[rule.id] ??= _ensure(rule).whenComplete(() {
    _ensuring.remove(rule.id);
  });

  Future<void> _ensure(CinemaRule rule) async {
    final config = rule.catalog!;
    final meta = await _store.catalogMeta(rule.id);
    if (meta != null && (meta.file == config.file || !config.builtAt.isAfter(meta.syncedAt))) return;
    final base = relay;
    if (base == null) throw const CinemaHttpException('的片名目录现在下不了');
    final started = DateTime.now();
    final fetched = await _http.fetch(base.resolve('/v1/app/files/${config.file}'), const {}, limit: config.bytes, timeout: catalogDownloadTimeout);
    if (fetched.status != 200) throw CinemaHttpException('的片名目录暂不可用（HTTP ${fetched.status}）', status: fetched.status);
    final bytes = fetched.bytes, sha256 = config.sha256;
    final entries = await Isolate.run(() => decodeCinemaCatalog(bytes, sha256));
    await _store.replaceCatalog(rule.id, config.file, config.builtAt, entries.entries);
    campusLog('[Cinema] action=catalog_base rule=${rule.id} entries=${entries.entries.length} ms=${DateTime.now().difference(started).inMilliseconds}');
  }

  // 在本机目录里找片名，再把找到的编号一次发给这个源取详情（海报、年份、备注）；按本机的排序给出。之后在后台补一次增量。
  Future<List<CinemaHit>> search(CinemaRule rule, String keyword, {Future<void>? cancel}) async {
    await ensure(rule);
    final found = await _store.searchCatalog(rule.id, cinemaFold(keyword), limit: catalogHitLimit);
    unawaited(refresh(rule).catchError((Object error, StackTrace stack) => campusLog('[Cinema] action=catalog_refresh rule=${rule.id} errorType=${error.runtimeType}\n$stack')));
    if (found.isEmpty) return const [];
    final raw = await _http.text(prepareCinemaRequest(rule.search.request, {'ids': [for (final (source, _) in found) source].join(',')}), userAgent: rule.userAgent, referer: rule.referer, cancel: cancel);
    final hits = {for (final hit in parseCinemaSearch(raw, rule)) hit.source: hit};
    return [for (final (source, _) in found) ?hits[source]];
  }

  // 补增量：离上次补到的时刻超过 catalogRefreshGap 才补，按 @hours（多补一小时防漏）一页页取，最多 catalogUpdatePages 页；同一个源同时只补一份。
  Future<void> refresh(CinemaRule rule) => _refreshing[rule.id] ??= _refresh(rule).whenComplete(() {
    _refreshing.remove(rule.id);
  });

  Future<void> _refresh(CinemaRule rule) async {
    final config = rule.catalog!;
    final meta = await _store.catalogMeta(rule.id);
    final started = _now().toUtc();
    if (meta == null || started.difference(meta.syncedAt) < catalogRefreshGap) return;
    if (started.difference(meta.syncedAt) > catalogIncrementalLimit) {
      campusLog('[Cinema] action=catalog_refresh rule=${rule.id} skip=too_old');
      return;
    }
    final hours = (started.difference(meta.syncedAt).inMinutes / 60).ceil() + 1;
    final entries = <(String, String)>[];
    var pageCount = 1;
    for (var page = 1; page <= pageCount && page <= catalogUpdatePages; page++) {
      final raw = await _http.text(prepareCinemaRequest(config.update, {'hours': '$hours', 'page': '$page'}), userAgent: rule.userAgent, referer: rule.referer);
      final parsed = parseCinemaCatalogPage(raw, config);
      entries.addAll(parsed.entries);
      pageCount = parsed.pageCount;
    }
    final total = await _store.mergeCatalog(rule.id, started, entries);
    campusLog('[Cinema] action=catalog_refresh rule=${rule.id} hours=$hours added=${entries.length} pages=$pageCount total=$total');
  }
}
