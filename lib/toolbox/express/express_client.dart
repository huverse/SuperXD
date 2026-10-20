import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多快递查询、身份码与绑定取件手机号接口客户端：登录态由 PddSession 带，接口无状态。
// 失败统一抛 ExpressFailure，页面按 code 分支；40001 及文案点出的登录失效单独归「未登录」交给重新登录。
class ExpressClient {
  ExpressClient({required this.session, ExpressHttp? http}) : _http = http ?? ExpressHttp();
  final PddSession session;
  final ExpressHttp _http;

  Uri _api(String path) => Uri.parse('${PddConstants.apiBase}$path');

  // 解析通用响应壳：success 为真、error_code 为 0 / 1000000，或根本没带 error_code（如绑定预检查成功）都算成功；
  // 40001 当未登录；异地登录等会话失效不一定回 40001，服务端文案点出登录失效时也归未登录；其余按服务端错误。
  Map<String, Object?> _unwrap(ExpressResponse response) {
    final data = expressJson(response.body);
    final code = '${data['error_code']}';
    if (code == '40001') throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    final codeOk = code == '0' || code == '1000000';
    final hasErrorCode = data.containsKey('error_code') && !codeOk;
    if (data['success'] != false && (data['success'] == true || !hasErrorCode)) return data;
    final message = '${data['error_msg'] ?? ''}';
    // 错误码记一行（不记文案与响应体）：异地登录真实返回的码可在真机 logcat 看到，用来精确对齐未登录判定。
    campusLog('[Express] action=server_error code=$code');
    if (_looksLikeAuthExpired(message)) throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    throw ExpressFailure(ExpressFailureCode.server, message.isEmpty ? '拼多多返回失败，请稍后重试' : message);
  }

  // 文案同时点到「登录/身份」与「失效/过期/重新」，或直接说未登录，才判为会话失效——
  // 避免把「验证码已失效」这类非鉴权错误误判成登录失效、把人误踢回登录页。
  bool _looksLikeAuthExpired(String message) {
    if (message.contains('未登录') || message.contains('请先登录') || message.contains('重新登录') || message.contains('重新登陆')) return true;
    const subject = ['登录', '登陆', '身份', '登陆态', '登录态', '账号'];
    const expiry = ['失效', '过期', '已退出', '不存在'];
    return subject.any(message.contains) && expiry.any(message.contains);
  }

  // antiContent 非空时加 anti-content 请求头（绑定类接口要过风控，见 express_anti_content.dart）。
  Future<Map<String, Object?>> _postJson(String path, {required String referer, required Map<String, Object?> body, String? antiContent}) async {
    final headers = session.headers(referer: referer);
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

  // 查询驿站/快递柜待取件。普通入口 entrySource=8；扫驿站二维码进入时传 stationCode 且 entrySource=4。
  Future<StationPackagesResult> queryStationPackages({String stationCode = '', int entrySource = PddConstants.entryOther}) async {
    final body = <String, Object?>{
      'entry_source': entrySource.toString(),
      'dynamic_qrcode': false,
      'install_token': session.installToken,
      'dp_source': '',
      'redirect_app': false,
      if (stationCode.isNotEmpty) 'station_code': stationCode,
    };
    final data = await _postJson('/api/express_trackbox/station/package', referer: PddConstants.mdkdReferer, body: body);
    final result = data['result'];
    return StationPackagesResult.fromJson(result is Map ? result.cast<String, Object?>() : const {});
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
