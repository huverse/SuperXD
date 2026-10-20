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
  });
}
