import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog.dart';
import 'package:superxd/toolbox/cinema/cinema_detail_page.dart';
import 'package:superxd/toolbox/cinema/cinema_episodes.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_page.dart';
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

List<int> packageBytes({int version = 1, int minClient = 0, List<Map<String, Object?>>? rules, List<Map<String, Object?>> catalogRules = const []}) => utf8.encode(jsonEncode({
  'format': 1,
  'version': version,
  'minClient': minClient,
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
Future<(ToolboxFixture, CinemaService)> openCinemaForPage(WidgetTester tester, {http.Client? client}) async {
  final fixture = ToolboxFixture();
  await tester.runAsync(fixture.initialize);
  addTearDown(() => tester.runAsync(fixture.close));
  final service = (await tester.runAsync(
    () => CinemaService.open(
      ToolboxServiceContext(base: fixture.directory, store: fixture.store, downloads: fixture.manager),
      feed: CinemaRulesFeed(fetch: () async => Uint8List.fromList(packageBytes()), versionCode: () async => 40),
      http: CinemaHttp(client: client ?? MockClient((request) async => reply('', 404))),
    ),
  ))!;
  addTearDown(() => tester.runAsync(service.close));
  return (fixture, service);
}

// 让真实的异步（本机库、替身回复）走完，直到 done 为真（最多约 1 秒）。
Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  for (var index = 0; index < 50 && !done(); index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  group('规则包', () {
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

    test('去广告：比正片短很多的不连续段去掉，去掉段里换过的密钥照旧补给后面的正片', () {
      final segments = [for (var index = 0; index < 30; index++) '#EXTINF:10,\nmain$index.ts'].join('\n');
      final media = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI="ad.key"\n#EXTINF:5,\nad0.ts\n#EXTINF:5,\nad1.ts\n#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n$segments\n#EXT-X-ENDLIST\n';
      final out = cinemaRewritePlaylist(media, Uri.parse('https://cdn.example.com/v/'), playlist: (uri) => '$uri', media: (uri) => uri.pathSegments.last, adBlocker: true);
      expect(out, isNot(contains('ad0.ts')));
      expect(out, isNot(contains('ad.key')));
      expect(out, contains('URI="main.key"'));
      expect('\n'.allMatches(out).length, greaterThan(60));
      expect(out.trimRight().endsWith('#EXT-X-ENDLIST'), isTrue);
      // 不开去广告原样保留。
      expect(cinemaRewritePlaylist(media, Uri.parse('https://cdn.example.com/v/'), playlist: (uri) => '$uri', media: (uri) => uri.pathSegments.last), contains('ad0.ts'));
    });

    test('去广告后初始化段的加密状态不变：明文初始化段的 MAP 仍在 KEY 前面，加密的仍在后面，去掉段里的密钥不套到明文初始化段上', () {
      final segments = [for (var index = 0; index < 30; index++) '#EXTINF:10,\nmain$index.m4s'].join('\n');
      String filtered(String main) => cinemaRewritePlaylist(
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI="ad.key"\n#EXTINF:5,\nad0.ts\n#EXT-X-DISCONTINUITY\n$main\n$segments\n#EXT-X-ENDLIST\n',
        Uri.parse('https://cdn.example.com/v/'),
        playlist: (uri) => '$uri',
        media: (uri) => uri.pathSegments.last,
        adBlocker: true,
      );
      const head = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n';
      const main = '#EXT-X-DISCONTINUITY\n#EXTINF:10,\nmain0.m4s\n';
      // 明文初始化段、加密分片：原清单先写 METHOD=NONE 再写 MAP，去掉广告后照旧是明文状态下的 MAP。
      expect(filtered('#EXT-X-KEY:METHOD=NONE\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"'), startsWith('$head#EXT-X-KEY:METHOD=NONE\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n$main'));
      // 加密的初始化段：KEY 在 MAP 前面。
      expect(filtered('#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n#EXT-X-MAP:URI="init.mp4"'), startsWith('$head#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n#EXT-X-MAP:URI="init.mp4"\n$main'));
      // 整份清单第一个密钥之前的 MAP 是明文：去掉开头的广告后，MAP 仍写在密钥前面。
      final plain = cinemaRewritePlaylist(
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:5,\nad0.ts\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n$segments\n#EXT-X-ENDLIST\n',
        Uri.parse('https://cdn.example.com/v/'),
        playlist: (uri) => '$uri',
        media: (uri) => uri.pathSegments.last,
        adBlocker: true,
      );
      expect(plain, startsWith('$head#EXT-X-MAP:URI="init.mp4"\n#EXT-X-KEY:METHOD=AES-128,URI="main.key"\n$main'));
      expect(plain, isNot(contains('ad0.ts')));
      expect('#EXT-X-MAP'.allMatches(plain), hasLength(1));
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
      final history = await store.history(limit: 100);
      expect(history, hasLength(cinemaHistoryLimit));
      expect(history.first.key, 'k${cinemaHistoryLimit + 4}');
      expect(history.any((item) => item.key == 'old'), isFalse);
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
      await pumpEventQueue();
      expect([for (final snapshot in snapshots) snapshot.pending], [2, 1]);
      expect(snapshots.last.titles.single.sources, hasLength(1), reason: '先回来的已经显示');
      slow.complete();
      await done;
      expect(snapshots.last.pending, 0);
      expect(snapshots.last.titles.single.sources, hasLength(2));
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
      await pumpEventQueue();
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
        await service.search('合成').last;
      }
      asked.clear();
      final paused = await service.search('合成').last;
      expect(asked, ['alpha.example.com'], reason: '暂停着的不去请求');
      expect(paused.failures.single.paused, isTrue);
      expect(service.hasPaused, isTrue);
      now = now.add(CinemaService.pauseFor);
      asked.clear();
      await service.search('合成').last;
      expect(asked, contains('beta.example.com'), reason: '到点恢复');
      service.resume();
      down = false;
      final recovered = await service.search('合成').last;
      expect(recovered.failures, isEmpty);
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
      expect((await service.search('合成电影').last).failures.single.message, contains('看不懂'));
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
      await service.search('合成电影').last;
      final alpha = service.rule('alpha')!, beta = service.rule('beta')!;
      expect((await service.chapters(alpha, '1')).single.episodes.single.url, 'https://cdn.example.com/one/index.m3u8');
      expect(details, isEmpty);
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

    test('选集：一处不等了只有它抛取消，另一处照样拿到；都不等了才中断，之后再要另起一次', () async {
      final details = <int>[];
      var gate = Completer<void>();
      final client = MockClient((request) async {
        details.add(details.length);
        await gate.future;
        return reply(macCmsList([{'vod_id': 7, 'vod_name': '合成', 'vod_play_from': 'm3u8', 'vod_play_url': r'第01集$https://cdn.example.com/one/index.m3u8'}]), 200);
      });
      final service = await open(() async => packageBytes(), client: client);
      final rule = (await service.rules()).rules.first;
      final leaving = Completer<void>(), staying = Completer<void>();
      final left = service.chapters(rule, '7', cancel: leaving.future), stayed = service.chapters(rule, '7', cancel: staying.future);
      leaving.complete();
      await expectLater(left, throwsA(isA<http.RequestAbortedException>()));
      gate.complete();
      expect((await stayed).single.episodes, hasLength(1));
      expect(details, hasLength(1));
      gate = Completer<void>();
      final first = Completer<void>(), second = Completer<void>();
      final a = service.chapters(rule, '8', cancel: first.future), b = service.chapters(rule, '8', cancel: second.future);
      first.complete();
      second.complete();
      await expectLater(a, throwsA(isA<http.RequestAbortedException>()));
      await expectLater(b, throwsA(isA<http.RequestAbortedException>()));
      final again = service.chapters(rule, '8');
      gate.complete();
      await again;
      expect(details, hasLength(3), reason: '都不等了的那次被中断，再要时另起一次');
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
      final old = service.chapters(rule, '7');
      await pumpEventQueue();
      final fresh = service.chapters(rule, '7', fresh: true);
      await pumpEventQueue();
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
    final stream = CinemaStream(headers: cinemaHeaders('', ''), adBlocker: false);
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
    final stream = CinemaStream(headers: cinemaHeaders('', ''), adBlocker: false);
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

  test('本机代理：重新载入登记的一路不用缓存的清单、重新探测；旧的晚回来不覆盖缓存；预取可以取消', () async {
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
    final stream = CinemaStream(headers: cinemaHeaders('', ''), adBlocker: false);
    final playlist = Uri.parse('https://cdn.example.com/v/index.m3u8');
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=1'));
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=1'), reason: '点播清单走缓存');
    probes.clear();
    expect((await getLocal(await proxy.open(playlist, stream, fresh: true))).$2, contains('sign=2'), reason: '重新载入不用缓存');
    expect(probes, isNotEmpty, reason: '重新载入也重新探测');
    expect((await getLocal(await proxy.open(playlist, stream))).$2, contains('sign=2'), reason: '新取的进了缓存');
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
    final link = await proxy.open(Uri.parse('https://cdn.example.com/v/index.m3u8'), CinemaStream(headers: cinemaHeaders('', ''), adBlocker: false));
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
    final stream = CinemaStream(headers: cinemaHeaders('', ''), adBlocker: false);
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

    testWidgets('首页：看过的是横向海报条、⋯ 里删除先确认；搜索中输入框照常可改；暂不可用只写源名；清空搜索框回到看过的', (tester) async {
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
      expect(find.textContaining('另一资源'), findsOneWidget);
      expect(find.textContaining('HTTP'), findsNothing);

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
      expect(await tester.runAsync(service.store.history), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('选集页：顶栏片名在大标题滚出去后才出现；120 集打开停在上次看到那集所在的一段', (tester) async {
      final episodes = [for (var index = 1; index <= 120; index++) '第$index集\$https://media.example.com/$index.mp4'].join('#');
      final client = MockClient((request) async => reply(macCmsList([{'vod_id': 1, 'vod_name': '合成长剧', 'vod_play_from': 'mp4', 'vod_play_url': episodes}]), 200));
      final (_, service) = await openCinemaForPage(tester, client: client);
      await tester.runAsync(() async {
        await service.rules();
        await service.store.saveHistory(CinemaHistory(key: 'long', name: '合成长剧', cover: '', ruleId: 'alpha', source: '1', road: 0, episode: 85, episodeName: '第86集', position: const Duration(minutes: 3), duration: const Duration(minutes: 40), updatedAt: DateTime.now().toUtc()));
      });
      final title = CinemaTitle(key: 'long', name: '合成长剧', year: '2026', cover: '', remarks: '')..sources.add(const CinemaSourceRef(ruleId: 'alpha', source: '1', name: '合成长剧', remarks: ''));
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
