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
  'theme': {'theme'},
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
        final target = match[1]!.split('/').first;
        if (!allowed.contains(target)) violations.add('${file.path} → $target');
      }
    }
    expect(violations, isEmpty);
  });
}
