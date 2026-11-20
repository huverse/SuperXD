import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:superxd/toolbox/cinema/cinema_rule.dart';

// 片名目录底包的文件格式（纯 Dart，手机与维护者工具 tool/cinema_catalog.dart、tool/cinema_rules.dart 共用；人工决策见 cinema_catalog.dart 文件头）：
// gzip 的 UTF-8 文本，首行「#SXD-CATALOG<TAB>1<TAB>抓取起点 UTC<TAB>条数」，之后每行「编号<TAB>片名」，按编号排。

// 底包的外部输入边界（在后台 isolate 里跑）：先核对 SHA-256，再解 gzip、逐行校验；首行条数要对得上，不超过 cinemaCatalogEntryLimit。
({DateTime builtAt, List<(String, String)> entries}) decodeCinemaCatalog(List<int> bytes, String expectedSha256) {
  if (sha256.convert(bytes).toString() != expectedSha256) throw const CinemaRuleException('片名目录没通过校验');
  final List<String> lines;
  try {
    lines = const LineSplitter().convert(utf8.decode(gzip.decode(bytes)));
  } on FormatException {
    throw const CinemaRuleException('片名目录格式不对');
  }
  final header = lines.isEmpty ? const <String>[] : lines.first.split('\t');
  final builtAt = header.length == 4 ? DateTime.tryParse(header[2]) : null;
  final count = header.length == 4 ? int.tryParse(header[3]) : null;
  if (header.isEmpty || header[0] != '#SXD-CATALOG' || header[1] != '1' || builtAt == null || !builtAt.isUtc || count == null || count != lines.length - 1 || count > cinemaCatalogEntryLimit) {
    throw const CinemaRuleException('片名目录格式不对');
  }
  final entries = <(String, String)>[];
  for (final line in lines.skip(1)) {
    final fields = line.split('\t');
    if (fields.length != 2 || fields[0].isEmpty || fields[1].trim().isEmpty || fields[0].length > 64 || fields[1].length > 200) throw const CinemaRuleException('片名目录格式不对');
    entries.add((fields[0], fields[1]));
  }
  return (builtAt: builtAt, entries: entries);
}

// 写底包（tool/cinema_catalog.dart 与测试用）：按编号排好，同一份输入得到同样的字节。
List<int> encodeCinemaCatalog(DateTime builtAt, Iterable<(String, String)> entries) {
  final sorted = [...entries]..sort((a, b) => a.$1.compareTo(b.$1));
  final text = StringBuffer('#SXD-CATALOG\t1\t${builtAt.toUtc().toIso8601String()}\t${sorted.length}\n');
  for (final (id, name) in sorted) {
    text.write('$id\t$name\n');
  }
  return GZipCodec(level: 9).encode(utf8.encode(text.toString()));
}
