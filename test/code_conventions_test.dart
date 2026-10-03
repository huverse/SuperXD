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

  // 只有图标的按钮没有文字，读屏只能读出“按钮”；tooltip同时提供读屏标签和长按提示。
  test('IconButton都带tooltip', () {
    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'\bIconButton(\.\w+)?\(').allMatches(source)) {
        var depth = 1;
        var end = match.end;
        while (depth > 0) {
          final char = source[end++];
          if (char == '(') depth++;
          if (char == ')') depth--;
        }
        if (source.substring(match.end, end).contains('tooltip:')) continue;
        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${file.path}:$line');
      }
    }
    expect(offenders, isEmpty);
  });

  // Flutter 不会把 FontWeight 映射到可变字体的字重轴，可变字体一律按默认实例渲染（Noto Serif SC 默认为 ExtraLight 200，曾让衬线全应用发细、粗体变假粗）；内置字体只用静态字重文件。
  test('内置字体都是静态字重文件', () {
    final variable = <String>[];
    for (final file in Directory('assets/fonts').listSync().whereType<File>().where((file) => file.path.endsWith('.ttf'))) {
      final bytes = file.readAsBytesSync();
      final tables = bytes[4] << 8 | bytes[5];
      for (var index = 0; index < tables; index++) {
        final offset = 12 + 16 * index;
        if (String.fromCharCodes(bytes.sublist(offset, offset + 4)) == 'fvar') variable.add(file.path);
      }
    }
    expect(variable, isEmpty);
  });
}
