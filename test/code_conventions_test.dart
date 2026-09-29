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
}
