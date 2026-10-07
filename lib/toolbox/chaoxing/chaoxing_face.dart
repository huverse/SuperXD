import 'dart:convert';
import 'dart:typed_data';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 人脸识别签到：学习通要求带上人脸照片的 objectId 与一份设备信息签名，先换一次性的 faceEnc 再提交。
// clientId 是学习通客户端用自己私钥签出的设备信息，这里只能拿公钥做模幂把它还原回来，
// 里面除设备号外还有一个秘密串 sc，用它按字段拼出的 md5 就是 signToken。
const chaoxingFaceResultUri =
    'https://mobilelearn.chaoxing.com/pptSign/check-face-result?DB_STRATEGY=PRIMARY_KEY&STRATEGY_PARA=activeId';
const chaoxingProfileFaceUri = 'https://mobilelearn.chaoxing.com/v2/apis/sign/collectionfilephotoEnc?DB_STRATEGY=DEFAULT';

// 学习通云盘里人脸照片的原图地址，预览用。
String chaoxingFaceImageUrl(String objectId) => 'https://p.cldisk.com/star4/$objectId/origin.jpg';

// 人脸照片原图的响应上限：比普通接口宽（参考项目下载原图无上限），默认 1MB 会把预览截断。
const chaoxingFacePreviewLimit = 10 * 1024 * 1024;

// 还原 clientId 里的设备信息（含 cid 与 sc）；解不出来返回空，人脸签到会退化成不带签名。
Map<String, Object?>? chaoxingDecryptClientId(String clientId) {
  final modulus = chaoxingRsaModulus();
  if (modulus == null || clientId.isEmpty) return null;
  final List<int> encrypted;
  try {
    encrypted = base64.decode(clientId);
  } on FormatException {
    return null;
  }
  if (encrypted.isEmpty || encrypted.length % chaoxingRsaBlockBytes != 0) return null;
  final output = BytesBuilder();
  for (var offset = 0; offset < encrypted.length; offset += chaoxingRsaBlockBytes) {
    final block = encrypted.sublist(offset, offset + chaoxingRsaBlockBytes);
    final bytes = _intToFixedBytes(chaoxingBytesToInt(block).modPow(BigInt.from(chaoxingRsaExponent), modulus));
    // PKCS#1 v1.5 的填充：00 01 FF…FF 00 之后才是内容。
    if (bytes.length < 3 || bytes[0] != 0 || bytes[1] != 1) return null;
    final separator = bytes.indexOf(0, 2);
    if (separator < 2) return null;
    output.add(bytes.sublist(separator + 1));
  }
  try {
    final json = jsonDecode(utf8.decode(output.toBytes()));
    return json is Map ? json.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

// 字段按 key 排序后逐个「键名接值」拼起来，加 sc 做 md5。
String chaoxingFaceSignToken({required Map<String, String> fields, required String secret}) {
  final keys = fields.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final key in keys) {
    buffer
      ..write(key)
      ..write(fields[key]);
  }
  buffer.write(secret);
  return chaoxingMd5(buffer.toString());
}

Future<Map<String, Object?>> chaoxingFaceResult(
  ChaoxingClient client, {
  required String objectId,
  DateTime? now,
}) async {
  final fields = <String, String>{
    'currentFaceId': objectId,
    'LiveDetectionStatus': '1',
    'collectStatus': '1',
  };
  final cxtime = '${(now ?? DateTime.now()).millisecondsSinceEpoch}';
  final result = <String, Object?>{
    'currentFaceId': objectId,
    'LiveDetectionStatus': 1,
    'collectStatus': 1,
    'cxtime': cxtime,
  };
  final deviceInfo = chaoxingDecryptClientId(client.account?.clientId ?? '');
  final cid = chaoxingString(deviceInfo?['cid']);
  final secret = chaoxingString(deviceInfo?['sc']);
  if (cid.isNotEmpty && secret.isNotEmpty) {
    result['cxcid'] = cid;
    // signToken 的拼串里也要有 cxcid（与 fields、cxtime 一起排序拼接，对齐参考项目的 TreeMap 口径），
    // 只把它写进上报 JSON 而不参与 md5 的话，服务端校验签名会不通过。
    result['signToken'] = chaoxingFaceSignToken(fields: {...fields, 'cxtime': cxtime, 'cxcid': cid}, secret: secret);
  }
  return result;
}

Future<String> chaoxingFaceEnc(ChaoxingClient client, {required int activeId, required String objectId}) async {
  final result = await chaoxingFaceResult(client, objectId: objectId);
  final response = await client.http.get(
    Uri.parse(chaoxingFaceResultUri).replace(
      queryParameters: {'activeId': '$activeId', 'faceResult': jsonEncode(result)},
    ),
  );
  final enc = chaoxingString(chaoxingJson(response.body)['enc']);
  if (enc.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.faceRequired, '人脸识别没通过，请换一张再试');
  }
  return enc;
}

// 学习通里已经存着的人脸照片：取它的 objectId 直接用，不用再传一次。
Future<String?> chaoxingProfileFaceObjectId(ChaoxingClient client) async {
  final response = await client.http.get(Uri.parse(chaoxingProfileFaceUri));
  final data = chaoxingJson(response.body)['data'];
  if (data is! Map) return null;
  final objectId = chaoxingString(data['oldObjectId']);
  return objectId.isEmpty ? null : objectId;
}

Uint8List _intToFixedBytes(BigInt value, {int length = chaoxingRsaBlockBytes}) {
  final bytes = Uint8List(length);
  var remaining = value;
  for (var index = length - 1; index >= 0; index--) {
    bytes[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  return bytes;
}

// 人脸参数只在位置与二维码签到上带（学习通客户端只在这两类上做人脸）。
bool chaoxingFaceApplies(ChaoxingSignType type, ChaoxingActiveInfo info) =>
    info.needFace && (type == ChaoxingSignType.location || type == ChaoxingSignType.qrCode);
