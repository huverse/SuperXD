import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';

const chaoxingQrPrefix = 'SIGNIN:';
const chaoxingSignDetailUri = 'https://mobilelearn.chaoxing.com/newsign/signDetail';

class ChaoxingQrCode {
  const ChaoxingQrCode({required this.enc, this.activeId, this.code});
  final String enc;

  // 二维码自带的活动号：和当前打开的活动不一致时按二维码里的来。
  final int? activeId;
  final String? code;
}

// 课堂签到二维码两种形态：SIGNIN: 开头的内嵌串，或带 enc 的链接。认不出返回空。
ChaoxingQrCode? chaoxingParseQrCode(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith(chaoxingQrPrefix)) {
    final content = text.substring(chaoxingQrPrefix.length).split('-').first;
    final mark = content.indexOf('&enc=');
    if (mark < 0) return null;
    final enc = content.substring(mark + '&enc='.length).split('&').first;
    if (enc.isEmpty) return null;
    final detail = content.substring(0, mark);
    final first = detail.split('&').first;
    final last = detail.split('&').last;
    return ChaoxingQrCode(
      enc: enc,
      activeId: _intOrNull(_valueAfter(first)),
      code: _valueAfter(last),
    );
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  final enc = uri.queryParameters['enc'];
  if (enc == null || enc.isEmpty) return null;
  return ChaoxingQrCode(
    enc: enc,
    activeId: _intOrNull(uri.queryParameters['id'] ?? uri.queryParameters['aid']),
    code: uri.queryParameters['c'],
  );
}

String? _valueAfter(String pair) {
  final index = pair.indexOf('=');
  if (index < 0) return pair.isEmpty ? null : pair;
  final value = pair.substring(index + 1).trim();
  return value.isEmpty ? null : value;
}

int? _intOrNull(String? value) => value == null ? null : int.tryParse(value);

// 二维码会随老师刷新，扫到新码时问一次是否还有效：过期为真、有效为假、无从判断为空（查询出错由调用方按不确定处理）。
// [人工决策-2026-10-21 19:40:00] 只有码里带着轮换签到码（c/Code 且不等于活动号）才查（用户选定）：
// 新格式链接 widget/sign/e?id=活动号&c=活动号 的 c 就是活动号（随刷新只换 enc），拿它比 signCode 永远对不上，
// 每张新码都判过期；没有 c 的同参考项目不发请求。结果只用来在取景页提示，过期与否以提交结果为准（见 chaoxing_sign_sheet.dart）。
Future<bool?> chaoxingQrCodeExpired(
  ChaoxingClient client, {
  required ChaoxingQrCode code,
  required int activeId,
}) async {
  final activePrimaryId = '${code.activeId ?? activeId}';
  final signCode = code.code;
  if (signCode == null || signCode == activePrimaryId) return null;
  final response = await client.http.get(
    Uri.parse(chaoxingSignDetailUri).replace(
      queryParameters: {'activePrimaryId': activePrimaryId, 'type': '1', 'msg': signCode},
    ),
  );
  final json = chaoxingJson(response.body);
  return chaoxingInt(json['isOver']) == 1 || chaoxingString(json['signCode']) != signCode;
}
