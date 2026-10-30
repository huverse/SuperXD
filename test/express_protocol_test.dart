import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/toolbox/express/express_anti_content.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 按路径返回合成响应的假拼多多服务；请求头原样回给调用方核对。
ExpressClient buildClient({required PddSession session, required Map<String, Object?> Function(String path) respond, void Function(http.Request request)? onRequest}) {
  final client = MockClient((request) async {
    onRequest?.call(request);
    return http.Response(jsonEncode(respond(request.url.path)), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
  });
  return ExpressClient(session: session, http: ExpressHttp(client: client));
}

void main() {
  const session = PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok; pdd_user_id=7209', installToken: 'inst', etag: 'et', userId: '7209');

  group('会话与请求头', () {
    test('headers 带上 AccessToken、Cookie 与 ETag', () {
      final headers = session.headers(referer: PddConstants.idCodeReferer);
      expect(headers['AccessToken'], 'tok');
      expect(headers['Cookie'], contains('PDDAccessToken=tok'));
      expect(headers['ETag'], 'et');
      expect(headers['Referer'], PddConstants.idCodeReferer);
    });

    test('只有 Cookie 时不带 AccessToken 头，仍算有效会话', () {
      const cookieOnly = PddSession(cookie: 'pdd_user_id=1');
      expect(cookieOnly.headers(referer: PddConstants.mdkdReferer).containsKey('AccessToken'), isFalse);
      expect(cookieOnly.isValid, isTrue);
      expect(const PddSession().isValid, isFalse);
    });

    test('会话编解码往返，字段缺失按空串容错', () {
      final decoded = PddSession.decode(session.encode());
      expect(decoded.accessToken, 'tok');
      expect(decoded.userId, '7209');
      expect(PddSession.fromJson(const {}).accessToken, '');
    });

    // 账号卡的昵称与取件号：null 是还没读过（要补读），空串是读过但拼多多没给（不再反复读），两者编解码后要分得开。
    test('昵称与常用取件号编解码往返，区分没读过与读过但没给', () {
      final plain = PddSession.decode(session.encode());
      expect((plain.nickname, plain.pickupMobile, plain.pickupMore), (null, null, false));
      expect(PddSession.decode(session.withAccount(nickname: '', pickupMobile: '').encode()).nickname, '');
      final filled = PddSession.decode(session.withAccount(nickname: '合成昵称', pickupMobile: '138****8888', pickupMore: true).encode());
      expect((filled.nickname, filled.pickupMobile, filled.pickupMore), ('合成昵称', '138****8888', true));
      expect((filled.accessToken, filled.cookie, filled.userId), (session.accessToken, session.cookie, session.userId));
      // 只改取件号时昵称保留。
      expect(filled.withAccount(pickupMobile: '139****2222').nickname, '合成昵称');
      expect(PddSession.fromJson(const {'nickname': 138, 'pickupMore': 'yes'}).nickname, isNull);
    });
  });

  group('响应解析', () {
    test('身份码解析码值、剩余有效期与手机号；缺 expire_mills 用缺省', () {
      final result = IdentityCodeResult.fromJson(const {
        'identification_code': 'dd202610190000000000001',
        'expire_mills': 132000,
        'mobile_info': {'mobile_info_desc': '已绑定常用手机号：138****8888'},
      });
      expect(result.identificationCode, 'dd202610190000000000001');
      expect(result.expireMills, 132000);
      expect(result.refreshAfter, const Duration(milliseconds: 132000));
      expect(result.mobileInfo?.desc, '已绑定常用手机号：138****8888');
      expect(IdentityCodeResult.fromJson(const {'identification_code': 'dd1'}).expireMills, PddConstants.defaultExpireMills);
    });

    test('驿站空列表解析手机尾号与「还有更多」', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 0,
        'no_package_mobile_info': {'mobileList': ['8888', '6666'], 'largerThan2': true},
      });
      expect(result.total, 0);
      expect(result.noPackageMobileInfo?.mobileList, ['8888', '6666']);
      expect(result.noPackageMobileInfo?.largerThanTwo, isTrue);
      expect(result.groups, isEmpty);
    });

    // 字段按官方 mdkd 包裹页的渲染取（combine_list 按驿站分组），数据是合成的。
    test('驿站非空列表按 combine_list 分组：站名、地址、取件码去掉前缀、快递公司、运单号、送货上门件数', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 2,
        'combine_list': [
          {
            'company_name': '合成驿站一号',
            'address': '测试路 1 号',
            'combine_track_list': [{'pick_code': '取件码 3-2-1001', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000001', 'mobile_alias': '自己'}],
            'station_delivery_track_list': [{'tracking_number': 'SX0000000002'}],
          },
        ],
      });
      expect(result.total, 2);
      final group = result.groups.single;
      expect(group.stationName, '合成驿站一号');
      expect(group.address, '测试路 1 号');
      expect(group.deliveryCount, 1);
      final parcel = group.packages.single;
      expect(parcel.pickCode, '3-2-1001');
      expect(parcel.shippingName, '合成快递');
      expect(parcel.trackingNumber, 'SX0000000001');
      expect(parcel.mobileAlias, '自己');
      // count 缺失时按列表里的件数算。
      expect(StationPackagesResult.fromJson(const {'combine_list': [{'combine_track_list': [{'pick_code': '1'}, {'pick_code': '2'}]}]}).total, 2);
    });

    // 结构取自 10-21 审阅移交包的真实响应（已脱敏），站名与站点码换成合成值。
    test('带驿站码查的结果读出站名与「只能微信扫码取件」（true 或 1 都算）', () {
      const body = {'count': 0, 'show_mobile_alias': true, 'can_add_package': true, 'station_name': '合成驿站', 'only_wx_scan': true, 'no_package_mobile_info': {'mobileList': [], 'largerThan2': false}};
      final result = StationPackagesResult.fromJson(body);
      expect(result.stationName, '合成驿站');
      expect(result.onlyWxScan, isTrue);
      expect(StationPackagesResult.fromJson(const {'count': 0, 'only_wx_scan': 1}).onlyWxScan, isTrue);
      expect(StationPackagesResult.fromJson(const {'count': 0, 'station_name': '合成驿站'}).onlyWxScan, isFalse);
    });

    // 字段按官方取快递页「近一周已取出」弹层的渲染取；查物流参数优先取 jump_url（官方点一项就是带着它进物流页）。数据合成。
    test('近一周已取出解析取件地址、时间、快递公司与运单号，物流参数先取 jump_url 再用条目字段；待取件带 shipping_id', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 1,
        'combine_list': [
          {'combine_track_list': [{'pick_code': '1-1-0001', 'tracking_number': 'SX0000000001', 'shipping_id': 101}]},
        ],
        'package_out_list': [
          {'address': '测试路 1 号', 'operate_time': '10-20 15:30', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000002', 'jump_url': '/track?tracking_number=SX0000000002&shipping_id=102&source_type=3'},
          {'tracking_number': 'SX0000000003', 'shipping_id': '103'},
        ],
      });
      expect(result.total, 1, reason: '已取出的不算待取件');
      expect(result.groups.single.packages.single.trackQuery, (trackingNumber: 'SX0000000001', shippingId: '101', sourceType: '', orderSn: '', entrySource: ''));
      final recent = result.recentPackages;
      expect(recent.first.address, '测试路 1 号');
      expect(recent.first.operateTime, '10-20 15:30');
      expect(recent.first.shippingName, '合成快递');
      expect(recent.first.trackQuery, (trackingNumber: 'SX0000000002', shippingId: '102', sourceType: '3', orderSn: '', entrySource: ''));
      expect(recent.last.trackQuery, (trackingNumber: 'SX0000000003', shippingId: '103', sourceType: '', orderSn: '', entrySource: ''));
    });

    // 10-30 用户真机：已取出的件只有拼多多 App 的原生通道出得了物流，同官方网页的「打开 App」拼 pinduoduo:// 链接。数据合成。
    test('已取出的件在拼多多 App 里看物流：/mdkd 接上 jump_url，扫过驿站码时加 station_code；jump_url 不是相对路径就不给', () {
      const jump = '/track?order_sn=&source_type=&entry_source=9&shipping_id=104&tracking_number=SX0000000004&partial_shipment_period=';
      expect(StationOutPackage.fromJson(const {'jump_url': jump}).jumpUrl, jump);
      expect(
        pddAppTrackLink(jump).toString(),
        'pinduoduo://com.xunmeng.pinduoduo/mdkd/track?order_sn=&source_type=&entry_source=9&shipping_id=104&tracking_number=SX0000000004&partial_shipment_period=',
      );
      expect(pddAppTrackLink(jump, stationCode: 'S000000001')!.queryParameters['station_code'], 'S000000001');
      expect(pddAppTrackLink(''), isNull);
      expect(pddAppTrackLink('https://example.com/track?tracking_number=SX0000000004'), isNull);
      expect(pddAppTrackLink('//example.com/track'), isNull);
    });

    // 10-25：官方物流页对链接里带 order_sn 的件（驿站里的件）按 order_sn 查驿站物流，不按运单号查通用物流；字段名照官方代码，数据合成。
    // 10-30 起同官方请求封装带 anti-content（见 express_models.dart 的人工决策）。
    test('驿站里的件物流参数先取 jump_url 里的 order_sn 与 source_type，查物流走 POST dsd/trackbox/shipping/track 并带 anti-content', () async {
      final parcel = StationPackage.fromJson(const {'tracking_number': 'SX0000000004', 'shipping_id': 104, 'order_sn': 'SN0000000009', 'jump_url': '/track?order_sn=SN0000000004&source_type=2'});
      expect(parcel.trackQuery, (trackingNumber: 'SX0000000004', shippingId: '104', sourceType: '2', orderSn: 'SN0000000004', entrySource: ''));
      http.Request? sent;
      final client = buildClient(session: session, onRequest: (request) => sent = request, respond: (_) => {'error_code': null, 'shipping': {'shipping_name': '合成快递', 'package_info': '尾号4321 的快递'}});
      final track = await client.queryShippingTrack(parcel.trackQuery, antiContent: 'ANTI');
      expect(sent!.method, 'POST');
      expect(sent!.headers[PddConstants.antiContentHeader], 'ANTI');
      expect(sent!.url.path, '/api/express/dsd/trackbox/shipping/track');
      expect(jsonDecode(sent!.body), {'order_sn': 'SN0000000004', 'source_type': 2, 'entry_source': null, 'query_type': 1});
      expect(track.ownerTail, '4321');
      client.close();
    });

    // 审阅移交包说 App 版分组里的包裹键是 list（官方 H5 是 combine_track_list），两种都认。
    test('分组里的包裹在 list 键下也能读出', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 1,
        'combine_list': [
          {'station_code': 'S000000001', 'list': [{'pick_code': '1-1-0001', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000009'}]},
        ],
      });
      expect(result.groups.single.packages.single.pickCode, '1-1-0001');
      expect(result.groups.single.packages.single.trackingNumber, 'SX0000000009');
    });

    test('驿站码从链接、App 内链、JSON 与裸码里取，取不到返回空；带 t 参数的是动态码', () {
      const code = 'S000000001';
      for (final raw in [
        'https://mdkd.pinduoduo.com/weixin/package?station_code=$code',
        'https://m.pinduoduo.net/mdkd/package?pr_page_from=scheme&station_code=$code',
        'pinduoduo://com.xunmeng.pinduoduo/mdkd/package?station_code=$code',
        '{"station_code":"$code"}',
        '  $code  ',
      ]) {
        expect(parseStationScan(raw), (code: code, dynamicQr: false), reason: raw);
      }
      expect(parseStationScan('https://mdkd.pinduoduo.com/weixin/package?station_code=$code&t=123'), (code: code, dynamicQr: true));
      for (final raw in ['https://example.com/station?foo=bar', '{"foo":"bar"}', '{坏的 JSON', '这不是驿站码', '']) {
        expect(parseStationScan(raw), isNull, reason: raw);
      }
      expect(weChatStationUrl(code), 'https://mdkd.pinduoduo.com/weixin/package?station_code=$code');
    });

    test('绑定手机号解析打码号、别名与常用标记', () {
      final mobile = PddBoundMobile.fromJson(const {'mobile_id': 'm1', 'mock_mobile': '138****8888', 'alias': '自己', 'commonly_used': true});
      expect(mobile.mobileId, 'm1');
      expect(mobile.maskedMobile, '138****8888');
      expect(mobile.alias, '自己');
      expect(mobile.commonlyUsed, isTrue);
      expect(PddBoundMobile.fromJson(const {'mobile_id': 'm2'}).commonlyUsed, isFalse);
    });

    // 驿站查询不给包裹寄到哪个号，物流接口的 package_info 写「尾号5678 的快递」（10-22 真机形状，数字合成）。
    test('物流详情从 package_info 取这件寄到的手机尾号，格式对不上当不知道', () {
      expect(ShippingTrack.fromJson(const {'package_info': '尾号1234 的快递'}).ownerTail, '1234');
      expect(ShippingTrack.fromJson(const {'package_info': '尾号 5678 的快递'}).ownerTail, '5678');
      expect(ShippingTrack.fromJson(const {'package_info': '寄给本人'}).ownerTail, '');
      expect(ShippingTrack.fromJson(const {}).ownerTail, '');
    });

    // 10-22 真机：隐藏页没登录态，加载几秒后自己跳 login.html、再试图拉起拼多多 App，跳走就丢了生成器（每次约 10 秒、偶尔失败）。
    test('anti_content 隐藏页的主框架只许停在官方 mdkd 页，跳登录页与外部 scheme 一律拦下', () {
      NavigationDecision decide(String url, {bool main = true}) => antiPageNavigation(NavigationRequest(url: url, isMainFrame: main));
      expect(decide(PddConstants.antiContentPage), NavigationDecision.navigate);
      expect(decide('https://m.pinduoduo.net/mdkd/package?other=1'), NavigationDecision.navigate);
      expect(decide('https://m.pinduoduo.net/login.html?from=x'), NavigationDecision.prevent);
      expect(decide('pinduoduo://com.xunmeng.pinduoduo/mdkd/package'), NavigationDecision.prevent);
      expect(decide('https://mobile.yangkeduo.com/mdkd/package'), NavigationDecision.prevent);
      expect(decide('https://static.pddpic.com/frame.html', main: false), NavigationDecision.navigate);
      expect(decide('pinduoduo://x', main: false), NavigationDecision.prevent);
    });

    test('认不出的返回抛 invalidResponse', () {
      expect(() => expressJson('<html>not json</html>'), throwsA(isA<ExpressFailure>().having((failure) => failure.code, 'code', ExpressFailureCode.invalidResponse)));
    });
  });

  group('客户端成功与错误映射', () {
    test('三项查询走通，身份码接口带 entry_source=APP 与 ID_CODE referer', () async {
      String? identityReferer;
      Object? identityBody;
      final client = buildClient(
        session: session,
        onRequest: (request) {
          if (request.url.path.endsWith('generate_identification_code')) {
            identityReferer = request.headers['Referer'];
            identityBody = jsonDecode(request.body);
          }
        },
        respond: (path) {
          if (path.endsWith('express/detail')) {
            return {'success': true, 'error_code': '0', 'new_binding_list': [{'mobile_id': 'm1', 'mock_mobile': '138****8888', 'alias': '自己'}]};
          }
          if (path.endsWith('station/package')) {
            return {'success': true, 'error_code': '0', 'result': {'count': 0, 'no_package_mobile_info': {'mobileList': ['8888']}}};
          }
          return {'success': true, 'error_code': '0', 'result': {'identification_code': 'dd202610190000000000001', 'expire_mills': 132000}};
        },
      );
      final mobiles = await client.queryBoundMobiles();
      expect(mobiles.single.maskedMobile, '138****8888');
      final packages = await client.queryStationPackages();
      expect(packages.noPackageMobileInfo?.mobileList, ['8888']);
      final code = await client.generateIdentityCode();
      expect(code.identificationCode, 'dd202610190000000000001');
      expect(identityReferer, PddConstants.idCodeReferer);
      expect((identityBody! as Map)['entry_source'], 'APP');
      client.close();
    });

    test('昵称走官方 mdkd 同款接口与 scene，读 result.nickname', () async {
      http.Request? sent;
      final client = buildClient(
        session: session,
        onRequest: (request) => sent = request,
        respond: (_) => {'success': true, 'error_code': '0', 'result': {'nickname': '合成昵称', 'avatar': ''}},
      );
      expect(await client.queryNickname(), '合成昵称');
      expect(sent!.url.path, '/api/express_trackbox/base/nickname/query');
      expect(jsonDecode(sent!.body), {'scene': 'dsd.usercenter'});
      client.close();
    });

    test('扫驿站码进入带 station_code 与 entry_source=4', () async {
      Object? body;
      final client = buildClient(
        session: session,
        onRequest: (request) => body = jsonDecode(request.body),
        respond: (_) => {'success': true, 'error_code': '0', 'result': {'count': 1, 'list': [{'x': 1}]}},
      );
      await client.queryStationPackages(stationCode: 'STATION-9', entrySource: PddConstants.entryScan);
      expect((body! as Map)['station_code'], 'STATION-9');
      expect((body! as Map)['entry_source'], '4');
      expect((body! as Map)['dynamic_qrcode'], isFalse);
      await client.queryStationPackages(stationCode: 'STATION-9', dynamicQr: true, entrySource: PddConstants.entryScan);
      expect((body! as Map)['dynamic_qrcode'], isTrue);
      client.close();
    });

    // 同官方物流页（/track）：GET、entry_source=9，shipping_id 与 source_type 有才带，请求头带 anti-content；结果在 shipping 里。数据合成。
    test('查物流走 GET shipping/track 带运单号等参数与 anti-content，解析快递公司、预计送达与轨迹；失败带回 error_message', () async {
      http.Request? sent;
      final client = buildClient(
        session: session,
        onRequest: (request) => sent = request,
        respond: (_) => {
          'shipping': {
            'shipping_name': '合成快递',
            'tracking_number': 'SX0000000002',
            'time_forecast': {'time_forecast_desc': '预计明天送达'},
            'traces': [
              {'info': '【合成市】快件已到达合成驿站', 'time': '2026-10-20 15:30:00'},
              {'info': '【合成市】快件已发出', 'time': '2026-10-19 08:00:00'},
            ],
          },
        },
      );
      final track = await client.queryShippingTrack((trackingNumber: 'SX0000000002', shippingId: '102', sourceType: '3', orderSn: '', entrySource: ''), antiContent: 'ANTI');
      expect(sent!.method, 'GET');
      expect(sent!.headers[PddConstants.antiContentHeader], 'ANTI');
      expect(sent!.url.path, '/api/express/shipping/track');
      expect(sent!.url.queryParameters, {'tracking_number': 'SX0000000002', 'shipping_id': '102', 'entry_source': '9', 'source_type': '3'});
      expect(track.shippingName, '合成快递');
      expect(track.forecast, '预计明天送达');
      expect(track.traces.map((trace) => trace.info), ['【合成市】快件已到达合成驿站', '【合成市】快件已发出']);
      expect(track.traces.first.time, '2026-10-20 15:30:00');
      await client.queryShippingTrack((trackingNumber: 'SX0000000002', shippingId: '', sourceType: '', orderSn: '', entrySource: ''), antiContent: 'anti');
      expect(sent!.url.queryParameters, {'tracking_number': 'SX0000000002', 'entry_source': '9'});
      client.close();

      // 10-22 真机：成功的物流返回不带 success、error_code 是 null，以前被当成失败只提示「拼多多返回失败」。
      final realShape = buildClient(session: session, respond: (_) => {'error_code': null, 'verify_auth_token': null, 'is_support': true, 'shipping': {'shipping_name': '合成快递', 'package_info': '尾号1234 的快递'}});
      final real = await realShape.queryShippingTrack((trackingNumber: 'SX0000000002', shippingId: '1', sourceType: '', orderSn: '', entrySource: ''), antiContent: 'anti');
      expect((real.shippingName, real.ownerTail), ('合成快递', '1234'));
      realShape.close();

      final failing = buildClient(session: session, respond: (_) => {'error_code': 1000101, 'error_message': '暂无该运单号物流轨迹信息'});
      await expectLater(
        failing.queryShippingTrack((trackingNumber: 'SX0000000009', shippingId: '', sourceType: '', orderSn: '', entrySource: ''), antiContent: 'anti'),
        throwsA(isA<ExpressFailure>().having((failure) => failure.message, 'message', '暂无该运单号物流轨迹信息')),
      );
      failing.close();
    });

    test('「登录验证码已失效」说的是验证码，不判为登录失效', () async {
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': '600', 'error_msg': '登录验证码已失效'});
      await expectLater(
        client.verifyBindSmsCode(mobileId: 'm', code: '000000', antiContent: 'anti'),
        throwsA(isA<ExpressFailure>().having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isFalse)),
      );
      client.close();
    });

    // 10-22 真机：反复查物流后拼多多回 54001 并带 verify_auth_token，官方页面这时跳官方安全验证页；过了之后的请求带 VerifyAuthToken。
    test('error_code=54001 映射为要先过安全验证并带回令牌；设了令牌之后的请求带 VerifyAuthToken 头', () async {
      final headers = <String?>[];
      final client = buildClient(
        session: session,
        onRequest: (request) => headers.add(request.headers['VerifyAuthToken']),
        respond: (_) => {'error_code': 54001, 'verify_auth_token': 'VT-1', 'shipping': null},
      );
      await expectLater(
        client.queryShippingTrack((trackingNumber: 'SX0000000001', shippingId: '1', sourceType: '', orderSn: '', entrySource: ''), antiContent: 'anti'),
        throwsA(isA<ExpressFailure>().having((failure) => (failure.code, failure.verifyToken), 'code', (ExpressFailureCode.verifyRequired, 'VT-1'))),
      );
      client.verifyToken = 'VT-1';
      await expectLater(client.queryStationPackages(), throwsA(isA<ExpressFailure>()));
      expect(headers, [null, 'VT-1']);
      client.close();
    });

    test('error_code=40001 映射为未登录', () async {
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': 40001, 'error_msg': ''});
      await expectLater(
        client.generateIdentityCode(),
        throwsA(isA<ExpressFailure>().having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isTrue)),
      );
      client.close();
    });

    test('其他失败码按服务端错误，带 error_msg', () async {
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': '50000', 'error_msg': '请稍后再试'});
      await expectLater(
        client.queryBoundMobiles(),
        throwsA(isA<ExpressFailure>().having((failure) => failure.message, 'message', '请稍后再试')),
      );
      client.close();
    });

    test('异地登录等会话失效不回 40001 时，按文案判为未登录', () async {
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': '43001', 'error_msg': '登录状态已失效，请重新登录'});
      await expectLater(
        client.generateIdentityCode(),
        throwsA(isA<ExpressFailure>().having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isTrue)),
      );
      client.close();
    });

    test('「验证码已失效」这类非鉴权文案不误判为未登录，仍按服务端错误', () async {
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': '600', 'error_msg': '验证码已失效，请重新获取'});
      await expectLater(
        client.verifyBindSmsCode(mobileId: 'm', code: '000000', antiContent: 'anti'),
        throwsA(isA<ExpressFailure>()
            .having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isFalse)
            .having((failure) => failure.message, 'message', '验证码已失效，请重新获取')),
      );
      client.close();
    });

    // 真机实测：异地登录把会话顶掉后 station/package 返回 HTTP 424（不是业务码 40001）。
    test('HTTP 424（异地登录被顶掉）映射为未登录', () async {
      final client = ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async => http.Response('', 424))));
      await expectLater(
        client.queryStationPackages(),
        throwsA(isA<ExpressFailure>().having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isTrue)),
      );
      client.close();
    });

    // 真机实测：绑定短信 /api/francis 返回 HTTP 403（风控），不能当未登录、不能把人登出。
    test('HTTP 403（风控）不当未登录，仍按服务器错误', () async {
      final client = ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async => http.Response('', 403))));
      await expectLater(
        client.sendBindSmsCode('13800000000', antiContent: 'anti'),
        throwsA(isA<ExpressFailure>()
            .having((failure) => failure.isNotLoggedIn, 'isNotLoggedIn', isFalse)
            .having((failure) => failure.code, 'code', ExpressFailureCode.server)),
      );
      client.close();
    });
  });

  group('绑定取件手机号', () {
    // 本账号手机号按官方绑定弹窗读 mobile_des（没绑过号时才给，10-22 真机已绑号的账号只回 has_binding_express_mobile）；
    // mobile_info_desc 是身份码接口的说明文字，不能当手机号。
    test('预检查成功即使不带 success/error_code 也解析，给出可快速绑定的已有号与本账号手机号', () async {
      final client = buildClient(session: session, respond: (_) => {'has_binding_express_mobile': false, 'mobile_id': 'mid1', 'mobile_id_scene': 1, 'mobile_des': '138****8888', 'mobile_info_desc': '已绑定常用手机号：138****8888'});
      final pre = await client.preCheckBindMobile();
      expect(pre.hasBound, isFalse);
      expect(pre.canFastBind, isTrue);
      expect(pre.mobileId, 'mid1');
      expect(pre.mobileIdScene, 1);
      expect(pre.mobileDesc, '138****8888');
      client.close();
    });

    test('发送验证码走 francis query 带手机号与 scene、anti-content 头，返回 mobile_id', () async {
      String? path;
      Object? body;
      String? antiHeader;
      final client = buildClient(
        session: session,
        onRequest: (request) {
          path = request.url.path;
          body = jsonDecode(request.body);
          antiHeader = request.headers['anti-content'];
        },
        respond: (_) => {'success': true, 'mobile_id': 'MID'},
      );
      final mobileId = await client.sendBindSmsCode('13800000000', antiContent: 'ANTI');
      expect(mobileId, 'MID');
      expect(path, endsWith('/api/francis/mobile/code/auth/query'));
      expect(antiHeader, 'ANTI');
      expect((body! as Map)['mobile'], '13800000000');
      expect((body! as Map)['mobile_type'], PddConstants.mobileTypeMobile);
      expect((body! as Map)['scene'], PddConstants.bindSmsScene);
      client.close();
    });

    test('mobile_id 裹在 result 里也能取到', () async {
      final client = buildClient(session: session, respond: (_) => {'success': true, 'result': {'mobile_id': 'MID2'}});
      expect(await client.sendBindSmsCode('13800000000', antiContent: 'anti'), 'MID2');
      client.close();
    });

    test('校验验证码返回 session_id', () async {
      Object? body;
      final client = buildClient(session: session, onRequest: (request) => body = jsonDecode(request.body), respond: (_) => {'success': true, 'session_id': 'SID'});
      expect(await client.verifyBindSmsCode(mobileId: 'MID', code: '123456', antiContent: 'anti'), 'SID');
      expect((body! as Map)['mobile_id'], 'MID');
      expect((body! as Map)['code'], '123456');
      client.close();
    });

    test('完成绑定带 session_id、protocol_code 与 entry_source=APP', () async {
      String? path;
      Object? body;
      final client = buildClient(
        session: session,
        onRequest: (request) {
          path = request.url.path;
          body = jsonDecode(request.body);
        },
        respond: (_) => {'success': true},
      );
      await client.newBindMobile('SID', antiContent: 'anti');
      expect(path, endsWith('/api/apoc/binding/mobile/dsd/new/express/mobile'));
      expect((body! as Map)['session_id'], 'SID');
      expect((body! as Map)['protocol_code'], PddConstants.bindProtocolCode);
      expect((body! as Map)['entry_source'], PddConstants.newBindEntrySource);
      client.close();
    });

    test('快速绑定带 mobile_id、protocol_code 与 entry_source=4，mobile_id_scene 为空时不带', () async {
      Object? body;
      final client = buildClient(session: session, onRequest: (request) => body = jsonDecode(request.body), respond: (_) => {'success': true});
      await client.fastBindMobile(mobileId: 'mid1', antiContent: 'anti');
      expect((body! as Map)['mobile_id'], 'mid1');
      expect((body! as Map)['protocol_code'], PddConstants.bindProtocolCode);
      expect((body! as Map)['entry_source'], PddConstants.fastBindEntrySource);
      expect((body! as Map).containsKey('mobile_id_scene'), isFalse);
      client.close();
    });

    // 官方在绑定成功后紧接着调它，把绑定前就已到站的包裹关联进本账号；body 为空，带 anti-content 头。
    test('关联驿站包裹走 bind/mobile/station/package，空 body、带 anti-content 头', () async {
      String? path;
      Object? body;
      String? antiHeader;
      final client = buildClient(
        session: session,
        onRequest: (request) {
          path = request.url.path;
          body = jsonDecode(request.body);
          antiHeader = request.headers['anti-content'];
        },
        respond: (_) => {'success': true},
      );
      await client.linkStationPackages(antiContent: 'ANTI');
      expect(path, endsWith('/api/express_trackbox/bind/mobile/station/package'));
      expect(body, isEmpty);
      expect(antiHeader, 'ANTI');
      client.close();
    });

    // 逆向结论：解绑 body 字段名是 mobile（值 mobileId），带 box_popup_service、mobile_id_scene 与 body 里的 anti_content，anti-content 头也带。
    test('解绑按修正后的字段发：mobile/box_popup_service/mobile_id_scene/anti_content + 头', () async {
      String? path;
      Object? body;
      String? antiHeader;
      final client = buildClient(
        session: session,
        onRequest: (request) {
          path = request.url.path;
          body = jsonDecode(request.body);
          antiHeader = request.headers['anti-content'];
        },
        respond: (_) => {'success': true},
      );
      await client.unbindMobile(mobileId: 'mid1', mobileIdScene: 1, antiContent: 'ANTI');
      expect(path, endsWith('/api/lobit/express/mobile/unbind'));
      expect(antiHeader, 'ANTI');
      expect((body! as Map)['mobile'], 'mid1');
      expect((body! as Map).containsKey('mobile_id'), isFalse);
      expect((body! as Map)['box_popup_service'], PddConstants.bindBoxPopupService);
      expect((body! as Map)['anti_content'], 'ANTI');
      expect((body! as Map)['mobile_id_scene'], 1);
      client.close();
    });
  });
}
