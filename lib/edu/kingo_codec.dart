import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:superxd/edu/kingo_des.dart';

String hexMd5(String value) {
  final bytes = [for (final unit in value.codeUnits) unit & 0xff];
  return md5.convert(bytes).toString();
}

String utf16To8(String value) {
  final out = StringBuffer();
  for (final code in value.codeUnits) {
    if (code >= 0x0001 && code <= 0x007f) {
      out.writeCharCode(code);
    } else if (code > 0x07ff) {
      out.writeCharCode(0xe0 | ((code >> 12) & 0x0f));
      out.writeCharCode(0x80 | ((code >> 6) & 0x3f));
      out.writeCharCode(0x80 | (code & 0x3f));
    } else {
      out.writeCharCode(0xc0 | ((code >> 6) & 0x1f));
      out.writeCharCode(0x80 | (code & 0x3f));
    }
  }
  return out.toString();
}

String kingoBase64(String value) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = StringBuffer();
  var i = 0;
  while (i < value.length) {
    final c1 = value.codeUnitAt(i++) & 0xff;
    if (i == value.length) {
      out.write(chars[c1 >> 2]);
      out.write(chars[(c1 & 0x3) << 4]);
      out.write('==');
      break;
    }
    final c2 = value.codeUnitAt(i++) & 0xff;
    if (i == value.length) {
      out.write(chars[c1 >> 2]);
      out.write(chars[((c1 & 0x3) << 4) | ((c2 & 0xf0) >> 4)]);
      out.write(chars[(c2 & 0xf) << 2]);
      out.write('=');
      break;
    }
    final c3 = value.codeUnitAt(i++) & 0xff;
    out.write(chars[c1 >> 2]);
    out.write(chars[((c1 & 0x3) << 4) | ((c2 & 0xf0) >> 4)]);
    out.write(chars[((c2 & 0xf) << 2) | ((c3 & 0xc0) >> 6)]);
    out.write(chars[c3 & 0x3f]);
  }
  return out.toString();
}

String encryptLoginParams(String plain, String tempDeskey) {
  return kingoBase64(utf16To8(strEnc(plain, tempDeskey, null, null)));
}

String loginToken(String plain, String timestamp) {
  return hexMd5(hexMd5(plain) + hexMd5(timestamp));
}

String utf8Base64(String value) => base64.encode(utf8.encode(value));
