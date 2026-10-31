import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多快递查询、身份码与绑定取件手机号接口客户端：登录态由 PddSession 带，接口无状态。
// 失败统一抛 ExpressFailure，页面按 code 分支；40001 及文案点出的登录失效单独归「未登录」交给重新登录。
class ExpressClient {
  ExpressClient({required this.session, ExpressHttp? http}) : _http = http ?? ExpressHttp();
  final PddSession session;
  final ExpressHttp _http;
  // 用户在官方页面过了安全验证后的令牌（见 ExpressFailureCode.verifyRequired），之后的请求同官方带上；只在内存里。
  String verifyToken = '';

  Uri _api(String path) => Uri.parse('${PddConstants.apiBase}$path');

  Map<String, String> _headers(String referer) {
    final headers = session.headers(referer: referer);
    if (verifyToken.isNotEmpty) headers['VerifyAuthToken'] = verifyToken;
    return headers;
  }

  // 解析通用响应壳：success 为真、error_code 为 0 / 1000000，或根本没带 error_code（如绑定预检查成功）都算成功；
  // error_code 为 null 也当没带：物流接口成功时不带 success、error_code 是 null（10-22 真机），以前误判成失败、只提示「拼多多返回失败」。
  // 40001 当未登录；异地登录等会话失效不一定回 40001，服务端文案点出登录失效时也归未登录；其余按服务端错误。
  Map<String, Object?> _unwrap(ExpressResponse response) {
    final data = expressJson(response.body);
    final code = '${data['error_code']}';
    if (code == '40001') throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    // 54001：拼多多风控要用户本人先过一次官方安全验证（10-22 真机：短时间里反复查物流后，带不带 anti-content 都回它并带 verify_auth_token）。
    // 官方 mdkd 页面遇到它就跳官方验证页；令牌不进日志。
    if (code == '54001') {
      campusLog('[Express] action=verify_required');
      throw ExpressFailure(ExpressFailureCode.verifyRequired, '拼多多要求先完成安全验证', verifyToken: '${data['verify_auth_token'] ?? data['verifyAuthToken'] ?? ''}');
    }
    final codeOk = code == '0' || code == '1000000';
    final hasErrorCode = data['error_code'] != null && !codeOk;
    if (data['success'] != false && (data['success'] == true || !hasErrorCode)) return data;
    // 文案多数接口叫 error_msg，物流接口叫 error_message。
    final message = '${data['error_msg'] ?? data['error_message'] ?? ''}';
    // 错误码记一行（不记文案与响应体）：异地登录真实返回的码可在真机 logcat 看到，用来精确对齐未登录判定。
    campusLog('[Express] action=server_error code=$code');
    if (_looksLikeAuthExpired(message)) throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    throw ExpressFailure(ExpressFailureCode.server, message.isEmpty ? '拼多多返回失败，请稍后重试' : message);
  }

  // 文案同时点到「登录/身份」与「失效/过期/重新」，或直接说未登录，才判为会话失效——
  // 避免把「验证码已失效」这类非鉴权错误误判成登录失效、把人误踢回登录页；说的是验证码的（如「登录验证码已失效」）一律不算。
  bool _looksLikeAuthExpired(String message) {
    if (message.contains('验证码')) return false;
    if (message.contains('未登录') || message.contains('请先登录') || message.contains('重新登录') || message.contains('重新登陆')) return true;
    const subject = ['登录', '登陆', '身份', '登陆态', '登录态', '账号'];
    const expiry = ['失效', '过期', '已退出', '不存在'];
    return subject.any(message.contains) && expiry.any(message.contains);
  }

  // antiContent 非空时加 anti-content 请求头（绑定类接口要过风控，见 express_anti_content.dart）。
  Future<Map<String, Object?>> _postJson(String path, {required String referer, required Map<String, Object?> body, String? antiContent}) async {
    final headers = _headers(referer);
    if (antiContent != null) headers[PddConstants.antiContentHeader] = antiContent;
    final response = await _http.postJson(_api(path), headers: headers, body: body);
    return _unwrap(response);
  }

  // 查询账号已绑定的取件手机号。
  Future<List<PddBoundMobile>> queryBoundMobiles() async {
    final data = await _postJson('/api/apoc/express/detail', referer: PddConstants.mdkdReferer, body: const {'entry_source': 17});
    final list = data['new_binding_list'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((entry) => PddBoundMobile.fromJson(entry.cast<String, Object?>())).toList();
  }

  // 本账号的拼多多昵称（只读，同官方 mdkd「我的」一栏的同一接口与 scene），只给账号卡认出是哪个账号。
  Future<String> queryNickname() async {
    final data = await _postJson('/api/express_trackbox/base/nickname/query', referer: PddConstants.mdkdReferer, body: const {'scene': 'dsd.usercenter'});
    final result = data['result'];
    return result is Map ? '${result['nickname'] ?? ''}' : '';
  }

  // 查询驿站/快递柜待取件。普通入口 entrySource=8；扫驿站二维码进入时传 stationCode 且 entrySource=4，动态码另带 dynamic_qrcode。
  Future<StationPackagesResult> queryStationPackages({String stationCode = '', bool dynamicQr = false, int entrySource = PddConstants.entryOther}) async {
    final body = <String, Object?>{
      'entry_source': entrySource.toString(),
      'dynamic_qrcode': dynamicQr,
      'install_token': session.installToken,
      'dp_source': '',
      'redirect_app': false,
      if (stationCode.isNotEmpty) 'station_code': stationCode,
    };
    final data = await _postJson('/api/express_trackbox/station/package', referer: PddConstants.mdkdReferer, body: body);
    final result = data['result'];
    return StationPackagesResult.fromJson(result is Map ? result.cast<String, Object?>() : const {});
  }

  // 把已绑号在绑定前就已到驿站的包裹关联进本账号：官方在绑定成功后紧接着调、body 为空，不调就查不到这些包裹。
  // 官方请求封装对 express_trackbox 一律带 anti-content；这是状态变更接口，照样带。
  Future<void> linkStationPackages({required String antiContent}) async {
    await _postJson('/api/express_trackbox/bind/mobile/station/package', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: const {});
  }

  // 查一件包裹的实时物流，同官方物流页（/track）按参数选接口，只读，结果都在 shipping 里：
  // 带 order_sn 的（驿站里的件）POST 驿站物流 dsd/trackbox/shipping/track，source_type 与 entry_source 同官方转成数字（没有就是 null）、query_type 固定 1；
  // 没有的 GET 通用物流 shipping/track，entry_source 固定 9。两个都不带 anti-content（真机不带也查得到，见 express_models.dart）。
  Future<ShippingTrack> queryShippingTrack(ExpressTrackQuery query) async {
    final Map<String, Object?> data;
    if (query.orderSn.isNotEmpty) {
      data = await _postJson('/api/express/dsd/trackbox/shipping/track', referer: PddConstants.mdkdReferer, body: {
        'order_sn': query.orderSn,
        'source_type': int.tryParse(query.sourceType),
        'entry_source': int.tryParse(query.entrySource),
        'query_type': 1,
      });
    } else {
      final uri = _api('/api/express/shipping/track').replace(queryParameters: {
        'tracking_number': query.trackingNumber,
        if (query.shippingId.isNotEmpty) 'shipping_id': query.shippingId,
        'entry_source': '9',
        if (query.sourceType.isNotEmpty) 'source_type': query.sourceType,
      });
      data = _unwrap(await _http.getJson(uri, headers: _headers(PddConstants.mdkdReferer)));
    }
    final shipping = data['shipping'];
    return ShippingTrack.fromJson(shipping is Map ? shipping.cast<String, Object?>() : const {});
  }

  // 生成/获取身份码：返回的 expireMills 是当前码剩余有效期，到期后再次调用即可拿到新码。
  Future<IdentityCodeResult> generateIdentityCode({String stationCode = ''}) async {
    final body = <String, Object?>{'entry_source': 'APP', if (stationCode.isNotEmpty) 'station_code': stationCode};
    final data = await _postJson('/api/express_trackbox/generate_identification_code', referer: PddConstants.idCodeReferer, body: body);
    final result = data['result'];
    if (result is! Map) throw const ExpressFailure(ExpressFailureCode.invalidResponse, '身份码响应缺少结果');
    return IdentityCodeResult.fromJson(result.cast<String, Object?>());
  }

  // --- 绑定取件手机号（会改账号状态，调用前必须由用户明确操作并同意；界面见 express_mobile_sheet.dart）---
  // 除预检查外都要 anti_content 过风控：多数接口放 anti-content 请求头，解绑另在 body 的 anti_content 再带一份（逆向结论）。
  // anti_content 由调用方（控制器）每次现取、不缓存（express_anti_content.dart）。

  // 绑定预检查（只读，不需 anti_content）：是否已绑定、有没有可一键快速绑定的已有号。
  Future<PddBindPreCheck> preCheckBindMobile() async {
    final data = await _postJson('/api/apoc/binding/mobile/dsd/fast/bind/c/mobile/pre/check', referer: PddConstants.mdkdReferer, body: const {});
    return PddBindPreCheck.fromJson(data);
  }

  // 快速绑定本账号已有的手机号（无需短信）。身份码入口 entry_source 发 "4"。
  Future<void> fastBindMobile({required String mobileId, int? mobileIdScene, required String antiContent}) async {
    await _postJson('/api/apoc/binding/mobile/dsd/fast/bind/c/mobile', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'mobile_id': mobileId,
      'mobile_id_scene': ?mobileIdScene,
      'protocol_code': PddConstants.bindProtocolCode,
      'entry_source': PddConstants.fastBindEntrySource,
    });
  }

  // 给新手机号发送绑定验证码；返回下一步校验要用的 mobile_id。
  Future<String> sendBindSmsCode(String mobile, {required String antiContent}) async {
    final data = await _postJson('/api/francis/mobile/code/auth/query', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'mobile_type': PddConstants.mobileTypeMobile,
      'mobile': mobile,
      'digits': 6,
      'scene': PddConstants.bindSmsScene,
    });
    return _pickField(data, 'mobile_id');
  }

  // 校验绑定验证码；返回完成绑定要用的 session_id。
  Future<String> verifyBindSmsCode({required String mobileId, required String code, required String antiContent}) async {
    final data = await _postJson('/api/francis/mobile/code/auth/verify', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'mobile_id': mobileId,
      'code': code,
      'scene': PddConstants.bindSmsScene,
    });
    return _pickField(data, 'session_id');
  }

  // 用校验拿到的 session_id 完成绑定新手机号。entry_source 发 "APP"（cellPhoneList 口径）。
  Future<void> newBindMobile(String sessionId, {required String antiContent, String alias = ''}) async {
    await _postJson('/api/apoc/binding/mobile/dsd/new/express/mobile', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'session_id': sessionId,
      'alias': alias,
      'verify_scene': PddConstants.bindSmsScene,
      'protocol_code': PddConstants.bindProtocolCode,
      'entry_source': PddConstants.newBindEntrySource,
    });
  }

  // 解绑取件手机号。body 字段名是 mobile（值为 mobileId），带 box_popup_service、mobile_id_scene 与 body 里的 anti_content；anti-content 头也带（逆向结论修正，原 {mobile_id} 会回 4000001）。
  Future<void> unbindMobile({required String mobileId, int? mobileIdScene, required String antiContent}) async {
    await _postJson('/api/lobit/express/mobile/unbind', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'mobile': mobileId,
      'box_popup_service': PddConstants.bindBoxPopupService,
      'anti_content': antiContent,
      'mobile_id_scene': ?mobileIdScene,
    });
  }

  // 修改取件手机号的备注（同官方「修改备注」弹窗，最多 5 个字，空串即清掉）：body 带 mobile_id、alias、mobile_id_scene 与 anti_content，anti-content 头也带。
  Future<void> updateMobileAlias({required String mobileId, int? mobileIdScene, required String alias, required String antiContent}) async {
    await _postJson('/api/apoc/express/mobile/alias', referer: PddConstants.mdkdReferer, antiContent: antiContent, body: {
      'mobile_id': mobileId,
      'alias': alias,
      'anti_content': antiContent,
      'mobile_id_scene': ?mobileIdScene,
    });
  }

  // --- 短信登录（还没有会话，用空会话建客户端；[人工决策] 见 express_models.dart 的登录常量）---
  // 同官方登录页：发码与登录都 POST 到 sigerus，失败原因与验证令牌在响应体里（可能是 4xx），成功后拼多多经 Set-Cookie 下发 PDDAccessToken。

  // 发登录验证码：screen_token 是现生成的 anti_content，requestTimes 是这次已发过几次（同官方）；行为字段不伪造，发空值。
  // 返回 need_call：拼多多改要电话告知验证码（这次没发短信），同意后带 send_voice_code 再发一次。
  Future<bool> sendLoginSms(String mobile, {required String antiContent, required int requestTimes, bool voice = false}) async {
    final response = await _http.postJson(_api('/api/sigerus/mobile/code/request'), headers: _headers(PddConstants.loginPage), errorBody: true, body: {
      // 官方是 JSON.stringify(platformType)，数字 4 即 "4"。
      'platform': '${PddConstants.loginPlatformOther}',
      'fingerprint': '{}',
      'touchevent': '{}',
      'mobile': mobile,
      'screen_token': antiContent,
      'request_times': requestTimes,
      if (voice) 'send_voice_code': true,
      'country_id': PddConstants.loginCountryId,
      'tel_code': PddConstants.loginTelCode,
    });
    return _unwrapLogin(response, 'login_sms')['need_call'] == true;
  }

  // 手机号加验证码登录，成功返回会话。
  Future<PddSession> loginWithSms({required String mobile, required String code, required String antiContent}) async {
    final response = await _http.postJson(_api('/api/sigerus/login_mobile'), headers: _headers(PddConstants.loginPage), errorBody: true, body: {
      'mobile': mobile,
      'code': code,
      'anti_content': antiContent,
      'add_cookie': true,
      'support_enhance_type': PddConstants.loginEnhanceType,
      'login_app_id': PddConstants.loginAppId,
      'country_id': PddConstants.loginCountryId,
      'tel_code': PddConstants.loginTelCode,
    });
    return _loginSession(response, _unwrapLogin(response, 'login'));
  }

  // 用户在官方验证页过了验证，拿登录时给的令牌完成登录（同官方登录页的 riskLogin）。
  Future<PddSession> verifiedLogin(String verifyToken) async {
    final response = await _http.postJson(_api('/api/sigerus/verify/login'), headers: _headers(PddConstants.loginPage), errorBody: true, body: {
      'verify_auth_token': verifyToken,
      'add_cookie': true,
    });
    return _loginSession(response, _unwrapLogin(response, 'verified_login'));
  }

  // 登录接口的响应：成功同 _unwrap 的判定；要验证的两种带上官方验证页（验证完跳回登录页），其余用拼多多给的文案。
  // 每次记一行形状（状态、错误码、字段名与下发的 Cookie 名，不记值）：拼多多认不认空的行为字段，要从真机上的这一行看。
  Map<String, Object?> _unwrapLogin(ExpressResponse response, String action) {
    final Map<String, Object?> data;
    try {
      data = expressJson(response.body);
    } on ExpressFailure {
      // 回的不是 JSON（如风控直接拒绝给的网页）：记下状态码，引导改用网页登录。
      campusLog('[Express] action=$action errorType=not_json status=${response.statusCode}');
      throw const ExpressFailure(ExpressFailureCode.server, '拼多多没有接受这次登录，可以改用拼多多网页登录');
    }
    final code = '${data['error_code']}';
    final shape = 'status=${response.statusCode} code=$code keys=${data.keys.join(',')} cookies=${_setCookies(response).keys.join(',')}';
    final failed = response.statusCode >= 400 || data['success'] == false || (data['error_code'] != null && code != '0' && code != '1000000');
    if (!failed) {
      campusLog('[Express] action=$action $shape');
      return data;
    }
    campusLog('[Express] action=$action errorType=server $shape');
    final token = '${data['verify_auth_token'] ?? ''}';
    if (token.isNotEmpty && (code == '54001' || code == '54002')) {
      final page = Uri.parse(PddConstants.loginVerifyPage).replace(queryParameters: {'VerifyAuthToken': token, 'from': PddConstants.loginPage});
      throw ExpressFailure(ExpressFailureCode.verifyRequired, '拼多多要求先完成安全验证', verifyToken: token, verifyPage: page);
    }
    // 本人验证页同官方带上打码手机号、头像与昵称（页面上让本人认），空的不带。
    if (token.isNotEmpty && code == '54015') {
      final page = Uri.parse(PddConstants.ownerVerifyPage).replace(queryParameters: {
        'verify_auth_token': token,
        'from': PddConstants.loginPage,
        for (final (key, field) in const [('mobile_des', 'mobile_des'), ('n_pic', 'avatar'), ('nick_name', 'nick_name')])
          if ('${data[field] ?? ''}'.isNotEmpty) key: '${data[field]}',
      });
      throw ExpressFailure(ExpressFailureCode.verifyRequired, '拼多多要求先确认是本人', verifyToken: token, verifyPage: page);
    }
    final message = '${data['error_msg'] ?? ''}';
    throw ExpressFailure(ExpressFailureCode.server, message.isEmpty ? '登录没有成功，请稍后重试' : message);
  }

  // 登录成功后的会话：拼多多经 Set-Cookie 下发 PDDAccessToken 等，全部 Cookie 拼成之后请求带的 Cookie 头；
  // 没下发时再看响应体的 access_token（真实返回还没见过，两处都认）。
  PddSession _loginSession(ExpressResponse response, Map<String, Object?> data) {
    final cookies = _setCookies(response);
    final token = cookies['PDDAccessToken'] ?? '${data['access_token'] ?? ''}';
    if (token.isEmpty) throw const ExpressFailure(ExpressFailureCode.invalidResponse, '登录没有拿到会话，请改用网页登录');
    cookies['PDDAccessToken'] = token;
    return PddSession(
      accessToken: token,
      cookie: cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; '),
      installToken: cookies['install_token'] ?? '',
      etag: cookies['ETag'] ?? '',
      userId: cookies['pdd_user_id'] ?? '${data['uid'] ?? ''}',
    );
  }

  // 同名响应头合成一行时以逗号隔开，Expires 里也有逗号：只在逗号后紧跟「名字=」处断开；每条取第一段的名字与值，空值（删 Cookie）不要。
  Map<String, String> _setCookies(ExpressResponse response) {
    final cookies = <String, String>{};
    for (final entry in (response.headers['set-cookie'] ?? '').split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
      final pair = entry.split(';').first.trim();
      final split = pair.indexOf('=');
      if (split > 0 && split < pair.length - 1) cookies[pair.substring(0, split)] = pair.substring(split + 1);
    }
    return cookies;
  }

  // 字段可能在顶层，也可能裹在 result 里，两处都找。
  String _pickField(Map<String, Object?> data, String key) {
    final top = data[key];
    if (top != null && '$top'.isNotEmpty) return '$top';
    final result = data['result'];
    if (result is Map) return '${result[key] ?? ''}';
    return '';
  }

  void close() => _http.close();
}
