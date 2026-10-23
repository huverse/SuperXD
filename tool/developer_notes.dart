import 'dart:convert';
import 'dart:io';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/developer_note.dart';

// 开发者的话（人工决策见 lib/domain/developer_note.dart）：把仓库 notes 目录里的信整理成中转用的 developer_notes.json。
// notes 目录有改动合并到 main 时由流水线 .github/workflows/notes.yml 调用并上传；也可手动运行看结果。CI 的 test/developer_notes_test.dart
// 会把 notes 目录整个读一遍，格式不对的 PR 合并不了。
// 每封信一个 .txt 文件，文件名（不含 .txt）是这封信的编号，发出后不要改（已读、弹过都按它记）；只许字母数字与 . _ -，如 2026-10-24-hello。内容：
//   标题：这封信的标题
//   时间：2026-10-24 21:30
//   （空一行）
//   正文……换行与空行照写的显示。
// 时间按校园时区写。只发最近 developerNoteLimit 封，更早的留在仓库里、应用里不再显示。
// 运行：dart run tool/developer_notes.dart --out <文件>
const developerNotesFileMaxBytes = 512 * 1024;

DeveloperNote parseDeveloperNoteFile(String id, String text) {
  if (!developerNoteId.hasMatch(id)) throw FormatException('$id.txt：文件名只能用字母数字与 . _ -，开头是字母或数字，不超过 64 个字符');
  final lines = text.replaceFirst('﻿', '').replaceAll('\r\n', '\n').split('\n');
  final title = lines.isEmpty ? null : RegExp(r'^标题[：:]\s*(.+?)\s*$').firstMatch(lines[0])?[1];
  final time = lines.length < 2 ? null : RegExp(r'^时间[：:]\s*(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s*$').firstMatch(lines[1]);
  if (title == null) throw FormatException('$id.txt：第一行要写「标题：……」');
  if (title.length > developerNoteTitleMax) throw FormatException('$id.txt：标题最多 $developerNoteTitleMax 字，现在 ${title.length} 字');
  final minutes = time == null ? null : clockMinutes(time[2]!);
  final date = time == null ? null : DateTime.tryParse(time[1]!);
  if (time == null || minutes == null || date == null || formatCampusDate(date) != time[1]) throw FormatException('$id.txt：第二行要写「时间：2026-10-24 21:30」（校园时区）');
  if (lines.length < 3 || lines[2].trim().isNotEmpty) throw FormatException('$id.txt：时间下面空一行再写正文');
  final body = lines.sublist(3).join('\n').trim();
  if (body.isEmpty) throw FormatException('$id.txt：正文是空的');
  if (body.length > developerNoteBodyMax) throw FormatException('$id.txt：正文最多 $developerNoteBodyMax 字，现在 ${body.length} 字');
  return DeveloperNote(id: id, title: title, publishedAt: campusMoment(time[1]!, minutes), body: body);
}

// 整个目录：每个 .txt 一封，按发出时刻从新到旧取最近 developerNoteLimit 封；有一封不对就整体失败。
Future<List<DeveloperNote>> readDeveloperNotes(Directory directory) async {
  if (!await directory.exists()) return [];
  final notes = [
    for (final file in (await directory.list().toList()).whereType<File>().where((file) => file.path.endsWith('.txt')))
      parseDeveloperNoteFile(file.uri.pathSegments.last.replaceFirst(RegExp(r'\.txt$'), ''), await file.readAsString()),
  ]..sort(compareDeveloperNotes);
  return notes.take(developerNoteLimit).toList();
}

String encodeDeveloperNotesFile(List<DeveloperNote> notes) {
  final json = jsonEncode(encodeDeveloperNotes(notes));
  final bytes = utf8.encode(json).length;
  if (bytes > developerNotesFileMaxBytes) throw FormatException('清单 $bytes 字节，超过中转的上限 $developerNotesFileMaxBytes');
  return json;
}

Future<void> main(List<String> args) async {
  final out = args.length == 2 && args[0] == '--out' ? args[1] : null;
  if (out == null) {
    stderr.writeln('usage: dart run tool/developer_notes.dart --out <file>');
    exitCode = 64;
    return;
  }
  try {
    final notes = await readDeveloperNotes(Directory('notes'));
    await File(out).writeAsString(encodeDeveloperNotesFile(notes));
    stdout.writeln('[DeveloperNotes] action=build count=${notes.length} latest=${notes.firstOrNull?.id}');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
