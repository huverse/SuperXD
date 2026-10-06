import 'dart:convert';
import 'dart:typed_data';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 人脸识别签到：学习通要求带上人脸照片的 objectId 与一份设备信息签名，先换一次性的 faceEnc 再提交。
// clientId 是学习通客户端用自己私钥签出的设备信息，这里只能拿公钥做模幂把它还原回来，
// 里面除设备号外还有一个秘密串 sc，用它按字段拼出的 md5 就是 signToken。
const chaoxingFacePublicKey =
    'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC79d8Ot0hCbxxSISC6x8SCwTBspFSzlLKHJUYqoFNu1TSRaw4hEYkOnvEaL1VyoxV6HXcDrzwYvaFZaZaPQPFnfCHZy5dQwxcmifgSHqS+oKXw40Ys4cVIqnU5d90S7EWSRdBglX489jlqVaNcQSkDx2TYmC+DbAq9FV/BU09ISQIDAQAB';
const chaoxingFaceExponent = 65537;
const chaoxingFaceBlockBytes = 128;
const chaoxingFaceResultUri =
    'https://mobilelearn.chaoxing.com/pptSign/check-face-result?DB_STRATEGY=PRIMARY_KEY&STRATEGY_PARA=activeId';
const chaoxingProfileFaceUri = 'https://mobilelearn.chaoxing.com/v2/apis/sign/collectionfilephotoEnc?DB_STRATEGY=DEFAULT';

// 公钥是 SPKI 格式：取出里面 128 字节的模数。拿不到就说明这把公钥换了，人脸签到按不可用处理。
BigInt? chaoxingFaceModulus() {
  try {
    final der = base64.decode(chaoxingFacePublicKey);
    // SEQUENCE { … BIT STRING { SEQUENCE { INTEGER(129，含前导零) , INTEGER(65537) } } }
    const head = [0x02, 0x81, 0x81, 0x00];
    final start = _indexOfSequence(der, head);
    if (start < 0 || start + head.length + chaoxingFaceBlockBytes > der.length) return null;
    return _bytesToInt(der.sublist(start + head.length, start + head.length + chaoxingFaceBlockBytes));
  } on FormatException {
    return null;
  }
}

int _indexOfSequence(List<int> bytes, List<int> pattern) {
  for (var index = 0; index + pattern.length <= bytes.length; index++) {
    var matched = true;
    for (var inner = 0; inner < pattern.length; inner++) {
      if (bytes[index + inner] != pattern[inner]) {
        matched = false;
        break;
      }
    }
    if (matched) return index;
  }
  return -1;
}

// 还原 clientId 里的设备信息（含 cid 与 sc）；解不出来返回空，人脸签到会退化成不带签名。
Map<String, Object?>? chaoxingDecryptClientId(String clientId) {
  final modulus = chaoxingFaceModulus();
  if (modulus == null || clientId.isEmpty) return null;
  final List<int> encrypted;
  try {
    encrypted = base64.decode(clientId);
  } on FormatException {
    return null;
  }
  if (encrypted.isEmpty || encrypted.length % chaoxingFaceBlockBytes != 0) return null;
  final output = BytesBuilder();
  for (var offset = 0; offset < encrypted.length; offset += chaoxingFaceBlockBytes) {
    final block = encrypted.sublist(offset, offset + chaoxingFaceBlockBytes);
    final bytes = _intToFixedBytes(_bytesToInt(block).modPow(BigInt.from(chaoxingFaceExponent), modulus));
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
    result['signToken'] = chaoxingFaceSignToken(fields: {...fields, 'cxtime': cxtime}, secret: secret);
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

BigInt _bytesToInt(List<int> bytes) => bytes.fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));

Uint8List _intToFixedBytes(BigInt value, {int length = chaoxingFaceBlockBytes}) {
  final bytes = Uint8List(length);
  var remaining = value;
  for (var index = length - 1; index >= 0; index--) {
    bytes[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining = remaining >> 8;
  }
  return bytes;
}
