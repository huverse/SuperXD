String strEnc(String data, String? firstKey, String? secondKey, String? thirdKey) {
  final first = _keyBytesOf(firstKey);
  final second = _keyBytesOf(secondKey);
  final third = _keyBytesOf(thirdKey);
  if (data.isEmpty) return '';
  final buffer = StringBuffer();
  final blocks = data.length ~/ 4;
  for (var i = 0; i < blocks; i++) {
    final block = _strToBt(data.substring(i * 4, i * 4 + 4));
    buffer.write(_bt64ToHex(_encrypt(block, first, second, third)));
  }
  final rest = data.length % 4;
  if (blocks == 0 || rest > 0) {
    final start = blocks * 4;
    final block = _strToBt(data.substring(start));
    buffer.write(_bt64ToHex(_encrypt(block, first, second, third)));
  }
  return buffer.toString();
}

String strDec(String data, String? firstKey, String? secondKey, String? thirdKey) {
  final first = _keyBytesOf(firstKey);
  final second = _keyBytesOf(secondKey);
  final third = _keyBytesOf(thirdKey);
  final buffer = StringBuffer();
  final blocks = data.length ~/ 16;
  for (var i = 0; i < blocks; i++) {
    final hex = data.substring(i * 16, i * 16 + 16);
    final bits = _hexToBt64(hex);
    buffer.write(_byteToString(_decrypt(bits, first, second, third)));
  }
  return buffer.toString();
}

List<List<int>>? _keyBytesOf(String? key) {
  if (key == null || key.isEmpty) return null;
  final out = <List<int>>[];
  final blocks = key.length ~/ 4;
  for (var i = 0; i < blocks; i++) {
    out.add(_strToBt(key.substring(i * 4, i * 4 + 4)));
  }
  if (key.length % 4 > 0) out.add(_strToBt(key.substring(blocks * 4)));
  return out;
}

List<int> _encrypt(List<int> data, List<List<int>>? first, List<List<int>>? second, List<List<int>>? third) {
  var temp = data;
  if (first != null) {
    for (final key in first) {
      temp = _enc(temp, key);
    }
  }
  if (second != null) {
    for (final key in second) {
      temp = _enc(temp, key);
    }
  }
  if (third != null) {
    for (final key in third) {
      temp = _enc(temp, key);
    }
  }
  return temp;
}

List<int> _decrypt(List<int> data, List<List<int>>? first, List<List<int>>? second, List<List<int>>? third) {
  var temp = data;
  if (third != null) {
    for (var i = third.length - 1; i >= 0; i--) {
      temp = _dec(temp, third[i]);
    }
  }
  if (second != null) {
    for (var i = second.length - 1; i >= 0; i--) {
      temp = _dec(temp, second[i]);
    }
  }
  if (first != null) {
    for (var i = first.length - 1; i >= 0; i--) {
      temp = _dec(temp, first[i]);
    }
  }
  return temp;
}

List<int> _strToBt(String str) {
  final bt = List<int>.filled(64, 0);
  final length = str.length > 4 ? 4 : str.length;
  for (var i = 0; i < length; i++) {
    final code = str.codeUnitAt(i);
    for (var j = 0; j < 16; j++) {
      var pow = 1;
      for (var m = 15; m > j; m--) {
        pow *= 2;
      }
      bt[16 * i + j] = (code ~/ pow) % 2;
    }
  }
  return bt;
}

String _bt64ToHex(List<int> byteData) {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final nibble = '${byteData[i * 4]}${byteData[i * 4 + 1]}${byteData[i * 4 + 2]}${byteData[i * 4 + 3]}';
    buffer.write(_bt4ToHex(nibble));
  }
  return buffer.toString();
}

List<int> _hexToBt64(String hex) {
  final bits = StringBuffer();
  for (var i = 0; i < 16; i++) {
    bits.write(_hexToBt4(hex.substring(i, i + 1)));
  }
  final text = bits.toString();
  return [for (var i = 0; i < 64; i++) int.parse(text.substring(i, i + 1))];
}

String _byteToString(List<int> byteData) {
  final buffer = StringBuffer();
  for (var i = 0; i < 4; i++) {
    var count = 0;
    for (var j = 0; j < 16; j++) {
      var pow = 1;
      for (var m = 15; m > j; m--) {
        pow *= 2;
      }
      count += byteData[16 * i + j] * pow;
    }
    if (count != 0) buffer.writeCharCode(count);
  }
  return buffer.toString();
}

String _bt4ToHex(String binary) {
  const hex = '0123456789ABCDEF';
  final value = int.parse(binary, radix: 2);
  return hex[value];
}

String _hexToBt4(String hex) => int.parse(hex, radix: 16).toRadixString(2).padLeft(4, '0');

List<int> _enc(List<int> dataByte, List<int> keyByte) => _crypt(dataByte, keyByte, encrypt: true);
List<int> _dec(List<int> dataByte, List<int> keyByte) => _crypt(dataByte, keyByte, encrypt: false);

List<int> _crypt(List<int> dataByte, List<int> keyByte, {required bool encrypt}) {
  final keys = _generateKeys(keyByte);
  final ipByte = _initPermute(dataByte);
  final ipLeft = List<int>.filled(32, 0);
  final ipRight = List<int>.filled(32, 0);
  for (var k = 0; k < 32; k++) {
    ipLeft[k] = ipByte[k];
    ipRight[k] = ipByte[32 + k];
  }
  for (var round = 0; round < 16; round++) {
    final i = encrypt ? round : 15 - round;
    final tempLeft = List<int>.from(ipLeft);
    for (var j = 0; j < 32; j++) {
      ipLeft[j] = ipRight[j];
    }
    final key = List<int>.from(keys[i]);
    final tempRight = _xor(_pPermute(_sBoxPermute(_xor(_expandPermute(ipRight), key))), tempLeft);
    for (var n = 0; n < 32; n++) {
      ipRight[n] = tempRight[n];
    }
  }
  final finalData = List<int>.filled(64, 0);
  for (var i = 0; i < 32; i++) {
    finalData[i] = ipRight[i];
    finalData[32 + i] = ipLeft[i];
  }
  return _finallyPermute(finalData);
}

List<int> _initPermute(List<int> original) {
  final ipByte = List<int>.filled(64, 0);
  for (var i = 0, m = 1, n = 0; i < 4; i++, m += 2, n += 2) {
    for (var j = 7, k = 0; j >= 0; j--, k++) {
      ipByte[i * 8 + k] = original[j * 8 + m];
      ipByte[i * 8 + k + 32] = original[j * 8 + n];
    }
  }
  return ipByte;
}

List<int> _expandPermute(List<int> rightData) {
  final epByte = List<int>.filled(48, 0);
  for (var i = 0; i < 8; i++) {
    epByte[i * 6] = i == 0 ? rightData[31] : rightData[i * 4 - 1];
    epByte[i * 6 + 1] = rightData[i * 4];
    epByte[i * 6 + 2] = rightData[i * 4 + 1];
    epByte[i * 6 + 3] = rightData[i * 4 + 2];
    epByte[i * 6 + 4] = rightData[i * 4 + 3];
    epByte[i * 6 + 5] = i == 7 ? rightData[0] : rightData[i * 4 + 4];
  }
  return epByte;
}

List<int> _xor(List<int> one, List<int> two) {
  return [for (var i = 0; i < one.length; i++) one[i] ^ two[i]];
}

const _boxes = <List<List<int>>>[
  [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7],
    [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8],
    [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0],
    [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
  ],
  [
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10],
    [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5],
    [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15],
    [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
  ],
  [
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8],
    [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1],
    [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7],
    [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
  ],
  [
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15],
    [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9],
    [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4],
    [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
  ],
  [
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9],
    [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6],
    [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14],
    [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
  ],
  [
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11],
    [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8],
    [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6],
    [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
  ],
  [
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1],
    [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6],
    [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2],
    [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
  ],
  [
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7],
    [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2],
    [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8],
    [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
  ],
];

List<int> _sBoxPermute(List<int> expandByte) {
  final out = List<int>.filled(32, 0);
  for (var m = 0; m < 8; m++) {
    final i = expandByte[m * 6] * 2 + expandByte[m * 6 + 5];
    final j = expandByte[m * 6 + 1] * 8 + expandByte[m * 6 + 2] * 4 + expandByte[m * 6 + 3] * 2 + expandByte[m * 6 + 4];
    final binary = _boxes[m][i][j].toRadixString(2).padLeft(4, '0');
    for (var bit = 0; bit < 4; bit++) {
      out[m * 4 + bit] = int.parse(binary[bit]);
    }
  }
  return out;
}

List<int> _pPermute(List<int> sBoxByte) {
  const order = [15, 6, 19, 20, 28, 11, 27, 16, 0, 14, 22, 25, 4, 17, 30, 9, 1, 7, 23, 13, 31, 26, 2, 8, 18, 12, 29, 5, 21, 10, 3, 24];
  return [for (final index in order) sBoxByte[index]];
}

List<int> _finallyPermute(List<int> endByte) {
  const order = [
    39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25, 32, 0, 40, 8, 48, 16, 56, 24,
  ];
  return [for (final index in order) endByte[index]];
}

List<List<int>> _generateKeys(List<int> keyByte) {
  final key = List<int>.filled(56, 0);
  for (var i = 0; i < 7; i++) {
    for (var j = 0, k = 7; j < 8; j++, k--) {
      key[i * 8 + j] = keyByte[8 * k + i];
    }
  }
  const loop = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
  final keys = List<List<int>>.generate(16, (_) => List<int>.filled(48, 0));
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < loop[i]; j++) {
      final tempLeft = key[0];
      final tempRight = key[28];
      for (var k = 0; k < 27; k++) {
        key[k] = key[k + 1];
        key[28 + k] = key[29 + k];
      }
      key[27] = tempLeft;
      key[55] = tempRight;
    }
    const pick = [
      13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3,
      25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39,
      50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ];
    for (var m = 0; m < 48; m++) {
      keys[i][m] = key[pick[m]];
    }
  }
  return keys;
}
