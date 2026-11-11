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
  // 功能性私信（设备级）：本机库、设备身份与中转服务客户端，只依赖 domain；页面经 SocialService 使用，百宝箱经组合根注入的回调使用。
  'social': {'domain', 'social'},
  'page': {'domain', 'application', 'gateway', 'local', 'social', 'theme', 'page', 'app_session.dart'},
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

  // 对外请求都经共用的有界请求内核 domain/campus_http.dart：超时、响应上限、取消与开发者模式的请求记录（campusRequestLog）只在那里实现一遍。
  // 自己构造 package:http 的客户端或请求、调它的顶层请求函数、用 dart:io 的 HttpClient 发请求的，只许是内核和下面列出的还没迁过来的文件，
  // 而且它们都得自己调 campusRequestLog；新模块一律经 CampusHttp 发，不再手写封装。只拿 http 的异常、参数类型或接收注入的 http.Client 转交给内核的不算；
  // 原生下载与 WebView 不经 Dart，不在此列。（以前只要求发请求的文件调 campusRequestLog，现在连自己发都不许，力度只增不减。）
  test('lib发请求的地方都经共用内核并接上开发者模式的请求记录', () {
    // 还没迁到内核的只剩 iOS 下载传输：它要先看响应头（状态、Content-Range、ETag）再决定续写还是重下、边收边写文件、逐跳自己跟跳转，
    // 内核交回的是读完的整份响应，接不上可续传的大文件下载。设备侧的中转清单、开发者的话与诊断包上传已经迁过去（内核加了无进展超时与流式请求体）；
    // 节日抽签经私信中转客户端（RelayClient.request），跟着它走内核。
    final unmigrated = {
      for (final name in ['toolbox/download/http_transfer.dart']) path.joinAll(['lib', ...name.split('/')]),
    };
    final kernel = path.join('lib', 'domain', 'campus_http.dart');
    final httpRaw = RegExp(
      r'\bhttp\.(Client|Request|AbortableRequest|StreamedRequest|AbortableStreamedRequest|MultipartRequest|AbortableMultipartRequest)\(|\bhttp\.Client\.new\b|(?<![\w.])http\.(get|post|put|patch|delete|head|read|readBytes)\(',
    );
    final ioRaw = RegExp(r'\b(HttpClient|IOClient)\(');
    final senders = <String>[], offenders = <String>[];
    for (final file in _dartFiles('lib')) {
      final text = file.readAsStringSync();
      if (!(text.contains('package:http/http.dart') && httpRaw.hasMatch(text)) && !ioRaw.hasMatch(text)) continue;
      senders.add(file.path);
      if (file.path != kernel && !unmigrated.contains(file.path)) {
        offenders.add('${file.path}：自己发请求，没经 CampusHttp');
      } else if (!text.contains('campusRequestLog(')) {
        offenders.add('${file.path}：发了对外请求，却没调 campusRequestLog');
      }
    }
    // 规则本身没失效：内核要能被认出来。
    expect(senders, contains(kernel));
    expect(offenders, isEmpty);
  });

  // 索引只在文件级兜底：新增、删除、搬迁都要同步登记；职责与不变量的变化靠改动前检查清单维护。
  // [人工决策-2026-10-17 13:25:26] 按最近的 CLAUDE.md 登记（从文件所在目录往上找到 lib 为止，都没有就登记在根文件），
  // 子目录可以有自己的索引（如 lib/toolbox/chaoxing），只在改那里时加载；以前只认 lib 下第一层目录。
  test('项目索引登记lib全部文件且无失效条目', () {
    String read(String index) => File(index).existsSync() ? File(index).readAsStringSync() : '';
    String nearestIndex(String file) {
      for (var dir = path.dirname(file); path.isWithin('lib', dir); dir = path.dirname(dir)) {
        final index = path.join(dir, 'CLAUDE.md');
        if (File(index).existsSync()) return index;
      }
      return 'CLAUDE.md';
    }

    final problems = <String>[];
    for (final file in _dartFiles('lib')) {
      final index = nearestIndex(file.path);
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
