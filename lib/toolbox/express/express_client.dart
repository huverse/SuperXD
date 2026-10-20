import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';

// 拼多多快递查询与身份码接口客户端：登录态由 PddSession 带，接口无状态。
// 失败统一抛 ExpressFailure，页面按 code 分支；40001（未登录）单独成一类交给重新登录。
class ExpressClient {
  ExpressClient({required this.session, ExpressHttp? http}) : _http = http ?? ExpressHttp();
  final PddSession session;
  final ExpressHttp _http;

  Uri _api(String path) => Uri.parse('${PddConstants.apiBase}$path');

  // 解析通用响应壳：success 或 error_code 为 0 / 1000000 算成功；40001 当未登录；其余按服务端错误。
  Map<String, Object?> _unwrap(ExpressResponse response) {
    final data = expressJson(response.body);
    final code = '${data['error_code']}';
    if (data['success'] == true || code == '0' || code == '1000000') return data;
    if (code == '40001') throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    final message = '${data['error_msg'] ?? ''}';
    throw ExpressFailure(ExpressFailureCode.server, message.isEmpty ? '拼多多返回失败' : message);
  }

  Future<Map<String, Object?>> _postJson(String path, {required String referer, required Map<String, Object?> body}) async {
    final response = await _http.postJson(_api(path), headers: session.headers(referer: referer), body: body);
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

  void close() => _http.close();
}
