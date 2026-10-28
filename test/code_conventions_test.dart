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

  // 页面滚动区一律包 CampusScrollFade（或 ScrollEdgeFade）：内容滚到透明顶栏下时自身渐隐，不被顶栏下缘硬切。
  // 10-20 用户截图指出快递、短视频解析两页是硬切、只有学习通有过渡。弹层、弹窗是玻璃面板（遮罩下玻璃取不到背景），没有 Scaffold，不在此列。
  test('有滚动区的页面都包了滚动边缘渐隐', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (source.contains('Scaffold(') && RegExp(r'\b(ListView|CustomScrollView|SingleChildScrollView|GridView)\b').hasMatch(source) && !RegExp(r'\b(CampusScrollFade|ScrollEdgeFade)\b').hasMatch(source)) offenders.add(file.path);
    }
    expect(offenders, isEmpty);
  });

  // 顶栏右侧操作一律用玻璃圆钮 CampusGlassCircleButton（主题规则：圆形玻璃按钮只用于顶栏操作与悬浮按钮）；10-20 统一性审查发现学习通、快递用的是普通图标。
  // 例外：地图选点页同屏有高德原生地图，玻璃与地图同屏曾闪退（玻璃限档的由来），顶栏保持普通图标。
  test('顶栏右侧操作用玻璃圆钮', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart') && !file.path.endsWith('chaoxing_map_page.dart'))) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'AppBar\(').allMatches(source)) {
        final actions = source.indexOf('actions: [', match.end);
        // 只看这个 AppBar 自己的 actions：下一个 AppBar 之前、括号配平的那一段。
        final next = source.indexOf('AppBar(', match.end);
        if (actions < 0 || (next >= 0 && actions > next)) continue;
        var depth = 0, end = actions + 'actions: '.length;
        for (; end < source.length; end++) {
          final char = source[end];
          if (char == '[' || char == '(' || char == '{') depth++;
          if (char == ']' || char == ')' || char == '}') depth--;
          if (depth == 0) break;
        }
        if (source.substring(actions, end).contains('IconButton(')) offenders.add('${file.path}:${'\n'.allMatches(source.substring(0, actions)).length + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  // 页面路由一律用 CampusPageRoute（GoRouter 经 campusPage）：转场计时从新页首帧画完后开始，
  // 直接用 MaterialPageRoute 时首帧一慢（首次加载字体、编译着色器）整段转场就被吃掉，看起来是硬切。
  test('页面路由不直接用MaterialPageRoute或MaterialPage', () {
    final offenders = <String>[];
    for (final file in [...Directory('lib').listSync(recursive: true), ...Directory('tool').listSync(recursive: true)].whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (RegExp(r'\bMaterialPageRoute\b|\bMaterialPage<\w+>\(|\bMaterialPage\(').hasMatch(lines[index]) && !file.path.endsWith('campus_transitions.dart')) offenders.add('${file.path}:${index + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  // 大半透明的离屏贴图在部分安卓驱动上有脏像素（10-27 vivo 骁龙 2K 屏上卡片颗粒整排冒出绿黑虚线，见 theme 的 FrostTexture）：
  // toImageSync 只留给先铺满底色的云雾贴图（campus_background.dart）；小图改成一次画完或在 CPU 上算好像素再上传（粒子贴图 RewardSprites）。
  test('toImageSync只用于铺满底色的云雾贴图', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart') && !file.path.endsWith('campus_background.dart'))) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].contains('toImageSync(')) offenders.add('${file.path}:${index + 1}');
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

  // ⋯菜单里的破坏性项（删除、移除、清空、关闭私信）图标与文字用警示色，见设计语言第 9 节；曾漏标「删除好友」「关闭私信」与下载记录的「删除」。
  // 选项来自列表、按值决定颜色的（下载管理）要在构造处写 destructive，这里只能查字面量。
  test('⋯菜单里的破坏性项标了警示色', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'\bCampusMenuItem\(').allMatches(source)) {
        var depth = 1;
        var end = match.end;
        while (depth > 0) {
          final char = source[end++];
          if (char == '(') depth++;
          if (char == ')') depth--;
        }
        final item = source.substring(match.end, end);
        final label = RegExp(r"label: '([^']*)'").firstMatch(item)?[1] ?? '';
        if (RegExp('删除|移除|清空|关闭私信').hasMatch(label) && !item.contains('destructive: true')) {
          offenders.add('${file.path}:${'\n'.allMatches(source.substring(0, match.start)).length + 1} $label');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  // 最低 Android 11，系统自带 SQLite 3.28（见 android/app/build.gradle.kts 的人工决策）。测试跑的是 sqflite_common_ffi 带的新版 SQLite，
  // 3.28 之后才有的写法在测试里照样通过、到真机上是语法错误，这里按关键字拦下；要用先对照 SQLite 版本并改最低系统版本。
  test('SQL不用SQLite 3.28之后才有的写法', () {
    final newer = RegExp(
      r'\bRETURNING\b|\bDROP COLUMN\b|\bIIF\(|\bNULLS (FIRST|LAST)\b|\bFILTER \(WHERE\b|\bGENERATED ALWAYS\b|\) STRICT\b|->>|\bUNIXEPOCH\(|\bMATERIALIZED\b',
    );
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (newer.hasMatch(lines[index])) offenders.add('${file.path}:${index + 1}');
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
