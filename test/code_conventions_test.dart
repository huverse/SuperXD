import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/font_pack.dart';
import 'package:superxd/local/display_settings.dart';

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
  // 例外：地图选点页同屏有地图（内嵌网页，也是原生视图），玻璃与原生地图同屏曾闪退（玻璃限档的由来），顶栏保持普通图标。
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

  // 内嵌网页是原生视图，不声明手势时 iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）会抢走网页里的横向拖动：
  // 10-28 拼多多安全验证的滑块拖不动、整页跟着滑走。用户能操作的网页一律带 EagerGestureRecognizer（取指纹的 1px 隐藏网页套着 IgnorePointer，不算）。
  test('用户能操作的内嵌网页把拖动交给网页', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        if (line.contains('WebViewWidget(') && !line.contains('IgnorePointer(') && !line.contains('EagerGestureRecognizer')) offenders.add('${file.path}:${index + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  // 只有图标的按钮没有文字，读屏只能读出“按钮”；tooltip同时提供读屏标签和长按提示。
  // 11-16 架构方案 PR D：字号与间距用 lib/theme/campus_tokens.dart 的令牌；这两个数是 lib/theme 以外现存的字面量个数，只许减少。
  // 换成令牌后把数改小（棘轮）；新代码要写字面量（一次性的超大展示数字）就在同一处换掉一个旧的。
  test('字号与间距的字面量只许减少：新代码用 CampusFontSize 与 CampusGap', () {
    const fontSizeLiterals = 359, gapLiterals = 460;
    final fontSize = RegExp(r'fontSize: [0-9]+(\.[0-9]+)?\b'), gap = RegExp(r'SizedBox\((height|width): [0-9]+(\.[0-9]+)?\)');
    var fonts = 0, gaps = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart') && !file.path.startsWith('lib/theme/'))) {
      final text = file.readAsStringSync();
      fonts += fontSize.allMatches(text).length;
      gaps += gap.allMatches(text).length;
    }
    expect(fonts, lessThanOrEqualTo(fontSizeLiterals), reason: '新写的字号用 CampusFontSize（lib/theme/campus_tokens.dart）');
    expect(gaps, lessThanOrEqualTo(gapLiterals), reason: '新写的 SizedBox 间距用 CampusGap（lib/theme/campus_tokens.dart）');
  });

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
  test('内置字体与字体包都是静态字重文件', () {
    final variable = <String>[];
    for (final file in [...Directory('assets/fonts').listSync(), ...Directory('font_packs').listSync()].whereType<File>().where((file) => file.path.endsWith('.ttf'))) {
      final bytes = file.readAsBytesSync();
      final tables = bytes[4] << 8 | bytes[5];
      for (var index = 0; index < tables; index++) {
        final offset = 12 + 16 * index;
        if (String.fromCharCodes(bytes.sublist(offset, offset + 4)) == 'fvar') variable.add(file.path);
      }
    }
    expect(variable, isEmpty);
  });

  // 衬线是下载的字体包（人工决策见 lib/domain/font_pack.dart）：客户端写死的文件名、大小与 SHA-256 要与仓库 font_packs 里发版时传上中转的文件一致，
  // 不能再打进安装包；随包的 Maple 与字体包的哈希都写进开源许可说明（已裁剪，见 tool/font_subset.py）。
  test('字体包的登记与仓库 font_packs 里的文件一致，不进安装包，哈希写进开源许可说明', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final notices = File('assets/third_party_notices.txt').readAsStringSync();
    for (final pack in fontPacks.values) {
      expect(DisplaySettings.fontFamilies[pack.id], pack.family, reason: '显示设置与字体包的族名要一致');
      expect(pubspec, isNot(contains('family: ${pack.family}')), reason: '${pack.family} 不再打进安装包');
      for (final entry in pack.files) {
        expect(fontPackFileName.hasMatch(entry.name), isTrue, reason: entry.name);
        final file = File('font_packs/${entry.name}');
        expect(file.existsSync(), isTrue, reason: '仓库 font_packs 里要有 ${entry.name}');
        final bytes = file.readAsBytesSync();
        expect(bytes.length, entry.size, reason: entry.name);
        expect(sha256.convert(bytes).toString(), entry.sha256, reason: entry.name);
        expect(notices, contains(entry.sha256), reason: '开源许可说明要写 ${entry.name} 的 SHA-256');
      }
    }
    for (final file in Directory('assets/fonts').listSync().whereType<File>().where((file) => file.path.endsWith('.ttf'))) {
      expect(notices, contains(sha256.convert(file.readAsBytesSync()).toString()), reason: '开源许可说明要写 ${file.path} 的 SHA-256');
    }
  });
  // [人工决策-2026-11-14 23:11:48] 用户第三次提描述性文字太多（口径见 lib/playground/playground_catalog.dart 文件头）：界面上一句话不超过 40 个字
  // （插值不计，相邻字面量连起来算）。授权与同意说明、删除与覆盖确认这类必须写全的，在上面三行内写「// 长文案：原因」才放行。
  // 法务正文、教务页面解析的正则、规则文件、日志与异常信息不上界面，不在此列。
  test('界面文案不堆说明，长文案要标明原因', () {
    final offenders = <String>[];
    final cjk = RegExp(r'[一-鿿]');
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart') && !file.path.endsWith('legal_page.dart') && !file.path.contains('/edu/') && !file.path.endsWith('_rules.dart'))) {
      final source = file.readAsStringSync();
      final lines = source.split('\n');
      for (final (line, text) in _DartLiterals(source).scan()) {
        if (text.runes.length <= 40 || !cjk.hasMatch(text)) continue;
        final at = lines[line - 1];
        if (at.contains('campusLog') || at.contains('Exception(') || at.contains('Error(')) continue;
        if (lines.sublist(line > 3 ? line - 4 : 0, line).any((above) => above.contains('长文案：'))) continue;
        offenders.add('${file.path}:$line ${String.fromCharCodes(text.runes.take(16))}…（${text.runes.length} 字）');
      }
    }
    expect(offenders, isEmpty);
  });
}

// 取出 Dart 源码里的字符串字面量（起始行、字面文字）：插值不计入文字（插值里嵌套的字面量另算一条），相邻字面量连成一条，原始字符串（正则）跳过，注释不看。
class _DartLiterals {
  _DartLiterals(this.source) {
    for (var index = 0; index < source.length; index++) {
      if (source.codeUnitAt(index) == 10) _newlines.add(index);
    }
  }

  final String source;
  final _newlines = <int>[];
  final _found = <(int, String)>[];

  List<(int, String)> scan() {
    _code(0, false);
    return _found;
  }

  int _line(int offset) {
    var low = 0, high = _newlines.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_newlines[middle] < offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low + 1;
  }

  static bool _word(int unit) => unit == 95 || (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);

  bool _quote(int at) => at < source.length && (source[at] == "'" || source[at] == '"');

  bool _stringStart(int at) => _quote(at) || (source[at] == 'r' && _quote(at + 1) && (at == 0 || !_word(source.codeUnitAt(at - 1))));

  // 扫一段代码；untilBrace 时停在配平的右花括号之后（插值的结尾）。
  int _code(int at, bool untilBrace) {
    var depth = 0;
    while (at < source.length) {
      if (source.startsWith('//', at)) {
        final end = source.indexOf('\n', at);
        at = end < 0 ? source.length : end;
        continue;
      }
      if (source.startsWith('/*', at)) {
        final end = source.indexOf('*/', at + 2);
        at = end < 0 ? source.length : end + 2;
        continue;
      }
      if (_stringStart(at)) {
        final start = at;
        final text = StringBuffer();
        while (true) {
          final (part, end) = _string(at);
          text.write(part);
          at = end;
          var next = at;
          while (next < source.length && ' \t\r\n'.contains(source[next])) {
            next++;
          }
          if (next < source.length && _stringStart(next)) {
            at = next;
            continue;
          }
          break;
        }
        if (text.isNotEmpty) _found.add((_line(start), text.toString()));
        continue;
      }
      final char = source[at];
      if (untilBrace && char == '{') depth++;
      if (untilBrace && char == '}') {
        if (depth == 0) return at + 1;
        depth--;
      }
      at++;
    }
    return at;
  }

  // 读一个字面量，返回字面文字（原始字符串为空）与结束位置。
  (String, int) _string(int start) {
    var at = start;
    final raw = source[at] == 'r';
    if (raw) at++;
    final quote = source[at];
    final close = source.startsWith(quote * 3, at) ? quote * 3 : quote;
    at += close.length;
    final text = StringBuffer();
    while (at < source.length && !source.startsWith(close, at)) {
      final char = source[at];
      if (!raw && char == r'\') {
        text.write(source[at + 1] == 'n' ? '\n' : source[at + 1]);
        at += 2;
      } else if (!raw && char == r'$' && at + 1 < source.length && source[at + 1] == '{') {
        at = _code(at + 2, true);
      } else if (!raw && char == r'$') {
        at++;
        while (at < source.length && _word(source.codeUnitAt(at))) {
          at++;
        }
      } else {
        text.write(char);
        at++;
      }
    }
    return (raw ? '' : text.toString(), at + close.length);
  }
}
