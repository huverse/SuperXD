import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/release_changelog.dart';

const _changelog = '''
# Changelog

## Unreleased

### 新增
- 还没发的改动。

## 1.0.0-alpha.5 - 2026-10-20

### 更新说明
- 课前提醒可以开状态栏胶囊。
* 第一次打开先同意协议与政策。

### 新增
- 详细的技术说明。

## 1.0.0-alpha.4 - 2026-10-18

### 发布
- 旧版本。
''';

void main() {
  test('发版材料：取对应版本节（不含标题、不串到下一版），更新说明去掉列表符号、每条一行', () {
    final release = parseReleaseChangelog(_changelog, '1.0.0-alpha.5');
    expect(release.notes, '课前提醒可以开状态栏胶囊。\n第一次打开先同意协议与政策。');
    expect(release.section, startsWith('### 更新说明'));
    expect(release.section, endsWith('- 详细的技术说明。'));
    expect(release.section, isNot(contains('旧版本')));
  });

  test('发版材料：没有版本节、没有更新说明、更新说明为空或超过 4000 字都拒绝；版本名里的点不当通配', () {
    expect(() => parseReleaseChangelog(_changelog, '1.0.0-alpha.6'), throwsFormatException);
    expect(() => parseReleaseChangelog(_changelog, '1.0.0-alpha.4'), throwsFormatException);
    expect(() => parseReleaseChangelog(_changelog, '1x0x0-alpha.5'), throwsFormatException);
    expect(() => parseReleaseChangelog('## 1.0.0 - 2026-10-20\n\n### 更新说明\n\n### 新增\n- 内容', '1.0.0'), throwsFormatException);
    expect(() => parseReleaseChangelog('## 1.0.0 - 2026-10-20\n\n### 更新说明\n- ${'字' * 4001}', '1.0.0'), throwsFormatException);
  });

  test('仓库 CHANGELOG 已发的最新版本节能取出更新说明（流水线试跑与发版都靠它）', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    final latest = RegExp(r'^## (\d\S*) - ', multiLine: true).firstMatch(changelog)![1]!;
    expect(parseReleaseChangelog(changelog, latest).notes, isNotEmpty);
  });
}
