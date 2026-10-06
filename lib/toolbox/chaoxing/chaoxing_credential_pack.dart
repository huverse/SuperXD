import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 代签凭据包：把「手机号 + 学习通密文密码 + 昵称 + 设备码」打成一个包，交给信得过的人。
// 包体用一次性随机密钥做 AES-256-GCM 加密：密钥不进服务器，也不跟密文放在一起（二维码里才有一份）。
// 设备码跟着一起走，是为了让对方签到时用同一个设备号，避免学习通提示「更换了签到设备」。
const chaoxingPackVersion = 1;
const chaoxingPackKeyBytes = 32;
const chaoxingPackMaxBytes = 2048;
const chaoxingPackPhoneLength = 11;
const chaoxingPackNameMaxLength = 40;
const chaoxingPackDeviceCodeMaxLength = 96;

class ChaoxingCredentialPack {
  const ChaoxingCredentialPack({
    required this.phoneNumber,
    required this.encryptedPassword,
    required this.name,
    required this.deviceCode,
  });
  final String phoneNumber;

  // 学习通登录表单用的那份 AES 密文（外层还有一次性密钥的一次加密）。
  final String encryptedPassword;
  final String name;
  final String deviceCode;
}

// 编好的包与给它用的密钥分开拿着：密钥随二维码给人，密文可以放服务器。
class ChaoxingSealedPack {
  const ChaoxingSealedPack({required this.key, required this.cipherText});
  final Uint8List key;
  final Uint8List cipherText;
}

final _aesGcm = AesGcm.with256bits();
final _random = Random.secure();

Uint8List chaoxingRandomBytes(int length) =>
    Uint8List.fromList([for (var index = 0; index < length; index++) _random.nextInt(256)]);

// 定长字段前面都带两字节长度，解的时候不用猜。
Uint8List encodeChaoxingCredentialPack(ChaoxingCredentialPack pack) {
  _checkPack(pack);
  final builder = BytesBuilder(copy: false)..addByte(chaoxingPackVersion);
  for (final field in [pack.phoneNumber, pack.encryptedPassword, pack.name, pack.deviceCode]) {
    final bytes = utf8.encode(field);
    builder
      ..addByte(bytes.length >> 8)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
  }
  final encoded = builder.toBytes();
  if (encoded.length > chaoxingPackMaxBytes) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包太大，无法分享');
  }
  return encoded;
}

// 凭据包来自别人的二维码或服务端，按外部输入处理：长度、版本、字段格式逐项校验。
ChaoxingCredentialPack decodeChaoxingCredentialPack(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > chaoxingPackMaxBytes) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个凭据包不完整');
  }
  final reader = _ByteReader(bytes);
  if (reader.readByte() != chaoxingPackVersion) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包版本不认识，请让对方更新应用');
  }
  final fields = [for (var index = 0; index < 4; index++) reader.readString()];
  final pack = ChaoxingCredentialPack(
    phoneNumber: fields[0],
    encryptedPassword: fields[1],
    name: fields[2],
    deviceCode: fields[3],
  );
  _checkPack(pack);
  return pack;
}

void _checkPack(ChaoxingCredentialPack pack) {
  if (pack.phoneNumber.length != chaoxingPackPhoneLength || int.tryParse(pack.phoneNumber) == null) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包里的手机号不对');
  }
  if (pack.encryptedPassword.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包里没有登录凭据');
  }
  if (pack.name.length > chaoxingPackNameMaxLength) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包里的昵称过长');
  }
  if (pack.deviceCode.length > chaoxingPackDeviceCodeMaxLength) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包里的设备码过长');
  }
}

Future<ChaoxingSealedPack> sealChaoxingCredentialPack(ChaoxingCredentialPack pack, {List<int>? key}) async {
  final secret = Uint8List.fromList(key ?? chaoxingRandomBytes(chaoxingPackKeyBytes));
  if (secret.length != chaoxingPackKeyBytes) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '密钥长度不对');
  }
  final box = await _aesGcm.encrypt(encodeChaoxingCredentialPack(pack), secretKey: SecretKey(secret));
  return ChaoxingSealedPack(
    key: secret,
    cipherText: Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]),
  );
}

Future<ChaoxingCredentialPack> openChaoxingCredentialPack(ChaoxingSealedPack sealed) async {
  // 随机数 12 字节 + 至少一个字节密文 + 标签 16 字节。
  if (sealed.key.length != chaoxingPackKeyBytes || sealed.cipherText.length < 12 + 1 + 16) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个凭据包不完整');
  }
  final nonce = sealed.cipherText.sublist(0, 12);
  final cipherText = sealed.cipherText.sublist(12, sealed.cipherText.length - 16);
  final mac = sealed.cipherText.sublist(sealed.cipherText.length - 16);
  final List<int> plain;
  try {
    plain = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(sealed.key),
    );
  } on SecretBoxAuthenticationError {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个凭据包解不开，请让对方重新生成');
  }
  return decodeChaoxingCredentialPack(plain);
}

// 面对面交换：二维码里只放取件号与一次性密钥，密文存在服务端，取走即删。
// 别人拍了二维码也只能拿到一个一次性取件号，真正的接收方取走后就没了。
const chaoxingPackTicketPrefix = 'SXDC1:';

class ChaoxingPackTicket {
  const ChaoxingPackTicket({required this.pickupId, required this.key});
  final String pickupId;
  final Uint8List key;
}

String encodeChaoxingPackTicket(ChaoxingPackTicket ticket) =>
    '$chaoxingPackTicketPrefix${ticket.pickupId}.${base64Url.encode(ticket.key).replaceAll('=', '')}';

ChaoxingPackTicket? decodeChaoxingPackTicket(String raw) {
  final text = raw.trim();
  if (!text.startsWith(chaoxingPackTicketPrefix)) return null;
  final content = text.substring(chaoxingPackTicketPrefix.length);
  final separator = content.indexOf('.');
  if (separator <= 0) return null;
  final pickupId = content.substring(0, separator);
  if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(pickupId)) return null;
  final encodedKey = content.substring(separator + 1);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encodedKey)) return null;
  try {
    final key = base64Url.decode(encodedKey.padRight((encodedKey.length + 3) ~/ 4 * 4, '='));
    if (key.length != chaoxingPackKeyBytes) return null;
    return ChaoxingPackTicket(pickupId: pickupId, key: Uint8List.fromList(key));
  } on FormatException {
    return null;
  }
}

class _ByteReader {
  _ByteReader(this._bytes);
  final List<int> _bytes;
  var _offset = 0;

  int readByte() {
    if (_offset >= _bytes.length) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个凭据包不完整');
    }
    return _bytes[_offset++];
  }

  String readString() {
    final length = (readByte() << 8) | readByte();
    if (_offset + length > _bytes.length) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个凭据包不完整');
    }
    final value = utf8.decode(_bytes.sublist(_offset, _offset + length), allowMalformed: true);
    _offset += length;
    return value;
  }
}
