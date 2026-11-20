import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/toolbox/cinema/cinema_catalog_file.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_playlist.dart';
import 'package:superxd/toolbox/cinema/cinema_proxy.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/cinema/cinema_store.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_page.dart';

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

// 片名目录型的源（同 wsy）：搜索请求按 @ids 取详情，目录的增量按 @hours、@page。
Map<String, Object?> catalogRule(String id, String api, {required List<int> file, required DateTime builtAt, String name = '目录资源'}) {
  final rule = macCmsRule(id, api, name: name);
  final search = rule['searchApiConfig']! as Map<String, Object?>;
  return {
    ...rule,
    'searchMode': 'catalog',
    'searchApiConfig': {...search, 'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'ids': '@ids'}}},
    'catalog': {
      'file': 'cinema-$id-0123456789ab.tsv.gz',
      'sha256': sha256OfForTest(file),
      'bytes': file.length,
      'builtAt': builtAt.toIso8601String(),
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

String sha256OfForTest(List<int> bytes) => crypto.sha256.convert(bytes).toString();

Future<String> encryptForTest(String plain) async {
  final box = await AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty).encrypt(utf8.encode(plain), secretKey: SecretKey(utf8.encode(testCipher.key)), nonce: utf8.encode(testCipher.iv));
  return base64.encode(box.cipherText);
}

// 替身回复一律按 UTF-8 字节给（http.Response 的字符串构造默认按 Latin-1 编码，中文会报错）。
http.Response reply(String body, int status, {Map<String, String> headers = const {}}) => http.Response.bytes(utf8.encode(body), status, headers: headers);

String macCmsList(List<Map<String, Object?>> items) => jsonEncode({'code': 1, 'msg': '数据列表', 'page': '1', 'pagecount': 1, 'total': items.length, 'list': items});

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

    test('片名目录型的源放在 catalogRules：接在普通源后面；详情要用 @ids，目录要写文件名、SHA-256、UTC 起点与带 @hours、@page 的增量请求，不合格整包拒收', () {
      final file = encodeCinemaCatalog(DateTime.utc(2026, 11, 20), [('1', '甲')]);
      Map<String, Object?> catalog() => catalogRule('wsy', 'https://wsy.example.com/api.php', file: file, builtAt: DateTime.utc(2026, 11, 20));
      final package = decodeCinemaPackage(packageBytes(catalogRules: [catalog()]));
      expect([for (final rule in package.rules) (rule.id, rule.catalog != null)], [('alpha', false), ('beta', false), ('wsy', true)]);
      expect(package.rules.last.catalog!.sha256, sha256OfForTest(file));
      final wrong = <Map<String, Object?>>[
        {...catalog(), 'searchMode': 'api'},
        {...catalog(), 'searchApiConfig': macCmsRule('wsy', 'https://wsy.example.com/api.php')['searchApiConfig']},
        {...catalog(), 'catalog': {...(catalog()['catalog']! as Map<String, Object?>), 'sha256': 'abc'}},
        {...catalog(), 'catalog': {...(catalog()['catalog']! as Map<String, Object?>), 'file': 'wsy.tsv.gz'}},
        {...catalog(), 'catalog': {...(catalog()['catalog']! as Map<String, Object?>), 'builtAt': '2026-11-20T00:00:00'}},
        {...catalog(), 'catalog': {...(catalog()['catalog']! as Map<String, Object?>), 'update': {'request': {'method': 'GET', 'url': 'https://wsy.example.com/'}, 'listPath': r'$.list[*]', 'idPath': r'$.vod_id', 'namePath': r'$.vod_name', 'pageCountPath': r'$.pagecount'}}},
        {...catalog(), 'id': 'alpha'},
      ];
      for (final (index, rule) in wrong.indexed) {
        expect(() => decodeCinemaPackage(packageBytes(catalogRules: [rule])), throwsA(isA<CinemaRuleException>()), reason: '第 $index 个');
      }
    });
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
      expect([for (final failure in result.failures) failure.message], ['挡住的资源暂不可用（HTTP 403）']);
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

    test('同一个源连续失败三次就暂停半小时、不再去请求；重试立即恢复；成功一次清零', () async {
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

    test('片名目录型的源：第一次搜先从中转下底包（核对 SHA-256），在本机找片名、只把编号发给源；隔一小时直连源补增量；规则包拿掉就删本机目录', () async {
      var now = DateTime.utc(2026, 11, 20, 8);
      final builtAt = DateTime.utc(2026, 11, 20, 7, 30);
      final base = encodeCinemaCatalog(builtAt, [('101', '合成电影'), ('102', '合成电影 第二季'), ('103', '别的片')]);
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'relay.example.com') return http.Response.bytes(base, 200);
        final query = request.url.queryParameters;
        if (query['ac'] == 'detail') {
          const names = {'101': '合成电影', '102': '合成电影 第二季', '104': '合成电影 第三季'};
          return reply(macCmsList([for (final id in query['ids']!.split(',')) {'vod_id': int.parse(id), 'vod_name': names[id], 'vod_year': '2020', 'vod_pic': 'https://img.example.com/$id.jpg'}]), 200);
        }
        return reply(jsonEncode({'code': 1, 'pagecount': 1, 'list': [{'vod_id': 104, 'vod_name': '合成电影 第三季'}]}), 200);
      });
      var catalogs = [catalogRule('wsy', 'https://wsy.example.com/api.php/provide/vod/', file: base, builtAt: builtAt)];
      final service = await open(() async => packageBytes(version: catalogs.isEmpty ? 2 : 1, rules: [macCmsRule('alpha', 'https://alpha.example.com/api.php')], catalogRules: catalogs), client: client, now: () => now, relay: Uri.parse('https://relay.example.com'));
      final package = await service.rules();
      final wsy = package.rules.singleWhere((rule) => rule.catalog != null);
      await service.grantRules([wsy]);
      final first = await service.search('合成电影').last;
      expect(requests.first.toString(), 'https://relay.example.com/v1/app/files/cinema-wsy-0123456789ab.tsv.gz');
      final detail = requests.singleWhere((uri) => uri.queryParameters['ac'] == 'detail');
      expect(detail.queryParameters['ids'], '101,102', reason: '完全一样的在前，片名没发出去');
      expect(detail.queryParameters.containsKey('wd'), isFalse);
      expect([for (final title in first.titles) title.sources.single.source], ['101', '102']);
      await pumpEventQueue();
      expect(requests.where((uri) => uri.queryParameters['ac'] == 'list'), isEmpty, reason: '底包刚抓的，不用补');
      now = now.add(const Duration(hours: 2));
      await service.search('第三季').last;
      await pumpEventQueue(times: 50);
      final update = requests.singleWhere((uri) => uri.queryParameters['ac'] == 'list');
      expect((update.queryParameters['h'], update.queryParameters['pg']), ('4', '1'), reason: '离底包起点两个半小时，向上取整再多补一小时');
      requests.clear();
      final third = await service.search('第三季').last;
      expect(third.titles.single.sources.single.source, '104', reason: '补进来的能搜到');
      expect(requests.where((uri) => uri.host == 'relay.example.com'), isEmpty, reason: '底包只下一次');
      catalogs = [];
      await service.rules(force: true);
      expect(await service.store.catalogMeta('wsy'), isNull);
      await service.close();
    });

    test('片名目录的底包是外部输入：SHA-256 对不上、首行条数不对、行格式不对都整份不用', () {
      final builtAt = DateTime.utc(2026, 11, 20);
      final good = encodeCinemaCatalog(builtAt, [('2', '乙'), ('1', '甲')]);
      final decoded = decodeCinemaCatalog(good, sha256OfForTest(good));
      expect(decoded.builtAt, builtAt);
      expect(decoded.entries, [('1', '甲'), ('2', '乙')]);
      expect(() => decodeCinemaCatalog(good, '0' * 64), throwsA(isA<CinemaRuleException>()));
      for (final text in ['#SXD-CATALOG\t1\t2026-11-20T00:00:00.000Z\t2\n1\t甲\n', '#SXD-CATALOG\t2\t2026-11-20T00:00:00.000Z\t1\n1\t甲\n', '#SXD-CATALOG\t1\t2026-11-20T00:00:00.000Z\t1\n1\t甲\t多\n', 'x']) {
        final bytes = gzip.encode(utf8.encode(text));
        expect(() => decodeCinemaCatalog(bytes, sha256OfForTest(bytes)), throwsA(isA<CinemaRuleException>()), reason: text);
      }
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
    // 绕开测试框架装的假 HttpClient，真的连本机代理。
    Future<(int, String)> get(Uri uri) => HttpOverrides.runWithHttpOverrides(() async {
      final local = HttpClient();
      try {
        final response = await (await local.getUrl(uri)).close();
        return (response.statusCode, await utf8.decodeStream(response));
      } finally {
        local.close(force: true);
      }
    }, _RealHttp());
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
  });
}

class _RealHttp extends HttpOverrides {}

class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);
  @override
  Stream<void> get changes => const Stream.empty();
}
