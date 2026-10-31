import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

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
// 同类错误聚合：同一签名在窗口内只记第一条全文，其余只计数；同时记着的签名最多这么多种，超了先结掉最早的。
const diagnosticRepeatWindow = Duration(minutes: 1);
const diagnosticRepeatKinds = 200;

// 上次退出原因那一行的开头（app_diagnostics.dart 的 recordExitReasons 写）：每次启动最多几条、各是一次独立的退出，不参与同类聚合。
const diagnosticExitHead = '[App] action=last_exit';

// 一条日志：写入时刻（UTC）与正文（首行是 [模块] key=value，错误带堆栈）。
typedef DiagnosticRecord = ({DateTime time, String text});

// 一种错误：签名、一共出现几次（含聚合掉的）、最近一次的时刻与全文。
typedef DiagnosticErrorKind = ({String signature, int count, DateTime last, String text});

// 把打好的日志包交给系统保存（组合根注入 device 层的导出），成功返回真。
typedef DiagnosticPublish = Future<bool> Function(File archive, String filename);

// 本机诊断日志：campusLog 的另一份输出，写进应用专属外部目录（Android/data/包名/files/logs，连电脑可 adb pull，其他应用读不到，卸载即删）。
// 平时只记错误（带 errorType= 或堆栈的那些），开发者模式下记全部；写入先进内存缓冲，每 2 秒或切到后台时批量追加，不阻塞调用方。
// 落盘前把链接与手机号掩掉：日志可能被导出、贴到公开的 Issue 里，各处 campusLog 本就不该写这些，这里再兜一层。
// [人工决策-2026-10-21 23:48:00] 用户选定加三项（同 Sentry 的错误分组、微信 xlog 的旧日志压缩）：同类错误一分钟内只记一次并计数，
// 免得周期性的错误（如断网时私信长轮询）刷满 1MB 错误记录、挤掉真正有用的；早于今天的开发者模式日志压成 .gz；错误可按种类汇总（查看页与诊断摘要）。
// [人工决策-2026-10-22 16:24:03] 审查后用户选定「同类」按首行加出错位置（堆栈前三帧）算，上次退出原因不参与合并，见 diagnosticErrorSignature。
class DiagnosticLog {
  DiagnosticLog._(this.directory, this._exports, this._publish, this._clock);
  final Directory directory;
  final Directory _exports;
  final DiagnosticPublish _publish;
  final DateTime Function() _clock;
  final _errors = <String>[];
  final _all = <String>[];
  final _repeats = <String, ({DateTime since, DateTime last, int count})>{};
  Timer? _timer;
  Timer? _repeatTimer;
  // 日志目录上的读写一个接一个：追加、轮换改名、清理压缩、读取、打包、删除都排在这把锁上，读到一半 errors.log 被改名会把同一段读两遍。
  final _queue = Lock();
  // 开发者选项页与悬浮工具都能导出：同时点时共用一次，同一秒的两个包同名，会互相覆盖、删掉对方的临时包。
  Future<String?>? _exporting;
  void Function(String message)? _console;

  // 开发者模式开着时记全部，关着时只记错误（组合根按开发者设置切换）。
  bool developer = false;

  // 运行环境（版本、构建号、渠道、系统、机型、架构），由组合根启动时填好；导出时写进 about.txt，开发者选项里显示。
  Map<String, String> environment = const {};

  // 字号状态（屏宽、系统与应用字号、字体、推荐上限），开发者模式开着时由组合根随变化更新；摘要与 about.txt 写在运行环境后面。
  Map<String, String> textSize = const {};

  static Future<DiagnosticLog> open({required Directory directory, required Directory exports, required DiagnosticPublish publish, DateTime Function() clock = DateTime.now}) async {
    final log = DiagnosticLog._(directory, exports, publish, clock);
    // 清理旧日志排进写入队列、不等它：跨天后第一次启动要压缩之前的日志（最多约 20MB），等着会拖慢启动；
    // 本机日志只是辅助记录，存储出错（如外部存储暂时不可用）也不能让应用起不来，失败只报到控制台。
    unawaited(log._queue.synchronized(log._prune).catchError((Object error, StackTrace stack) {
      log._console?.call('[Diagnostics] action=prune errorType=${error.runtimeType}\n$stack');
    }));
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
    // 堆栈行两种写法都认：调试包是「#0      函数 (文件:行:列)」，正式包用 --split-debug-info 构建，是缩进的「    #00 abs … virt …」。
    final error = message.contains('errorType=') || _frameLine.hasMatch(message);
    if (!error && !developer) return;
    final now = _clock(), scrubbed = _scrub(message);
    _closeRepeats(now);
    if (error && !message.startsWith(diagnosticExitHead)) {
      // 签名按落盘后的样子算（先掩码），和查看时从文件里算的一致。
      final signature = diagnosticErrorSignature(scrubbed);
      final open = _repeats[signature];
      if (open != null) {
        _repeats[signature] = (since: open.since, last: now, count: open.count + 1);
        _repeatTimer ??= Timer(diagnosticRepeatWindow, () {
          _repeatTimer = null;
          unawaited(flush());
        });
        return;
      }
      if (_repeats.length >= diagnosticRepeatKinds) _closeRepeat(_repeats.keys.first, now);
      _repeats[signature] = (since: now, last: now, count: 0);
    }
    final line = '${now.toUtc().toIso8601String()} $scrubbed\n';
    if (error) _errors.add(line);
    if (developer) _all.add(line);
    _timer ??= Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  // 窗口到了的签名补一条「又出现 N 次」（all 为真时全部结掉，导出与切到后台时用）；只出现过一次的不补。
  // 每条日志都要走这里：表里按第一次出现的先后排着（计数只改值、不挪位置），从最早的结到第一个还没到窗口的就停，不每次把整张表过一遍。
  void _closeRepeats(DateTime now, {bool all = false}) {
    final due = [for (final MapEntry(:key) in _repeats.entries.takeWhile((entry) => all || now.difference(entry.value.since) >= diagnosticRepeatWindow)) key];
    for (final signature in due) {
      _closeRepeat(signature, now);
    }
  }

  void _closeRepeat(String signature, DateTime now) {
    final open = _repeats.remove(signature)!;
    if (open.count == 0) return;
    // 行首是结算的时刻（文件里按时间先后），最后一次真正出现的时刻另记在 last。
    final line = '${now.toUtc().toIso8601String()} $_repeatHead count=${open.count} seconds=${open.last.difference(open.since).inSeconds} last=${open.last.toUtc().toIso8601String()} | $signature\n';
    _errors.add(line);
    if (developer) _all.add(line);
  }

  // 把缓冲写进文件；写入一个接一个排队，不会两次同时追加同一个文件。settle 为真时先把聚合中的计数全部写出（导出、切到后台）。
  // 缓冲是空的也排一次队：等前面还没写完的写完再返回。
  Future<void> flush({bool settle = false}) {
    _timer?.cancel();
    _timer = null;
    _closeRepeats(_clock(), all: settle);
    if (_repeats.values.any((open) => open.count > 0)) {
      _repeatTimer ??= Timer(diagnosticRepeatWindow, () {
        _repeatTimer = null;
        unawaited(flush());
      });
    } else {
      _repeatTimer?.cancel();
      _repeatTimer = null;
    }
    final errors = _errors.join(), all = _all.join();
    _errors.clear();
    _all.clear();
    return _queue.synchronized(() async {
      if (errors.isNotEmpty || all.isNotEmpty) await _write(errors, all);
    });
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

  // 只往当天最新的一卷追加，放不下就另起下一卷，不回头填早先几卷的空余：卷号就是先后，查看页从最后一卷往前读、超总量从最前一卷删，都靠它。
  Future<void> _appendDiagnostics(List<int> bytes) async {
    final day = formatCampusDate(campusInstant(_clock()));
    var part = 1;
    for (final (_, fileDay, filePart) in await _diagnosticFiles()) {
      if (fileDay == day && filePart > part) part = filePart;
    }
    File file() => File(path.join(directory.path, part == 1 ? 'diagnostics-$day.log' : 'diagnostics-$day.$part.log'));
    if (await file().exists() && await file().length() + bytes.length > diagnosticFileLimit) part++;
    await file().writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  // 开发者模式日志按日期与分卷从旧到新（早于今天的是压缩过的 .log.gz）；超过保留天数的删掉，总量超了从最旧的删起。
  Future<List<(File, String, int)>> _diagnosticFiles() async {
    final pattern = RegExp(r'^diagnostics-(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log(?:\.gz)?$');
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
    final today = campusInstant(_clock());
    final day = formatCampusDate(today);
    final oldest = formatCampusDate(DateTime.utc(today.year, today.month, today.day - (diagnosticKeepDays - 1)));
    // 超过保留天数的直接删；其余早于今天的不会再追加，在后台 isolate 里压成 .gz（日志文本约能压到十分之一），同样 20MB 能留更多。
    for (final (file, fileDay, _) in await _diagnosticFiles()) {
      if (fileDay.compareTo(oldest) < 0) {
        await file.delete();
      } else if (fileDay.compareTo(day) < 0 && !file.path.endsWith('.gz')) {
        final source = file.path;
        await Isolate.run(() => _gzip(source));
      }
    }
    final files = await _diagnosticFiles();
    final sizes = [for (final (file, _, _) in files) await file.length()];
    var total = sizes.fold(0, (sum, size) => sum + size);
    for (final (index, (file, _, _)) in files.indexed) {
      if (total <= diagnosticTotalLimit) break;
      total -= sizes[index];
      await file.delete();
    }
  }

  // 本机日志一共占多少字节（先把缓冲写进去）。
  Future<int> totalBytes() async {
    await flush();
    return _queue.synchronized(() async {
      var total = 0;
      if (!await directory.exists()) return total;
      await for (final entity in directory.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    });
  }

  // 最新的若干条，新的在前：errorsOnly 读错误记录（开发者模式开启前的错误也在里面），否则读开发者模式日志。
  // 读文件、解压与逐行解析都在后台 isolate 里做：最多半兆文本、早于今天的还要先整份解压，放在界面线程上打开查看页会掉帧。
  Future<List<DiagnosticRecord>> recent({required bool errorsOnly}) async {
    await flush();
    return _queue.synchronized(() async => _readIsolated(errorsOnly ? _errorFiles() : [for (final (file, _, _) in await _diagnosticFiles()) file.path]));
  }

  // 错误按种类汇总，最近出过的在前：聚合补的「又出现 N 次」计进同一种，全文取最近那条。先把聚合中的计数结算写出，次数才是准的。
  // 汇总整份错误记录（两份合计约 1MB）：只读查看页那半兆的话，带堆栈的错误只剩两百来条，较早那份基本算不进去，次数也少算。
  Future<List<DiagnosticErrorKind>> errorKinds() async {
    await flush(settle: true);
    return _queue.synchronized(() => _kindsIsolated(_errorFiles()));
  }

  List<String> _errorFiles() => [path.join(directory.path, 'errors.1.log'), path.join(directory.path, 'errors.log')];

  // 诊断摘要：运行环境加最近的十种错误（已掩码），一段纯文字，粘贴进聊天或 Issue 用，不用传整个日志包。
  Future<String> summary() async {
    final kinds = await errorKinds();
    String moment(DateTime time) {
      final local = campusInstant(time);
      String two(int value) => value.toString().padLeft(2, '0');
      return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
    }
    return [
      'SuperXD 诊断摘要',
      for (final MapEntry(:key, :value) in {...environment, ...textSize}.entries) '$key: $value',
      '',
      kinds.isEmpty ? '最近没有错误' : '最近的错误（共 ${kinds.length} 种，按最近出现排）：',
      for (final (index, kind) in kinds.take(10).indexed) '${index + 1}. ${kind.signature} × ${kind.count}（最近 ${moment(kind.last)}）',
    ].join('\n');
  }

  // 清除开发者模式日志（关闭开发者模式时），错误记录保留。
  Future<void> clearDiagnostics() async {
    await flush();
    await _queue.synchronized(() async {
      for (final (file, _, _) in await _diagnosticFiles()) {
        await file.delete();
      }
    });
  }

  // 清除全部本机日志（错误记录与开发者模式日志）。聚合中的签名一并忘掉：清除后再出的错要重新记一条全文，不能只补一行「又出现 N 次」。
  Future<void> clear() async {
    await flush();
    _repeats.clear();
    _repeatTimer?.cancel();
    _repeatTimer = null;
    await _queue.synchronized(() async {
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is File) await entity.delete();
      }
    });
  }

  // 导出：全部日志加 about.txt（运行环境与导出时刻）打成 zip（在后台 isolate 里打，不卡界面），交给系统存进公共目录；临时包用完即删。
  // 成功返回文件名，没有日志或没存成返回空。
  Future<String?> export() => _exporting ??= _export().whenComplete(() => _exporting = null);

  Future<String?> _export() async {
    await flush(settle: true);
    final now = campusInstant(_clock());
    String two(int value) => value.toString().padLeft(2, '0');
    final filename = 'SuperXD-日志-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
    final about = [
      for (final MapEntry(:key, :value) in {...environment, ...textSize}.entries) '$key: $value',
      'exportedAt: ${_clock().toUtc().toIso8601String()}',
      'developer: $developer',
      'note: 早于导出当天的开发者模式日志是 .log.gz，用 gunzip 解开',
    ].join('\n');
    await _exports.create(recursive: true);
    final archive = File(path.join(_exports.path, filename));
    try {
      final packed = await _queue.synchronized(() => _zipIsolated(directory.path, archive.path, about));
      return packed && await _publish(archive, filename) ? filename : null;
    } finally {
      if (await archive.exists()) await archive.delete();
    }
  }
}

// 交给后台 isolate 的几样活：放在顶层函数里起 isolate，免得闭包连带捕获 DiagnosticLog（锁、定时器带不过去）。
Future<List<DiagnosticRecord>> _readIsolated(List<String> files) => Isolate.run(() => _readRecent(files));

Future<List<DiagnosticErrorKind>> _kindsIsolated(List<String> files) =>
    Isolate.run(() async => _errorKinds(await _readRecent(files, budget: 2 * diagnosticErrorLimit, limit: null)));

// 目录里没有日志时不打包、返回假。
Future<bool> _zipIsolated(String directory, String target, String about) async {
  if (!await Directory(directory).exists()) return false;
  final sources = [await for (final entity in Directory(directory).list()) if (entity is File) entity.path]..sort();
  if (sources.isEmpty) return false;
  await Isolate.run(() => _zip(target, sources, about));
  return true;
}

// 在后台 isolate 里跑：从最新的文件往前读，合计不超过 budget 字节，堆栈续行并进上一条，新的在前、最多 limit 条（为空不限）。
Future<List<DiagnosticRecord>> _readRecent(List<String> paths, {int budget = diagnosticViewBytes, int? limit = diagnosticViewLimit}) async {
  final chunks = <String>[];
  for (final file in paths.reversed.map(File.new)) {
    if (budget <= 0) break;
    if (!await file.exists()) continue;
    final List<int> bytes;
    if (file.path.endsWith('.gz')) {
      // 压缩过的整份解开（单份解开后不超过 diagnosticFileLimit），再取末尾一段。
      final whole = GZipDecoder().decodeBytes(await file.readAsBytes());
      bytes = whole.length > budget ? whole.sublist(whole.length - budget) : whole;
      budget -= bytes.length;
      final text = utf8.decode(bytes, allowMalformed: true);
      chunks.insert(0, bytes.length == whole.length ? text : text.substring(text.indexOf('\n') + 1));
      continue;
    }
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
  return records.reversed.take(limit ?? records.length).toList();
}

List<DiagnosticErrorKind> _errorKinds(List<DiagnosticRecord> records) {
  final kinds = <String, DiagnosticErrorKind>{};
  for (final record in records.reversed) {
    final repeat = record.text.startsWith(_repeatHead);
    final signature = repeat ? record.text.substring(record.text.indexOf(' | ') + 3) : diagnosticErrorSignature(record.text);
    final count = repeat ? int.tryParse(RegExp(r'count=(\d+)').firstMatch(record.text)?[1] ?? '') ?? 0 : 1;
    final known = kinds[signature];
    final last = repeat ? DateTime.tryParse(RegExp(r' last=(\S+)').firstMatch(record.text)?[1] ?? '') ?? record.time : record.time;
    kinds[signature] = (
      signature: signature,
      count: (known?.count ?? 0) + count,
      last: known != null && known.last.isAfter(last) ? known.last : last,
      text: repeat ? known?.text ?? signature : record.text,
    );
  }
  return kinds.values.toList()..sort((left, right) => right.last.compareTo(left.last));
}

Future<void> _zip(String target, List<String> sources, String about) async {
  final encoder = ZipFileEncoder()..create(target);
  encoder.addArchiveFile(ArchiveFile.string('about.txt', about));
  for (final source in sources) {
    await encoder.addFile(File(source));
  }
  await encoder.close();
}

Future<void> _gzip(String source) async {
  final file = File(source);
  await File('$source.gz').writeAsBytes(GZipEncoder().encodeBytes(await file.readAsBytes()), flush: true);
  await file.delete();
}

const _repeatHead = '[Diagnostics] action=repeat errorType=Repeated';

// 错误的签名：首行（[模块] action=… errorType=…）掩掉像编号的段与数字，同一处错误换了编号、时长也算同一种；
// 带堆栈的再接上前三帧出错位置的短摘要（[人工决策-2026-10-22 16:24:03]，同 Sentry 按堆栈分组）：同一种错误类型在不同位置出的错分开记、各留各的堆栈。
// 位置取帧里稳定的部分：调试包是「函数 (文件:行:列)」，正式包去掉每次启动都变的 abs 地址、留 virt 偏移。代码位置有限，签名种类仍然有界。
String diagnosticErrorSignature(String message) {
  final end = message.indexOf('\n');
  var head = (end < 0 ? message : message.substring(0, end)).replaceAll(_identifier, '#').replaceAll(_digits, '#');
  if (head.length > 200) head = head.substring(0, 200);
  final frames = [for (final match in _frameLocation.allMatches(message).take(3)) match[1]!];
  return frames.isEmpty ? head : '$head @${md5.convert(utf8.encode(frames.join('\n'))).toString().substring(0, 8)}';
}

final _frameLine = RegExp(r'\n\s*#\d');
final _frameLocation = RegExp(r'^\s*#\d+\s+(?:abs [0-9a-f]+ )?(.+)$', multiLine: true);
final _identifier = RegExp(r'(?<![A-Za-z0-9_-])(?=[A-Za-z_-]*\d)[A-Za-z0-9_-]{8,}');
final _digits = RegExp(r'\d+');
// 链接：带协议或 www. 开头的，以及不带协议但有域名加路径的（如 jw.example.edu.cn/xx）。
// 不带协议的只从一串字母数字的开头起匹配（结果不变）：从串中间每一位起头都要扫到串尾，耗时随长度平方涨，4000 字的一串要约 0.2 秒，记日志在主线程上。
final _link = RegExp(r'(?:https?://|www\.)\S+|(?<![A-Za-z0-9-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|cn|net|org)/\S*');
// 手机号：可带 +86 或 86 前缀，号码中间可用空格或短横分成 3-4-4。
final _phone = RegExp(r'(?<!\d)(?:\+?86[\s-]?)?1[3-9]\d(?:[\s-]?\d{4}){2}(?!\d)');

String _scrub(String message) => message.replaceAll(_link, '<链接>').replaceAll(_phone, '<手机号>');
