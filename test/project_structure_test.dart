import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

// [人工决策-2026-09-29 21:14:34] 分层只许自上而下：页面/百宝箱 → 应用编排 → 网关 → 教务协议/本地存储 → 领域核心，主题只供界面使用；根目录组合根不限。出现反向依赖先重划职责，不绕过本检查。
const _allowed = {
  'domain': {'domain'},
  'edu': {'domain', 'edu'},
  'local': {'domain', 'local'},
  'gateway': {'domain', 'edu', 'local', 'gateway'},
  'application': {'domain', 'gateway', 'application'},
  // 设备能力适配（系统通知等），只实现 domain 端口，由组合根注入；页面不直接依赖。
  'device': {'domain', 'device'},
  'theme': {'theme', 'domain/campus_log.dart'},
  'toolbox': {'domain', 'theme', 'toolbox'},
  'page': {'domain', 'application', 'gateway', 'local', 'theme', 'page', 'app_session.dart'},
};

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

void main() {
  test('lib分层依赖只允许自上而下', () {
    final violations = <String>[];
    for (final file in _dartFiles('lib')) {
      final parts = path.split(path.relative(file.path, from: 'lib'));
      if (parts.length == 1) continue;
      final allowed = _allowed[parts.first];
      if (allowed == null) {
        violations.add('${file.path}：目录${parts.first}未登记分层');
        continue;
      }
      final imports = RegExp(r'''^import\s+['"]package:superxd/([^'"]+)['"]''', multiLine: true);
      for (final match in imports.allMatches(file.readAsStringSync())) {
        final target = match[1]!;
        if (!allowed.contains(target.split('/').first) && !allowed.contains(target)) {
          violations.add('${file.path} → $target');
        }
      }
    }
    expect(violations, isEmpty);
  });

  // 日志统一走 campusLog，出口在 domain/campus_log.dart，由入口注入 debugPrint；直写 stderr 在 Android 上看不到。
  test('lib日志只经campusLog出口', () {
    final direct = RegExp(r'(?<![\w.])(debugPrint|print)\(|stderr\.write|developer\.log\(');
    final offenders = <String>[];
    for (final file in _dartFiles('lib').where((file) => !file.path.endsWith('campus_log.dart'))) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (direct.hasMatch(lines[index])) offenders.add('${file.path}:${index + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  // 索引只在文件级兜底：新增、删除、搬迁都要同步登记；职责与不变量的变化靠改动前检查清单维护。
  test('项目索引登记lib全部文件且无失效条目', () {
    String read(String index) => File(index).existsSync() ? File(index).readAsStringSync() : '';
    final problems = <String>[];
    for (final file in _dartFiles('lib')) {
      final parts = path.split(path.relative(file.path, from: 'lib'));
      final module = path.join('lib', parts.first, 'CLAUDE.md');
      final index = parts.length > 1 && File(module).existsSync() ? module : 'CLAUDE.md';
      if (!read(index).contains(path.basename(file.path))) problems.add('${file.path}未登记于$index');
    }
    final known = {
      for (final root in ['lib', 'test', 'tool', 'android/app/src'])
        for (final entity in Directory(root).listSync(recursive: true))
          if (entity is File) path.basename(entity.path),
    };
    final indexes = [
      'CLAUDE.md',
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File && path.basename(entity.path) == 'CLAUDE.md') entity.path,
    ];
    for (final index in indexes) {
      for (final match in RegExp(r'[\w.]+\.(?:dart|kt)\b').allMatches(read(index))) {
        if (!known.contains(match[0])) problems.add('$index提到的${match[0]}不存在');
      }
    }
    expect(problems, isEmpty);
  });
}
