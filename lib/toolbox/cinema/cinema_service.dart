import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pool/pool.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_proxy.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// [人工决策-2026-11-19 22:42:37] 百宝箱新增电影院（灰度测试，用户四项选择）：
// - 灰度：功能开关 toolbox.cinema（domain/feature_flags.dart 的 cinemaFlag），可按比例放量与点名，没登录应用账号的设备也能被比例抽中；
// - 积分授权预接好、不启用：以后按「有效期」卖（花积分买 N 天，到期时刻记在服务器、续买往后叠加），规则见服务端 src/modules/unlock/unlock_rules.ts；
// - 片源规则不进公开仓库：维护者本机签名后经中转下发（/v1/app/cinema，签名内容类型 cinema），应用不内置，第一次打开时拉取并缓存；
// - 播放器用 media_kit（libmpv，Kazumi 同款）。
// 服务器负担（用户要求尽量不在服务端处理）：搜索、选集、云解析、取流全在手机上直连片源，中转只发几 KB 的签名规则包；
// 交接原设计把视频字节经服务端转发（一个 1080p 观众约 3–8 Mbps），这里改成手机上的本机代理只改写 m3u8 文本、播放器直连 CDN。
// 规则写法借鉴 Kazumi（GPL-3.0，与本项目同许可，出处见 assets/third_party_notices.txt），第一版只做它的 API 模式；XPath 规则与网页嗅探下一轮做。

// 组合根注入的规则包来源：中转下发、验签通过的载荷字节，与本机构建号（规则包的 minClient 按它比）。
class CinemaRulesFeed {
  const CinemaRulesFeed({required this.fetch, required this.versionCode});
  final Future<Uint8List> Function() fetch;
  final Future<int> Function() versionCode;
}

// 同意的主体：一条片源规则或一个云解析，按接口主机认（换了主机要重新同意）。
String cinemaRuleSubject(CinemaRule rule) => 'rule:${rule.id}';
String cinemaParserSubject(CinemaParser parser) => 'parser:${parser.id}';

class CinemaPlayable {
  const CinemaPlayable({required this.uri, required this.headers});
  // 交给播放器的地址（m3u8 是本机代理地址）。
  final Uri uri;
  // 播放器取分片、密钥时带的请求头（规则的 UA，没写 Referer 就不带）。
  final Map<String, String> headers;
}

class CinemaService implements ToolboxService {
  CinemaService._(this.store, this._feed, this._directory, {CinemaHttp? http, DateTime Function()? now, Uri? relay})
    : _http = http ?? CinemaHttp(),
      _now = now ?? DateTime.now {
    _proxy = CinemaProxy(_http);
    cloud = CinemaCloudParse(_http, now: _now);
    catalog = CinemaCatalog(_http, relay: relay);
  }

  static const serviceId = 'cinema';
  // 积分时长券的编号（人工决策见 domain/pass.dart；中转的 passes.json 写了它才收，现在没写）。
  static const passId = 'toolbox.cinema';
  // 两次拉规则包至少隔这么久（同灰度配置）。
  static const refreshGap = Duration(hours: 1);
  // 同时搜几个源、每个源最多取几条。
  static const searchConcurrency = 6;
  static const hitsPerSource = 20;
  // [人工决策-2026-11-20 15:38:08] 边搜边显示、连续失败就暂停（用户选定，同 Kazumi、TVBox 类做法）：哪个源先回来先合进结果；
  // 同一个源连续失败 pauseAfter 次就暂停 pauseFor 不再去请求，列在「暂不可用」里，点重试（resume）立即恢复。暂停只记在内存（本次运行），不上传。
  static const pauseAfter = 3;
  static const pauseFor = Duration(minutes: 30);

  final CinemaStore store;
  final CinemaRulesFeed? _feed;
  final Directory _directory;
  final CinemaHttp _http;
  final DateTime Function() _now;
  late final CinemaProxy _proxy;
  late final CinemaCloudParse cloud;
  late final CinemaCatalog catalog;
  CinemaPackage? _package;
  Future<CinemaPackage>? _loading;
  // 各源连续失败几次、暂停到什么时刻（只在内存）。
  final _strikes = <String, int>{};
  final _pausedUntil = <String, DateTime>{};

  static Future<CinemaService> open(ToolboxServiceContext context, {required CinemaRulesFeed? feed, CinemaHttp? http, DateTime Function()? now, Uri? relay}) async {
    final directory = Directory(path.join(context.base.path, serviceId));
    await directory.create(recursive: true);
    final service = CinemaService._(await CinemaStore.open(path.join(directory.path, 'cinema.db')), feed, directory, http: http, now: now, relay: relay);
    final cached = await service.store.package();
    if (cached != null) {
      try {
        service._package = decodeCinemaPackage(cached.payload);
      } on CinemaRuleException catch (error) {
        campusLog('[Cinema] action=cached_package errorType=CinemaRuleException message=${error.message}');
      }
    }
    return service;
  }

  CinemaPackage? get package => _package;

  // 当前的规则包：本机没有或拉过超过 refreshGap 才去中转拉；拉不到照旧用本机的，本机也没有才报错。force 为真时不等间隔（页面上的「重试」）。
  Future<CinemaPackage> rules({bool force = false}) => _loading ??= _rules(force).whenComplete(() => _loading = null);

  Future<CinemaPackage> _rules(bool force) async {
    final cached = await store.package();
    final current = _package;
    final feed = _feed;
    if (feed == null || (!force && current != null && cached != null && _now().difference(cached.fetchedAt) < refreshGap)) {
      return current ?? (throw const CinemaRuleException('还没拿到片源规则'));
    }
    try {
      final payload = await feed.fetch();
      final fetched = decodeCinemaPackage(payload);
      if (current != null && fetched.version <= current.version) {
        await store.touchPackage(_now());
        return current;
      }
      if (fetched.minClient > await feed.versionCode()) {
        campusLog('[Cinema] action=rules skip=min_client version=${fetched.version}');
        if (current == null) throw const CinemaRuleException('片源规则要更新应用才能用');
        await store.touchPackage(_now());
        return current;
      }
      await store.savePackage(fetched.version, payload, _now());
      campusLog('[Cinema] action=rules version=${fetched.version} rules=${fetched.rules.length} parsers=${fetched.parsers.length}');
      return _package = fetched;
    } on CinemaRuleException catch (error) {
      campusLog('[Cinema] action=rules errorType=CinemaRuleException message=${error.message}');
      return current ?? (throw error);
    } catch (error, stack) {
      campusLog('[Cinema] action=rules errorType=${error.runtimeType}\n$stack');
      return current ?? (throw const CinemaRuleException('连不上服务器，拿不到片源规则'));
    }
  }

  // 还没同意过的（新源、换了主机的）。
  Future<List<CinemaRule>> unconsentedRules(CinemaPackage package) async {
    final granted = await store.consents();
    return [for (final rule in package.rules) if (granted[cinemaRuleSubject(rule)] != rule.host) rule];
  }

  Future<bool> parserConsented(CinemaParser parser) async => (await store.consents())[cinemaParserSubject(parser)] == parser.host;

  Future<void> grantRules(Iterable<CinemaRule> rules) => store.grant({for (final rule in rules) cinemaRuleSubject(rule): rule.host});

  Future<void> grantParser(CinemaParser parser) => store.grant({cinemaParserSubject(parser): parser.host});

  // 多源并行搜索（只搜同意过的源），按片名加年份聚合，边搜边给快照（CinemaSearchResult.pending 是还没回来的源数，最后一份为 0）。
  // 一个源失败只进 failures，不影响别的源；暂停着的源不去请求、直接列进 failures。结果按第一次出现的先后排、只往后加，搜的过程中不跳动。
  // cancel 完成时中断还没回来的请求。
  Stream<CinemaSearchResult> search(String keyword, {Future<void>? cancel}) async* {
    final package = await rules();
    final granted = await store.consents();
    final now = _now();
    final failures = <CinemaFailure>[];
    final active = <CinemaRule>[];
    for (final rule in package.rules) {
      if (granted[cinemaRuleSubject(rule)] != rule.host) continue;
      final until = _pausedUntil[rule.id];
      if (until != null && now.isBefore(until)) {
        failures.add(CinemaFailure(ruleId: rule.id, message: '${rule.name}连续没连上，${formatCampusClock(until)}前先不搜', paused: true));
      } else {
        active.add(rule);
      }
    }
    final titles = <String, CinemaTitle>{};
    var pending = active.length;
    CinemaSearchResult snapshot() => CinemaSearchResult(titles: [...titles.values], failures: [...failures], pending: pending);
    campusLog('[Cinema] action=search sources=${active.length} paused=${failures.length}');
    yield snapshot();
    if (active.isEmpty) return;
    final pool = Pool(searchConcurrency);
    final arrivals = StreamController<(CinemaRule, List<CinemaHit>?, CinemaFailure?)>();
    for (final rule in active) {
      unawaited(pool.withResource(() => _searchOne(rule, keyword, cancel)).then(arrivals.add));
    }
    await for (final (rule, hits, failure) in arrivals.stream.take(active.length)) {
      pending--;
      if (hits != null) {
        _strikes.remove(rule.id);
        for (final hit in hits.take(hitsPerSource)) {
          final key = cinemaTitleKey(hit.name, hit.year);
          final title = titles.putIfAbsent(key, () => CinemaTitle(key: key, name: hit.name, year: hit.year, cover: hit.cover, remarks: hit.remarks));
          title.addCover(hit.cover);
          if (title.sources.any((ref) => ref.ruleId == hit.ruleId && ref.source == hit.source)) continue;
          title.sources.add(CinemaSourceRef(ruleId: hit.ruleId, source: hit.source, name: hit.name, remarks: hit.remarks));
        }
      }
      if (failure != null) {
        failures.add(failure);
        final strikes = (_strikes[rule.id] ?? 0) + 1;
        _strikes[rule.id] = strikes;
        if (strikes >= pauseAfter) {
          _strikes.remove(rule.id);
          _pausedUntil[rule.id] = _now().add(pauseFor);
          campusLog('[Cinema] action=pause rule=${rule.id}');
        }
      }
      yield snapshot();
    }
    await arrivals.close();
    await pool.close();
    campusLog('[Cinema] action=search titles=${titles.length} failures=${failures.length}');
  }

  // 一个源搜一次：成功给结果，失败给原因，被取消（新的一次搜索顶掉或离开了页面）两个都为空、不算这个源失败。不抛错。
  Future<(CinemaRule, List<CinemaHit>?, CinemaFailure?)> _searchOne(CinemaRule rule, String keyword, Future<void>? cancel) async {
    try {
      if (rule.catalog != null) return (rule, await catalog.search(rule, keyword, cancel: cancel), null);
      final raw = await _http.text(prepareCinemaRequest(rule.search.request, {'keyword': keyword}), userAgent: rule.userAgent, referer: rule.referer, cancel: cancel);
      return (rule, parseCinemaSearch(raw, rule), null);
    } on CinemaHttpException catch (error) {
      return (rule, null, CinemaFailure(ruleId: rule.id, message: '${rule.name}${error.message}'));
    } on CinemaRuleException catch (error) {
      return (rule, null, CinemaFailure(ruleId: rule.id, message: '${rule.name}：${error.message}'));
    } on http.RequestAbortedException {
      return (rule, null, null);
    } catch (error, stack) {
      campusLog('[Cinema] action=search_source errorType=${error.runtimeType}\n$stack');
      return (rule, null, CinemaFailure(ruleId: rule.id, message: '${rule.name}出错了'));
    }
  }

  // 有没有暂停着的源（页面据此给「重试」）；resume 立即恢复全部。
  bool get hasPaused => _pausedUntil.values.any(_now().isBefore);

  void resume() {
    _pausedUntil.clear();
    _strikes.clear();
  }

  CinemaRule? rule(String id) => _package?.rules.where((rule) => rule.id == id).firstOrNull;

  // 一个源里这部片的选集（只留能直接播的线路），没有可播的报错让用户换源。
  Future<List<CinemaRoad>> chapters(CinemaRule rule, String source) async {
    final request = prepareCinemaRequest(rule.chapters.request, {'source': source});
    final raw = await _http.text(request, userAgent: rule.userAgent, referer: rule.referer);
    final roads = parseCinemaChapters(raw, rule, request.uri);
    if (roads.isEmpty) throw const CinemaRuleException('这个源没有能直接播的剧集，换一个源试试');
    return roads;
  }

  // 交给播放器的地址：m3u8 经本机代理改写清单，其余直接播；rule 为空（云解析的结果）时用默认 UA、不带 Referer、不去广告。
  Future<CinemaPlayable> playable(String url, {CinemaRule? rule, bool playlist = false}) async {
    final headers = cinemaHeaders(rule?.userAgent ?? '', rule?.referer ?? '');
    final uri = Uri.parse(url);
    if (!playlist && !cinemaPlaylistUrl(url)) return CinemaPlayable(uri: uri, headers: headers);
    return CinemaPlayable(uri: await _proxy.open(uri, CinemaStream(headers: headers, adBlocker: rule?.adBlocker ?? false)), headers: headers);
  }

  @override
  Future<void> close() async {
    await _proxy.close();
    _http.close();
    await store.close();
  }

  // 清除数据：删掉 cinema.db（规则包缓存、同意记录、看过的记录），再用要重新拉规则、重新同意。
  @override
  Future<void> clearData() async {
    await close();
    if (await _directory.exists()) await _directory.delete(recursive: true);
  }
}
