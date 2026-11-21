import 'dart:async';
import 'dart:convert';

import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';

// [人工决策-2026-11-20 16:40:37] 片名目录型的源（用户要求把交接里的 wsy 按最佳实践接上；同日改为片名目录放中转，用户澄清「减少服务端压力」指流量，
// 另要求应用体积不做不必要的增长；隐私政策随之升修订 12，用户选定）：wsy 的采集接口把关键字搜索关了，片名目录由中转维护（服务端
// src/modules/cinema_catalog/cinema_catalog.service.ts，每小时向源补片名）。手机搜这个源时把片名 POST 给中转（不进地址），拿回最多 20 个编号，
// 再把编号一次发给这个源取详情（海报、年份、备注）；选集与取流照旧直连源。手机上不下载、不存目录，一次搜索来回几 KB。

// 中转回的编号最多这么多个（同服务端 cinemaCatalogHits），每个编号最长 64 个字。
const catalogHitLimit = 20;

class CinemaCatalog {
  CinemaCatalog(this._http, {required this.relay});
  final CinemaHttp _http;
  // 中转地址；没配中转为空，片名目录型的源用不了。
  final Uri? relay;

  // 请中转查编号，再向源取详情，按中转给的先后排（完全一样的片名在前）。
  Future<List<CinemaHit>> search(CinemaRule rule, String keyword, {Future<void>? cancel}) async {
    final base = relay;
    if (base == null) throw const CinemaHttpException('现在用不了（没配服务器）');
    final reply = await _http.text(
      CinemaPreparedRequest(method: 'POST', uri: base.resolve('/v1/app/cinema/catalogs/${rule.id}/search'), headers: const {'content-type': 'application/json'}, body: jsonEncode({'q': keyword})),
      userAgent: '',
      referer: '',
      cancel: cancel,
    );
    final ids = decodeCatalogIds(reply);
    if (ids.isEmpty) return const [];
    final detail = prepareCinemaRequest(rule.search.request, {'ids': ids.join(',')});
    final raw = await _http.text(detail, userAgent: rule.userAgent, referer: rule.referer, cancel: cancel, forward: rule.forward);
    final hits = {for (final hit in parseCinemaSearch(raw, rule, base: detail.uri)) hit.source: hit};
    return [for (final id in ids) ?hits[id]];
  }
}

// 中转的回复是外部输入：{ids: [编号]}，不超过 catalogHitLimit 个、每个是 1–64 个字的非空串，不合格整份不用。
List<String> decodeCatalogIds(String raw) {
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    throw const CinemaRuleException('片名目录的回复看不懂');
  }
  if (json case {'ids': final List<Object?> ids} when ids.length <= catalogHitLimit && ids.every((id) => id is String && id.isNotEmpty && id.length <= 64)) {
    return ids.cast<String>();
  }
  throw const CinemaRuleException('片名目录的回复看不懂');
}
