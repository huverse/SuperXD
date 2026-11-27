import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/application/quick_nav.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/quick_nav.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/domain/sync_record.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/quick_nav_memory.dart';
import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_spaces.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/third_party_licenses.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_http.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/short_video/short_video_service.dart';
import 'package:superxd/toolbox/short_video/short_video_store.dart';
import 'package:superxd/toolbox/short_video/svparse_video_parser.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import '../test/chaoxing_fake_server.dart';
import '../test/fake_relay.dart';

// README 截图入口（手动，不进 CI）：内存 SQLite 里的合成课表与作息，假登录，不连教务、不读写本机账号库。
// 私信是内存中转上的两台设备（好友「小红」发来一份课表），快递是内存会话加假拼多多，住理生活是登好的合成账号加假住理，都不联网。
// 功能开关按全量开着（电影院的解析照线上关着），侧栏的常用与最近只在内存里。
// 课程、教师、教室、快递、取件码与洗浴设备均为虚构。运行：flutter run --profile -t tool/readme_demo.dart
Future<void> main() async {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  // 同 main.dart：内容画到导航栏下面，否则截图底部露出一条窗口底色。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  final database = await AppDatabase.openMemory();
  final gateway = KingoCampusGateway(database: database);
  const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
  const previous = TermRef(xn: '2025', xq: '1', label: '2025-2026学年第二学期');
  await database.saveTerms([term, previous], currentXn: term.xn, currentXq: term.xq);
  await database.writeGrades(previous.xn, previous.xq, DateTime.now().toUtc().toIso8601String(), _gradesJson(previous));
  // 开学日取本周往前四周的周一，截图当天落在第 5 周。
  final today = DateTime.now();
  final monday = today.subtract(Duration(days: today.weekday - 1 + 28));
  final start = '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
  await database.setTermStart(term, start);
  await database.writeBells(xn: term.xn, xq: term.xq, fetchedAt: DateTime.now().toUtc().toIso8601String(), empty: false, message: '', periodsJson: _bellsJson);
  await gateway.saveScheduleRevision(term, _courses, '演示课表', expectedRevisionId: null);
  final social = await _demoSocial(term, start);
  final session = AppSession(_DemoAccounts(gateway));
  final quickNav = QuickNav(memory: FileQuickNavMemory.memory(const QuickNavPrefs(recent: ['/toolbox/cinema', '/playground/nonogram', 'appearance'])));
  // 扫码同组合根接扫码页（住理生活首页有扫码才画「扫码」按钮）。
  // 学习通推断正在上的课读本应用课表，同组合根。
  final toolbox = ToolboxRuntime(
    catalog: _demoCatalog,
    scanQrCode: (context, hint, accept, {then}) => Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => QrScanPage(hint: hint, accept: accept, then: then))),
    campusTimetable: () => campusTimetableToday(session.gateway, signedIn: session.loggedIn),
  );
  runApp(SuperXdApp(session: session, services: AppServices(display: DisplaySettings.memory(), social: social, toolbox: toolbox, features: _DemoFeatures(), quickNav: quickNav)));
  await initializeCampusGlass();
  await session.restore();
}

// 私信：自己与好友「小红」两台设备经内存中转互加好友，小红发来同一学期的课表（看好友课表与共同空闲）。
Future<SocialService> _demoSocial(TermRef term, String start) async {
  final relay = FakeRelay();
  final temporary = await getTemporaryDirectory();
  Future<SocialService> device(String name) async {
    final directory = Directory(path.join(temporary.path, 'readme_demo_$name'));
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync();
    final keys = MemoryAppAccountVault();
    final service = SocialService(spaces: SocialSpaces(vault: MemoryIdentityVault(), directory: directory.path), accountKeys: keys, transport: relay.transport(), serverKeys: FakeRelay.serverKeys);
    await service.switchAccount(await relay.signIn(keys));
    await service.enable(name);
    return service;
  }
  final me = await device('林同学'), friend = await device('小红');
  await friend.redeem(InviteCode.decode((await me.createInvite()).encode())!);
  await me.refresh();
  await friend.refresh();
  await friend.send(friend.friends.first.deviceId, ScheduleShare(term: term, courses: _friendCourses, bells: _bells(), termStartDate: start));
  await me.refresh();
  return me;
}

// 百宝箱用正式注册表，只把快递换成内存会话加假拼多多（已登录、驿站有件）、住理生活换成登好的合成账号，其余工具照常。
List<ToolboxModule> _demoCatalog(ToolboxRuntime runtime) => [for (final module in toolboxCatalog(runtime)) _demoModule(module)];

ToolboxModule _demoModule(ToolboxModule module) => ToolboxModule(
  id: module.id, name: module.name, icon: module.icon, builder: module.builder, resource: module.resource, clearedData: module.clearedData,
  openShared: module.openShared, shortcuts: module.shortcuts, flag: module.flag, children: [for (final child in module.children) _demoModule(child)],
  openService: switch (module.id) {
    ExpressService.serviceId => (_) async => _demoExpress(),
    ZhuliService.serviceId => (_) async => _demoZhuli(),
    ShortVideoService.serviceId => _demoShortVideo,
    ChaoxingService.serviceId => _demoChaoxing,
    CinemaService.serviceId => _demoCinema,
    _ => module.openService,
  },
);

// 合成图片：本仓库自己的开屏画作（GitHub 上的公开原图），当视频封面与电影海报，不用任何第三方的内容。
Uri _painting(String name) => Uri.parse('https://raw.githubusercontent.com/huverse/SuperXD/main/assets/paintings/$name.jpg');

// 合成视频解析：来源的名字与画质字段同线上的 BugPK 新版，解析结果是假的（封面是开屏画作）；预先记一条解析历史，点开就是结果页。
Future<ShortVideoService> _demoShortVideo(ToolboxServiceContext context) async {
  final file = path.join(context.base.path, 'readme_demo_short_video.db');
  if (File(file).existsSync()) File(file).deleteSync();
  final store = await ShortVideoStore.open(file, legacy: context.store);
  final link = Uri.parse('https://v.example.com/s/demo');
  await store.addHistory(id: 'demo', sourceUrl: link, providerId: _DemoParser.real.id, title: '清晨的钟楼（合成演示）', kind: 'video');
  return ShortVideoService(coordinator: ParseCoordinator([_DemoParser()]), store: store, downloads: context.downloads, consents: context.store);
}

class _DemoParser implements ParseProvider {
  static final real = SvparseVideoParser(key: 'demo').source;
  @override
  ParseSource get source => real;
  @override
  bool supports(Uri uri) => true;
  @override
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation) async => ParseResult(
    sourceUrl: uri,
    providerId: real.id,
    title: '清晨的钟楼（合成演示）',
    author: '示例作者',
    cover: MediaResource(id: 'cover', kind: MediaKind.image, url: _painting('misty_sunrise'), label: '封面'),
    resources: [
      MediaResource(id: 'v1', kind: MediaKind.video, url: Uri.parse('https://media.example.com/demo-1080.mp4'), label: '视频', quality: '原画', bytes: 10590000, duration: const Duration(seconds: 13), width: 1080, height: 1920),
      MediaResource(id: 'v2', kind: MediaKind.video, url: Uri.parse('https://media.example.com/demo-720.mp4'), label: '备用清晰度', quality: '720p', bytes: 4180000, duration: const Duration(seconds: 13), width: 720, height: 1280),
    ],
  );
  @override
  void close() {}
}

// 合成学习通：测试用的内存版学习通服务（test/chaoxing_fake_server.dart），登好一个账号；两门课各有一场签到，
// 高等数学那场正在进行（对上今天页的课，首页出「可能正在签到」）。
Future<ChaoxingService> _demoChaoxing(ToolboxServiceContext context) async {
  final fake = await FakeChaoxing.create(name: '林同学');
  fake.photo = '';
  fake.courses = [
    {'content': {'id': 88, 'course': {'data': [{'id': 9001, 'name': '高等数学（上）', 'teacherfactor': '林老师'}]}}},
    {'content': {'id': 89, 'course': {'data': [{'id': 9002, 'name': '大学英语', 'teacherfactor': '周老师'}]}}},
  ];
  final now = DateTime.now().millisecondsSinceEpoch;
  const minute = 60000;
  final activities = {
    '9001': [{'id': 601, 'type': 2, 'otherId': '4', 'nameOne': '位置签到', 'startTime': now - 6 * minute, 'endTime': now + 9 * minute, 'status': 1, 'userStatus': 0}],
    '9002': [{'id': 602, 'type': 2, 'otherId': '5', 'nameOne': '签到码签到', 'startTime': now - 3 * 24 * 60 * minute, 'endTime': now - 3 * 24 * 60 * minute + 10 * minute, 'status': 2, 'userStatus': 1}],
  };
  final inner = fake.client();
  final client = MockClient((request) async {
    if (request.url.path == '/v2/apis/active/student/activelist') {
      final list = activities[request.url.queryParameters['courseId']] ?? const [];
      return http.Response.bytes(utf8.encode(jsonEncode({'result': 1, 'data': {'activeList': list, 'ext': {'a': 1}}})), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }
    // 外层已经定型的请求不能再发一次，复制一份交给内存版学习通。
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return http.Response.fromStream(await inner.send(copy));
  });
  final file = path.join(context.base.path, 'readme_demo_chaoxing.db');
  if (File(file).existsSync()) File(file).deleteSync();
  final accounts = ChaoxingAccounts(store: await ChaoxingStore.open(file), vault: MemoryChaoxingVault(), transport: (cookies) => ChaoxingHttp(client: client, cookies: cookies));
  await accounts.signIn(phoneNumber: '13800138000', password: 'myPassword123');
  return ChaoxingService(accounts: accounts, hub: null);
}

// 合成电影院：两个假片源（苹果 CMS 写法，同测试里的规则），对任何片名都回同样几部合成影片，海报是开屏画作；预先记两条看过的。
Future<CinemaService> _demoCinema(ToolboxServiceContext context) async {
  Map<String, Object?> rule(String id, String name) {
    final api = 'https://$id.example.com/api.php/provide/vod/';
    return {
      'id': id, 'api': '1', 'type': 'movie', 'name': name, 'version': '1', 'userAgent': '', 'referer': '', 'adBlocker': false, 'searchMode': 'api', 'chapterMode': 'api',
      'searchApiConfig': {
        'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'wd': '@keyword'}},
        'listPath': r'$.list[*]', 'namePath': r'$.vod_name', 'sourcePath': r'$.vod_id', 'coverPath': r'$.vod_pic', 'yearPath': r'$.vod_year', 'remarksPath': r'$.vod_remarks', 'categoryPath': r'$.type_name',
      },
      'chapterApiConfig': {
        'request': {'method': 'GET', 'url': api, 'query': {'ac': 'detail', 'ids': '@source'}},
        'format': 'delimited', 'roadNamesPath': r'$.list[0].vod_play_from', 'roadEpisodesPath': r'$.list[0].vod_play_url',
      },
    };
  }
  final package = Uint8List.fromList(utf8.encode(jsonEncode({'format': 1, 'version': 1, 'minClient': 0, 'rules': [rule('demo-a', '合成资源甲'), rule('demo-b', '合成资源乙')], 'catalogRules': <Object>[], 'parsers': <Object>[]})));
  final titles = [
    ('1', '雾中钟楼', '2026', '剧情', '正片', 'misty_sunrise'),
    ('2', '河畔的树', '2025', '剧集', '更新至12集', 'riverside_tree'),
    ('3', '星夜列车', '2024', '动画', '全24集', 'starry_night'),
  ];
  final client = MockClient((request) async {
    final ids = request.url.queryParameters['ids'];
    final list = [
      for (final (id, name, year, category, remarks, poster) in titles)
        if (ids == null || ids == id)
          {'vod_id': id, 'vod_name': name, 'vod_pic': _painting(poster).toString(), 'vod_year': year, 'vod_remarks': remarks, 'type_name': category, 'vod_play_from': '合成线路', 'vod_play_url': [for (var episode = 1; episode <= 12; episode++) '第${episode.toString().padLeft(2, '0')}集\$https://media.example.com/$id/$episode.m3u8'].join('#')},
    ];
    return http.Response.bytes(utf8.encode(jsonEncode({'code': 1, 'msg': '数据列表', 'page': 1, 'pagecount': 1, 'total': list.length, 'list': list})), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final service = await CinemaService.open(context, feed: CinemaRulesFeed(fetch: () async => package, versionCode: () async => 40), http: CinemaHttp(client: client));
  final now = DateTime.now().toUtc();
  for (final (index, (id, name, year, category, _, poster)) in titles.take(2).indexed) {
    await service.store.saveHistory(CinemaHistory(key: cinemaTitleKey(name, year, category: category), name: name, cover: _painting(poster).toString(), ruleId: 'demo-a', source: id, road: 0, episode: index * 4, episodeName: '第${(index * 4 + 1).toString().padLeft(2, '0')}集', position: Duration(minutes: 18 + index * 7), duration: const Duration(minutes: 45), updatedAt: now.subtract(Duration(hours: index + 1))));
  }
  return service;
}

// 功能开关按线上现状：灰度中的功能都开着，电影院的解析关着。
class _DemoFeatures implements FeatureGate {
  @override
  bool isOn(FeatureFlag flag) => flag != cinemaParseFlag;
  @override
  Stream<void> get changes => const Stream.empty();
}

// 合成住理生活：登好的账号（合成学院），余额、券余额与最近使用的四台设备，没有进行中的单；只答首页要的几个接口。
Future<ZhuliService> _demoZhuli() async {
  Map<String, Object?> ok(Object? data) => {'result': true, 'data': zhuliBase64(jsonEncode(data))};
  final client = MockClient((request) async {
    final reply = switch (request.url.path) {
      '/webapi/users/login' => ok({'user_info': {'id': 'U1', 'identity_code': 'I1'}, 'server_info': {'server_addr': 'https://demo.whxinna.com', 'server_appid': 1, 'server_id': 2, 'session_secret': 'S', 'projectname': '合成学院'}}),
      '/webapi/v1/staff/get_user_detail_by_id' => ok({'balance': '17.4900', 'frozen_balance': 0.0, 'cash_coupon_count': 2, 'ChargeRules': [{'device_type': 0, 'device_group_id': 0, 'charge_option': 'metering', 'charge_money': 5.0, 'charge_units': [{'price': 0.07}]}]}),
      '/webapi/v1/app_setting/get_config' => ok({'consume_order_display_cut_enable': 1, 'consume_order_display_cut_days': 30, 'bath_enable': 1, 'recharge_enable': 1, 'recharge_display_enable': 1, 'alipay_enable': 1}),
      '/webapi/v1/cash_coupon/list_staff_cash_coupon_app' => ok({'rows': [
        {'id': 'Q1', 'cash_coupon_name': '买200赠80', 'balance': 176.35, 'total_money': 280.0, 'use_limit': 'bath', 'use_order': 0, 'start_at': '2026-09-30 11:37:49', 'expire_at': '2028-09-19 11:37:49'},
        {'id': 'Q2', 'cash_coupon_name': '优惠券', 'balance': 12.5, 'total_money': 130.0, 'use_limit': 'bath', 'use_order': 1, 'start_at': '2026-10-01 00:00:00', 'expire_at': '2028-12-31 23:59:59'},
      ], 'total_count': 2}),
      '/webapi/v1/consume/get_staff_last_record' => ok(null),
      '/webapi/v1/staff/query_pending_order' => ok(<Object>[]),
      _ => {'result': false, 'msg': '合成服务没有这个接口'},
    };
    return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
  final service = ZhuliService(vault: MemoryZhuliVault(), devices: ZhuliDeviceStore.memory(), client: ZhuliClient(http: ZhuliHttp(client: client)), payer: _DemoPayer());
  await service.signIn('13800000001', '123456');
  for (final (id, room, mode) in [(1300021, 231, '蓝牙'), (1300017, 118, '蓝牙'), (2100342, 232, '云端/蓝牙'), (1300024, 232, '蓝牙')]) {
    await service.devices.used('13800000001', ZhuliDeviceEntry(id: id, name: '', place: '14号楼 2层 $room', mode: mode));
  }
  return service;
}

// 演示里不付钱。
class _DemoPayer implements LifeAlipay {
  @override
  Future<String> pay(String orderContent) => Completer<String>().future;
}

Future<ExpressService> _demoExpress() async {
  final vault = MemoryExpressVault();
  await vault.save(const PddSession(accessToken: 'demo', cookie: 'PDDAccessToken=demo', userId: '1000000', nickname: '林同学', pickupMobile: '138****0000', pickupMore: true));
  await vault.saveStationLinked(true);
  return ExpressService(vault: vault, clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: _fakePdd())));
}

// 合成拼多多：一个驿站三件待取件，物流的 package_info 写寄到的手机尾号（两件 0000、一件 1111），近一周取走一件；身份码 10 分钟有效。
http.Client _fakePdd() => MockClient((request) async {
  final route = request.url.path;
  final Object body;
  if (route.endsWith('/shipping/track')) {
    final number = request.url.queryParameters['tracking_number'] ?? '';
    body = {'error_code': null, 'shipping': {'shipping_name': '合成快递', 'tracking_number': number, 'package_info': number == 'SX0000000003' ? '尾号1111 的快递' : '尾号0000 的快递', 'traces': [{'info': '快件已到达合成驿站一号，请凭取件码取件', 'time': '2026-10-26 09:12:00'}]}};
  } else if (route.endsWith('/station/package')) {
    body = {
      'success': true,
      'error_code': '0',
      'result': {
        'count': 3,
        'combine_list': [
          {
            'company_name': '合成驿站一号',
            'address': '示例路 1 号',
            'combine_track_list': [
              for (final (index, code) in ['3-2-1001', '3-2-1002', '5-1-2003'].indexed)
                {'pick_code': '取件码 $code', 'shipping_name': '合成快递', 'tracking_number': 'SX000000000${index + 1}', 'shipping_id': 1},
            ],
          },
        ],
        'package_out_list': [
          {'address': '示例路 1 号', 'operate_time': '10-24 18:05', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000009', 'jump_url': '/track?tracking_number=SX0000000009&shipping_id=1&source_type=3'},
        ],
      },
    };
  } else {
    body = {'success': true, 'error_code': '0', 'result': {'identification_code': 'dd20261026000000001234', 'expire_mills': 600000}};
  }
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
});

const _bellsJson = '[{"period":1,"start":"08:00","end":"08:45"},{"period":2,"start":"08:55","end":"09:40"},{"period":3,"start":"10:00","end":"10:45"},{"period":4,"start":"10:55","end":"11:40"},{"period":5,"start":"14:00","end":"14:45"},{"period":6,"start":"14:55","end":"15:40"},{"period":7,"start":"16:00","end":"16:45"},{"period":8,"start":"16:55","end":"17:40"},{"period":9,"start":"19:00","end":"19:45"},{"period":10,"start":"19:55","end":"20:40"}]';

final _allWeeks = List.generate(16, (index) => index + 1);
CourseRecord _course(String code, String name, String teacher, double credit, List<(int, int, int, String)> meetings) => CourseRecord(
  courseCode: code, courseName: name, sectionId: '$code-01', credit: credit, teacherName: teacher,
  meetings: [for (final (weekday, start, end, place) in meetings) CourseMeeting(weekday: weekday, periodStart: start, periodEnd: end, place: place, weeks: _allWeeks)],
);

final _courses = [
  _course('D101', '高等数学（上）', '林老师', 5, [(1, 1, 2, '明德楼 A201'), (3, 3, 4, '明德楼 A201')]),
  _course('D102', '大学英语', '周老师', 3, [(1, 5, 6, '外语楼 305'), (4, 1, 2, '外语楼 305')]),
  _course('D103', '程序设计基础', '陈老师', 4, [(2, 1, 2, '信息楼 B402'), (5, 3, 4, '实验中心 210')]),
  _course('D104', '线性代数', '赵老师', 3, [(2, 5, 6, '明德楼 C108')]),
  _course('D105', '大学物理', '孙老师', 4, [(3, 1, 2, '格物楼 101'), (5, 1, 2, '格物楼 101')]),
  _course('D106', '思想道德与法治', '吴老师', 3, [(4, 5, 6, '综合楼 402')]),
  _course('D107', '体育', '郑老师', 1, [(1, 3, 4, '东区体育馆')]),
  _course('D108', '创新创业基础', '冯老师', 2, [(3, 9, 10, '综合楼 210')]),
];

// 好友小红的合成课表：和自己有一门同班的大学英语，其余错开，共同空闲里能看出两人都没课的时段。
final _friendCourses = [
  _course('E201', '数据结构', '何老师', 4, [(1, 1, 2, '信息楼 B201'), (3, 5, 6, '信息楼 B201')]),
  _course('E202', '概率论', '许老师', 3, [(2, 3, 4, '明德楼 A305')]),
  _course('D102', '大学英语', '周老师', 3, [(1, 5, 6, '外语楼 305'), (4, 1, 2, '外语楼 305')]),
  _course('E203', '电路分析', '马老师', 4, [(4, 3, 4, '电气楼 110'), (5, 5, 6, '电气楼 110')]),
];

List<BellPeriod> _bells() => [
  for (final period in (jsonDecode(_bellsJson) as List).cast<Map<String, Object?>>())
    BellPeriod(period: period['period']! as int, dayPart: '', dayPartCode: '', start: period['start']! as String, end: period['end']! as String),
];

// 上一学期的合成成绩（成绩页截图用）：课程沿用演示课表，分数虚构，绩点按分数线性折算。
String _gradesJson(TermRef term) {
  const scores = [92, 86, 95, 78, 84, 90, 88, 81];
  final rows = [for (final (index, course) in _courses.indexed) (course: course, score: scores[index])];
  return jsonEncode({
    'empty': false,
    'message': '',
    'term': {'xn': term.xn, 'xq': term.xq, 'label': term.label},
    'student': {'loginId': '20260000001', 'name': '林同学', 'college': '示例学院', 'major': '示例专业', 'level': '本科', 'className': '示例计算机班'},
    'summary': {'earnedCredit': 25, 'gpa': 3.75, 'averageScore': 86.75, 'weightedAverage': 87.52},
    'summaryScope': 'term',
    'effective': [
      for (final row in rows)
        {'courseCode': row.course.courseCode, 'courseName': row.course.courseName, 'credit': row.course.credit, 'score': row.score, 'earnedCredit': row.course.credit, 'gradePoint': (row.score - 50) / 10},
    ],
    'original': [
      for (final row in rows)
        {'courseCode': row.course.courseCode, 'courseName': row.course.courseName, 'credit': row.course.credit, 'usualScore': row.score, 'midtermScore': null, 'finalScore': row.score, 'skillScore': null, 'totalScore': row.score},
    ],
  });
}

// 假登录：账号固定为一个虚构学生，教务数据全部走内存库里的合成数据。
class _DemoAccounts extends AccountAccess {
  _DemoAccounts(this.inner);
  final CampusGateway inner;
  final SessionView _student = const SessionView(loginId: '20260000001', name: '林同学', className: '示例计算机班');

  @override
  int get generation => 1;
  @override
  SessionView? get activeSession => _student;
  @override
  AccountIdentity? get activeIdentity => AccountIdentity(source: 'https://school.example', loginId: _student.loginId);
  @override
  Future<GatewayResult<SessionView>> restoreSession() async => GatewayResult(ok: true, source: 'local', fetchedAt: DateTime.now().toUtc().toIso8601String(), data: _student);
  @override
  Future<GatewayResult<LoginView>> login(String account, String password) async => GatewayResult(ok: true, source: 'local', fetchedAt: DateTime.now().toUtc().toIso8601String(), data: LoginView(session: _student));
  @override
  Future<void> cancelLogin() async {}
  @override
  Future<void> logout() async {}
  @override
  Future<LegacyImportState> legacyImportState() async => const LegacyImportState(available: false, deferred: false);
  @override
  Future<void> deferLegacyImport() async {}
  @override
  Future<GatewayResult<LegacyImportReport>> importLegacy() => throw UnsupportedError('演示模式没有旧数据');
  @override
  Future<void> close() async {}

  @override
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) => inner.submitLoginCaptcha(code);
  @override
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() => inner.refreshLoginCaptcha();
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() => inner.listTerms();
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => inner.listTerms();
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) => inner.readSchedule(ScheduleScope.term(term));
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) => inner.readSchedule(scope);
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) => inner.readGrades(term);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => inner.readGrades(term);
  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) => inner.readGradeYear(year);
  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) => inner.readBells(term);
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) => inner.readBells(term);
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) => inner.readBellsSource(term);
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) => inner.useBellsSource(target, source);
  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) => inner.setTermStart(term, date);
  @override
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId}) => inner.saveScheduleRevision(term, courses, summary, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) => inner.planScheduleSync(term, courses);
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) => inner.commitScheduleSync(term, courses, confirm: confirm, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20}) => inner.listScheduleRevisions(term, beforeSequence: beforeSequence, limit: limit);
  @override
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id) => inner.readScheduleRevision(term, id);
  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) => inner.restoreScheduleRevision(term, id, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<ReminderSetting>> readReminderSetting(TermRef term) => inner.readReminderSetting(term);
  @override
  Future<GatewayResult<ReminderSetting>> saveReminderSetting(TermRef term, ReminderSetting setting) => inner.saveReminderSetting(term, setting);
  @override
  Future<GatewayResult<RevisionView>> commitScheduleMerge(TermRef term, List<CourseRecord> courses, List<CourseRecord> merged, String summary, {required String? expectedRevisionId}) => inner.commitScheduleMerge(term, courses, merged, summary, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<bool>> holdScheduleSync(TermRef term, List<CourseRecord> courses, {required bool dismissed}) => inner.holdScheduleSync(term, courses, dismissed: dismissed);
  @override
  Future<GatewayResult<List<HeldScheduleSync>>> readHeldScheduleSyncs() => inner.readHeldScheduleSyncs();
  @override
  Future<T> keepSessionDuring<T>(Future<T> Function() body) => inner.keepSessionDuring(body);
  @override
  Future<GatewayResult<AutoSyncView>> readAutoSync() => inner.readAutoSync();
  @override
  Future<GatewayResult<AutoSyncSetting>> saveAutoSyncSetting(AutoSyncSetting setting) => inner.saveAutoSyncSetting(setting);
  @override
  Future<GatewayResult<AutoSyncStatus>> recordAutoSync(AutoSyncStatus status) => inner.recordAutoSync(status);
  @override
  Future<GatewayResult<SyncRecord>> recordSync(SyncRecord record) => inner.recordSync(record);
  @override
  Future<GatewayResult<List<SyncRecord>>> readSyncRecords() => inner.readSyncRecords();
}
