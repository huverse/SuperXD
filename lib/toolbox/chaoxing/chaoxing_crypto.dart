import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as castle;

// 学习通固定的传输加密：手机号与密码用 AES-128-CBC（PKCS7，IV 与密钥同为固定串）后 Base64。
// 这是对方的协议事实，不是我们的安全设计，凭据本身另存系统安全存储。
const chaoxingTransferKey = 'u2oh6Vu^HWe4_AES';

// 学习通客户端的设备公钥（SPKI，1024 位、指数 65537）：上传设备信息时用它加密，
// 人脸签名用的 clientId 也是对应私钥签出来的，拿它做模幂就能还原。
const chaoxingRsaPublicKey =
    'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC79d8Ot0hCbxxSISC6x8SCwTBspFSzlLKHJUYqoFNu1TSRaw4hEYkOnvEaL1VyoxV6HXcDrzwYvaFZaZaPQPFnfCHZy5dQwxcmifgSHqS+oKXw40Ys4cVIqnU5d90S7EWSRdBglX489jlqVaNcQSkDx2TYmC+DbAq9FV/BU09ISQIDAQAB';
const chaoxingRsaExponent = 65537;
const chaoxingRsaBlockBytes = 128;

// PKCS#1 v1.5 每块要留 11 字节填充，1024 位密钥一块最多装 117 字节明文。
const chaoxingRsaPlainBlockBytes = 117;

// 设备码的固定密钥：学习通客户端用 AES-ECB 把 OAID 加密成设备码。
const chaoxingDeviceCodeKey = 'QrCbNY@MuK1X8HGw';

final _aesCbc128 = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);

Future<String> chaoxingEncrypt(String plain) async {
  final key = utf8.encode(chaoxingTransferKey);
  final box = await _aesCbc128.encrypt(utf8.encode(plain), secretKey: SecretKey(key), nonce: key);
  return base64.encode(box.cipherText);
}

String chaoxingMd5(String value) => hash.md5.convert(utf8.encode(value)).toString();

List<int> chaoxingSha256Bytes(List<int> value) => hash.sha256.convert(value).bytes;

String chaoxingSha256Hex(String value) => hash.sha256.convert(utf8.encode(value)).toString();

// 公钥是 SPKI 格式：取出里面 128 字节的模数。拿不到就说明这把公钥换了，依赖它的功能按不可用处理。
BigInt? chaoxingRsaModulus() {
  try {
    final der = base64.decode(chaoxingRsaPublicKey);
    // SEQUENCE { … BIT STRING { SEQUENCE { INTEGER(129，含前导零) , INTEGER(65537) } } }
    const head = [0x02, 0x81, 0x81, 0x00];
    final start = _indexOfSequence(der, head);
    if (start < 0 || start + head.length + chaoxingRsaBlockBytes > der.length) return null;
    return chaoxingBytesToInt(der.sublist(start + head.length, start + head.length + chaoxingRsaBlockBytes));
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

BigInt chaoxingBytesToInt(List<int> bytes) => bytes.fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));

// 用学习通的设备公钥按 PKCS#1 v1.5 分块加密，块密文直接拼起来再 Base64（与客户端一致）。
String chaoxingRsaEncrypt(List<int> plain) {
  final modulus = chaoxingRsaModulus();
  if (modulus == null) throw StateError('学习通设备公钥解析失败');
  final cipher = castle.PKCS1Encoding(castle.RSAEngine())
    ..init(true, castle.PublicKeyParameter<castle.RSAPublicKey>(castle.RSAPublicKey(modulus, BigInt.from(chaoxingRsaExponent))));
  final output = BytesBuilder(copy: false);
  for (var offset = 0; offset < plain.length; offset += chaoxingRsaPlainBlockBytes) {
    final end = offset + chaoxingRsaPlainBlockBytes > plain.length ? plain.length : offset + chaoxingRsaPlainBlockBytes;
    output.add(cipher.process(Uint8List.fromList(plain.sublist(offset, end))));
  }
  return base64.encode(output.toBytes());
}

// 设备码 = AES-128-ECB(PKCS7) 加密 OAID 后 Base64。
String chaoxingDeviceCodeFromOaid(String oaid) {
  final cipher = castle.PaddedBlockCipherImpl(castle.PKCS7Padding(), castle.ECBBlockCipher(castle.AESEngine()))
    ..init(
      true,
      castle.PaddedBlockCipherParameters<castle.CipherParameters, castle.CipherParameters?>(
        castle.KeyParameter(Uint8List.fromList(utf8.encode(chaoxingDeviceCodeKey))),
        null,
      ),
    );
  return base64.encode(cipher.process(Uint8List.fromList(utf8.encode(oaid))));
}
