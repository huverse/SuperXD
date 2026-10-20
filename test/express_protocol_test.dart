import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

    test('驿站空列表解析手机尾号', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 0,
        'no_package_mobile_info': {'mobileList': ['8888', '6666'], 'largerThan2': false},
      });
      expect(result.count, 0);
      expect(result.noPackageMobileInfo?.mobileList, ['8888', '6666']);
      expect(result.packages, isEmpty);
    });

    test('驿站非空列表从任一常见键取并保留 raw', () {
      final result = StationPackagesResult.fromJson(const {
        'count': 2,
        'package_list': [{'a': 1}, {'b': 2}],
      });
      expect(result.count, 2);
      expect(result.packages.length, 2);
      expect(result.raw['count'], 2);
    });

    test('绑定手机号解析打码号与别名', () {
      final mobile = PddBoundMobile.fromJson(const {'mobile_id': 'm1', 'mock_mobile': '138****8888', 'alias': '自己'});
      expect(mobile.mobileId, 'm1');
      expect(mobile.maskedMobile, '138****8888');
      expect(mobile.alias, '自己');
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
      final client = buildClient(session: session, respond: (_) => {'success': false, 'error_code': '54001', 'error_msg': '请稍后再试'});
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
    test('预检查成功即使不带 success/error_code 也解析，给出可快速绑定的已有号', () async {
      final client = buildClient(session: session, respond: (_) => {'has_binding_express_mobile': false, 'mobile_id': 'mid1', 'mobile_id_scene': 1, 'mobile_info_desc': '138****8888'});
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
