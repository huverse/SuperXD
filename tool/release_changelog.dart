import 'dart:io';

// 从 CHANGELOG.md 取某个版本的发版材料（发版流水线 .github/workflows/release.yml 调用，也可手动运行）：
// 版本节「## <版本名> - <日期>」整节套进 tool/release_body.md 成为 GitHub Release 正文；节里「### 更新说明」的各条
// 去掉列表符号后是应用内更新弹窗的说明，交给 tool/release_manifest.dart。缺版本节、缺更新说明或说明超长时失败。
// 运行：
//   dart run tool/release_changelog.dart --version <版本名> --commit <提交号> --certificate <证书 SHA-256> --notes-out <文件> --body-out <文件>
class ReleaseChangelog {
  const ReleaseChangelog({required this.section, required this.notes});
  // 版本节去掉标题行后的全文。
  final String section;
  // 应用内更新说明：每条一行。
  final String notes;
}

ReleaseChangelog parseReleaseChangelog(String changelog, String version) {
  final lines = changelog.split('\n');
  final heading = RegExp('^## ${RegExp.escape(version)}( - .+)?\$');
  final start = lines.indexWhere(heading.hasMatch);
  if (start < 0) throw FormatException('CHANGELOG 里没有「## $version - 日期」版本节');
  final end = lines.indexWhere((line) => line.startsWith('## '), start + 1);
  final section = lines.sublist(start + 1, end < 0 ? lines.length : end);
  final notesStart = section.indexWhere((line) => line.trim() == '### 更新说明');
  if (notesStart < 0) throw FormatException('$version 的版本节里没有「### 更新说明」');
  final notesEnd = section.indexWhere((line) => line.startsWith('### '), notesStart + 1);
  final notes = [
    for (final line in section.sublist(notesStart + 1, notesEnd < 0 ? section.length : notesEnd))
      if (line.trim().isNotEmpty) line.trim().replaceFirst(RegExp(r'^[-*]\s+'), ''),
  ].join('\n');
  if (notes.isEmpty || notes.length > 4000) throw FormatException('更新说明要有内容且不超过 4000 字，现在 ${notes.length} 字');
  return ReleaseChangelog(section: section.join('\n').trim(), notes: notes);
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var index = 0; index + 1 < args.length; index += 2) {
    options[args[index].replaceFirst('--', '')] = args[index + 1];
  }
  final version = options['version'], commit = options['commit'], certificate = options['certificate'];
  final notesOut = options['notes-out'], bodyOut = options['body-out'];
  if (version == null || commit == null || certificate == null || notesOut == null || bodyOut == null) {
    _fail('usage: dart run tool/release_changelog.dart --version <name> --commit <sha> --certificate <sha256> --notes-out <file> --body-out <file>');
    return;
  }
  final ReleaseChangelog release;
  try {
    release = parseReleaseChangelog(await File('CHANGELOG.md').readAsString(), version);
  } on FormatException catch (error) {
    _fail(error.message);
    return;
  }
  final template = await File('tool/release_body.md').readAsString();
  final body = template
      .replaceAll('{{version}}', version)
      .replaceAll('{{commit}}', commit.substring(0, 7))
      .replaceAll('{{certificate}}', certificate)
      .replaceAll('{{changelog}}', release.section);
  await File(notesOut).writeAsString('${release.notes}\n');
  await File(bodyOut).writeAsString(body);
  stdout.writeln('[ReleaseChangelog] version=$version notes=${release.notes.length} body=${body.length}');
}

void _fail(String reason) {
  stderr.writeln('[ReleaseChangelog] failed reason=$reason');
  exitCode = 2;
}
