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

// 二维码会随老师刷新，提交前先问一次是否还有效。
Future<bool> chaoxingQrCodeExpired(
  ChaoxingClient client, {
  required ChaoxingQrCode code,
  required int activeId,
}) async {
  final response = await client.http.get(
    Uri.parse(chaoxingSignDetailUri).replace(
      queryParameters: {
        'activePrimaryId': '${code.activeId ?? activeId}',
        'type': '1',
        'msg': code.code ?? '',
      },
    ),
  );
  final json = chaoxingJson(response.body);
  if (chaoxingInt(json['isOver']) == 1) return true;
  final expected = code.code;
  return expected != null && chaoxingString(json['signCode']) != expected;
}
