import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog.dart';
import 'package:superxd/toolbox/cinema/cinema_detail_page.dart';
import 'package:superxd/toolbox/cinema/cinema_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_episodes.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_consent.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_page.dart';
import 'package:superxd/toolbox/cinema/cinema_playback_truth.dart';
import 'package:superxd/toolbox/cinema/cinema_player_controls.dart';
import 'package:superxd/toolbox/cinema/cinema_player_page.dart';
import 'package:superxd/toolbox/cinema/cinema_playlist.dart';
import 'package:superxd/toolbox/cinema/cinema_poster.dart';
import 'package:superxd/toolbox/cinema/cinema_proxy.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/cinema/cinema_store.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'toolbox_test_support.dart';

// 电影院（人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头）：规则包的校验、规则引擎（搜索与苹果 CMS 选集）、播放清单改写、
// 云解析的判定与解密、本机库的保留、服务的规则拉取与搜索聚合、本机代理、灰度开关藏起入口。全部用合成数据与假的站点，不连真实片源。

// 一条合成的苹果 CMS 规则（同维护者规则包的写法，地址是假的）。
Map<String, Object?> macCmsRule(String id, String api, {String name = '合成资源'}) => {
  'id': id,
  'api': '1',
  'type': 'movie',
  'name': name,
  'version': '1',
  'userAgent': '',
  'referer': '',
  // 线上第 4 版以前的规则包都写着 true：照样能解，播放清单也不删分片（人工决策见 cinema_playlist.dart 文件头）。
  'adBlocker': true,
  'searchMode': 'api',
  'chapterMode': 'api',
  'searchApiConfig': {
    'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'wd': '@keyword'}},
    'listPath': r'$.list[*]',
    'namePath': r'$.vod_name',
    'sourcePath': r'$.vod_id',
    'coverPath': r'$.vod_pic',
    'yearPath': r'$.vod_year',
    'remarksPath': r'$.vod_remarks',
  },
  'chapterApiConfig': {
    'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'ids': '@source'}},
    'format': 'delimited',
    'roadNamesPath': r'$.list[0].vod_play_from',
    'roadEpisodesPath': r'$.list[0].vod_play_url',
  },
};

final testCipher = (key: 'ABCDEFGHIJKLMNOP', iv: 'abcdefghijklmnop');

Map<String, Object?> parserRule() => {
  'id': 'cloud',
  'name': '合成云解析',
  'request': {'method': 'POST', 'url': 'https://parse.example.com/api.php', 'bodyType': 'form', 'body': {'url': '@url'}},
  'codePath': r'$.code',
  'okCode': '200',
  'titlePath': r'$.title',
  'urlPath': r'$.url',
  'typePath': r'$.type',
  'cipher': {'algorithm': 'aes-128-cbc', 'key': testCipher.key, 'iv': testCipher.iv},
};

List<int> packageBytes({int version = 1, int minClient = 0, List<Map<String, Object?>>? rules, List<Map<String, Object?>> catalogRules = const [], String? forward}) => utf8.encode(jsonEncode({
  'format': 1,
  'version': version,
  'minClient': minClient,
  'forward': ?forward,
  'rules': rules ?? [macCmsRule('alpha', 'https://alpha.example.com/api.php/provide/vod/'), macCmsRule('beta', 'https://beta.example.com/api.php/provide/vod', name: '另一资源')],
  'catalogRules': catalogRules,
  'parsers': [parserRule()],
}));

// 片名目录型的源（同 wsy）：搜索请求按 @ids 取详情；目录在中转上，update 是给中转抓片名的请求（@hours、@page）。
Map<String, Object?> catalogRule(String id, String api, {String name = '目录资源'}) {
  final rule = macCmsRule(id, api, name: name);
  final search = rule['searchApiConfig']! as Map<String, Object?>;
  return {
    ...rule,
    'searchMode': 'catalog',
    'searchApiConfig': {...search, 'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'ids': '@ids'}}},
    'catalog': {
      'update': {
        'request': {'method': 'GET', 'url': api, 'query': {'ac': 'list', 'h': '@hours', 'pg': '@page'}},
        'listPath': r'$.list[*]',
        'idPath': r'$.vod_id',
        'namePath': r'$.vod_name',
        'pageCountPath': r'$.pagecount',
      },
    },
  };
}

Future<String> encryptForTest(String plain) async {
  final box = await AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty).encrypt(utf8.encode(plain), secretKey: SecretKey(utf8.encode(testCipher.key)), nonce: utf8.encode(testCipher.iv));
  return base64.encode(box.cipherText);
}

// 替身回复一律按 UTF-8 字节给（http.Response 的字符串构造默认按 Latin-1 编码，中文会报错）。
http.Response reply(String body, int status, {Map<String, String> headers = const {}}) => http.Response.bytes(utf8.encode(body), status, headers: headers);

// 搜索回复每条自带剧集的写法（search.chapters，路径相对每一条）。
Map<String, Object?> macCmsRuleWithChapters(String id, String api) {
  final rule = macCmsRule(id, api);
  return {
    ...rule,
    'searchApiConfig': {...(rule['searchApiConfig']! as Map<String, Object?>), 'chapters': {'roadNamesPath': r'$.vod_play_from', 'roadEpisodesPath': r'$.vod_play_url'}},
  };
}

// 规则写了分类路径（苹果 CMS 的 type_name）。
Map<String, Object?> withCategory(Map<String, Object?> rule) => {...rule, 'searchApiConfig': {...(rule['searchApiConfig']! as Map<String, Object?>), 'categoryPath': r'$.type_name'}};

// 开发者模式下截下日志（测完恢复）。
List<String> captureDiagnostics() {
  final logs = <String>[];
  final previous = campusLog;
  campusLog = logs.add;
  campusDiagnostics = true;
  addTearDown(() {
    campusLog = previous;
    campusDiagnostics = false;
  });
  return logs;
}

// 绕开测试框架装的假 HttpClient，真的连本机代理。
Future<(int, String)> getLocal(Uri uri) => HttpOverrides.runWithHttpOverrides(() async {
  final local = HttpClient();
  try {
    final response = await (await local.getUrl(uri)).close();
    return (response.statusCode, await utf8.decodeStream(response));
  } finally {
    local.close(force: true);
  }
}, _RealHttp());

String macCmsList(List<Map<String, Object?>> items) => jsonEncode({'code': 1, 'msg': '数据列表', 'page': '1', 'pagecount': 1, 'total': items.length, 'list': items});

// 页面测试用的电影院：真的服务与本机库（测试目录里），片源请求走给的替身。
Future<(ToolboxFixture, CinemaService)> openCinemaForPage(WidgetTester tester, {http.Client? client, List<int>? package}) async {
  final fixture = ToolboxFixture();
  await tester.runAsync(fixture.initialize);
  addTearDown(() => tester.runAsync(fixture.close));
  final service = (await tester.runAsync(
    () => CinemaService.open(
      ToolboxServiceContext(base: fixture.directory, store: fixture.store, downloads: fixture.manager),
      feed: CinemaRulesFeed(fetch: () async => Uint8List.fromList(package ?? packageBytes()), versionCode: () async => 40),
      http: CinemaHttp(client: client ?? MockClient((request) async => reply('', 404))),
    ),
  ))!;
  addTearDown(() => tester.runAsync(service.close));
  return (fixture, service);
}

// 让真实的异步（本机库、替身回复）走完，直到 done 为真（最多约 1 秒）。
// 纯 test() 里按条件等（最多 5 秒）：搜索先读本机库（sqflite 在另一个 isolate、按真实时间完成），只让出几轮事件循环不一定够，
// CI 忙时会还没发出请求就断言（11-21 #342 的 CI 踩过「一次搜索 14 个源同时发出」拿到 0 个请求）。
Future<void> untilTrue(bool Function() done) async {
  for (var waited = 0; !done() && waited < 5000; waited += 10) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  for (var index = 0; index < 50 && !done(); index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  group('规则包', () {
    // 人工决策见 cinema_rule.dart 的 CinemaRule.forward（11-21 国内连不上的源走境外转发）。
    test('境外转发：规则写 forward 要规则包有 https 的转发地址、只支持 GET；改走转发的源同意记录对不上（要重新同意），同意弹窗写明', () {
      Map<String, Object?> forwarded(Map<String, Object?> rule) => {...rule, 'forward': true};
      const edge = 'https://edge.example.net/v1/forward';
      final direct = decodeCinemaPackage(packageBytes());
      final package = decodeCinemaPackage(packageBytes(forward: edge, rules: [forwarded(macCmsRule('alpha', 'https://alpha.example.com/api.php/provide/vod/')), macCmsRule('beta', 'https://beta.example.com/api.php/provide/vod', name: '另一资源')]));
      expect(package.rules.first.forward, Uri.parse(edge));
      expect(package.rules.last.forward, isNull);
      expect(package.rules.first.host, isNot(direct.rules.first.host));
      expect(package.rules.last.host, direct.rules.last.host);
      expect(cinemaConsentName(package.rules.first), '合成资源（经开发者的境外转发，不保存）');
      expect(cinemaConsentName(package.rules.last), '另一资源');
      expect(() => decodeCinemaPackage(packageBytes(rules: [forwarded(macCmsRule('alpha', 'https://alpha.example.com/api.php'))])), throwsA(isA<CinemaRuleException>()), reason: '规则包没写转发地址');
      for (final bad in ['http://edge.example.net/f', 'https://edge.example.net/f?x=1', 'https://edge.example.net:8443/f', 'https://user@edge.example.net/f']) {
        expect(() => decodeCinemaPackage(packageBytes(forward: bad)), throwsA(isA<CinemaRuleException>()), reason: bad);
      }
      final post = forwarded(macCmsRule('alpha', 'https://alpha.example.com/api.php'));
      post['searchApiConfig'] = {...(post['searchApiConfig']! as Map<String, Object?>), 'request': {'method': 'POST', 'url': 'https://alpha.example.com/api.php', 'bodyType': 'form', 'body': {'wd': '@keyword'}}};
      expect(() => decodeCinemaPackage(packageBytes(forward: edge, rules: [post])), throwsA(isA<CinemaRuleException>()), reason: '走转发只支持 GET');
    });

    test('合法的包解得出；规则 id、主机与路径都在', () {
      final package = decodeCinemaPackage(packageBytes(version: 3));
      expect(package.version, 3);
      expect([for (final rule in package.rules) rule.id], ['alpha', 'beta']);
      expect(package.rules.first.host, 'alpha.example.com');
      expect(package.parsers.single.cipher?.key, hasLength(16));
    });

    test('不合格整包拒收：XPath 模式、重复 id、过滤表达式、搜索不用 @keyword、写法版本不对、密钥长度不对、太大', () {
      void rejects(Object? Function(Map<String, Object?> rule) edit, {Map<String, Object?>? package}) {
        final rule = macCmsRule('alpha', 'https://alpha.example.com/api.php');
        final changed = edit(rule);
        final raw = package ?? {'format': 1, 'version': 1, 'rules': [changed ?? rule]};
        expect(() => decodeCinemaPackage(utf8.encode(jsonEncode(raw))), throwsA(isA<CinemaRuleException>()));
      }

      rejects((rule) => rule..['searchMode'] = 'xpath');
      rejects((rule) => null, package: {'format': 1, 'version': 1, 'rules': [macCmsRule('alpha', 'https://a.example.com/'), macCmsRule('alpha', 'https://b.example.com/')]});
      rejects((rule) => rule..['searchApiConfig'] = {...(rule['searchApiConfig'] as Map), 'listPath': r'$.list[?(@.x)]'});
      rejects((rule) => rule..['searchApiConfig'] = {...(rule['searchApiConfig'] as Map), 'request': {'method': 'GET', 'url': 'https://a.example.com/'}});
      rejects((rule) => null, package: {'format': 2, 'version': 1, 'rules': [macCmsRule('alpha', 'https://a.example.com/')]});
      rejects((rule) => null, package: {'format': 1, 'version': 1, 'rules': [macCmsRule('alpha', 'https://a.example.com/')], 'parsers': [parserRule()..['cipher'] = {'algorithm': 'aes-128-cbc', 'key': 'short', 'iv': testCipher.iv}]});
      expect(() => decodeCinemaPackage(List.filled(cinemaPackageMaxBytes + 1, 32)), throwsA(isA<CinemaRuleException>()));
    });

    test('片名目录型的源放在 catalogRules：接在普通源后面；详情要用 @ids，增量请求要用 @hours 与 @page，不合格整包拒收', () {
      Map<String, Object?> catalog() => catalogRule('wsy', 'https://wsy.example.com/api.php');
      Map<String, Object?> update() => (catalog()['catalog']! as Map<String, Object?>)['update']! as Map<String, Object?>;
      final package = decodeCinemaPackage(packageBytes(catalogRules: [catalog()]));
      expect([for (final rule in package.rules) (rule.id, rule.catalog != null)], [('alpha', false), ('beta', false), ('wsy', true)]);
      final wrong = <Map<String, Object?>>[
        {...catalog(), 'searchMode': 'api'},
        {...catalog(), 'searchApiConfig': macCmsRule('wsy', 'https://wsy.example.com/api.php')['searchApiConfig']},
        {...catalog(), 'catalog': {'update': {...update(), 'request': {'method': 'GET', 'url': 'https://wsy.example.com/'}}}},
        {...catalog(), 'catalog': {'update': {...update(), 'request': {'method': 'POST', 'url': 'https://wsy.example.com/?h=@hours&pg=@page'}}}},
        {...catalog(), 'catalog': {'update': {...update(), 'listPath': r'$.list[?(@.x)]'}}},
        {...catalog(), 'id': 'alpha'},
      ];
      for (final (index, rule) in wrong.indexed) {
        expect(() => decodeCinemaPackage(packageBytes(catalogRules: [rule])), throwsA(isA<CinemaRuleException>()), reason: '第 $index 个');
      }
    });
  });

  test('搜索配置可以带每条自带的剧集路径（search.chapters，格式同选集）；路径写法不对整包拒收；不带为空', () {
    final rule = decodeCinemaPackage(packageBytes(rules: [macCmsRuleWithChapters('alpha', 'https://alpha.example.com/api.php')])).rules.single;
    expect((rule.search.chapters?.roadNamesPath, rule.search.chapters?.format), (r'$.vod_play_from', 'delimited'));
    expect(decodeCinemaPackage(packageBytes()).rules.first.search.chapters, isNull);
    final broken = macCmsRuleWithChapters('alpha', 'https://alpha.example.com/api.php');
    (broken['searchApiConfig']! as Map<String, Object?>)['chapters'] = {'roadNamesPath': r'$.vod_play_from'};
    expect(() => decodeCinemaPackage(packageBytes(rules: [broken])), throwsA(isA<CinemaRuleException>()));
  });

  group('规则引擎', () {
    final rule = decodeCinemaPackage(packageBytes()).rules.first;

    test('填模板：@keyword 进查询串并编码，地址原有的查询保留；表单按 form 编码；缺变量报错', () {
      final request = prepareCinemaRequest(rule.search.request, {'keyword': '合成 片名&'});
      expect(request.uri.host, 'alpha.example.com');
      expect(request.uri.queryParameters, {'ac': 'detail', 'wd': '合成 片名&'});
      final parser = decodeCinemaPackage(packageBytes()).parsers.single;
      final post = prepareCinemaRequest(parser.request, {'url': 'https://v.example.com/x?a=1'});
      expect(post.method, 'POST');
      expect(post.headers['content-type'], 'application/x-www-form-urlencoded');
      expect(post.body, 'url=${Uri.encodeQueryComponent('https://v.example.com/x?a=1')}');
      expect(() => prepareCinemaRequest(rule.search.request, const {}), throwsA(isA<CinemaRuleException>()));
    });

    test('搜索：回复按 JSON 解（不看 Content-Type），缺名字或编号的跳过，年份只留四位数字', () {
      final hits = parseCinemaSearch(macCmsList([
        {'vod_id': 90305, 'vod_name': ' 合成剧 第二季 ', 'vod_year': '2024', 'vod_pic': 'https://img.example.com/a.jpg', 'vod_remarks': '第36集完结'},
        {'vod_id': 2, 'vod_name': '', 'vod_year': '2020'},
        {'vod_id': 3, 'vod_name': '合成电影', 'vod_year': '2019年'},
      ]), rule);
      expect([for (final hit in hits) (hit.source, hit.name, hit.year)], [('90305', '合成剧 第二季', '2024'), ('3', '合成电影', '')]);
      expect(hits.first.cover, 'https://img.example.com/a.jpg');
      expect(() => parseCinemaSearch('暂不支持搜索', rule), throwsA(isA<CinemaRuleException>()));
    });

    test('搜索：规则写了 categoryPath 的取出分类（预告片、纪录片、解说），没写为空', () {
      final categorized = decodeCinemaPackage(packageBytes(rules: [withCategory(macCmsRule('alpha', 'https://alpha.example.com/api.php'))])).rules.single;
      final raw = macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'type_name': '预告片'}]);
      expect(parseCinemaSearch(raw, categorized).single.category, '预告片');
      expect(parseCinemaSearch(raw, rule).single.category, '');
    });

    // 11-21 Codex 指出：金鹰、光速 HTTP 200 回「服务器繁忙」，原来当成搜不到。
    test('搜不到与回复不对分开：list 是空数组或 null（如意）是搜不到；连 list 都没有、是别的类型、不是 JSON 都报错；上游的 msg 不进原因（可能带着片名）', () {
      expect(parseCinemaSearch('{"code":1,"msg":"数据列表","list":[]}', rule), isEmpty);
      expect(parseCinemaSearch('{"code":1,"msg":"数据列表","list":null}', rule), isEmpty);
      Matcher fails(String message) => throwsA(isA<CinemaRuleException>().having((error) => error.message, 'message', message));
      expect(() => parseCinemaSearch('{"code":1,"msg":"服务器繁忙，请稍后搜索"}', rule), fails('回复里没有结果列表'));
      expect(() => parseCinemaSearch('{"code":1,"msg":"没有找到合成电影"}', rule), fails('回复里没有结果列表'));
      expect(() => parseCinemaSearch('[]', rule), fails('回复里没有结果列表'));
      expect(() => parseCinemaSearch('{"list":"维护中"}', rule), fails('结果列表格式不对'));
      expect(() => parseCinemaSearch('{"list":{}}', rule), fails('结果列表格式不对'));
      expect(() => parseCinemaSearch('<html>验证</html>', rule), fails('返回的不是 JSON'));
    });

    String chapters(String from, String url) => macCmsList([{'vod_id': 1, 'vod_name': '合成剧', 'vod_play_from': from, 'vod_play_url': url}]);
    final requestUri = Uri.parse('https://alpha.example.com/api.php/provide/vod/?ac=detail&ids=1');

    test('选集（交接 06 第 2 节的四条，换成合成地址）：只留直链线路、缺省集名按序号、非法地址丢掉、空线路整条不要', () {
      var roads = parseCinemaChapters(chapters(r'share$$$m3u8', r'第01集$https://cdn.example.com/play/a$$$第01集$https://cdn.example.com/play/a/index.m3u8'), rule, requestUri);
      expect([for (final road in roads) road.name], ['m3u8']);
      expect(roads.single.episodes.single.url, 'https://cdn.example.com/play/a/index.m3u8');
      roads = parseCinemaChapters(chapters('m3u8', r'第01集$https://cdn.example.com/1.m3u8#第02集$https://cdn.example.com/2.m3u8#https://cdn.example.com/3.m3u8'), rule, requestUri);
      expect([for (final episode in roads.single.episodes) episode.name], ['第01集', '第02集', '第 3 集']);
      roads = parseCinemaChapters(chapters('m3u8', r'第01集$javascript:alert(1)#第02集$https://cdn.example.com/2.m3u8#第03集$https://user:pass@cdn.example.com/3.m3u8'), rule, requestUri);
      expect([for (final episode in roads.single.episodes) episode.name], ['第02集']);
      expect(parseCinemaChapters(chapters('share', r'第01集$https://cdn.example.com/play/a'), rule, requestUri), isEmpty);
    });

    test('搜索自带剧集：每条按自己的记录解（不是都配上第一条的），相对地址按搜索地址补全；规则没写为空', () {
      final rule = decodeCinemaPackage(packageBytes(rules: [macCmsRuleWithChapters('alpha', 'https://alpha.example.com/api.php')])).rules.single;
      final raw = macCmsList([
        {'vod_id': 1, 'vod_name': '甲', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/a/index.m3u8'},
        {'vod_id': 2, 'vod_name': '乙', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$/b/index.m3u8'},
      ]);
      final hits = parseCinemaSearch(raw, rule, base: Uri.parse('https://alpha.example.com/api.php?ac=detail'));
      expect([for (final hit in hits) hit.roads!.single.episodes.single.url], ['https://cdn.example.com/a/index.m3u8', 'https://alpha.example.com/b/index.m3u8']);
      expect(parseCinemaSearch(raw, decodeCinemaPackage(packageBytes()).rules.first).first.roads, isNull);
    });

    test('选集：相对地址按选集请求的地址补全', () {
      final roads = parseCinemaChapters(chapters('m3u8', r'正片$/videos/1/index.m3u8'), rule, requestUri);
      expect(roads.single.episodes.single.url, 'https://alpha.example.com/videos/1/index.m3u8');
    });

    test('聚合键（交接 06 第 4 节）：去空白、全角空格与全角字母折成半角、转小写，年份不是四位数字为空', () {
      expect(cinemaTitleKey('庆余年 第二季', '2024'), '庆余年第二季|2024');
      expect(cinemaTitleKey('庆余年　第二季', '2024'), '庆余年第二季|2024');
      expect(cinemaTitleKey('庆余年第二季', ''), '庆余年第二季|');
      expect(cinemaTitleKey('庆余年', '2019年'), '庆余年|');
      expect(cinemaTitleKey('ＡＢＣ Movie', '2020'), 'abcmovie|2020');
    });
  });

  // 11-21 Codex 总交接：换源集名要一字不差、晚到的源进不了菜单；看完的再打开停在片尾（人工决策见 CinemaHistory.finished）。
  group('换源与看完', () {
    test('集号：第01集、第1集、01、EP1、1、第1话都是 1；特别篇、预告、上下集、正片、HD中字没有集号', () {
      for (final name in ['第01集', '第1集', '01', 'EP1', 'ep01', '1', '第1话', '第 1 集', 'Ｅ１']) {
        expect(cinemaEpisodeNumber(name), 1, reason: name);
      }
      for (final name in ['第1集特别篇', '预告', '第1集上', '正片', 'HD中字', '1080P', '第一集', '20231201期']) {
        expect(cinemaEpisodeNumber(name), isNull, reason: name);
      }
    });

    test('换源找同一集：先比原名，再比集号，两边都只有一集按同一集；不知道原名时按第几集；找不到为 -1', () {
      List<CinemaEpisode> named(List<String> names) => [for (final name in names) CinemaEpisode(name: name, url: 'https://media.example.com/$name.mp4')];
      expect(cinemaMatchEpisode(named(['第1集', '第01集', '第02集']), '第01集', index: 0, single: false), 1, reason: '原名优先');
      expect(cinemaMatchEpisode(named(['第01集', '第02集', '第03集']), '第2集', index: 0, single: false), 1);
      expect(cinemaMatchEpisode(named(['EP1', 'EP2']), '02', index: 0, single: false), 1);
      expect(cinemaMatchEpisode(named(['第1集', '第1集特别篇']), '第1集特别篇', index: 0, single: false), 1);
      expect(cinemaMatchEpisode(named(['第1集', '第2集']), '第1集特别篇', index: 0, single: false), -1, reason: '特别篇不配到正片');
      expect(cinemaMatchEpisode(named(['HD中字']), '正片', index: 0, single: true), 0, reason: '电影两边都只有一集');
      expect(cinemaMatchEpisode(named(['HD中字', '预告']), '正片', index: 0, single: true), -1);
      expect(cinemaMatchEpisode(named(['HD中字']), '正片', index: 0, single: false), -1);
      expect(cinemaMatchEpisode(named(['第1集', '第2集', '第3集']), null, index: 2, single: false), 2);
      expect(cinemaMatchEpisode(named(['第1集']), null, index: 2, single: false), -1);
    });

    test('看完了：剩下的不到片长 5% 或 3 分钟（取更短的）才算', () {
      CinemaHistory watched(Duration position, Duration duration) => CinemaHistory(key: 'k', name: 'k', cover: '', ruleId: 'alpha', source: '1', road: 0, episode: 0, episodeName: '正片', position: position, duration: duration, updatedAt: DateTime.utc(2026, 11, 21));
      const movie = Duration(hours: 2), episode = Duration(minutes: 20);
      expect(watched(movie - const Duration(minutes: 3), movie).finished, isTrue, reason: '长片按 3 分钟');
      expect(watched(movie - const Duration(minutes: 3, seconds: 1), movie).finished, isFalse);
      expect(watched(episode - const Duration(minutes: 1), episode).finished, isTrue, reason: '短片按 5%（1 分钟）');
      expect(watched(episode - const Duration(minutes: 1, seconds: 1), episode).finished, isFalse);
      expect(watched(const Duration(minutes: 5), Duration.zero).finished, isFalse, reason: '不知道片长的不算');
    });

    test('一部片的片源：同一个源只留一条、加上了才通知；新来的接在已排好的后面，不往前插', () {
      final title = CinemaTitle(key: 'k', name: '合成电影', year: '2020', cover: '', remarks: '');
      var notified = 0;
      title.changes.listen((_) => notified++);
      CinemaSourceRef ref(String id) => CinemaSourceRef(ruleId: id, source: '1', name: '合成电影', remarks: '');
      expect(title.addSource(ref('alpha')), isTrue);
      expect(title.addSource(ref('alpha')), isFalse);
      expect(title.addSource(ref('beta')), isTrue);
      expect(notified, 2);
      final shown = [title.sources.last, title.sources.first];
      title.addSource(ref('gamma'));
      expect([for (final source in appendCinemaSources(shown, title.sources)) source.ruleId], ['beta', 'alpha', 'gamma']);
      expect(() => title.sources.add(ref('delta')), throwsUnsupportedError, reason: '只能经 addSource 加');
    });

    // 人工决策见 cinema_models.dart 的 cinemaCutDiffers（11-21 总交接第 6.4 节）。
    test('换源后片长对不上：差过 2 分钟与原片长 3% 里更大的那个才提醒，给出长了还是短了多少', () {
      const movie = Duration(minutes: 120), episode = Duration(minutes: 40);
      expect(cinemaCutDiffers(movie, movie + const Duration(minutes: 3)), isNull, reason: '长片按 3%（3.6 分钟）');
      expect(cinemaCutDiffers(movie, movie - const Duration(minutes: 4)), const Duration(minutes: -4));
      expect(cinemaCutDiffers(episode, episode + const Duration(minutes: 2)), isNull, reason: '短的按 2 分钟');
      expect(cinemaCutDiffers(episode, episode + const Duration(minutes: 2, seconds: 1)), const Duration(minutes: 2, seconds: 1));
      expect(cinemaCutDiffers(Duration.zero, episode), isNull, reason: '原来的片长不知道不比');
    });

    // 人工决策见 cinema_models.dart 的 cinemaTitleKey（11-21 总交接第 6.6 节）。
    test('聚合键：分类里带预告、解说、花絮的单独成条，正片（别的分类、没有分类）的键不变', () {
      expect(cinemaTitleKey('流浪地球', '2019', category: '科幻片'), '流浪地球|2019');
      expect(cinemaTitleKey('流浪地球', '2019', category: '纪录片'), '流浪地球|2019');
      expect(cinemaTitleKey('流浪地球', '2019', category: '预告片'), '流浪地球|2019|预告');
      expect(cinemaTitleKey('流浪地球', '2019', category: '电影解说'), '流浪地球|2019|解说');
      expect(cinemaTitleKey('流浪地球', '2019', category: '幕后花絮'), '流浪地球|2019|花絮');
    });

    test('播放器报错的原话进日志前去掉网址（本机代理的口令、上游的签名地址），主机名留着，截到 120 字', () {
      expect(cinemaLogSafe('Failed to open http://127.0.0.1:44129/W9Rvh/p?s=0&u=https%3A%2F%2Fmedia.example.com%2F86.m3u8.'), 'Failed to open <地址>');
      expect(cinemaLogSafe('tcp: Failed to resolve hostname seg.invalid'), 'tcp: Failed to resolve hostname seg.invalid');
      expect(cinemaLogSafe('x' * 200), hasLength(120));
    });

    // 11-21 总交接第 6.6 节：原来只有每 10 秒、换集与离开时记，暂停后被强杀会退回 10 秒前。
    testWidgets('看到哪的保存：每 10 秒一次；暂停、跳转后等 1 秒合并成一次；切后台、换集立即记并取消还没到的；离开后不再记', (tester) async {
      var saves = 0;
      final schedule = CinemaSaveSchedule(() async => saves++);
      addTearDown(schedule.dispose);
      await tester.pump(const Duration(seconds: 10));
      expect(saves, 1);
      schedule.soon();
      await tester.pump(const Duration(milliseconds: 500));
      schedule.soon();
      await tester.pump(const Duration(milliseconds: 900));
      expect(saves, 1, reason: '连着两次，等最后一次之后满 1 秒');
      await tester.pump(const Duration(milliseconds: 200));
      expect(saves, 2);
      schedule.soon();
      await schedule.now();
      expect(saves, 3);
      await tester.pump(const Duration(seconds: 2));
      expect(saves, 3, reason: '立即记过了，等着的那次取消');
      schedule.dispose();
      await tester.pump(const Duration(seconds: 30));
      expect(saves, 3);
    });
  });

  group('播放清单', () {
    test('域名前置还原：路径第一段像域名才换，端口一并去掉，其余原样', () {
      expect(cinemaUnwrapHost(Uri.parse('https://edge.cdn.example.com/real.example.com/a.ts?token=1')).toString(), 'https://real.example.com/a.ts?token=1');
      expect(cinemaUnwrapHost(Uri.parse('https://edge.example.com:999/real.example.com/a.ts')).toString(), 'https://real.example.com/a.ts');
      for (final same in ['https://cdn.example.com/play/x/index.m3u8', 'https://cdn.example.com/a/b.ts', 'https://a.example.com/a.example.com/x.ts']) {
        expect(cinemaUnwrapHost(Uri.parse(same)).toString(), same);
      }
    });

    test('主清单：码率子清单与音轨回到本机代理，相对地址按清单地址补全', () {
      const master = '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/index.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n1080/index.m3u8\n';
      final out = cinemaRewritePlaylist(master, Uri.parse('https://cdn.example.com/v/index.m3u8'), playlist: (uri) => 'P($uri)', media: (uri) => 'M($uri)');
      expect(out, '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="P(https://cdn.example.com/v/audio/index.m3u8)"\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nP(https://cdn.example.com/v/1080/index.m3u8)\n');
    });

    test('子清单：分片换成绝对地址交给播放器直连，AES 密钥回到本机代理；不是网络地址的密钥原样留着', () {
      const media = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x0\n#EXTINF:10.4,\nseg0.ts\n#EXTINF:9.6,\nhttps://other.example.com/seg1.ts\n#EXT-X-ENDLIST\n';
      final out = cinemaRewritePlaylist(media, Uri.parse('https://cdn.example.com/v/1080/index.m3u8'), playlist: (uri) => 'P($uri)', media: (uri) => '$uri', key: (uri) => 'K($uri)');
      expect(out, contains('URI="K(https://cdn.example.com/v/1080/enc.key)"'));
      expect(cinemaRewritePlaylist('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc"\n#EXTINF:1,\na.ts\n', Uri.parse('https://cdn.example.com/'), playlist: (uri) => '$uri', media: (uri) => '$uri', key: (uri) => 'K'), contains('URI="skd://abc"'));
      expect(out, contains('\nhttps://cdn.example.com/v/1080/seg0.ts\n'));
      expect(out, contains('\nhttps://other.example.com/seg1.ts\n'));
      expect(cinemaFirstSegment(media, Uri.parse('https://cdn.example.com/v/1080/index.m3u8')).toString(), 'https://cdn.example.com/v/1080/seg0.ts');
    });

    // 人工决策见 cinema_playlist.dart 文件头（11-21 不删任何分片）。
    test('不删分片：短的不连续段、换过的密钥、初始化段、BYTERANGE 与媒体序号原样留着、顺序不变，只改地址', () {
      final segments = [for (var index = 0; index < 30; index++) '#EXTINF:10,\nmain$index.ts'].join('\n');
      final media = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI="ad.key"\n#EXTINF:5,\nad0.ts\n#EXTINF:5,\nad1.ts\n'
          '#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=NONE\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n$segments\n'
          '#EXT-X-DISCONTINUITY\n#EXTINF:4,\n#EXT-X-BYTERANGE:1000@0\nshort.ts\n#EXT-X-ENDLIST\n';
      final base = Uri.parse('https://cdn.example.com/v/');
      expect(cinemaRewritePlaylist(media, base, playlist: (uri) => '$uri', media: (uri) => uri.pathSegments.last, key: (uri) => uri.pathSegments.last), media);
      expect(cinemaRewritePlaylist(media, base, playlist: (uri) => '$uri', media: (uri) => '$uri'), contains('\n#EXTINF:5,\nhttps://cdn.example.com/v/ad0.ts\n'));
    });
  });

  group('云解析', () {
    final parser = decodeCinemaPackage(packageBytes()).parsers.single;

    test('code 不论数字还是字符串的 200 都算成功，地址按 AES-128-CBC 解开；3 分钟内同一地址走缓存，重新解析跳过缓存', () async {
      var calls = 0;
      final cipher = await encryptForTest('https://media.example.com/a.m3u8');
      final client = MockClient((request) async {
        calls++;
        expect(request.body, 'url=${Uri.encodeQueryComponent('https://v.example.com/x')}');
        return reply(jsonEncode({'code': calls.isOdd ? 200 : '200', 'msg': '解析成功', 'title': '合成_01', 'url': cipher, 'type': 'm3u8'}), 200, headers: {'content-type': 'text/html'});
      });
      var now = DateTime.utc(2026, 11, 20);
      final cloud = CinemaCloudParse(CinemaHttp(client: client), now: () => now);
      final first = await cloud.parse(parser, 'https://v.example.com/x');
      expect((first.title, first.type, first.url, first.direct), ('合成_01', 'm3u8', 'https://media.example.com/a.m3u8', false));
      await cloud.parse(parser, 'https://v.example.com/x');
      expect(calls, 1);
      await cloud.parse(parser, 'https://v.example.com/x', fresh: true);
      expect(calls, 2);
      now = now.add(CinemaCloudParse.cacheLifetime);
      await cloud.parse(parser, 'https://v.example.com/x');
      expect(calls, 3);
    });

    test('业务码不是 200、没有地址、解不开都报原因；输入本身是媒体直链时不发请求', () async {
      final replies = [
        {'code': 404, 'msg': '解析失败'},
        {'code': '200', 'title': 'x'},
        {'code': 200, 'url': 'bm90LWFlcw=='},
      ];
      var calls = 0;
      final cloud = CinemaCloudParse(CinemaHttp(client: MockClient((request) async => reply(jsonEncode(replies[calls++]), 200))));
      for (var index = 0; index < replies.length; index++) {
        await expectLater(cloud.parse(parser, 'https://v.example.com/$index'), throwsA(isA<CinemaParseException>()));
      }
      final direct = await cloud.parse(parser, 'https://cdn.example.com/a.mp4');
      expect(direct.direct, isTrue);
      expect(calls, replies.length);
    });
  });

  group('本机库与服务', () {
    late ToolboxFixture fixture;
    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
    });

    CinemaHistory entry(String key, DateTime at) => CinemaHistory(key: key, name: key, cover: '', ruleId: 'alpha', source: '1', road: 0, episode: 0, episodeName: '第01集', position: const Duration(seconds: 5), duration: const Duration(minutes: 40), updatedAt: at);

    test('看过的最多留 50 条、超过 180 天没再看的删掉，按最近看排', () async {
      final store = await CinemaStore.open(path.join(fixture.directory.path, 'cinema_history.db'));
      addTearDown(store.close);
      final now = DateTime.utc(2026, 11, 20);
      await store.saveHistory(entry('old', now.subtract(const Duration(days: 181))));
      for (var index = 0; index < cinemaHistoryLimit + 5; index++) {
        await store.saveHistory(entry('k$index', now.add(Duration(minutes: index))));
      }
      final history = await store.history(now, limit: 100);
      expect(history, hasLength(cinemaHistoryLimit));
      expect(history.first.key, 'k${cinemaHistoryLimit + 4}');
      expect(history.any((item) => item.key == 'old'), isFalse);
    });

    // 11-22 Codex 复核：原来只在写新记录时清过期的，长期不用再回来，181 天前的照样显示。
    test('看过的读的时候也清过期的：181 天没再看的不显示，它在各源的编号一起删', () async {
      final store = await CinemaStore.open(path.join(fixture.directory.path, 'cinema_expire.db'));
      addTearDown(store.close);
      final then = DateTime.utc(2026, 5, 1), later = then.add(const Duration(days: 181));
      await store.saveHistory(entry('old', then));
      await store.saveTitleSources('old', const [CinemaSourceRef(ruleId: 'alpha', source: '1', name: 'old', remarks: '')]);
      expect(await store.history(then), hasLength(1));
      expect(await store.history(later), isEmpty);
      expect(await store.titleSources('old'), isEmpty);
      // 选集页读一部片的记录（接着看）也一样。
      await store.saveHistory(entry('other', then));
      expect(await store.historyOf('other', later), isNull);
    });

    Future<CinemaService> open(Future<List<int>> Function() fetch, {http.Client? client, int versionCode = 40, DateTime Function()? now, Uri? relay}) async {
      final service = await CinemaService.open(
        ToolboxServiceContext(base: fixture.directory, store: fixture.store, downloads: fixture.manager),
        feed: CinemaRulesFeed(fetch: () async => Uint8List.fromList(await fetch()), versionCode: () async => versionCode),
        http: CinemaHttp(client: client ?? MockClient((request) async => reply('', 404))),
        now: now,
        relay: relay,
      );
      return service;
    }

    // 11-22 Codex 复核 P1：选集与解析结果都不签名，里面的地址可能指向手机所在的内网。
    test('交给播放器的地址只认公网：本机、内网的直链与清单报「地址不对」，不去取', () async {
      var requests = 0;
      final service = await open(() async => packageBytes(), client: MockClient((request) async {
        requests++;
        return reply('', 404);
      }));
      final rule = (await service.rules()).rules.first;
      for (final url in ['http://192.168.1.2/a.mp4', 'http://127.0.0.1:8080/index.m3u8', 'http://nas.local/a.mp4', 'http://router/a.mp4', 'http://[fe80::1]/a.mp4']) {
        await expectLater(service.playable(url, rule: rule), throwsA(isA<CinemaHttpException>().having((error) => error.message, 'message', '地址不对')), reason: url);
      }
      expect(requests, 0);
      await service.close();
    });

    // 11-22 Codex 复核 P1：同一个源换了接口主机或加了境外转发，搜索会重新问，续播与换源取选集却直接发给新地址。
    test('取选集前核对同意：没同意过、换了接口主机或改走境外转发的源不发请求（抛 CinemaConsentNeeded），同意了才发', () async {
      final hosts = <String>[];
      var version = 1;
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        return reply(macCmsList([{'vod_id': 7, 'vod_name': '合成', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/one/index.m3u8'}]), 200);
      });
      List<int> package() => switch (version) {
        1 => packageBytes(rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php')]),
        2 => packageBytes(version: 2, rules: [macCmsRule('alpha', 'https://alpha2.example.com/api.php')]),
        _ => packageBytes(version: 3, forward: 'https://edge.example.net/v1/forward', rules: [{...macCmsRule('alpha', 'https://alpha2.example.com/api.php'), 'forward': true}]),
      };
      final service = await open(() async => package(), client: client);
      await service.rules();
      await expectLater(service.chapters(service.rule('alpha')!, '7'), throwsA(isA<CinemaConsentNeeded>()), reason: '没同意过');
      await service.grantRules([service.rule('alpha')!]);
      await service.chapters(service.rule('alpha')!, '7');
      expect(hosts, ['alpha.example.com']);
      version = 2;
      await service.rules(force: true);
      await expectLater(service.chapters(service.rule('alpha')!, '7', fresh: true), throwsA(isA<CinemaConsentNeeded>()), reason: '换了接口主机');
      await service.grantRules([service.rule('alpha')!]);
      version = 3;
      await service.rules(force: true);
      await expectLater(service.chapters(service.rule('alpha')!, '7', fresh: true), throwsA(isA<CinemaConsentNeeded>()), reason: '改走境外转发');
      expect(hosts, ['alpha.example.com'], reason: '没同意时一个请求都没发');
      await service.grantRules([service.rule('alpha')!]);
      await service.chapters(service.rule('alpha')!, '7', fresh: true);
      expect(hosts.last, 'edge.example.net');
      await service.close();
    });

    test('规则包：拉到就缓存，一小时内不再拉；版本只升不降；要更新客户端的不换；拉不到照旧用本机的', () async {
      var now = DateTime.utc(2026, 11, 20);
      var payload = packageBytes(version: 2);
      var fetches = 0;
      var service = await open(() async {
        fetches++;
        return payload;
      }, now: () => now);
      expect((await service.rules()).version, 2);
      await service.rules();
      expect(fetches, 1);
      payload = packageBytes(version: 1);
      expect((await service.rules(force: true)).version, 2, reason: '旧包不换');
      payload = packageBytes(version: 5, minClient: 99);
      expect((await service.rules(force: true)).version, 2, reason: '要更新客户端的不换');
      payload = packageBytes(version: 3);
      expect((await service.rules(force: true)).version, 3);
      await service.close();
      // 重开：本机缓存的照旧能用，拉不到也不报错。
      now = now.add(const Duration(hours: 2));
      service = await open(() async => throw const SocketException('down'), now: () => now);
      expect(service.package?.version, 3);
      expect((await service.rules()).version, 3);
      await service.close();
    });

    test('本机没有规则包又拉不到：报拿不到片源规则', () async {
      final service = await open(() async => throw const SocketException('down'));
      await expectLater(service.rules(), throwsA(isA<CinemaRuleException>()));
      await service.close();
    });

    test('搜索：只搜同意过的源，按片名加年份聚合、按第一次出现的先后排；一个源 403 只进失败列表；换了主机要重新同意', () async {
      final client = MockClient((request) async => switch (request.url.host) {
        'alpha.example.com' => reply(macCmsList([
          {'vod_id': 1, 'vod_name': '合成电影', 'vod_year': '2020', 'vod_pic': 'https://img.example.com/1.jpg'},
          {'vod_id': 2, 'vod_name': '只此一家', 'vod_year': '2021'},
        ]), 200, headers: {'content-type': 'text/html; charset=utf-8'}),
        'beta.example.com' => reply(macCmsList([
          {'vod_id': 9, 'vod_name': '合成 电影', 'vod_year': '2020'},
        ]), 200),
        _ => reply('', 403),
      });
      final service = await open(() async => packageBytes(rules: [
        macCmsRule('alpha', 'https://alpha.example.com/api.php'),
        macCmsRule('beta', 'https://beta.example.com/api.php'),
        macCmsRule('gamma', 'https://gamma.example.com/api.php', name: '挡住的资源'),
      ]), client: client);
      final package = await service.rules();
      expect([for (final rule in await service.unconsentedRules(package)) rule.id], ['alpha', 'beta', 'gamma']);
      await service.grantRules(package.rules.where((rule) => rule.id != 'beta'));
      var result = await service.search('合成').last;
      expect([for (final title in result.titles) title.name], ['合成电影', '只此一家']);
      expect(result.titles.first.sources, hasLength(1));
      expect([for (final failure in result.failures) (failure.name, failure.message)], [('挡住的资源', '挡住的资源暂不可用（HTTP 403）')]);
      await service.grantRules(package.rules);
      result = await service.search('合成').last;
      expect([for (final ref in result.titles.first.sources) '${ref.ruleId}:${ref.source}'], ['alpha:1', 'beta:9']);
      expect(result.titles.first.cover, 'https://img.example.com/1.jpg');
      await service.close();
    });

    // 人工决策见 cinema_service.dart 的 pauseAfter（11-20 边搜边显示、连续失败就暂停）。
    test('边搜边给快照：先给一份全在搜的，每回来一个源一份，最后一份 pending 为 0；慢的源不挡住先回来的', () async {
      final slow = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.host == 'beta.example.com') await slow.future;
        return reply(macCmsList([{'vod_id': request.url.host == 'alpha.example.com' ? 1 : 2, 'vod_name': '合成电影', 'vod_year': '2020'}]), 200);
      });
      final service = await open(() async => packageBytes(), client: client);
      await service.grantRules((await service.rules()).rules);
      final snapshots = <CinemaSearchResult>[];
      final done = service.search('合成').forEach(snapshots.add);
      await untilTrue(() => snapshots.length >= 2);
      expect([for (final snapshot in snapshots) snapshot.pending], [2, 1]);
      expect(snapshots.last.titles.single.sources, hasLength(1), reason: '先回来的已经显示');
      slow.complete();
      await done;
      expect(snapshots.last.pending, 0);
      expect(snapshots.last.titles.single.sources, hasLength(2));
      await service.close();
    });

    // 人工决策见 cinema_rule.dart 的 CinemaRule.forward（11-21 国内连不上的源走境外转发）。
    test('境外转发：走转发的源搜索与选集发给转发地址（原地址在 u 里、请求头照带），相对地址仍按原地址补全；转发自己出的错按直连时的原因算；别的源照旧直连', () async {
      final requests = <http.BaseRequest>[];
      var forwardError = '';
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'edge.example.net' && forwardError.isNotEmpty) return reply('', forwardError == 'timeout' ? 504 : 403, headers: {'x-forward-error': forwardError});
        return reply(macCmsList([{'vod_id': 7, 'vod_name': '合成电影', 'vod_play_from': '线路', 'vod_play_url': r'第1集$/v/1.m3u8'}]), 200);
      });
      final rules = [{...macCmsRule('alpha', 'https://alpha.example.com/api.php'), 'forward': true}, macCmsRule('beta', 'https://beta.example.com/api.php', name: '另一资源')];
      final service = await open(() async => packageBytes(forward: 'https://edge.example.net/v1/forward', rules: rules), client: client);
      await service.grantRules((await service.rules()).rules);
      await service.search('合成').drain<void>();
      final viaEdge = requests.singleWhere((request) => request.url.host == 'edge.example.net');
      final original = Uri.parse(viaEdge.url.queryParameters['u']!);
      expect((viaEdge.method, viaEdge.url.path, original.host, original.queryParameters['wd']), ('GET', '/v1/forward', 'alpha.example.com', '合成'));
      expect((viaEdge.headers['user-agent'], viaEdge.headers['accept']), (cinemaDefaultUserAgent, 'application/json, text/plain, */*'));
      expect(requests.where((request) => request.url.host == 'beta.example.com'), hasLength(1), reason: '没走转发的照旧直连');
      final roads = await service.chapters(service.rule('alpha')!, '7');
      expect(requests.last.url.host, 'edge.example.net');
      expect(Uri.parse(requests.last.url.queryParameters['u']!).queryParameters['ids'], '7');
      expect(roads.single.episodes.single.url, 'https://alpha.example.com/v/1.m3u8', reason: '相对地址按原地址补全，不按转发地址');
      forwardError = 'timeout';
      expect((await service.search('超时').last).failures.single.message, '合成资源超时');
      forwardError = 'target';
      expect((await service.search('拒绝').last).failures.single.message, '合成资源转发不可用（HTTP 403）');
      await service.close();
    });

    // 人工决策见 cinema_page.dart 的 _onQuery 上 11-22 那条（暂不可用按原因分组）。
    test('暂不可用按原因分组：连接失败算连不上，401–451 与人机验证算拒绝访问（人机验证单独记日志），别的状态码、繁忙与转发自己出的错算出错；暂停着的照最后一次分组', () async {
      final logs = captureDiagnostics();
      final client = MockClient((request) async => switch (request.url.host) {
        'down.example.com' => throw const SocketException('连不上'),
        'shield.example.com' => reply('<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script>window._cf_chl_opt={}</script></body></html>', 403),
        'busy.example.com' => reply('', 429),
        'error.example.com' => reply('', 500),
        'empty.example.com' => reply('{"code":1,"msg":"服务器繁忙"}', 200),
        'edge.example.net' => reply('', 429, headers: {'x-forward-error': 'rate_limited'}),
        _ => reply(macCmsList([]), 200),
      });
      final service = await open(() async => packageBytes(forward: 'https://edge.example.net/v1/forward', rules: [
        macCmsRule('down', 'https://down.example.com/api.php', name: '断网资源'),
        macCmsRule('shield', 'https://shield.example.com/api.php', name: '验证资源'),
        macCmsRule('busy', 'https://busy.example.com/api.php', name: '限流资源'),
        macCmsRule('error', 'https://error.example.com/api.php', name: '坏掉资源'),
        macCmsRule('empty', 'https://empty.example.com/api.php', name: '繁忙资源'),
        {...macCmsRule('relayed', 'https://relayed.example.com/api.php', name: '转发资源'), 'forward': true},
      ]), client: client);
      await service.grantRules((await service.rules()).rules);
      Map<String, CinemaFailureKind> kinds(CinemaSearchResult result) => {for (final failure in result.failures) failure.ruleId: failure.kind};
      var result = await service.search('合成').last;
      expect(kinds(result), {
        'down': CinemaFailureKind.unreachable,
        'shield': CinemaFailureKind.refused,
        'busy': CinemaFailureKind.refused,
        'error': CinemaFailureKind.broken,
        'empty': CinemaFailureKind.broken,
        'relayed': CinemaFailureKind.broken,
      });
      expect(logs.where((line) => line.contains('rule=shield result=failed_challenge')), hasLength(1));
      expect(logs.where((line) => line.contains('rule=busy result=failed_http_429')), hasLength(1));
      for (var round = 1; round < CinemaService.pauseAfter; round++) {
        await service.search('合成$round').last;
      }
      result = await service.search('合成再搜').last;
      expect(result.failures.every((failure) => failure.paused), isTrue);
      expect(kinds(result)['down'], CinemaFailureKind.unreachable, reason: '暂停着的照最后一次失败分组');
      expect(kinds(result)['shield'], CinemaFailureKind.refused);
      await service.close();
    });

    test('境外转发：同意过直连的源改走转发后要重新同意', () async {
      var payload = packageBytes();
      final service = await open(() async => payload);
      await service.grantRules((await service.rules()).rules);
      expect(await service.unconsentedRules(await service.rules()), isEmpty);
      payload = packageBytes(version: 2, forward: 'https://edge.example.net/v1/forward', rules: [{...macCmsRule('alpha', 'https://alpha.example.com/api.php/provide/vod/'), 'forward': true}, macCmsRule('beta', 'https://beta.example.com/api.php/provide/vod', name: '另一资源')]);
      final package = await service.rules(force: true);
      expect(package.version, 2);
      expect([for (final rule in await service.unconsentedRules(package)) rule.id], ['alpha']);
      await service.close();
    });

    // 11-21：并发由 6 调到 16、接口请求带浏览器常见的两个头（cinema_service.dart 的 searchConcurrency、cinema_http.dart 的 cinemaApiHeaders）。
    test('一次搜索 14 个源同时发出（挂着的源不让别的源排队）；接口请求带 accept 与 accept-language，规则写了同名头以规则为准', () async {
      final gate = Completer<void>();
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        await gate.future;
        return reply(macCmsList(const []), 200);
      });
      final rules = [
        for (var index = 0; index < 13; index++) macCmsRule('s$index', 'https://s$index.example.com/api.php'),
        {
          ...macCmsRule('own', 'https://own.example.com/api.php'),
          'searchApiConfig': {
            ...(macCmsRule('own', 'https://own.example.com/api.php')['searchApiConfig']! as Map<String, Object?>),
            'request': {'method': 'GET', 'url': 'https://own.example.com/api.php', 'query': {'ac': 'detail', 'wd': '@keyword'}, 'headers': {'Accept': 'text/html'}},
          },
        },
      ];
      final service = await open(() async => packageBytes(rules: rules), client: client);
      await service.grantRules((await service.rules()).rules);
      final done = service.search('合成').drain<void>();
      await untilTrue(() => requests.length >= 14);
      expect(requests, hasLength(14), reason: '没有一个源在排队');
      expect(CinemaService.searchConcurrency, greaterThanOrEqualTo(14));
      final plain = requests.firstWhere((request) => request.url.host == 's0.example.com');
      expect((plain.headers['accept'], plain.headers['accept-language']), ('application/json, text/plain, */*', 'zh-CN,zh;q=0.9,en;q=0.8'));
      expect(plain.headers['user-agent'], cinemaDefaultUserAgent);
      expect(requests.firstWhere((request) => request.url.host == 'own.example.com').headers['accept'], 'text/html');
      gate.complete();
      await done;
      await service.close();
    });

    test('同一个源连续失败三次就暂停 pauseFor、不再去请求；重试立即恢复；成功一次清零', () async {
      var now = DateTime.utc(2026, 11, 20, 8);
      final asked = <String>[];
      var down = true;
      final client = MockClient((request) async {
        asked.add(request.url.host);
        if (request.url.host == 'beta.example.com' && down) return reply('', 502);
        return reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影'}]), 200);
      });
      final service = await open(() async => packageBytes(), client: client, now: () => now);
      await service.grantRules((await service.rules()).rules);
      for (var round = 0; round < CinemaService.pauseAfter; round++) {
        await service.search('合成', fresh: true).last;
      }
      asked.clear();
      final paused = await service.search('合成', fresh: true).last;
      expect(asked, ['alpha.example.com'], reason: '暂停着的不去请求');
      expect(paused.failures.single.paused, isTrue);
      expect(service.hasPaused, isTrue);
      now = now.add(CinemaService.pauseFor);
      asked.clear();
      await service.search('合成', fresh: true).last;
      expect(asked, contains('beta.example.com'), reason: '到点恢复');
      service.resume();
      down = false;
      final recovered = await service.search('合成', fresh: true).last;
      expect(recovered.failures, isEmpty);
      await service.close();
    });

    test('上游 HTTP 200 回繁忙（没有 list）算这个源失败：进暂不可用、计连续失败到暂停；回空列表的源不算失败', () async {
      final client = MockClient((request) async => request.url.host == 'beta.example.com' ? reply('{"code":1,"msg":"服务器繁忙，请稍后搜索"}', 200) : reply(macCmsList(const []), 200));
      final service = await open(() async => packageBytes(), client: client);
      await service.grantRules((await service.rules()).rules);
      for (var round = 0; round < CinemaService.pauseAfter; round++) {
        final result = await service.search('合成').last;
        expect([for (final failure in result.failures) (failure.name, failure.paused)], [('另一资源', false)]);
      }
      expect(service.hasPaused, isTrue);
      await service.close();
    });

    test('片名目录型的源：片名 POST 给中转（不进地址）查编号，再把编号一次发给源取详情、按中转给的先后排；中转回的不合格整份不用', () async {
      final requests = <http.Request>[];
      var relayReply = jsonEncode({'ids': ['102', '101']});
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'relay.example.com') return reply(relayReply, 200);
        const names = {'101': '合成电影 第二季', '102': '合成电影'};
        return reply(macCmsList([for (final id in request.url.queryParameters['ids']!.split(',')) {'vod_id': int.parse(id), 'vod_name': names[id], 'vod_year': '2020'}]), 200);
      });
      final service = await open(() async => packageBytes(rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php')], catalogRules: [catalogRule('wsy', 'https://wsy.example.com/api.php/provide/vod/')]), client: client, relay: Uri.parse('https://relay.example.com'));
      final wsy = (await service.rules()).rules.singleWhere((rule) => rule.catalog != null);
      await service.grantRules([wsy]);
      final result = await service.search('合成电影').last;
      final relay = requests.first;
      expect((relay.method, relay.url.path, relay.url.query), ('POST', '/v1/app/cinema/catalogs/wsy/search', ''));
      expect(jsonDecode(relay.body), {'q': '合成电影'});
      final detail = requests.last;
      expect((detail.url.host, detail.url.queryParameters['ids'], detail.url.queryParameters.containsKey('wd')), ('wsy.example.com', '102,101', false));
      expect([for (final title in result.titles) title.sources.single.source], ['102', '101']);
      relayReply = jsonEncode({'ids': [for (var index = 0; index <= catalogHitLimit; index++) '$index']});
      expect((await service.search('合成电影', fresh: true).last).failures.single.message, contains('看不懂'));
      expect(() => decodeCatalogIds('{"ids":[""]}'), throwsA(isA<CinemaRuleException>()));
      await service.close();
    });

    test('片名目录型的源在没配中转的包里用不了：列进暂不可用，不影响别的源', () async {
      final client = MockClient((request) async => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影'}]), 200));
      final service = await open(() async => packageBytes(rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php')], catalogRules: [catalogRule('wsy', 'https://wsy.example.com/api.php')]), client: client);
      await service.grantRules((await service.rules()).rules);
      final result = await service.search('合成').last;
      expect(result.titles.single.sources.single.ruleId, 'alpha');
      expect(result.failures.single.ruleId, 'wsy');
      await service.close();
    });


    test('选集缓存：搜索自带的剧集点开不再请求；没带的两处同时要只发一次、之后走缓存；重新载入、过了 10 分钟、规则包换了版本才重取', () async {
      var now = DateTime.utc(2026, 11, 20);
      var version = 1;
      final details = <String>[];
      var gate = Completer<void>();
      final client = MockClient((request) async {
        final query = request.url.queryParameters;
        final item = {'vod_id': request.url.host.startsWith('alpha') ? 1 : 7, 'vod_name': '合成电影', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/one/index.m3u8'};
        if (query.containsKey('wd')) return reply(macCmsList([item]), 200);
        details.add('${request.url.host} ${query['ids']}');
        await gate.future;
        return reply(macCmsList([item]), 200);
      });
      final service = await open(() async => packageBytes(version: version, rules: [macCmsRuleWithChapters('alpha', 'https://alpha.example.com/api.php'), macCmsRule('beta', 'https://beta.example.com/api.php')]), client: client, now: () => now);
      final package = await service.rules();
      await service.grantRules(package.rules);
      final found = await service.search('合成电影').last;
      final alpha = service.rule('alpha')!, beta = service.rule('beta')!;
      final carried = found.titles.single.sources.firstWhere((ref) => ref.ruleId == 'alpha').carried;
      expect((await service.chapters(alpha, '1', carried: carried)).single.episodes.single.url, 'https://cdn.example.com/one/index.m3u8');
      expect(details, isEmpty);
      expect(found.titles.single.sources.firstWhere((ref) => ref.ruleId == 'beta').carried, isNull, reason: '规则没写 search.chapters 的不带');
      final both = Future.wait([service.chapters(beta, '7'), service.chapters(beta, '7')]);
      gate.complete();
      expect((await both).map((roads) => roads.single.episodes.length), [1, 1]);
      await service.chapters(beta, '7');
      expect(details, ['beta.example.com 7']);
      await service.chapters(beta, '7', fresh: true);
      expect(details, hasLength(2));
      now = now.add(const Duration(minutes: 11));
      await service.chapters(beta, '7');
      expect(details, hasLength(3));
      version = 2;
      await service.rules(force: true);
      await service.chapters(service.rule('beta')!, '7');
      expect(details, hasLength(4));
      gate = Completer<void>()..complete();
      await service.close();
    });

    // 11-21 Codex 总交接：原来搜索自带的剧集都写进 64 条的选集缓存，5 个源各 20 条时先回来的被挤掉，点开又请求一次。
    test('一次搜索 5 个源各 20 条：搜索自带的剧集跟着结果走，点开哪一条都不再请求详情；一次搜索最多带 carriedEpisodeLimit 集', () async {
      var details = 0;
      final client = MockClient((request) async {
        if (!request.url.queryParameters.containsKey('wd')) {
          details++;
          return reply(macCmsList(const []), 200);
        }
        return reply(macCmsList([for (var index = 1; index <= 20; index++) {'vod_id': index, 'vod_name': '合成电影$index', 'vod_play_from': 'm3u8', 'vod_play_url': '第01集\$https://cdn.example.com/${request.url.host}/$index.m3u8'}]), 200);
      });
      final service = await open(() async => packageBytes(rules: [for (var index = 0; index < 5; index++) macCmsRuleWithChapters('s$index', 'https://s$index.example.com/api.php')]), client: client);
      await service.grantRules((await service.rules()).rules);
      final result = await service.search('合成电影').last;
      final refs = [for (final title in result.titles) ...title.sources];
      expect(refs, hasLength(100));
      for (final ref in refs) {
        await service.chapters(service.rule(ref.ruleId)!, ref.source, carried: ref.carried);
      }
      expect(details, 0);
      await service.close();
    });

    test('搜索自带的剧集超过一次搜索的上限：超出的那条不带，点开再取', () async {
      String episodes(int count, String tag) => [for (var index = 1; index <= count; index++) '第$index集\$https://cdn.example.com/$tag/$index.m3u8'].join('#');
      const first = CinemaService.carriedEpisodeLimit - 10;
      final client = MockClient((request) async => reply(macCmsList([
        {'vod_id': 1, 'vod_name': '合成长剧', 'vod_play_from': 'm3u8', 'vod_play_url': episodes(first, 'a')},
        {'vod_id': 2, 'vod_name': '合成长剧 续', 'vod_play_from': 'm3u8', 'vod_play_url': episodes(20, 'b')},
        {'vod_id': 3, 'vod_name': '合成短片', 'vod_play_from': 'm3u8', 'vod_play_url': episodes(10, 'c')},
      ]), 200));
      final service = await open(() async => packageBytes(rules: [macCmsRuleWithChapters('alpha', 'https://alpha.example.com/api.php')]), client: client);
      await service.grantRules((await service.rules()).rules);
      final result = await service.search('合成').last;
      final carried = {for (final title in result.titles) title.sources.single.source: title.sources.single.carried != null};
      expect(carried, {'1': true, '2': false, '3': true});
      await service.close();
    });

    test('找其他片源：按片名搜同意过的源，片名加年份相同的接进这部片并通知，年份不同的不要；返回新加了几个', () async {
      final client = MockClient((request) async => switch (request.url.host) {
        'alpha.example.com' => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_year': '2020'}]), 200),
        'beta.example.com' => reply(macCmsList([{'vod_id': 9, 'vod_name': '合成 电影', 'vod_year': '2020'}, {'vod_id': 10, 'vod_name': '合成电影', 'vod_year': '1999'}]), 200),
        _ => reply('', 404),
      });
      final service = await open(() async => packageBytes(), client: client);
      await service.grantRules((await service.rules()).rules);
      final title = CinemaTitle(key: cinemaTitleKey('合成电影', '2020'), name: '合成电影', year: '', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      var notified = 0;
      title.changes.listen((_) => notified++);
      expect(await service.findMoreSources(title), 1);
      expect([for (final ref in title.sources) '${ref.ruleId}:${ref.source}'], ['alpha:1', 'beta:9']);
      expect(notified, 1);
      expect(await service.findMoreSources(title), 0, reason: '已有的不重复加');
      await service.close();
    });

    // 11-21 总交接第 7.2 节：补搜缺少的源时不再打这部片已有的源与刚失败的源。
    test('找其他片源不再搜这部片已有的源与一分钟内刚失败过的源，过了一分钟再试', () async {
      var now = DateTime.utc(2026, 11, 21, 8);
      final asked = <String>[];
      final client = MockClient((request) async {
        asked.add(request.url.host);
        return request.url.host == 'gamma.example.com' ? reply('', 502) : reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_year': '2020'}]), 200);
      });
      final service = await open(
        () async => packageBytes(rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php'), macCmsRule('beta', 'https://beta.example.com/api.php'), macCmsRule('gamma', 'https://gamma.example.com/api.php')]),
        client: client,
        now: () => now,
      );
      await service.grantRules((await service.rules()).rules);
      await service.search('别的片').last;
      CinemaTitle watched() => CinemaTitle(key: cinemaTitleKey('合成电影', '2020'), name: '合成电影', year: '', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      asked.clear();
      expect(await service.findMoreSources(watched()), 1);
      expect(asked, ['beta.example.com']);
      asked.clear();
      now = now.add(CinemaService.recentFailure);
      await service.findMoreSources(watched());
      expect(asked, contains('gamma.example.com'));
      expect(asked, isNot(contains('alpha.example.com')));
      await service.close();
    });

    // 人工决策见 cinema_service.dart 的 searchCacheLifetime（11-21 总交接第 7.4 节）。
    test('最近的搜索结果：一分钟内同一个源同一个词不再请求；失败的不记、照样去请求；重新搜、过了一分钟、规则包换了版本才再请求', () async {
      var now = DateTime.utc(2026, 11, 21, 8);
      var version = 1;
      final asked = <String>[];
      final client = MockClient((request) async {
        asked.add(request.url.host);
        return request.url.host == 'beta.example.com' ? reply('', 502) : reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影'}]), 200);
      });
      final service = await open(() async => packageBytes(version: version), client: client, now: () => now);
      await service.grantRules((await service.rules()).rules);
      await service.search('合成').last;
      expect(asked.toSet(), {'alpha.example.com', 'beta.example.com'});
      asked.clear();
      final again = await service.search('合成').last;
      expect(asked, ['beta.example.com']);
      expect(again.titles.single.sources.single.ruleId, 'alpha', reason: '用的是上次的结果');
      asked.clear();
      await service.search('合成', fresh: true).last;
      expect(asked, contains('alpha.example.com'));
      asked.clear();
      await service.search('合成片').last;
      expect(asked, contains('alpha.example.com'), reason: '别的词');
      asked.clear();
      now = now.add(CinemaService.searchCacheLifetime);
      await service.search('合成').last;
      expect(asked, contains('alpha.example.com'), reason: '过了一分钟');
      asked.clear();
      version = 2;
      await service.rules(force: true);
      await service.search('合成').last;
      expect(asked, contains('alpha.example.com'), reason: '规则包换了版本');
      await service.close();
    });

    test('同一个源同一个词正在搜：两处一起等、只发一次；一处不等了，另一处照样拿到', () async {
      final gate = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        await gate.future;
        return reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影'}]), 200);
      });
      final service = await open(() async => packageBytes(rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php')]), client: client);
      await service.grantRules((await service.rules()).rules);
      final leaving = Completer<void>();
      final first = service.search('合成', cancel: leaving.future).last;
      final second = service.search('合成').last;
      await untilTrue(() => requests >= 1);
      // 第二处也要读完本机库才轮到它：多等一会儿，它若另发一次就会被数到。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 1);
      leaving.complete();
      await pumpEventQueue();
      gate.complete();
      expect((await second).titles, hasLength(1));
      expect((await first).titles, isEmpty, reason: '不等了的那处算取消');
      expect(requests, 1);
      await service.close();
    });

    // 11-21 总交接第 8 节：手机上比各源快慢要逐源的排队、用时、结果分类与字节数。
    test('开发者模式的搜索诊断：逐源记结果分类（含用的是最近的结果）、用时、字节，整轮记首条与全部结束；日志里没有搜的片名', () async {
      final logs = captureDiagnostics();
      final client = MockClient((request) async => request.url.host == 'beta.example.com' ? reply('{"code":1,"msg":"没找到合成机密片"}', 200) : reply(macCmsList([{'vod_id': 1, 'vod_name': '合成机密片'}]), 200));
      final service = await open(() async => packageBytes(), client: client);
      await service.grantRules((await service.rules()).rules);
      await service.search('合成机密片').last;
      await service.search('合成机密片').last;
      expect(logs.where((line) => line.contains('action=search_source rule=alpha result=ok waitMs=')), hasLength(1));
      expect(logs.where((line) => line.contains('action=search_source rule=alpha result=cached')), hasLength(1));
      expect(logs.where((line) => line.contains('action=search_source rule=beta result=failed_no_list')), hasLength(2));
      expect(logs.any((line) => line.contains('action=search_fetch rule=alpha forward=false fetchMs=') && line.contains('bytes=')), isTrue);
      expect(logs.where((line) => line.startsWith('[Cinema] action=search titles=') && line.contains('firstMs=') && line.contains('totalMs=')), hasLength(2));
      expect(logs.where((line) => line.contains('合成机密片')), isEmpty);
      await service.close();
    });

    test('选集：一处不等了只有它抛取消，另一处照样拿到；都不等了才中断，之后再要另起一次', () async {
      final details = <int>[];
      var gate = Completer<void>();
      final client = MockClient((request) async {
        details.add(details.length);
        await gate.future;
        return reply(macCmsList([{'vod_id': 7, 'vod_name': '合成', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/one/index.m3u8'}]), 200);
      });
      final counting = _CountingClient(client);
      final service = await open(() async => packageBytes(), client: counting);
      final rule = (await service.rules()).rules.first;
      await service.grantRules([rule]);
      // 等请求真的发出去（取选集先读本机库核对同意）。
      Future<void> sent(int count) async {
        for (var tries = 0; details.length < count && tries < 200; tries++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final leaving = Completer<void>(), staying = Completer<void>();
      final left = service.chapters(rule, '7', cancel: leaving.future), stayed = service.chapters(rule, '7', cancel: staying.future);
      await sent(1);
      leaving.complete();
      await expectLater(left, throwsA(isA<http.RequestAbortedException>()));
      gate.complete();
      expect((await stayed).single.episodes, hasLength(1));
      expect(details, hasLength(1));
      gate = Completer<void>();
      final first = Completer<void>(), second = Completer<void>();
      final a = service.chapters(rule, '8', cancel: first.future), b = service.chapters(rule, '8', cancel: second.future);
      await sent(2);
      first.complete();
      second.complete();
      await expectLater(a, throwsA(isA<http.RequestAbortedException>()));
      await expectLater(b, throwsA(isA<http.RequestAbortedException>()));
      final again = service.chapters(rule, '8');
      gate.complete();
      await again;
      expect(details, hasLength(3), reason: '都不等了的那次被中断，再要时另起一次');
      // 还没发出去就不等了的（核对同意的这段时间里）：连发都不发（替身在中断后不调回复，只能数交给客户端的次数）。
      final sends = counting.sends;
      final early = Completer<void>()..complete();
      await expectLater(service.chapters(rule, '9', cancel: early.future), throwsA(isA<http.RequestAbortedException>()));
      expect(counting.sends, sends);
      await service.close();
    });

    test('选集：重新载入另起的一次先回来、旧的后回来，缓存留新的', () async {
      final gates = <Completer<void>>[];
      var served = 0;
      final client = MockClient((request) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        served++;
        return reply(macCmsList([{'vod_id': 7, 'vod_name': '合成', 'vod_play_from': 'm3u8', 'vod_play_url': '第01集\$https://cdn.example.com/${gates.indexOf(gate) + 1}.m3u8'}]), 200);
      });
      final service = await open(() async => packageBytes(), client: client);
      final rule = (await service.rules()).rules.first;
      await service.grantRules([rule]);
      // 等请求真的发到假服务器再放行：chapters 先查本机库（sqflite 是真异步），慢机器上两次 pumpEventQueue 不够（11-23 CI 偶发 gates[1] 越界）。
      Future<void> requested(int count) async {
        for (var wait = 0; wait < 400 && gates.length < count; wait++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(gates, hasLength(count));
      }
      final old = service.chapters(rule, '7');
      await requested(1);
      final fresh = service.chapters(rule, '7', fresh: true);
      await requested(2);
      gates[1].complete();
      expect((await fresh).single.episodes.single.url, 'https://cdn.example.com/2.m3u8');
      gates[0].complete();
      expect((await old).single.episodes.single.url, 'https://cdn.example.com/1.m3u8');
      expect((await service.chapters(rule, '7')).single.episodes.single.url, 'https://cdn.example.com/2.m3u8', reason: '旧的晚回来不覆盖');
      expect(served, 2);
      await service.close();
    });

    test('后台在拉规则包时，搜索直接用本机的，不等它', () async {
      var now = DateTime.utc(2026, 11, 20);
      var gate = Completer<void>()..complete();
      final service = await open(() async {
        await gate.future;
        return packageBytes();
      }, client: MockClient((request) async => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影'}]), 200)), now: () => now);
      await service.grantRules((await service.rules()).rules);
      now = now.add(const Duration(hours: 2));
      gate = Completer<void>();
      final refreshing = service.rules();
      final result = await service.search('合成').last.timeout(const Duration(seconds: 2));
      expect(result.titles.single.name, '合成电影');
      gate.complete();
      await refreshing;
      await service.close();
    });

    test('规则包拉不到：5 分钟内不再去拉（照旧用本机的），重试不等；拉到了就清零', () async {
      var now = DateTime.utc(2026, 11, 20);
      var fetches = 0;
      var fail = false;
      final service = await open(() async {
        fetches++;
        if (fail) throw const SocketException('连不上');
        return packageBytes(version: fetches);
      }, now: () => now);
      await service.rules();
      fail = true;
      now = now.add(const Duration(hours: 2));
      expect((await service.rules()).version, 1);
      await service.rules();
      await service.rules();
      expect(fetches, 2, reason: '失败后 5 分钟内不再拉');
      now = now.add(const Duration(minutes: 6));
      await service.rules();
      expect(fetches, 3);
      await service.rules(force: true);
      expect(fetches, 4, reason: '重试不等');
      fail = false;
      await service.rules(force: true);
      fail = true;
      now = now.add(const Duration(hours: 2));
      await service.rules();
      expect(fetches, 6, reason: '拉到过就清零，过了一小时照常去拉');
      await service.close();
    });

    test('播放记录：每个源一行，播成记首帧、没播成只记时刻，30 天没再播的删掉；能播的在前（首帧快的在前）、没记录的照搜到的先后、没播成的最后；标注', () async {
      final store = await CinemaStore.open(path.join(fixture.directory.path, 'cinema_stats.db'));
      addTearDown(store.close);
      final now = DateTime.utc(2026, 11, 20);
      await store.recordPlayback('alpha', ok: true, firstFrame: const Duration(seconds: 3), at: now);
      await store.recordPlayback('beta', ok: false, at: now);
      await store.recordPlayback('gamma', ok: true, firstFrame: const Duration(seconds: 1), at: now);
      await store.recordPlayback('delta', ok: true, firstFrame: const Duration(seconds: 1), at: now.subtract(const Duration(days: 31)));
      await store.recordPlayback('alpha', ok: false, at: now.subtract(const Duration(minutes: 1)));
      final stats = await store.sourceStats(now);
      expect(stats.keys.toSet(), {'alpha', 'beta', 'gamma'});
      expect((stats['alpha']!.lastOk, stats['alpha']!.firstFrame), (true, const Duration(seconds: 3)));
      CinemaSourceRef ref(String id) => CinemaSourceRef(ruleId: id, source: '1', name: id, remarks: '');
      expect([for (final item in rankCinemaSources([ref('beta'), ref('alpha'), ref('eps'), ref('gamma'), ref('zeta')], stats)) item.ruleId], ['gamma', 'alpha', 'eps', 'zeta', 'beta']);
      expect([cinemaSourceStatLabel(stats['gamma']), cinemaSourceStatLabel(stats['beta']), cinemaSourceStatLabel(null)], ['上次能播', '上次没播成', null]);
      await store.recordPlayback('gamma', ok: false, at: now.add(const Duration(minutes: 1)));
      expect((await store.sourceStats(now))['gamma']!.lastOk, isFalse);
    });

    // 人工决策见 cinema_page.dart 的 _resume（11-21 总交接第 6.5 节）。
    test('看过的片的各个源：按先后整份换掉、最多 32 个；没有看过的记录不记；删掉记录、被挤出上限时一起删', () async {
      final store = await CinemaStore.open(path.join(fixture.directory.path, 'cinema_sources.db'));
      addTearDown(store.close);
      CinemaSourceRef ref(int index) => CinemaSourceRef(ruleId: 'r$index', source: '$index', name: '合成', remarks: 'HD');
      final now = DateTime.utc(2026, 11, 21);
      await store.saveTitleSources('none', [ref(0)]);
      expect(await store.titleSources('none'), isEmpty);
      await store.saveHistory(entry('k', now));
      await store.saveTitleSources('k', [for (var index = 0; index < 40; index++) ref(index)]);
      final saved = await store.titleSources('k');
      expect(saved, hasLength(cinemaTitleSourceLimit));
      expect((saved.first.ruleId, saved.first.source, saved.first.remarks), ('r0', '0', 'HD'));
      await store.saveTitleSources('k', [ref(5), ref(1)]);
      expect([for (final source in await store.titleSources('k')) source.ruleId], ['r5', 'r1']);
      await store.deleteHistory('k');
      expect(await store.titleSources('k'), isEmpty);
      await store.saveHistory(entry('old', now));
      await store.saveTitleSources('old', [ref(0)]);
      for (var index = 0; index < cinemaHistoryLimit; index++) {
        await store.saveHistory(entry('n$index', now.add(Duration(minutes: index + 1))));
      }
      expect(await store.titleSources('old'), isEmpty, reason: '看过的记录被挤掉就一起删');
    });

    test('本机库从第 1 版升上来补上播放记录表，原有的记录还在', () async {
      final file = path.join(fixture.directory.path, 'cinema_v1.db');
      final old = await databaseFactory.openDatabase(file, options: OpenDatabaseOptions(version: 1, onCreate: (database, _) async {
        await database.execute('CREATE TABLE package (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, payload BLOB NOT NULL, fetched_at INTEGER NOT NULL)');
        await database.execute('CREATE TABLE consent (subject TEXT PRIMARY KEY, version TEXT NOT NULL)');
        await database.execute(
          'CREATE TABLE history (key TEXT PRIMARY KEY, name TEXT NOT NULL, cover TEXT NOT NULL, rule_id TEXT NOT NULL, source TEXT NOT NULL, road INTEGER NOT NULL, episode INTEGER NOT NULL, episode_name TEXT NOT NULL, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
        );
        await database.insert('consent', {'subject': 'rule:alpha', 'version': 'alpha.example.com'});
      }));
      await old.close();
      final store = await CinemaStore.open(file);
      addTearDown(store.close);
      await store.recordPlayback('alpha', ok: true, firstFrame: const Duration(seconds: 2), at: DateTime.utc(2026, 11, 20));
      expect((await store.sourceStats(DateTime.utc(2026, 11, 20))).keys, ['alpha']);
      expect(await store.consents(), {'rule:alpha': 'alpha.example.com'});
      await store.saveHistory(entry('k', DateTime.utc(2026, 11, 21)));
      await store.saveTitleSources('k', const [CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成', remarks: '')]);
      expect(await store.titleSources('k'), hasLength(1), reason: '第 3 版的表也补上了');
      await store.savePreference('engine', 'mpv');
      expect(await store.preference('engine'), 'mpv', reason: '第 4 版的设置表也补上了');
    });

    // 人工决策见 cinema_engine.dart 文件头（11-21 用户选安卓默认 ExoPlayer、允许自己换）。
    test('播放内核的选择记在本机（cinema.db），重开服务还在；没选过为空（按平台默认）', () async {
      var service = await open(() async => packageBytes());
      expect(service.enginePreference, isNull);
      await service.chooseEngine('mpv');
      await service.close();
      service = await open(() async => packageBytes());
      expect(service.enginePreference, 'mpv');
      await service.close();
    });

    test('选集与播放地址：没有可播线路报错；m3u8 经本机代理、mp4 直接播，都带规则的 UA、不带 Referer；清除数据删掉整个目录', () async {
      final client = MockClient((request) async => reply(
        request.url.queryParameters['ids'] == '1'
            ? macCmsList([{'vod_id': 1, 'vod_name': '合成', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/a/index.m3u8#第02集$https://cdn.example.com/b.mp4'}])
            : macCmsList([{'vod_id': 2, 'vod_name': '合成', 'vod_play_from': 'share', 'vod_play_url': r'第01集$https://cdn.example.com/play/a'}]),
        200,
      ));
      final service = await open(() async => packageBytes(), client: client);
      final rule = (await service.rules()).rules.first;
      await service.grantRules([rule]);
      final roads = await service.chapters(rule, '1');
      expect(roads.single.episodes, hasLength(2));
      await expectLater(service.chapters(rule, '2'), throwsA(isA<CinemaRuleException>()));
      final playlist = await service.playable(roads.single.episodes.first.url, rule: rule);
      expect(playlist.uri.host, '127.0.0.1');
      expect(playlist.headers, {'user-agent': cinemaDefaultUserAgent});
      final direct = await service.playable(roads.single.episodes.last.url, rule: rule);
      expect(direct.uri.toString(), 'https://cdn.example.com/b.mp4');
      final directory = Directory(path.join(fixture.directory.path, CinemaService.serviceId));
      expect(directory.existsSync(), isTrue);
      await service.clearData();
      expect(directory.existsSync(), isFalse);
    });

    test('旧规则包写着 adBlocker 也不删分片：经本机代理拿到的清单一个分片不少', () async {
      final segments = [for (var index = 0; index < 30; index++) '#EXTINF:10,\nmain$index.ts'].join('\n');
      final playlist = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:5,\nad0.ts\n#EXT-X-DISCONTINUITY\n$segments\n#EXT-X-ENDLIST\n';
      final client = MockClient((request) async => reply(playlist, 200, headers: {'content-type': 'application/vnd.apple.mpegurl'}));
      final service = await open(() async => packageBytes(), client: client);
      final playable = await service.playable('https://cdn.example.com/v/index.m3u8', rule: (await service.rules()).rules.first);
      final (status, body) = await getLocal(playable.uri);
      expect(status, 200);
      expect(body, contains('\nhttps://cdn.example.com/v/ad0.ts\n'));
      expect('#EXTINF'.allMatches(body), hasLength(31));
      await service.close();
    });

    // 人工决策见 cinema_proxy.dart 文件头（11-21 总交接第 7.8 节：播放器 5 秒读不到就放弃，先备好再交给它）。
    test('打开前先备好：主清单的各码率子清单、第一把密钥与探测都取好，播放器来取时一个请求都不再发', () async {
      final fetched = <String>[];
      final client = MockClient((request) async {
        fetched.add(request.url.path);
        return switch (request.url.path) {
          '/v/index.m3u8' => reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2\n1080/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720/index.m3u8\n', 200),
          '/v/1080/index.m3u8' || '/v/720/index.m3u8' => reply('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200),
          '/v/1080/enc.key' || '/v/720/enc.key' => reply('0123456789abcdef', 200),
          _ => reply('xx', 206),
        };
      });
      final service = await open(() async => packageBytes(), client: client);
      final playable = await service.playable('https://cdn.example.com/v/index.m3u8');
      expect(fetched.toSet(), {'/v/index.m3u8', '/v/1080/index.m3u8', '/v/720/index.m3u8', '/v/1080/enc.key'});
      fetched.clear();
      final master = await getLocal(playable.uri);
      for (final variant in master.$2.split('\n').where((line) => line.startsWith('http'))) {
        final media = await getLocal(Uri.parse(variant));
        await getLocal(Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(media.$2)!.group(1)!));
      }
      expect(fetched.where((path) => path != '/v/720/enc.key'), isEmpty, reason: '清单与第一把密钥都命中缓存（720 的密钥地址不同，播放器选了它才取）');
      await service.close();
    });

  });

  test('本机代理：只认带令牌的路径；改写清单后交回，子清单与密钥回到代理（密钥取一次就记住），分片是绝对地址；上游失败回 502', () async {
    var keyFetches = 0;
    final client = MockClient((request) async => switch (request.url.path) {
      '/v/index.m3u8' => reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n1080/index.m3u8\n', 200, headers: {'content-type': 'application/vnd.apple.mpegurl'}),
      '/v/1080/index.m3u8' => reply('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200),
      '/v/1080/enc.key' => (() {
        keyFetches++;
        return reply('0123456789abcdef', 200);
      })(),
      '/moved.m3u8' => reply('', 302, headers: {'location': 'https://cdn.example.com/v/1080/index.m3u8'}),
      _ => reply('', 404),
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    final get = getLocal;
    final master = await get(await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream));
    expect(master.$1, 200);
    final variant = Uri.parse(master.$2.split('\n').firstWhere((line) => line.startsWith('http')));
    expect(variant.host, '127.0.0.1');
    final media = await get(variant);
    expect(media.$2, contains('\nhttps://cdn.example.com/v/1080/seg0.ts\n'));
    final key = Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(media.$2)!.group(1)!);
    expect((key.host, key.pathSegments.last), ('127.0.0.1', 'k'));
    expect(await get(key), (200, '0123456789abcdef'));
    expect(await get(key), (200, '0123456789abcdef'));
    expect(keyFetches, 1);
    // 跳转之后按最终地址补全相对路径。
    final moved = await get(await proxy.open(Uri.parse('https://cdn.example.com/moved.m3u8'), stream));
    expect(moved.$2, contains('https://cdn.example.com/v/1080/seg0.ts'));
    expect((await get(await proxy.open(Uri.parse('https://cdn.example.com/missing.m3u8'), stream))).$1, HttpStatus.badGateway);
    final forged = (await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream)).replace(pathSegments: ['wrong', 'p']);
    expect((await get(forged)).$1, HttpStatus.notFound);
  });

  // 11-22 Codex 复核 P1：外部清单能让手机去取 127.0.0.1 上的服务（清单、选集与跳转都不签名，规则包的签名与本机代理的口令挡不住）。
  test('本机代理只认公网：子清单、密钥、跳转指向本机或内网都不去取，分片与初始化段指向本机或内网整份不给', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      return switch (request.url.path) {
        '/master.m3u8' => reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://127.0.0.1:8080/admin.m3u8\n', 200),
        '/key.m3u8' => reply('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="http://192.168.1.1/key"\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200),
        '/seg.m3u8' => reply('#EXTM3U\n#EXTINF:10,\nhttp://10.0.0.8:9000/seg0.ts\n#EXT-X-ENDLIST\n', 200),
        '/map.m3u8' => reply('#EXTM3U\n#EXT-X-MAP:URI="http://router/init.mp4"\n#EXTINF:10,\nseg0.m4s\n#EXT-X-ENDLIST\n', 200),
        '/moved.m3u8' => reply('', 302, headers: {'location': 'http://[::1]:9000/x.m3u8'}),
        '/port.m3u8' => reply('#EXTM3U\n#EXTINF:10,\nhttps://cdn2.example.com:8443/seg0.ts\n#EXT-X-ENDLIST\n', 200),
        _ => reply('', 404),
      };
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    Future<(int, String)> open(String path) async => getLocal(await proxy.open(Uri.parse('https://cdn.example.com$path'), stream));
    final master = await open('/master.m3u8');
    expect(master.$1, 200, reason: '主清单本身在公网');
    expect((await getLocal(Uri.parse(master.$2.split('\n').firstWhere((line) => line.startsWith('http'))))).$1, HttpStatus.badGateway);
    final keyed = await open('/key.m3u8');
    expect((await getLocal(Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(keyed.$2)!.group(1)!))).$1, HttpStatus.badGateway);
    expect((await open('/seg.m3u8')).$1, HttpStatus.badGateway, reason: '分片由播放器直连，指向内网就整份不给');
    expect((await open('/map.m3u8')).$1, HttpStatus.badGateway, reason: '单段主机名');
    expect((await open('/moved.m3u8')).$1, HttpStatus.badGateway);
    expect((await open('/port.m3u8')).$1, 200, reason: '公网 CDN 的非标准端口照常');
    expect(hosts.toSet(), {'cdn.example.com'}, reason: '本机、内网一个请求都没发');
  });

  // 11-22 Codex 复核：密钥原来只按地址记、不过期，同一地址按请求条件给不同密钥时，后一路拿到前一路的那把、解不开。
  test('本机代理的密钥按地址加请求头记、5 分钟后重取', () async {
    var now = DateTime.utc(2026, 11, 22);
    final fetched = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) return reply('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200);
      final agent = request.headers['user-agent']!;
      fetched.add(agent);
      return reply(agent == 'UA-A' ? 'aaaaaaaaaaaaaaaa' : 'bbbbbbbbbbbbbbbb', 200);
    });
    final proxy = CinemaProxy(CinemaHttp(client: client), now: () => now);
    addTearDown(proxy.close);
    Future<String> key(String agent) async {
      final media = await getLocal(await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), CinemaStream(headers: cinemaHeaders(agent, ''))));
      return (await getLocal(Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(media.$2)!.group(1)!))).$2;
    }

    expect(await key('UA-A'), 'aaaaaaaaaaaaaaaa');
    expect(await key('UA-B'), 'bbbbbbbbbbbbbbbb', reason: '请求条件不同，不拿前一路的那把');
    expect(await key('UA-A'), 'aaaaaaaaaaaaaaaa');
    expect(fetched, ['UA-A', 'UA-B']);
    now = now.add(const Duration(minutes: 6));
    await key('UA-A');
    expect(fetched, ['UA-A', 'UA-B', 'UA-A'], reason: '过了有效期重取');
  });

  test('取清单的跳转共用一个总时限：三跳各 100 毫秒、总时限 180 毫秒就超时（不是每跳重新计）', () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return switch (request.url.path) {
        '/a' => reply('', 302, headers: {'location': '/b'}),
        '/b' => reply('', 302, headers: {'location': '/c'}),
        _ => reply('#EXTM3U\n', 200),
      };
    });
    final cinema = CinemaHttp(client: client);
    addTearDown(cinema.close);
    await expectLater(cinema.fetch(Uri.parse('https://cdn.example.com/a'), const {}, timeout: const Duration(milliseconds: 180)), throwsA(isA<CinemaHttpException>().having((error) => error.message, 'message', '超时')));
    expect((await cinema.fetch(Uri.parse('https://cdn.example.com/a'), const {}, timeout: const Duration(seconds: 2))).uri.path, '/c');
  });

  test('本机代理的探测：原地址与替代地址同时探、原地址取得到就不换（原地址优先），取不到而替代取得到才换；结论按主机记住；超时这类没定论的一分钟后再探；主清单不探', () async {
    var now = DateTime.utc(2026, 11, 20);
    final hits = <String>[];
    final client = MockClient((request) async {
      final url = request.url;
      if (url.path.endsWith('.m3u8')) {
        final edge = url.pathSegments.first;
        // 每份分片清单都是新地址（不走清单缓存），第一个分片的路径首段是真实域名。
        return reply('#EXTM3U\n#EXTINF:10,\nhttps://$edge.example.com/real-$edge.example.com/seg0.ts\n#EXT-X-ENDLIST\n', 200);
      }
      hits.add(url.host);
      return switch (url.host) {
        'ok.example.com' || 'real-ok.example.com' => reply('xx', 206),
        'front.example.com' => reply('', 418),
        'real-front.example.com' => reply('xx', 206),
        'slow.example.com' => await Completer<http.Response>().future,
        _ => reply('xx', 206),
      };
    });
    final proxy = CinemaProxy(CinemaHttp(client: client), now: () => now, probeBudget: const Duration(milliseconds: 200));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    var serial = 0;
    Future<String> playlist(String edge) async => (await getLocal(await proxy.open(Uri.parse('https://cdn.example.com/$edge/${serial++}.m3u8'), stream))).$2;
    expect(await playlist('ok'), contains('https://ok.example.com/real-ok.example.com/seg0.ts'));
    expect(hits.toSet(), {'ok.example.com', 'real-ok.example.com'}, reason: '两路同时探');
    expect(await playlist('front'), contains('https://real-front.example.com/seg0.ts'));
    hits.clear();
    await playlist('front');
    expect(hits, isEmpty, reason: '同一主机记住结论');
    expect(await playlist('slow'), contains('https://real-slow.example.com/seg0.ts'));
    hits.clear();
    await playlist('slow');
    expect(hits, isEmpty);
    now = now.add(const Duration(minutes: 2));
    await playlist('slow');
    expect(hits, contains('slow.example.com'), reason: '没定论的一分钟后再探');
    hits.clear();
    now = now.add(const Duration(minutes: 2));
    await playlist('front');
    expect(hits, isEmpty, reason: '确定的结论记 30 分钟');
    final master = MockClient((request) async {
      hits.add(request.url.host);
      return reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://edge.example.com/real.example.com/1080/index.m3u8\n', 200);
    });
    final masterProxy = CinemaProxy(CinemaHttp(client: master));
    addTearDown(masterProxy.close);
    hits.clear();
    await getLocal(await masterProxy.open(Uri.parse('https://cdn.example.com/master.m3u8'), stream));
    expect(hits, ['cdn.example.com'], reason: '主清单里是子清单，不探');
  });

  test('本机代理：重新载入的预取不用缓存的清单、重新探测，取到的进缓存给播放器用；预取可以取消', () async {
    var version = 0;
    final probes = <String>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        version++;
        return reply('#EXTM3U\n#EXTINF:10,\nhttps://edge.example.com/real.example.com/seg$version.ts?sign=$version\n#EXT-X-ENDLIST\n', 200);
      }
      probes.add(request.url.host);
      return reply('xx', 206);
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    final playlist = Uri.parse('https://cdn.example.com/v/index.m3u8');
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=1'));
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=1'), reason: '点播清单走缓存');
    probes.clear();
    await proxy.warm(playlist, stream, fresh: true);
    expect(probes, isNotEmpty, reason: '重新载入也重新探测');
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=2'), reason: '重新载入的预取不用缓存，取到的进了缓存');
    expect(version, 2, reason: '播放器来取时用的是刚取的，不再请求一次');
    // 预取取消：没人等了，下一次另起请求。
    final gate = Completer<void>();
    final slow = MockClient((request) async {
      await gate.future;
      return reply('#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200);
    });
    final warmProxy = CinemaProxy(CinemaHttp(client: slow));
    addTearDown(warmProxy.close);
    final cancel = Completer<void>();
    final warming = warmProxy.warm(Uri.parse('https://cdn.example.com/slow.m3u8'), stream, cancel: cancel.future);
    await pumpEventQueue();
    cancel.complete();
    await warming.timeout(const Duration(seconds: 1));
    gate.complete();
  });

  test('本机代理：一路交回后它还在等的清单请求立即回 404，之后再来的也是 404', () async {
    final gate = Completer<void>();
    final client = MockClient((request) async {
      await gate.future;
      return reply('#EXTM3U\n#EXTINF:10,\nseg0.ts\n', 200);
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final link = await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), CinemaStream(headers: cinemaHeaders('', '')));
    final waiting = getLocal(link);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    proxy.release(link);
    expect((await waiting).$1, HttpStatus.notFound);
    gate.complete();
    expect((await getLocal(link)).$1, HttpStatus.notFound);
  });

  test('预取：取主清单与第一个码率的子清单并探好，之后播放直接用缓存的（点播几分钟内不再取）；直播清单每次现取', () async {
    final fetched = <String>[];
    final client = MockClient((request) async {
      fetched.add(request.url.path);
      return switch (request.url.path) {
        '/v/index.m3u8' => reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n1080/index.m3u8\n', 200),
        '/v/1080/index.m3u8' => reply('#EXTM3U\n#EXTINF:10,\nhttps://edge.example.com/real.example.com/seg0.ts\n#EXT-X-ENDLIST\n', 200),
        '/live.m3u8' => reply('#EXTM3U\n#EXTINF:10,\nseg0.ts\n', 200),
        _ => reply('xx', 206),
      };
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    await proxy.warm(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream);
    expect(fetched, ['/v/index.m3u8', '/v/1080/index.m3u8', '/real.example.com/seg0.ts', '/seg0.ts']);
    fetched.clear();
    final master = await getLocal(await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream));
    final variant = Uri.parse(master.$2.split('\n').firstWhere((line) => line.startsWith('http')));
    expect((await getLocal(variant)).$2, contains('https://edge.example.com/real.example.com/seg0.ts'));
    expect(fetched, isEmpty, reason: '预取过的清单与探测结论直接用');
    final live = await proxy.open(Uri.parse('https://cdn.example.com/live.m3u8'), stream);
    await getLocal(live);
    await getLocal(live);
    expect(fetched, ['/live.m3u8', '/live.m3u8']);
  });

  // 11-21 总交接第 7.6 节：先量预取命中率再定预取策略。
  test('开发者模式下记播放器来取的清单预取过没有、用没用上缓存、跳没跳转，密钥取了多久；没预取的记 miss', () async {
    final logs = captureDiagnostics();
    final client = MockClient((request) async => switch (request.url.path) {
      '/v/index.m3u8' => reply('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n1080/index.m3u8\n', 200),
      '/v/1080/index.m3u8' => reply('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200),
      '/v/1080/enc.key' => reply('0123456789abcdef', 200),
      '/cold.m3u8' => reply('#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n', 200),
      _ => reply('xx', 206),
    });
    final proxy = CinemaProxy(CinemaHttp(client: client));
    addTearDown(proxy.close);
    final stream = CinemaStream(headers: cinemaHeaders('', ''));
    await proxy.warm(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream);
    final master = await getLocal(await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), stream));
    final variant = await getLocal(Uri.parse(master.$2.split('\n').firstWhere((line) => line.startsWith('http'))));
    await getLocal(Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(variant.$2)!.group(1)!));
    await getLocal(await proxy.open(Uri.parse('https://cdn.example.com/cold.m3u8'), stream));
    final playlists = [for (final line in logs) if (line.contains('action=playlist')) line];
    expect(playlists, hasLength(3));
    expect(playlists.take(2).every((line) => line.contains('cache=hit warmed=yes') && line.contains('redirected=false')), isTrue);
    expect(playlists.last, contains('cache=miss warmed=no'));
    expect(logs.any((line) => line.contains('action=key') && line.contains('cached=true ok=true')), isTrue, reason: '预取时已经取好第一把密钥');
    expect(logs.where((line) => line.contains('cdn.example.com')), isEmpty, reason: '不记地址');
  });

  // 人工决策见 cinema_page.dart 的 _onQuery 与 _historySlivers、cinema_episodes.dart、cinema_detail_page.dart 的 _onScroll（11-20 只留找片后的界面优化）。
  group('页面', () {
    testWidgets('选集网格：一格同宽（按这一段最长的集名）、超过 50 集分段只建当前一段、打开停在选中那集的一段、倒序从最后一集起、只有一集不给倒序', (tester) async {
      final picked = <int>[];
      List<CinemaEpisode> episodes(int count) => [for (var index = 0; index < count; index++) CinemaEpisode(name: index == 60 ? '第61集 特别篇' : '第${index + 1}集', url: 'https://media.example.com/$index.mp4')];
      Future<void> show(List<CinemaEpisode> list, int? selected) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: SingleChildScrollView(child: CinemaEpisodeGrid(episodes: list, selected: selected, onPick: picked.add)))));
      }

      await show(episodes(120), 85);
      // 标题行「选集 · 共 N 集」，倒序在同一行（11-21 用户嫌倒序单独挂着不协调）。
      expect(find.text('共 120 集'), findsOneWidget);
      expect(tester.getCenter(find.text('倒序')).dy, closeTo(tester.getCenter(find.text('选集')).dy, 2));
      expect(find.text('51–100'), findsOneWidget);
      expect(find.text('第86集'), findsOneWidget);
      expect(find.text('第1集'), findsNothing);
      expect(find.byType(CampusGlassChip), findsNWidgets(3 + cinemaEpisodePage));
      expect(tester.getSize(find.widgetWithText(CampusGlassChip, '第62集')).width, tester.getSize(find.widgetWithText(CampusGlassChip, '第61集 特别篇')).width);
      await tester.tap(find.text('倒序'));
      await tester.pump();
      expect(find.text('120–71'), findsOneWidget);
      expect(find.text('正序'), findsOneWidget);
      await tester.tap(find.text('第120集'));
      expect(picked, [119]);
      await show(episodes(12), null);
      expect(find.textContaining('–'), findsNothing);
      expect(find.text('倒序'), findsOneWidget);
      await show(episodes(1), null);
      expect(find.text('倒序'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('首页：看过的是横向海报条、⋯ 里删除先确认；搜索中输入框照常可改；暂不可用按原因分组只写源名；清空搜索框回到看过的', (tester) async {
      final slow = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.host == 'beta.example.com') return reply('', 404);
        await slow.future;
        return reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_year': '2020'}]), 200);
      });
      final (fixture, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(() async {
        await service.grantRules((await service.rules()).rules);
        await service.store.saveHistory(CinemaHistory(key: 'seen', name: '看过的合成片', cover: '', ruleId: 'alpha', source: '1', road: 0, episode: 0, episodeName: '第01集', position: const Duration(minutes: 10), duration: const Duration(minutes: 40), updatedAt: DateTime.now().toUtc()));
      });
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {CinemaService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPage(runtime: runtime)));
      await settleUntil(tester, () => find.text('看过的合成片').evaluate().isNotEmpty);
      expect(find.byType(CinemaHistoryCard), findsOneWidget);

      await tester.enterText(find.byType(TextField), '合成');
      await tester.tap(find.text('搜索'));
      await settleUntil(tester, () => find.text('看过的合成片').evaluate().isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue, reason: '还有源没回来，输入框照常可改');
      slow.complete();
      await settleUntil(tester, () => find.text('合成电影').evaluate().isNotEmpty);
      expect(find.text('出错：另一资源'), findsOneWidget, reason: 'HTTP 404 算出错，只写源名');
      expect(find.textContaining('HTTP'), findsNothing);
      expect(find.textContaining('暂不可用'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.text('合成电影'), findsNothing);
      expect(find.text('看过的合成片'), findsOneWidget);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('删除这条记录'), findsOneWidget);
      await tester.tap(find.text('删除').last);
      await settleUntil(tester, () => find.text('看过的合成片').evaluate().isEmpty);
      expect(find.text('看过的'), findsNothing);
      expect(await tester.runAsync(() => service.store.history(DateTime.now())), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('选集页：顶栏片名在大标题滚出去后才出现；120 集打开停在上次看到那集所在的一段', (tester) async {
      final episodes = [for (var index = 1; index <= 120; index++) '第$index集\$https://media.example.com/$index.mp4'].join('#');
      final client = MockClient((request) async => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成长剧', 'vod_play_from': 'mp4', 'vod_play_url': episodes}]), 200));
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(() async {
        await service.rules();
        await service.grantRules(service.package!.rules);
        await service.store.saveHistory(CinemaHistory(key: 'long', name: '合成长剧', cover: '', ruleId: 'alpha', source: '1', road: 0, episode: 85, episodeName: '第86集', position: const Duration(minutes: 3), duration: const Duration(minutes: 40), updatedAt: DateTime.now().toUtc()));
      });
      final title = CinemaTitle(key: 'long', name: '合成长剧', year: '2026', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成长剧', remarks: ''));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaDetailPage(service: service, title: title)));
      await settleUntil(tester, () => find.text('第86集').evaluate().isNotEmpty);
      double heading() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.descendant(of: find.byType(AppBar), matching: find.text('合成长剧')), matching: find.byType(AnimatedOpacity))).opacity;
      expect(find.text('51–100'), findsOneWidget);
      expect(find.text('第1集'), findsNothing);
      expect(heading(), 0);
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pump();
      expect(heading(), 1);
      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      await tester.pump();
      expect(heading(), 0);
      await tester.pumpWidget(const SizedBox());
    });

    // 人工决策见 cinema_models.dart 的 cinemaTitleKey 与 cinema_service.dart 的 searchCacheLifetime（11-21 总交接第 6.6、7.4 节）。
    testWidgets('首页：搜索结果写分类、预告片单独一条；离开结果再搜同一个词用最近的结果，结果显示着时再按搜索是重新搜', (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_year': '2020', 'type_name': '科幻片'}, {'vod_id': 2, 'vod_name': '合成电影', 'vod_year': '2020', 'type_name': '预告片'}]), 200);
      });
      final (fixture, service) = await openCinemaForPage(tester, client: client, package: packageBytes(rules: [withCategory(macCmsRule('alpha', 'https://alpha.example.com/api.php'))]));
      await tester.runAsync(() async => service.grantRules((await service.rules()).rules));
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {CinemaService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPage(runtime: runtime)));
      await settleUntil(tester, () => find.byType(TextField).evaluate().isNotEmpty);
      Future<void> search() async {
        await tester.tap(find.text('搜索'));
        await settleUntil(tester, () => find.text('2020 · 预告片').evaluate().isNotEmpty);
        await settleUntil(tester, () => find.textContaining('还在搜').evaluate().isEmpty && find.text('搜索').evaluate().isNotEmpty);
      }

      await tester.enterText(find.byType(TextField), '合成');
      await search();
      expect(find.text('2020 · 科幻片'), findsOneWidget);
      expect(find.text('合成电影'), findsNWidgets(2), reason: '正片与预告片各一条');
      expect(requests, 1);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '合成');
      await search();
      expect(requests, 1, reason: '一分钟内用最近的结果');
      await tester.tap(find.text('搜索'));
      await settleUntil(tester, () => requests == 2);
      expect(requests, 2, reason: '结果显示着时再按是重新搜');
      await settleUntil(tester, () => find.text('搜索').evaluate().isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    // 11-21 Codex 总交接：原来选集页进页面时复制一份片源就不变了，搜索晚回来的源只在「几个源」里数得到。
    testWidgets('选集页：进页面以后又回来的源接在片源菜单末尾，已选的那个不变', (tester) async {
      final client = MockClient((request) async => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_play_from': 'mp4', 'vod_play_url': r'正片$https://media.example.com/movie.mp4'}]), 200));
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(service.rules);
      final title = CinemaTitle(key: 'movie', name: '合成电影', year: '', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaDetailPage(service: service, title: title)));
      await settleUntil(tester, () => find.text('正片').evaluate().isNotEmpty);
      CampusMenuField<int> menu() => tester.widget<CampusMenuField<int>>(find.byType(CampusMenuField<int>));
      expect(menu().items, hasLength(1));
      title.addSource(const CinemaSourceRef(ruleId: 'beta', source: '2', name: '合成电影', remarks: ''));
      await tester.pump();
      expect([for (final item in menu().items) item.label], ['合成资源', '另一资源']);
      expect(menu().value, 0);
      expect(find.textContaining('2 个源'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('选集页：看完了的「接着看」变成看下一集，没有下一集是从头看（人工决策见 CinemaHistory.finished）', (tester) async {
      final client = MockClient((request) async => reply(
        macCmsList([
          request.url.queryParameters['ids'] == '1'
              ? {'vod_id': 1, 'vod_name': '合成剧', 'vod_play_from': 'mp4', 'vod_play_url': r'第01集$https://media.example.com/1.mp4#第02集$https://media.example.com/2.mp4'}
              : {'vod_id': 2, 'vod_name': '合成电影', 'vod_play_from': 'mp4', 'vod_play_url': r'正片$https://media.example.com/movie.mp4'},
        ]),
        200,
      ));
      final (_, service) = await openCinemaForPage(tester, client: client);
      CinemaHistory watched(String key, String source, String episodeName, Duration position) =>
          CinemaHistory(key: key, name: key, cover: '', ruleId: 'alpha', source: source, road: 0, episode: 0, episodeName: episodeName, position: position, duration: const Duration(minutes: 40), updatedAt: DateTime.now().toUtc());
      await tester.runAsync(() async {
        await service.rules();
        await service.grantRules(service.package!.rules);
        await service.store.saveHistory(watched('series', '1', '第01集', const Duration(minutes: 39)));
        await service.store.saveHistory(watched('movie', '2', '正片', const Duration(minutes: 39)));
        await service.store.saveHistory(watched('half', '1', '第01集', const Duration(minutes: 20)));
      });
      Future<void> show(String key, String source, String label) async {
        final title = CinemaTitle(key: key, name: key, year: '', cover: '', remarks: '')..addSource(CinemaSourceRef(ruleId: 'alpha', source: source, name: key, remarks: ''));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaDetailPage(service: service, title: title)));
        await settleUntil(tester, () => find.text(label).evaluate().isNotEmpty);
        expect(find.text(label), findsOneWidget, reason: key);
      }

      await show('series', '1', '看下一集 第02集');
      await show('movie', '2', '从头看 正片');
      await show('half', '1', '接着看 第01集');
      await tester.pumpWidget(const SizedBox());
    });

    // 11-21 Codex 指出：进度条画的时候左右各缩进 10，点按却按整宽换算，点画出来的起点不是 0、终点到不了片尾（轨道越窄、片子越长差得越多）。
    testWidgets('进度条：点画出来的起点跳到 0、终点跳到片尾，拖到起点松手也是 0', (tester) async {
      final platform = _SeekRecorder()..state = PlayerState(duration: const Duration(seconds: 10417));
      final player = Player(platformPlayer: platform);
      final seeked = <Duration>[];
      // onSeek 要在命令交给播放器之前（播放页从这一刻开始计跳转用时）：回调里播放器还停在上一次的目标。
      final before = <Duration?>[];
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 220,
              child: CinemaPlayerControls(player: CinemaMpvEngine.wrap(player), title: '合成', subtitle: '', fullscreen: false, busy: false, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}, onSeek: (target) {
                seeked.add(target);
                before.add(platform.target);
              }),
            ),
          ),
        ),
      ));
      await tester.pump();
      final bar = tester.getRect(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter.runtimeType.toString() == '_ProgressPainter'));
      // 两次点按隔开双击的时限，免得算成双击暂停。
      await tester.tapAt(Offset(bar.left + 10, bar.center.dy));
      await tester.pump(const Duration(milliseconds: 500));
      expect(platform.target, Duration.zero);
      await tester.tapAt(Offset(bar.right - 10, bar.center.dy));
      await tester.pump(const Duration(milliseconds: 500));
      expect(platform.target, const Duration(seconds: 10417));
      await tester.dragFrom(bar.center, Offset(-(bar.width / 2 - 10), 0));
      await tester.pump();
      expect(platform.target, Duration.zero);
      expect(seeked, [Duration.zero, const Duration(seconds: 10417), Duration.zero], reason: '每次跳转都告诉播放页（记看到哪、诊断用时）');
      expect(before, [null, Duration.zero, const Duration(seconds: 10417)], reason: '先告诉播放页、再交给播放器');
      await tester.pumpWidget(const SizedBox());
      await player.dispose();
    });

    // 11-21 Codex 总交接第 12.5 节：实际可跳的缓存是好几段，seek 一交出就返回、位置立刻报成目标（cinema_playback_truth.dart）。
    test('缓存状态：libmpv 写成 JSON 的 demuxer-cache-state 取出几段能本地跳转的缓存，按起点排、起点不小于零；给了空列表是明确没有，读不懂是读不到（null）', () {
      // 同 11-21 本机 mpv 跳到 20:00 后读到的形状（截掉无关字段）。
      const state = '{"cache-end":1287.38,"reader-pts":1209.54,"eof":false,"ts-per-stream":[{"type":"video","cache-end":1288.8}],"bof-cached":true,"seekable-ranges":[{"start":1198.623222,"end":1283.703222},{"start":-0.000000,"end":49.143222}]}';
      expect(cinemaSeekableRanges(state), [(Duration.zero, const Duration(milliseconds: 49100)), (const Duration(milliseconds: 1198600), const Duration(milliseconds: 1283700))]);
      expect(cinemaSeekableRanges('{"seekable-ranges":[{"start":10,"end":20},{"start":5,"end":3},{"start":"x","end":9},{"start":-2,"end":3}]}'), [(Duration.zero, const Duration(seconds: 3)), (const Duration(seconds: 10), const Duration(seconds: 20))], reason: '倒着的、不是数字的段不要，起点夹到零');
      expect(cinemaSeekableRanges('{"seekable-ranges":[]}'), isEmpty, reason: '明确没有缓存');
      expect(cinemaSeekableRanges('{"seekable-ranges":[{"start":"x","end":9}]}'), isNull, reason: '列了段却一段都读不懂：读不到，不当成没有');
      expect(cinemaSeekableRanges('{"cache-end":3}'), isNull);
      expect(cinemaSeekableRanges('not json'), isNull);
      expect(cinemaSeekableRanges('[]'), isNull);
    });

    // 11-21 Codex 复核 #344：上一次跳转晚到的 no 把这一次记成 0 毫秒；原生恢复与目标处走起来要分开记；读不到缓存段要记 unknown。
    test('跳转计时：原生恢复要 seeking 变回 no 且位置就是这次的目标（上一次晚到的 no 不算）；在播的再等时钟越过目标才算走起来；缓存记 true、false、unknown；读出网络层的下载速率', () async {
      final platform = _SeekRecorder()..state = const PlayerState(duration: Duration(hours: 1));
      final truth = CinemaPlaybackTruth(Player(platformPlayer: platform));
      addTearDown(truth.dispose);
      void at(Duration position, {bool playing = false}) => platform.state = platform.state.copyWith(position: position, playing: playing);
      expect(truth.seekable.value, isNull, reason: '测试替身不是 libmpv，读不到');
      expect(await truth.decoder(), '', reason: '问不到解码器');

      // 读不到缓存段：unknown（null），不当成确定没命中。
      final unknown = truth.begin(const Duration(minutes: 2));
      at(const Duration(minutes: 2));
      truth.notify(seeking: 'no');
      expect((await unknown).cached, isNull);

      truth.notify(cacheState: '{"seekable-ranges":[{"start":0,"end":80},{"start":1198,"end":1214}]}');
      expect(truth.seekable.value, hasLength(2));
      // 网络层的下载速率（卡顿时记，分清线路慢还是缓冲策略）；没给为空。
      truth.notify(cacheState: '{"raw-input-rate":262144,"seekable-ranges":[{"start":0,"end":80},{"start":1198,"end":1214}]}');
      expect(truth.inputRate, 262144);
      truth.notify(cacheState: '{"seekable-ranges":[{"start":0,"end":80},{"start":1198,"end":1214}]}');
      expect(truth.inputRate, isNull);
      // Codex 复现的顺序：A 进行中（yes）开始 B，A 晚到的 no 读到的位置是 A 的落点，不能把 B 记成恢复。
      // 暂停着：原生恢复就算完，晚到的 no 一旦被认成这一次的会立刻记成恢复（在播时还有「走起来」那一步挡着，测不出归属）。
      final first = truth.begin(const Duration(minutes: 10));
      at(const Duration(minutes: 10));
      truth.notify(seeking: 'yes');
      final second = truth.begin(const Duration(minutes: 20, seconds: 5));
      var settled = false;
      unawaited(second.then((_) => settled = true));
      truth.notify(seeking: 'no');
      await pumpEventQueue();
      expect(settled, isFalse, reason: '位置还是上一次的落点');
      expect(((await first).result, (await first).cached), ('superseded', false));
      // B 原生恢复了（位置是 B 的目标）；在播的还要等时钟越过目标才算走起来。
      at(const Duration(minutes: 20, seconds: 5), playing: true);
      truth.notify(seeking: 'no');
      await pumpEventQueue();
      expect(settled, isFalse, reason: '原生恢复了还没走起来');
      truth.notify(position: const Duration(minutes: 20, seconds: 5, milliseconds: 400));
      final done = await second;
      expect((done.result, done.cached, done.id, done.restartMs != null, done.playingMs != null), ('ok', true, (await first).id + 1, true, true));
      expect(done.playingMs! >= done.restartMs!, isTrue);

      // 命中缓存时 yes、no 挨得很近、两次通知都读到 no：不要求先看到 yes；暂停着跳的原生恢复就算完。
      final quick = truth.begin(const Duration(seconds: 30));
      at(const Duration(seconds: 30));
      truth.notify(seeking: 'no');
      final quickDone = await quick;
      expect((quickDone.result, quickDone.cached, quickDone.playingMs), ('ok', true, null));

      // 播放器明确说没有缓存：cached=false，不是 unknown。
      truth.notify(cacheState: '{"seekable-ranges":[]}');
      expect(truth.seekable.value, isEmpty);
      final empty = truth.begin(const Duration(seconds: 40));
      truth.reset();
      expect(((await empty).cached, (await empty).result), (false, 'cancelled'), reason: '换了媒体不再算');
    });

    test('进度条的已缓冲：按真实的几段画；播放器明确说没有就不画；读不到时只画当前位置到缓存末端，不从零画起；片长不知道时不画', () {
      const hour = Duration(hours: 1);
      expect(cinemaCachedSpans([(Duration.zero, const Duration(minutes: 6)), (const Duration(minutes: 30), const Duration(minutes: 36))], duration: hour, position: const Duration(minutes: 31), bufferEnd: const Duration(minutes: 36)), [(0.0, 0.1), (0.5, 0.6)]);
      expect(cinemaCachedSpans(const [], duration: hour, position: const Duration(minutes: 10), bufferEnd: const Duration(minutes: 11)), isEmpty, reason: '明确没有（Codex 复现：原来照样画出 600–660 秒）');
      expect(cinemaCachedSpans(null, duration: hour, position: const Duration(minutes: 30), bufferEnd: const Duration(minutes: 36)), [(0.5, 0.6)]);
      expect(cinemaCachedSpans(null, duration: hour, position: const Duration(minutes: 30), bufferEnd: const Duration(minutes: 30)), isEmpty);
      expect(cinemaCachedSpans([(Duration.zero, const Duration(minutes: 6))], duration: Duration.zero, position: Duration.zero, bufferEnd: Duration.zero), isEmpty);
    });

    // 人工决策见 cinema_player_controls.dart 文件头 11-21 那条（用户要求直接删除跳过片头）。
    testWidgets('没有「跳过片头」：长片刚开播、控件显示着也不给', (tester) async {
      final player = Player(platformPlayer: _SeekRecorder()..state = PlayerState(duration: const Duration(minutes: 95)));
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: Scaffold(body: SizedBox(width: 360, height: 220, child: CinemaPlayerControls(player: CinemaMpvEngine.wrap(player), title: '合成', subtitle: '', fullscreen: false, busy: false, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}))),
      ));
      await tester.pump();
      expect(find.text('合成'), findsOneWidget, reason: '控件显示着');
      expect(find.textContaining('片头'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await player.dispose();
    });

    // 11-21 用户截图：中间闪的是刚进入的状态、下栏写的是点了会怎样，两处正好相反，还叠在加载动画上（cinema_player_controls.dart 的 _playButton）。
    testWidgets('播放暂停：中间与下栏是同一个意思（暂停时都是「播放」、播放中都是「暂停」）；打开中、出错时中间不放，只剩下栏一颗', (tester) async {
      Future<void> show(PlayerState state, {bool busy = false, String? error}) async {
        final player = Player(platformPlayer: _SeekRecorder()..state = state);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(
          theme: campusTheme(),
          home: Scaffold(body: SizedBox(width: 360, height: 220, child: CinemaPlayerControls(player: CinemaMpvEngine.wrap(player), title: '合成', subtitle: '', fullscreen: false, busy: busy, error: error, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}))),
        ));
        await tester.pump();
        addTearDown(player.dispose);
      }

      const length = Duration(minutes: 95);
      await show(const PlayerState(duration: length));
      expect((find.byTooltip('播放').evaluate().length, find.byTooltip('暂停').evaluate().length), (2, 0));
      await show(const PlayerState(duration: length, playing: true));
      expect((find.byTooltip('播放').evaluate().length, find.byTooltip('暂停').evaluate().length), (0, 2));
      await show(const PlayerState(duration: length, playing: true), busy: true);
      expect(find.byTooltip('暂停'), findsOneWidget, reason: '打开中中间是加载动画');
      await show(const PlayerState(duration: length), error: '这个源暂不可用（HTTP 404），换一个源试试');
      expect(find.byTooltip('播放'), findsOneWidget, reason: '出错时中间是报错卡片');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('片长还不知道（打开中）时进度两边写「--:--」，不写「00:00」', (tester) async {
      final player = Player(platformPlayer: _SeekRecorder()..state = const PlayerState());
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: Scaffold(body: SizedBox(width: 360, height: 220, child: CinemaPlayerControls(player: CinemaMpvEngine.wrap(player), title: '合成', subtitle: '', fullscreen: false, busy: true, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}, resumedFrom: const Duration(hours: 2, minutes: 13, seconds: 42)))),
      ));
      await tester.pump();
      expect(find.text('--:--'), findsNWidgets(2));
      expect(find.text('00:00'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      await player.dispose();
    });

    testWidgets('续播的「从头播放」出错时不显示（不和报错卡片叠在一起），没出错照常显示', (tester) async {
      final player = Player(platformPlayer: _SeekRecorder()..state = PlayerState(duration: const Duration(minutes: 95)));
      Future<void> show({String? error}) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(
          theme: campusTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 220,
              child: CinemaPlayerControls(player: CinemaMpvEngine.wrap(player), title: '合成', subtitle: '', fullscreen: false, busy: false, error: error, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}, resumedFrom: const Duration(minutes: 30, seconds: 20)),
            ),
          ),
        ));
        await tester.pump();
      }

      await show();
      expect(find.textContaining('从头播放'), findsOneWidget);
      await show(error: '这个源暂不可用（HTTP 404），换一个源试试');
      expect(find.textContaining('从头播放'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      await player.dispose();
    });
  });

  // 人工决策见 cinema_engine.dart 文件头（11-21 真机对照后用户选安卓默认 ExoPlayer，允许自己换，打不开的退回 mpv）。
  group('播放内核', () {
    test('没选过时安卓默认系统播放器（菜单写 ExoPlayer）、iOS 默认 mpv；记下的选择优先，认不出的用默认', () {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect((cinemaEngineOf(null), CinemaEngineKind.system.label), (CinemaEngineKind.system, 'ExoPlayer'));
        expect(cinemaEngineOf('mpv'), CinemaEngineKind.mpv);
        expect(cinemaEngineOf('vlc'), CinemaEngineKind.system);
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect((cinemaEngineOf(null), CinemaEngineKind.system.label), (CinemaEngineKind.mpv, '系统播放器'));
        expect(cinemaEngineOf('system'), CinemaEngineKind.system);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('系统播放器的请求头：UA 与 Referer 改成 video_player 认的标准写法（小写的 UA 会被它换成自己的默认 UA），其余原样', () {
      expect(cinemaSystemHeaders({'user-agent': 'UA', 'referer': 'https://r.example.com/', 'x-token': 't'}), {'User-Agent': 'UA', 'Referer': 'https://r.example.com/', 'x-token': 't'});
      expect(cinemaSystemHeaders({'User-Agent': 'UA'}), {'User-Agent': 'UA'});
    });

    test('首帧：从头开的位置动了就算；从中途开的要等时钟越过起点 0.3 秒（播放器出画之前就把位置报成起点），或越过打开中见过的最早位置（跳回了片头）', () {
      expect(cinemaFirstFrame(const Duration(milliseconds: 40), start: Duration.zero, firstSeen: null), isTrue);
      expect(cinemaFirstFrame(Duration.zero, start: Duration.zero, firstSeen: null), isFalse);
      const start = Duration(minutes: 27, seconds: 32);
      expect(cinemaFirstFrame(start, start: start, firstSeen: start), isFalse, reason: '只是位置报成了起点');
      expect(cinemaFirstFrame(start + const Duration(milliseconds: 300), start: start, firstSeen: start), isTrue);
      // 11-21 真机：打开中跳回片头，位置从 0 开始走。
      expect(cinemaFirstFrame(const Duration(milliseconds: 100), start: start, firstSeen: Duration.zero), isFalse);
      expect(cinemaFirstFrame(const Duration(milliseconds: 400), start: start, firstSeen: Duration.zero), isTrue);
    });

    // 11-21 Codex 复核：旧的打开晚回来，把当前这一路当成上一路交回本机代理，当前视频再取清单 404。
    testWidgets('播放页：旧的一次打开晚回来只交回自己，当前这一路的清单照样取得到；打开中缓冲状态卡住但位置在走时收起加载圈；竖屏画面至少 16:9', (tester) async {
      // 手机竖屏的尺寸（400×800），画面区的上限不碰到。
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final client = MockClient((request) async => reply('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg0.ts\n#EXT-X-ENDLIST\n', 200));
      final created = <_FakeEngine>[];
      // 挡住第一次打开的挡板要在真实时钟里建（见 flutter-test 的写法：假时钟里建的 Completer 晚完成时等的人收不到）。
      final gate = (await tester.runAsync(() async => Completer<void>()))!;
      debugCinemaEngineFactory = (kind) {
        final engine = _FakeEngine(kind)..hold = gate;
        created.add(engine);
        return engine;
      };
      addTearDown(() => debugCinemaEngineFactory = null);
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(service.rules);
      final title = CinemaTitle(key: 'film', name: '合成电影', year: '2026', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      const roads = [CinemaRoad(name: 'm3u8', episodes: [CinemaEpisode(name: '正片', url: 'https://media.example.com/1/index.m3u8')])];
      // 本机代理先在真实时钟里起来（在假时钟里起的服务器，真实的请求要等假时钟往前走才处理，等回复时会互相等）。
      await tester.runAsync(() async => service.release(await service.playable(roads.single.episodes.single.url, rule: service.rule('alpha'))));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPlayerPage.title(service: service, title: title, source: title.sources.single, road: 0, episode: 0, start: const Duration(minutes: 38), roads: roads)));
      await settleUntil(tester, () => created.single.opens.isNotEmpty);
      final engine = created.single;
      // 第一次还挡着，点「从头播放」开第二次；第二次先回来。
      await tester.tap(find.textContaining('从头播放'));
      await settleUntil(tester, () => engine.opens.length == 2);
      final current = Uri.parse(engine.opens.last.$1);
      expect(engine.opens.last.$2, Duration.zero);
      expect((await tester.runAsync(() => getLocal(current)))!.$1, 200);
      gate.complete();
      await settleUntil(tester, () => false);
      expect((await tester.runAsync(() => getLocal(current)))!.$1, 200, reason: '旧的晚回来不能把当前这一路交回');
      // 出画后缓冲状态卡在「在缓冲」：位置一下跳很远（跳转）不算播着走，加载圈留着（11-22 Codex 复核）；之后连着往前走一秒多才收起。
      engine.frame(const Duration(milliseconds: 400));
      await tester.pump();
      engine.buffering(true);
      await tester.pump();
      expect(find.byType(CampusLoader), findsWidgets);
      engine.frame(const Duration(seconds: 30));
      await tester.pump();
      expect(find.byType(CampusLoader), findsWidgets, reason: '跳过去不算在播');
      for (var step = 1; step <= 3; step++) {
        engine.frame(Duration(seconds: 30, milliseconds: 250 * step));
        await tester.pump();
      }
      expect(find.byType(CampusLoader), findsWidgets, reason: '还没走满一秒');
      engine.frame(const Duration(seconds: 31));
      await tester.pump();
      expect(find.byType(CampusLoader), findsNothing);
      // 2.35:1 的片子：竖屏画面区按 16:9 给高度，不按片子比例缩成一条。
      engine.size(1920, 818);
      // 尺寸的事件在下一帧才让页面重排、画面区的动画从那一帧起算：先多出两帧再拨过动画时长（pump(时长) 是先拨时间再出帧）。
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final stage = tester.getSize(find.byType(AnimatedContainer).first);
      expect(stage.height, closeTo(stage.width * 9 / 16, 1));
      await tester.pumpWidget(const SizedBox());
      // 出过画的离开时会记看到哪（写本机库）：让它在真实时钟里写完，不然收尾关库时一直等。
      await settleUntil(tester, () => false);
      await tester.pump(const Duration(seconds: 11));
    }, timeout: const Timeout(Duration(seconds: 60)));

    // 11-21 真机：上下栏的渐变整条接住点击，竖屏画面矮时中间的播放暂停点不动、点画面也不能收起控件。
    testWidgets('播放控件：竖屏 16:9 画面区里中间的播放暂停点得到，点上栏下面的空白处收起控件', (tester) async {
      final engine = _FakeEngine(CinemaEngineKind.system)..frame(const Duration(seconds: 5));
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: Scaffold(body: Align(alignment: Alignment.topCenter, child: SizedBox(width: 400, height: 225, child: CinemaPlayerControls(player: engine, title: '合成', subtitle: '第01集', fullscreen: false, busy: false, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {})))),
      ));
      await tester.pump();
      await tester.tap(find.byTooltip('暂停').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(engine.toggles, 1);
      double opacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.text('第01集'), matching: find.byType(AnimatedOpacity)).first).opacity;
      expect(opacity(), 1);
      await tester.tapAt(const Offset(200, 72));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(), 0, reason: '点在上栏渐变里的空白处也能收起');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('播放页：打开中（还没出首帧）点「从头播放」改成从片头重开，出画后加载圈收起、菜单能点（11-21 真机卡在转圈）', (tester) async {
      final created = <_FakeEngine>[];
      debugCinemaEngineFactory = (kind) {
        final engine = _FakeEngine(kind);
        created.add(engine);
        return engine;
      };
      addTearDown(() => debugCinemaEngineFactory = null);
      final (_, service) = await openCinemaForPage(tester);
      await tester.runAsync(service.rules);
      final title = CinemaTitle(key: 'film', name: '合成电影', year: '2026', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      const roads = [CinemaRoad(name: 'mp4', episodes: [CinemaEpisode(name: '正片', url: 'https://media.example.com/1.mp4')])];
      const start = Duration(minutes: 38, seconds: 18);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPlayerPage.title(service: service, title: title, source: title.sources.single, road: 0, episode: 0, start: start, roads: roads)));
      await settleUntil(tester, () => created.single.opens.isNotEmpty);
      expect(find.byType(CampusLoader), findsWidgets, reason: '打开中');
      await tester.tap(find.textContaining('从头播放'));
      await settleUntil(tester, () => created.single.opens.length == 2);
      expect(created.single.opens.last.$2, Duration.zero, reason: '在目标位置重开');
      created.single.frame(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(CampusLoader), findsNothing, reason: '出画了');
      expect(tester.widget<CinemaSettingRow<CinemaEngineKind>>(find.byType(CinemaSettingRow<CinemaEngineKind>)).onChanged, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
    });

    // 11-22 Codex 复核 P1：续播时规则包已给这个源换了接口主机或加了境外转发，播放页照样把请求发给新地址。
    testWidgets('播放页：续播的源还没（重新）同意时当场弹同意框，同意了才取选集；不同意不发请求、写没同意，不算这个源没播成', (tester) async {
      final created = <_FakeEngine>[];
      debugCinemaEngineFactory = (kind) {
        final engine = _FakeEngine(kind);
        created.add(engine);
        return engine;
      };
      addTearDown(() => debugCinemaEngineFactory = null);
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        return reply(macCmsList([{'vod_id': 1, 'vod_name': '合成电影', 'vod_play_from': 'mp4', 'vod_play_url': r'正片$https://media.example.com/1.mp4'}]), 200);
      });
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(service.rules);
      final title = CinemaTitle(key: 'film', name: '合成电影', year: '2026', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      Future<void> resume() async {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPlayerPage.title(service: service, title: title, source: title.sources.single, road: 0, episode: 0, start: const Duration(minutes: 3))));
        await settleUntil(tester, () => find.text('使用第三方片源').evaluate().isNotEmpty);
        expect(find.textContaining('合成资源'), findsWidgets);
        expect(hosts, isEmpty, reason: '问之前不发请求');
      }

      await resume();
      await tester.tap(find.text('取消'));
      await settleUntil(tester, () => find.textContaining('没同意使用这个源').evaluate().isNotEmpty);
      expect(find.textContaining('没同意使用这个源'), findsOneWidget);
      expect(hosts, isEmpty);
      expect(await tester.runAsync(service.sourceStats), isEmpty, reason: '不算这个源没播成');
      await tester.pumpWidget(const SizedBox());
      await resume();
      // 在同意框上停了 20 秒：同意之后慢提示从头计，不因为等用户就提示换源。
      await tester.pump(const Duration(seconds: 20));
      await tester.tap(find.text('同意并继续'));
      await settleUntil(tester, () => created.isNotEmpty && created.last.opens.isNotEmpty);
      expect(find.text('还在缓冲，可以换个源试试'), findsNothing);
      expect(hosts, ['alpha.example.com']);
      expect(created.last.opens.single.$1, 'https://media.example.com/1.mp4');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
    });

    // 11-22 Codex 复核：换源时先进「打开中」再记看到哪，_save 见打开中直接返回，新源没打开成就退出，最近一段进度丢了；四条以上线路播放页没有切换入口。
    testWidgets('播放页：换源前先记下旧片源看到哪，新源没打开成也不丢；四条以上线路给线路下拉', (tester) async {
      // 手机竖屏的尺寸（400×900），下面的选集区放得下线路下拉。
      tester.view.physicalSize = const Size(1200, 2700);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final created = <_FakeEngine>[];
      debugCinemaEngineFactory = (kind) {
        final engine = _FakeEngine(kind);
        created.add(engine);
        return engine;
      };
      addTearDown(() => debugCinemaEngineFactory = null);
      final client = MockClient((request) async => reply('', request.url.host.startsWith('beta') ? 500 : 404));
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(() async {
        await service.rules();
        await service.grantRules(service.package!.rules);
      });
      final title = CinemaTitle(key: 'film', name: '合成电影', year: '2026', cover: '', remarks: '')
        ..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''))
        ..addSource(const CinemaSourceRef(ruleId: 'beta', source: '2', name: '合成电影', remarks: ''));
      final roads = [for (var index = 1; index <= 4; index++) CinemaRoad(name: '线路$index', episodes: const [CinemaEpisode(name: '正片', url: 'https://media.example.com/1.mp4')])];
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPlayerPage.title(service: service, title: title, source: title.sources.first, road: 0, episode: 0, roads: roads)));
      await settleUntil(tester, () => created.isNotEmpty && created.single.opens.isNotEmpty);
      expect(find.byType(CampusMenuField<int>), findsOneWidget, reason: '四条线路分段放不下，用下拉');
      created.single.frame(const Duration(seconds: 1));
      await tester.pump();
      created.single.frame(const Duration(minutes: 7));
      await tester.pump();
      await tester.ensureVisible(find.text('片源'));
      await tester.tap(find.text('片源'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.textContaining('另一资源').last);
      await tester.pump(const Duration(milliseconds: 500));
      await settleUntil(tester, () => find.textContaining('暂不可用').evaluate().isNotEmpty);
      final history = await tester.runAsync(() => service.store.historyOf('film', DateTime.now()));
      expect((history?.ruleId, history?.position), ('alpha', const Duration(minutes: 7)));
      await tester.pumpWidget(const SizedBox());
      await settleUntil(tester, () => false);
      await tester.pump(const Duration(seconds: 11));
    });

    // 11-22 Codex 复核：播完倒数时回拖接着看，5 秒后照样被切到下一集。
    testWidgets('播放控件：播完的连播倒数在跳转、又播起来或播完的状态撤销时作废，放着不动才连播', (tester) async {
      final engine = _FakeEngine(CinemaEngineKind.system)..frame(const Duration(minutes: 40));
      var nexts = 0;
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: Scaffold(body: Center(child: SizedBox(width: 800, height: 450, child: CinemaPlayerControls(player: engine, title: '合成', subtitle: '第01集', fullscreen: false, busy: false, fit: CinemaFit.automatic, onFit: (_) {}, onBack: () {}, onFullscreen: () {}, onNext: () => nexts++)))),
      ));
      await tester.pump();
      final countdown = find.textContaining('秒后播放下一集');
      // 流的事件在这一帧里才到，下一帧才画出来。
      Future<void> frames() async {
        await tester.pump();
        await tester.pump();
      }

      Future<void> finish() async {
        engine.complete(true);
        await frames();
        expect(countdown, findsOneWidget);
      }

      await finish();
      engine.complete(false);
      await frames();
      expect(countdown, findsNothing, reason: '播完的状态撤销了（回拖）');
      await finish();
      engine.play(true);
      await frames();
      expect(countdown, findsNothing, reason: '又播起来了');
      await finish();
      final bar = tester.getRect(find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter.runtimeType.toString() == '_ProgressPainter'));
      await tester.tapAt(Offset(bar.left + bar.width / 4, bar.center.dy));
      await frames();
      expect(countdown, findsNothing, reason: '跳转了');
      await tester.pump(const Duration(seconds: 6));
      expect(nexts, 0);
      await finish();
      await tester.pump(const Duration(seconds: 6));
      expect(nexts, 1, reason: '放着不动照样连播');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });

    // 11-22 Codex 复核：video_player（2.14.1）的 play 还没回来就 dispose，回来后照样起每 100 毫秒的定时器、永远不取消（控制器留在内存里、一直唤醒）。
    // 测试结束时还挂着的定时器会让 testWidgets 报错，原来的写法正好留下这一个。
    testWidgets('系统播放器：换媒体时上一个的 play 还没回来，等它回来再释放，不留下 video_player 的定时器', (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _FakeVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final engine = CinemaSystemEngine();
      final gate = platform.playGate = Completer<void>();
      unawaited(engine.open('https://media.example.com/1.mp4', const {}));
      for (var index = 0; index < 10 && platform.plays == 0; index++) {
        await tester.pump();
      }
      expect(platform.plays, 1);
      platform.playGate = null;
      unawaited(engine.open('https://media.example.com/2.mp4', const {}));
      await tester.pump();
      expect(platform.disposed, isEmpty, reason: '上一个的 play 还没回来，先不释放');
      gate.complete();
      // video_player 释放时等的取消订阅是根区的 future，假时钟推不动：交替让真实的事件循环走一走。
      Future<void> settle(int count) async {
        for (var index = 0; index < 20 && platform.disposed.length < count; index++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
      }

      await settle(1);
      expect(platform.disposed, [0]);
      await engine.dispose();
      await settle(2);
      expect(platform.disposed, [0, 1]);
    });

    testWidgets('播放页：系统播放器打不开时这一页退回 mpv、在同一位置再开；「播放内核」写正在用的，换了记在本机并用新内核在当前位置重开', (tester) async {
      final created = <_FakeEngine>[];
      var systemFails = true;
      debugCinemaEngineFactory = (kind) {
        final engine = _FakeEngine(kind, failOpen: kind == CinemaEngineKind.system && systemFails);
        created.add(engine);
        return engine;
      };
      addTearDown(() => debugCinemaEngineFactory = null);
      final logs = captureDiagnostics();
      final (_, service) = await openCinemaForPage(tester);
      await tester.runAsync(service.rules);
      final title = CinemaTitle(key: 'film', name: '合成电影', year: '2026', cover: '', remarks: '')..addSource(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成电影', remarks: ''));
      const roads = [CinemaRoad(name: 'mp4', episodes: [CinemaEpisode(name: '正片', url: 'https://media.example.com/1.mp4')])];
      const start = Duration(minutes: 12);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPlayerPage.title(service: service, title: title, source: title.sources.single, road: 0, episode: 0, start: start, roads: roads)));
      await settleUntil(tester, () => created.length == 2 && created.last.opens.isNotEmpty);
      expect([for (final engine in created) engine.kind], [CinemaEngineKind.system, CinemaEngineKind.mpv], reason: '安卓默认系统播放器，打不开退回 mpv');
      expect((created.first.disposed, created.last.opens.single.$2), (true, start), reason: '在同一位置再开');
      expect(logs.any((line) => line.contains('action=engine_fallback') && line.contains('to=mpv')), isTrue);
      created.last.frame(start + const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('播放内核'), findsOneWidget);
      expect(find.text('mpv'), findsOneWidget, reason: '写正在用的');
      expect(find.textContaining('播放出错'), findsNothing);
      // 用户换回系统播放器：记在本机，在当前位置用新内核重开（这回打得开）。
      systemFails = false;
      await tester.ensureVisible(find.text('mpv'));
      await tester.tap(find.text('mpv'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('ExoPlayer（推荐）').last);
      await tester.pump(const Duration(milliseconds: 500));
      await settleUntil(tester, () => created.length == 3 && created.last.opens.isNotEmpty);
      expect((created.last.kind, created.last.opens.single.$2, created[1].disposed), (CinemaEngineKind.system, start + const Duration(seconds: 1), true));
      expect(service.enginePreference, 'system');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 11));
    });
  });

  group('灰度开关', () {
    const flag = FeatureFlag('toolbox.synthetic', fallback: false);
    final module = ToolboxModule(id: 'synthetic', name: '合成工具', icon: Icons.abc, builder: (_) => const SizedBox(), flag: flag);
    final plain = ToolboxModule(id: 'plain', name: '普通工具', icon: Icons.abc, builder: (_) => const SizedBox());

    test('登记了开关的工具开着才显示，没给开关查询（测试与没配中转）当关着；没登记的照常', () {
      expect(toolboxVisible(module), isFalse);
      expect(toolboxVisible(module, features: _Gate({flag.id})), isTrue);
      expect(toolboxVisible(module, features: _Gate({})), isFalse);
      expect(toolboxVisible(plain), isTrue);
    });

    test('电影院登记了开关 toolbox.cinema（默认关）', () {
      expect(featureFlags, contains(cinemaFlag));
      expect((cinemaFlag.id, cinemaFlag.fallback), ('toolbox.cinema', false));
    });

    testWidgets('解析在开关 toolbox.cinema.parse 后面（默认关）：关着只有找片、没有切换，开着才有，页面开着时被关掉就回到找片', (tester) async {
      expect(featureFlags, contains(cinemaParseFlag));
      expect((cinemaParseFlag.id, cinemaParseFlag.fallback), ('toolbox.cinema.parse', false));
      final (fixture, service) = await openCinemaForPage(tester);
      Future<void> show(FeatureGate? features) async {
        final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {CinemaService.serviceId: service}, features: features);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CinemaPage(runtime: runtime)));
        await settleUntil(tester, () => find.text('片名').evaluate().isNotEmpty);
      }

      for (final features in [null, _Gate({})]) {
        await show(features);
        expect(find.text('片名'), findsOneWidget);
        expect(find.text('解析'), findsNothing);
        expect(find.text('找片'), findsNothing);
      }
      final gate = _Gate({cinemaParseFlag.id});
      await show(gate);
      await tester.tap(find.text('解析'));
      await tester.pump();
      expect(find.text('视频页面地址'), findsOneWidget);
      gate.turn(cinemaParseFlag.id, enabled: false);
      await tester.pump();
      expect(find.text('解析'), findsNothing);
      expect(find.text('视频页面地址'), findsNothing);
      expect(find.text('片名'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _RealHttp extends HttpOverrides {}

// 不接 libmpv 的播放器替身：只记下最后一次跳到哪。
class _SeekRecorder extends PlatformPlayer {
  _SeekRecorder() : super(configuration: const PlayerConfiguration());
  Duration? target;

  @override
  Future<void> seek(Duration duration) async => target = duration;
}

class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  final _changes = StreamController<void>.broadcast(sync: true);
  void turn(String id, {required bool enabled}) {
    enabled ? on.add(id) : on.remove(id);
    _changes.add(null);
  }

  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);
  @override
  Stream<void> get changes => _changes.stream;
}

// 测试用的播放内核：记下每次打开的地址与起点，可以让它打不开、或报出首帧。
class _FakeEngine implements CinemaEngine {
  _FakeEngine(this.kind, {this.failOpen = false});
  @override
  final CinemaEngineKind kind;
  final bool failOpen;
  final opens = <(String, Duration)>[];
  var disposed = false;
  var toggles = 0;
  // 不为空时下一次打开等它完成才返回（模拟原生回调晚到）。
  Completer<void>? hold;
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playings = StreamController<bool>.broadcast();
  final _bufferings = StreamController<bool>.broadcast();
  final _completions = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _widths = StreamController<int?>.broadcast();
  final _heights = StreamController<int?>.broadcast();
  String? _uri;
  var _state = const CinemaEngineState();

  @override
  late final CinemaEngineStreams stream = CinemaEngineStreams(position: _positions.stream, duration: _durations.stream, playing: _playings.stream, buffering: _bufferings.stream, completed: _completions.stream, error: _errors.stream, width: _widths.stream, height: _heights.stream);

  @override
  CinemaEngineState get state => _state;

  @override
  String? get currentUri => _uri;

  @override
  final ValueNotifier<List<(Duration, Duration)>?> seekable = ValueNotifier(null);

  @override
  int? get inputRate => null;

  @override
  Future<void> open(String uri, Map<String, String> headers, {Duration start = Duration.zero, bool playlist = false}) async {
    opens.add((uri, start));
    final latest = opens.length, gate = hold;
    hold = null;
    if (failOpen) throw const CinemaEngineException('打不开');
    // 同真的内核：后开的那个才是当前的，晚回来的旧一次不改当前媒体。
    _uri = uri;
    if (gate != null) await gate.future;
    if (latest != opens.length) return;
    _state = CinemaEngineState(position: start, duration: const Duration(minutes: 40), playing: true);
  }

  // 报出画面尺寸（宽高比）。
  void size(int width, int height) {
    _state = CinemaEngineState(position: _state.position, duration: _state.duration, playing: _state.playing, width: width, height: height);
    _widths.add(width);
    _heights.add(height);
  }

  void buffering(bool value) => _bufferings.add(value);

  // 播完了（或撤销播完）、播起来了。
  void complete(bool done) => _completions.add(done);

  void play(bool playing) => _playings.add(playing);

  // 出画并走到 position。
  void frame(Duration position) {
    _state = CinemaEngineState(position: position, duration: const Duration(minutes: 40), playing: true);
    _positions.add(position);
  }

  @override
  Future<void> seek(Duration target) async {}

  @override
  Future<void> playOrPause() async => toggles++;

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Widget view({required BoxFit fit, double? ratio}) => const ColoredBox(color: Colors.black);

  @override
  Future<CinemaSeekResult> beginSeek(Duration target) async => CinemaSeekResult(id: 1, target: target, cached: null, result: 'ok', restartMs: null, playingMs: null);

  @override
  void resetSeeks() {}

  @override
  Future<String> describe() async => 'engine=fake';

  @override
  Future<void> dispose() async => disposed = true;
}

// 假的系统播放器平台（video_player 的平台接口）：打开即给出已初始化，play 等 playGate 才回来，记下 dispose 了哪些。
class _FakeVideoPlatform extends VideoPlayerPlatform {
  Completer<void>? playGate;
  final disposed = <int>[];
  var plays = 0;
  var _next = 0;
  final _events = <int, StreamController<VideoEvent>>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _next++;
    _events[id] = StreamController<VideoEvent>()..add(VideoEvent(eventType: VideoEventType.initialized, duration: const Duration(minutes: 40), size: const Size(1920, 1080)));
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) {
    plays++;
    return playGate?.future ?? Future<void>.value();
  }

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
  }
}

// 数一数交给底层客户端的请求（替身 MockClient 在请求被中断后不调回复，看不出发没发过）。
class _CountingClient extends http.BaseClient {
  _CountingClient(this._inner);
  final http.Client _inner;
  var sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return _inner.send(request);
  }
}
