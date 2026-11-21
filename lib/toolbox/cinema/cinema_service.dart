import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pool/pool.dart';
import 'package:quiver/collection.dart';

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
  // 同时搜几个源、每个源最多取几条。各源是不同域名，一次全发（11-21 由 6 调到 16，现有 14 个源）：只有 6 路时，挂着的源要占名额到接口超时，
  // 其余的源排在后面等（DeepSeek 实测 10 个源 6 路 3.10 秒、10 路 1.82 秒）。
  static const searchConcurrency = 16;
  static const hitsPerSource = 20;
  // [人工决策-2026-11-20 15:38:08] 边搜边显示、连续失败就暂停（用户选定，同 Kazumi、TVBox 类做法）：哪个源先回来先合进结果；
  // 同一个源连续失败 pauseAfter 次就暂停 pauseFor 不再去请求，列在「暂不可用」里，点重试（resume）立即恢复。暂停只记在内存（本次运行），不上传。
  // [人工决策-2026-11-21 10:46:00] 暂停由 30 分钟缩短到 2 分钟（DeepSeek 建议，用户选定；没选 5 分钟、保持 30 分钟）：搜索一次全发后坏源不再拖慢别的源，
  // 暂停只为少打连着失败的源；偶发超时这类瞬时故障连着 3 次就被停半小时，源早恢复了还搜不到。同常见熔断的短冷却。
  static const pauseAfter = 3;
  static const pauseFor = Duration(minutes: 2);
  // 拉规则包失败后这么久内不再去拉（照旧用本机的；页面上的「重试」不等）：进页面、同意、搜索不会接连撞同一个失败的请求。
  static const retryGap = Duration(minutes: 5);
  // 选集在内存里留多久、最多几部（规则包换了版本即失效；播放地址可能带签名会过期，所以短；「重新载入」不用缓存）。
  static const chaptersLifetime = Duration(minutes: 10);
  static const chaptersLimit = 64;

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
  DateTime? _retryAt;
  // 选集缓存（键见 _chaptersKey）与正在取的（同一部片同时只发一次，几处一起等）。
  final _chapters = LruMap<String, (DateTime, List<CinemaRoad>)>(maximumSize: chaptersLimit);
  final _chaptersLoading = <String, CinemaShared<List<CinemaRoad>>>{};
  Map<String, CinemaSourceStat>? _stats;

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

  // 当前的规则包：本机没有或拉过超过 refreshGap 才去中转拉；拉不到照旧用本机的，本机也没有才报错；失败后 retryGap 内不再拉。
  // force 为真时不等间隔（页面上的「重试」）。本机有规则包时页面不必等它，见 cinema_page.dart 的 _initialize。
  Future<CinemaPackage> rules({bool force = false}) => _loading ??= _rules(force).whenComplete(() => _loading = null);

  // 现在能用的规则包：本机有就直接用（到了间隔顺带在后台更新，不等它），没有才等拉取。同意与搜索用它，后台刷新挡不住搜索。
  Future<CinemaPackage> usable() async {
    final current = _package;
    if (current == null) return rules();
    unawaited(rules().then<void>((_) {}, onError: (Object error, StackTrace stack) => campusLog('[Cinema] action=rules_background errorType=${error.runtimeType}\n$stack')));
    return current;
  }

  Future<CinemaPackage> _rules(bool force) async {
    final cached = await store.package();
    final current = _package;
    final feed = _feed;
    if (feed == null || (!force && current != null && cached != null && _now().difference(cached.fetchedAt) < refreshGap)) {
      return current ?? (throw const CinemaRuleException('还没拿到片源规则'));
    }
    final retryAt = _retryAt;
    if (!force && retryAt != null && _now().isBefore(retryAt)) return current ?? (throw const CinemaRuleException('连不上服务器，拿不到片源规则'));
    _retryAt = _now().add(retryGap);
    try {
      final payload = await feed.fetch();
      final fetched = decodeCinemaPackage(payload);
      if (current != null && fetched.version <= current.version) {
        _retryAt = null;
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
      _retryAt = null;
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
    final package = await usable();
    final granted = await store.consents();
    final now = _now();
    final failures = <CinemaFailure>[];
    final active = <CinemaRule>[];
    for (final rule in package.rules) {
      if (granted[cinemaRuleSubject(rule)] != rule.host) continue;
      final until = _pausedUntil[rule.id];
      if (until != null && now.isBefore(until)) {
        failures.add(CinemaFailure(ruleId: rule.id, name: rule.name, message: '${rule.name}连续没连上，${formatCampusClock(until)}前先不搜', paused: true));
      } else {
        active.add(rule);
      }
    }
    final titles = <String, CinemaTitle>{};
    var pending = active.length;
    CinemaSearchResult snapshot() => CinemaSearchResult(titles: [...titles.values], failures: [...failures], pending: pending);
    campusLog('[Cinema] action=search rules=${package.version} sources=${active.length} paused=${failures.length}');
    yield snapshot();
    if (active.isEmpty) return;
    // 开发者模式下逐源记从发出搜索到这个源回来用了多久（请求记录只有路径，各源同一个路径分不出是哪个源），用来在手机上比各源快慢。
    final watch = Stopwatch()..start();
    final pool = Pool(searchConcurrency);
    final arrivals = StreamController<(CinemaRule, List<CinemaHit>?, CinemaFailure?)>();
    for (final rule in active) {
      unawaited(pool.withResource(() => _searchOne(rule, keyword, cancel)).then(arrivals.add));
    }
    await for (final (rule, hits, failure) in arrivals.stream.take(active.length)) {
      pending--;
      if (campusDiagnostics) campusLog('[Cinema] action=search_arrival rule=${rule.id} ms=${watch.elapsedMilliseconds} hits=${hits?.length ?? '-'}');
      if (hits != null) {
        _strikes.remove(rule.id);
        for (final hit in hits.take(hitsPerSource)) {
          // 搜索回复自带剧集的源：记进选集缓存，点开不再请求详情。
          if (hit.roads case final roads? when roads.isNotEmpty) _chapters[_chaptersKey(rule, hit.source)] = (_now(), roads);
          final key = cinemaTitleKey(hit.name, hit.year);
          final title = titles.putIfAbsent(key, () => CinemaTitle(key: key, name: hit.name, year: hit.year, cover: hit.cover, remarks: hit.remarks));
          title.addCover(hit.cover);
          if (title.sources.any((ref) => ref.ruleId == hit.ruleId && ref.source == hit.source)) continue;
          title.sources.add(CinemaSourceRef(ruleId: hit.ruleId, source: hit.source, name: hit.name, remarks: hit.remarks));
        }
      }
      if (failure != null) {
        // 页面只写源名，原因（HTTP 状态、超时、看不懂回复）记在这里；不带搜的片名。
        campusLog('[Cinema] action=search_source rule=${rule.id} failed=${failure.message}');
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
      final request = prepareCinemaRequest(rule.search.request, {'keyword': keyword});
      final raw = await _http.text(request, userAgent: rule.userAgent, referer: rule.referer, cancel: cancel);
      return (rule, parseCinemaSearch(raw, rule, base: request.uri), null);
    } on CinemaHttpException catch (error) {
      return (rule, null, CinemaFailure(ruleId: rule.id, name: rule.name, message: '${rule.name}${error.message}'));
    } on CinemaRuleException catch (error) {
      return (rule, null, CinemaFailure(ruleId: rule.id, name: rule.name, message: '${rule.name}：${error.message}'));
    } on http.RequestAbortedException {
      return (rule, null, null);
    } catch (error, stack) {
      campusLog('[Cinema] action=search_source errorType=${error.runtimeType}\n$stack');
      return (rule, null, CinemaFailure(ruleId: rule.id, name: rule.name, message: '${rule.name}出错了'));
    }
  }

  // 有没有暂停着的源（页面据此给「重试」）；resume 立即恢复全部。
  bool get hasPaused => _pausedUntil.values.any(_now().isBefore);

  void resume() {
    _pausedUntil.clear();
    _strikes.clear();
  }

  CinemaRule? rule(String id) => _package?.rules.where((rule) => rule.id == id).firstOrNull;

  // 选集缓存的键：规则包版本、规则与它的版本、这个源里的编号（规则包换了或这条规则改了即对不上）。
  String _chaptersKey(CinemaRule rule, String source) => '${_package?.version}\u0000${rule.id}\u0000${rule.version}\u0000$source';

  // 一个源里这部片的选集（只留能直接播的线路），没有可播的报错让用户换源。先看缓存（搜索自带的、选集页取过的）；
  // 同一部片同时只发一次，选集页与播放页一起等；cancel 完成时这一处不等了（抛 RequestAbortedException），别处还在等就不中断请求。
  // fresh 为真时不用缓存（「重新载入」）。
  Future<List<CinemaRoad>> chapters(CinemaRule rule, String source, {bool fresh = false, Future<void>? cancel}) {
    final key = _chaptersKey(rule, source);
    final cached = _chapters[key];
    if (!fresh && cached != null && _now().difference(cached.$1) < chaptersLifetime) return Future.value(cached.$2);
    final loading = _chaptersLoading[key];
    if (!fresh && loading != null && loading.live) return loading.wait(cancel);
    late final CinemaShared<List<CinemaRoad>> shared;
    shared = _chaptersLoading[key] = CinemaShared((abort) => _fetchChapters(rule, source, key, abort, current: () => identical(_chaptersLoading[key], shared)));
    unawaited(shared.settled.then((_) {
      if (identical(_chaptersLoading[key], shared)) _chaptersLoading.remove(key);
    }));
    return shared.wait(cancel);
  }

  // current 为假时（「重新载入」另起了更新的一次）不写缓存：新的先回来、旧的后回来时，旧地址不会盖掉新的。
  Future<List<CinemaRoad>> _fetchChapters(CinemaRule rule, String source, String key, Future<void> abort, {required bool Function() current}) async {
    final request = prepareCinemaRequest(rule.chapters.request, {'source': source});
    final raw = await _http.text(request, userAgent: rule.userAgent, referer: rule.referer, cancel: abort);
    final roads = parseCinemaChapters(raw, rule, request.uri);
    if (roads.isEmpty) throw const CinemaRuleException('这个源没有能直接播的剧集，换一个源试试');
    if (current()) _chapters[key] = (_now(), roads);
    return roads;
  }

  // 交给播放器的地址：m3u8 经本机代理改写清单（不删分片，人工决策见 cinema_playlist.dart 文件头），其余直接播；rule 为空（云解析的结果）时用默认 UA、不带 Referer。
  // 换集、换源、离开播放页时交回 release，本机代理里这一路还没回来的请求随之中断。fresh（「重新载入」）时清单不用缓存、探测重新做。
  Future<CinemaPlayable> playable(String url, {CinemaRule? rule, bool playlist = false, bool fresh = false}) async {
    final headers = cinemaHeaders(rule?.userAgent ?? '', rule?.referer ?? '');
    final uri = Uri.parse(url);
    if (!playlist && !cinemaPlaylistUrl(url)) return CinemaPlayable(uri: uri, headers: headers);
    return CinemaPlayable(uri: await _proxy.open(uri, CinemaStream(headers: headers), fresh: fresh), headers: headers);
  }

  void release(CinemaPlayable playable) => _proxy.release(playable.uri);

  // [人工决策-2026-11-20 20:32:51] 预取（Codex 建议第 6 条，用户选「快播完时预取下一集，再加选集页预取当前集」）：选集页取到选集后预取「接着看」那一集（没看过就第一集），
  // 一集剩最后 2 分钟时预取下一集。只取播放清单（主清单再取第一个码率的子清单）并探好域名前置，几 KB，发给的是用户同意过的同一个片源站；
  // 结果在本机代理里留几分钟（直播清单不留），出错只记日志。直链（不是 m3u8）不预取。cancel 由发起的页面管（换源、离开时完成），别处还在等同一份就不中断。
  Future<void> warm(String url, {CinemaRule? rule, Future<void>? cancel}) async {
    if (!cinemaPlaylistUrl(url)) return;
    await _proxy.warm(Uri.parse(url), CinemaStream(headers: cinemaHeaders(rule?.userAgent ?? '', rule?.referer ?? '')), cancel: cancel);
  }

  // [人工决策-2026-11-20 20:32:51] 选源看能不能播（Codex 建议第 5 条，用户选「本机记录，能播的排前并标注」，没选只标注与自动换源）：
  // 播放页每次打开记一次结果（出了首帧算播成、记首帧用时；出错，或等了 15 秒还没出首帧就换集换源或离开，算没播成），只记在本机 cinema.db、30 天没再播的删掉；
  // 选集页按 rankCinemaSources 排片源、默认选最前面的，片源名后标「上次能播」「上次没播成」；不自动换源。
  Future<Map<String, CinemaSourceStat>> sourceStats() async => _stats ??= await store.sourceStats(_now());

  // 已经读过的播放结果（没读过为空），给不便等的地方用。
  Map<String, CinemaSourceStat> get knownStats => _stats ?? const {};

  Future<void> recordPlayback(String ruleId, {required bool ok, Duration? firstFrame}) async {
    final at = _now().toUtc();
    await store.recordPlayback(ruleId, ok: ok, firstFrame: firstFrame, at: at);
    final stats = await sourceStats();
    final old = stats[ruleId];
    stats[ruleId] = ok ? CinemaSourceStat(okAt: at, failAt: old?.failAt, firstFrame: firstFrame) : CinemaSourceStat(okAt: old?.okAt, failAt: at, firstFrame: old?.firstFrame);
    campusLog('[Cinema] action=playback rule=$ruleId ok=$ok firstFrameMs=${firstFrame?.inMilliseconds}');
  }

  @override
  Future<void> close() async {
    _chapters.clear();
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

// 片源的显示名：源名、这个源里的备注、最近的播放结果（选集页与播放页的片源菜单共用）。
String cinemaSourceLabel(CinemaService service, CinemaSourceRef ref) => [
  service.rule(ref.ruleId)?.name ?? ref.ruleId,
  if (ref.remarks.isNotEmpty) ref.remarks,
  ?cinemaSourceStatLabel(service.knownStats[ref.ruleId]),
].join(' · ');
