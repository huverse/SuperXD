import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_clock.dart';

// 错误记录每份的上限：两份轮换（errors.log 写满改名成 errors.1.log），合计约 1MB，平时也记。
const diagnosticErrorLimit = 512 * 1024;
// 开发者模式日志：按校园日分文件，单个文件超过上限另起一份；最多保留 7 天、总量 20MB，超出先删最旧的。
const diagnosticFileLimit = 4 * 1024 * 1024;
const diagnosticTotalLimit = 20 * 1024 * 1024;
const diagnosticKeepDays = 7;
// 查看日志只读最新的这么多字节、最多这么多条，不把整份日志读进内存。
const diagnosticViewBytes = 512 * 1024;
const diagnosticViewLimit = 1000;

// 一条日志：写入时刻（UTC）与正文（首行是 [模块] key=value，错误带堆栈）。
typedef DiagnosticRecord = ({DateTime time, String text});

// 把打好的日志包交给系统保存（组合根注入 device 层的导出），成功返回真。
typedef DiagnosticPublish = Future<bool> Function(File archive, String filename);

// 本机诊断日志：campusLog 的另一份输出，写进应用专属外部目录（Android/data/包名/files/logs，连电脑可 adb pull，其他应用读不到，卸载即删）。
// 平时只记错误（带 errorType= 或堆栈的那些），开发者模式下记全部；写入先进内存缓冲，每 2 秒或切到后台时批量追加，不阻塞调用方。
// 落盘前把链接与手机号掩掉：日志可能被导出、贴到公开的 Issue 里，各处 campusLog 本就不该写这些，这里再兜一层。
class DiagnosticLog {
  DiagnosticLog._(this.directory, this._exports, this._publish, this._clock);
  final Directory directory;
  final Directory _exports;
  final DiagnosticPublish _publish;
  final DateTime Function() _clock;
  final _errors = <String>[];
  final _all = <String>[];
  Timer? _timer;
  Future<void> _writing = Future.value();
  void Function(String message)? _console;

  // 开发者模式开着时记全部，关着时只记错误（组合根按开发者设置切换）。
  bool developer = false;

  // 运行环境（版本、构建号、渠道、系统、机型、架构），由组合根启动时填好；导出时写进 about.txt，开发者选项里显示。
  Map<String, String> environment = const {};

  static Future<DiagnosticLog> open({required Directory directory, required Directory exports, required DiagnosticPublish publish, DateTime Function() clock = DateTime.now}) async {
    final log = DiagnosticLog._(directory, exports, publish, clock);
    await directory.create(recursive: true);
    await log._prune();
    return log;
  }

  // campusLog 的出口：照旧交给控制台（logcat），再记进文件。写盘出错只报到控制台，不再经 campusLog 绕回来。
  void Function(String message) tee(void Function(String message) console) {
    _console = console;
    return (message) {
      console(message);
      record(message);
    };
  }

  void record(String message) {
    final error = message.contains('errorType=') || message.contains('\n#0');
    if (!error && !developer) return;
    final line = '${_clock().toUtc().toIso8601String()} ${_scrub(message)}\n';
    if (error) _errors.add(line);
    if (developer) _all.add(line);
    _timer ??= Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  // 把缓冲写进文件；写入一个接一个排队，不会两次同时追加同一个文件。
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final errors = _errors.join(), all = _all.join();
    _errors.clear();
    _all.clear();
    if (errors.isEmpty && all.isEmpty) return _writing;
    return _writing = _writing.then((_) => _write(errors, all));
  }

  Future<void> _write(String errors, String all) async {
    try {
      await directory.create(recursive: true);
      if (errors.isNotEmpty) await _appendErrors(utf8.encode(errors));
      if (all.isNotEmpty) {
        await _appendDiagnostics(utf8.encode(all));
        await _prune();
      }
    } catch (error, stack) {
      _console?.call('[Diagnostics] action=write errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _appendErrors(List<int> bytes) async {
    final file = File(path.join(directory.path, 'errors.log'));
    if (await file.exists() && await file.length() + bytes.length > diagnosticErrorLimit) {
      await file.rename(path.join(directory.path, 'errors.1.log'));
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  Future<void> _appendDiagnostics(List<int> bytes) async {
    final day = formatCampusDate(campusInstant(_clock()));
    var part = 1;
    File file() => File(path.join(directory.path, part == 1 ? 'diagnostics-$day.log' : 'diagnostics-$day.$part.log'));
    while (await file().exists() && await file().length() + bytes.length > diagnosticFileLimit) {
      part++;
    }
    await file().writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  // 开发者模式日志按日期与分卷从旧到新；超过保留天数的删掉，总量超了从最旧的删起。
  Future<List<(File, String, int)>> _diagnosticFiles() async {
    final pattern = RegExp(r'^diagnostics-(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log$');
    final files = <(File, String, int)>[];
    if (!await directory.exists()) return files;
    await for (final entity in directory.list()) {
      final match = pattern.firstMatch(path.basename(entity.path));
      if (entity is File && match != null) files.add((entity, match[1]!, int.parse(match[2] ?? '1')));
    }
    files.sort((left, right) => left.$2 == right.$2 ? left.$3.compareTo(right.$3) : left.$2.compareTo(right.$2));
    return files;
  }

  Future<void> _prune() async {
    final files = await _diagnosticFiles();
    final today = campusInstant(_clock());
    final oldest = formatCampusDate(DateTime.utc(today.year, today.month, today.day - (diagnosticKeepDays - 1)));
    final sizes = [for (final (file, _, _) in files) await file.length()];
    var total = sizes.fold(0, (sum, size) => sum + size);
    for (final (index, (file, day, _)) in files.indexed) {
      if (day.compareTo(oldest) >= 0 && total <= diagnosticTotalLimit) break;
      total -= sizes[index];
      await file.delete();
    }
  }

  // 本机日志一共占多少字节（先把缓冲写进去）。
  Future<int> totalBytes() async {
    await flush();
    var total = 0;
    if (!await directory.exists()) return total;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  // 最新的若干条，新的在前：errorsOnly 读错误记录（开发者模式开启前的错误也在里面），否则读开发者模式日志。
  Future<List<DiagnosticRecord>> recent({required bool errorsOnly}) async {
    await flush();
    final files = errorsOnly
        ? [File(path.join(directory.path, 'errors.1.log')), File(path.join(directory.path, 'errors.log'))]
        : [for (final (file, _, _) in await _diagnosticFiles()) file];
    final chunks = <String>[];
    var budget = diagnosticViewBytes;
    for (final file in files.reversed) {
      if (budget <= 0) break;
      if (!await file.exists()) continue;
      final handle = await file.open();
      try {
        final length = await handle.length();
        final start = length > budget ? length - budget : 0;
        await handle.setPosition(start);
        final text = utf8.decode(await handle.read(length - start), allowMalformed: true);
        // 从文件中间截开时丢掉第一行残片。
        chunks.insert(0, start == 0 ? text : text.substring(text.indexOf('\n') + 1));
        budget -= length - start;
      } finally {
        await handle.close();
      }
    }
    final records = <DiagnosticRecord>[];
    final head = RegExp(r'^(\d{4}-\d{2}-\d{2}T[0-9:.]+Z) ');
    for (final line in const LineSplitter().convert(chunks.join())) {
      final match = head.firstMatch(line);
      if (match != null) {
        records.add((time: DateTime.parse(match[1]!), text: line.substring(match.end)));
      } else if (records.isNotEmpty) {
        final last = records.removeLast();
        records.add((time: last.time, text: '${last.text}\n$line'));
      }
    }
    return records.reversed.take(diagnosticViewLimit).toList();
  }

  // 清除开发者模式日志（关闭开发者模式时），错误记录保留。
  Future<void> clearDiagnostics() async {
    await flush();
    for (final (file, _, _) in await _diagnosticFiles()) {
      await file.delete();
    }
  }

  // 清除全部本机日志（错误记录与开发者模式日志）。
  Future<void> clear() async {
    await flush();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File) await entity.delete();
    }
  }

  // 导出：全部日志加 about.txt（运行环境与导出时刻）打成 zip（在后台 isolate 里打，不卡界面），交给系统存进公共目录；临时包用完即删。
  // 成功返回文件名，没有日志或没存成返回空。
  Future<String?> export() async {
    await flush();
    if (!await directory.exists()) return null;
    final sources = [await for (final entity in directory.list()) if (entity is File) entity.path]..sort();
    if (sources.isEmpty) return null;
    final now = campusInstant(_clock());
    String two(int value) => value.toString().padLeft(2, '0');
    final filename = 'SuperXD-日志-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
    final about = [
      for (final MapEntry(:key, :value) in environment.entries) '$key: $value',
      'exportedAt: ${_clock().toUtc().toIso8601String()}',
      'developer: $developer',
    ].join('\n');
    await _exports.create(recursive: true);
    final archive = File(path.join(_exports.path, filename));
    final target = archive.path;
    try {
      await Isolate.run(() => _zip(target, sources, about));
      return await _publish(archive, filename) ? filename : null;
    } finally {
      if (await archive.exists()) await archive.delete();
    }
  }
}

Future<void> _zip(String target, List<String> sources, String about) async {
  final encoder = ZipFileEncoder()..create(target);
  encoder.addArchiveFile(ArchiveFile.string('about.txt', about));
  for (final source in sources) {
    await encoder.addFile(File(source));
  }
  await encoder.close();
}

final _link = RegExp(r'https?://\S+');
final _phone = RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)');

String _scrub(String message) => message.replaceAll(_link, '<链接>').replaceAll(_phone, '<手机号>');
