// 生活各子模块共用的金额换算（住理生活、胖乖生活）：金额一律按「分」的整数处理，服务端给的数或十进制文本按文本换算、四舍五入到分，不经浮点运算。

// 金额换成分：数或十进制文本（"13.3900"、176.35、-0.14），四舍五入到分；不是金额返回空。
int? lifeCents(Object? raw) {
  final text = switch (raw) {
    final num value => value.toString(),
    final String value => value.trim(),
    _ => null,
  };
  final match = text == null ? null : RegExp(r'^(-?)(\d{1,12})(?:\.(\d+))?$').firstMatch(text);
  if (match == null) return null;
  final fraction = (match[3] ?? '').padRight(3, '0');
  final cents = int.parse(match[2]!) * 100 + int.parse(fraction.substring(0, 2)) + (int.parse(fraction[2]) >= 5 ? 1 : 0);
  return match[1] == '-' ? -cents : cents;
}

// 分写成元，两位小数（1840 → 18.40）。
String lifeYuan(int cents) => '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';
