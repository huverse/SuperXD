import 'dart:io';

// CI 的覆盖率门槛（.github/workflows/ci.yml 的 Flutter 作业调用，也可手动运行）：读 flutter test --coverage 写出的 lcov，
// 只算 lib 下的文件，合计行覆盖率低于门槛就失败。
// 运行：
//   flutter test --coverage
//   dart run tool/coverage_check.dart [--lcov coverage/lcov.info]

// [人工决策-2026-11-10 12:58:48] CI 加覆盖率门槛（用户同意按最佳实践处理）：只守 lib 合计行覆盖率不往下掉，门槛取比现状略低的整数，
// 留一点余量给正常的增删；没选按文件或按改动行设门槛（单文件波动大，误报多）。覆盖率实打实涨上去后再调高，不为过线调低。
const minimumLinePercent = 85;

void main(List<String> args) {
  final lcovPath = args.length == 2 && args[0] == '--lcov' ? args[1] : 'coverage/lcov.info';
  final lcov = File(lcovPath);
  if (!lcov.existsSync()) {
    stderr.writeln('[Coverage] failed reason=missing_lcov path=$lcovPath');
    exitCode = 2;
    return;
  }
  var files = 0, lines = 0, hit = 0;
  var inLib = false;
  for (final line in lcov.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      inLib = line.substring(3).replaceAll(r'\', '/').startsWith('lib/');
      if (inLib) files++;
    } else if (inLib && line.startsWith('DA:')) {
      lines++;
      if (int.parse(line.substring(3).split(',')[1]) > 0) hit++;
    }
  }
  if (lines == 0) {
    stderr.writeln('[Coverage] failed reason=no_lib_lines path=$lcovPath');
    exitCode = 2;
    return;
  }
  final percent = hit * 100 / lines;
  stdout.writeln('[Coverage] files=$files lines=$lines hit=$hit percent=${percent.toStringAsFixed(2)} minimum=$minimumLinePercent');
  if (percent < minimumLinePercent) {
    stderr.writeln('[Coverage] failed reason=below_minimum percent=${percent.toStringAsFixed(2)} minimum=$minimumLinePercent');
    exitCode = 1;
  }
}
