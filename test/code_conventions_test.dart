import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // setState先执行回调，回调返回Future时debug断言抛错且不重建页面；箭头写法给Future字段赋值正是这种情况，调用方的catch会把成功误报成失败。
  test('setState回调不返回Future，给Future字段赋值须用块体', () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      final fields = RegExp(r'Future<[^;{}]*>\??\s+(_?\w+)\s*[=;]')
          .allMatches(source)
          .map((match) => match[1]!)
          .toSet();
      for (final field in fields) {
        final assignment = RegExp(
          'setState\\(\\s*\\(\\)\\s*=>\\s*${RegExp.escape(field)}\\s*=[^=]',
        );
        for (final match in assignment.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
          offenders.add('${file.path}:$line');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  // 日志统一走 campusLog，出口在 domain/campus_log.dart，由入口注入 debugPrint；直写 stderr 在 Android 上看不到。
  test('lib日志只经campusLog出口', () {
    final direct = RegExp(r'(?<![\w.])(debugPrint|print)\(|stderr\.write|developer\.log\(');
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart') && !file.path.endsWith('campus_log.dart'));
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (direct.hasMatch(lines[index])) offenders.add('${file.path}:${index + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
