import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/device/relay_note_feed.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/domain/interruption.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/developer_note_memory.dart';

import '../tool/developer_notes.dart';

DeveloperNote note(String id, DateTime publishedAt, {String title = '近况', String body = '正文'}) => DeveloperNote(id: id, title: title, publishedAt: publishedAt, body: body);

// 只回放给定的清单；calls 记联网次数，gate 不为空时等它完成才回（测并发只拉一次）。
class FakeNoteFeed implements DeveloperNoteFeed {
  FakeNoteFeed(this.notes);
  List<DeveloperNote> notes;
  Object? failure;
  Completer<void>? gate;
  var calls = 0;

  @override
  Future<List<DeveloperNote>> fetch() async {
    calls++;
    await gate?.future;
    if (failure case final failure?) throw failure;
    return notes;
  }
}

CourseOccurrence lesson(DateTime start, DateTime end) => CourseOccurrence(
  date: '2026-10-26',
  start: start,
  end: end,
  course: CourseRecord(courseCode: 'c', courseName: '课程甲', sectionId: 's', credit: 4, teacherName: '教师甲', meetings: const []),
  meeting: CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: 'A101', weeks: const [1]),
);

void main() {
  final now = DateTime.utc(2026, 10, 24, 13, 30);

  group('信的格式（tool/developer_notes.dart）', () {
    test('标题、校园时区的时间、空行后的正文；换行原样保留', () {
      final parsed = parseDeveloperNoteFile('2026-10-24-hello', '﻿标题：今天想说的话\r\n时间：2026-10-24 21:30\r\n\r\n第一段\r\n\r\n第二段\r\n');
      expect(parsed.title, '今天想说的话');
      expect(parsed.publishedAt, DateTime.utc(2026, 10, 24, 13, 30));
      expect(parsed.body, '第一段\n\n第二段');
    });

    test('格式不对时说清是哪个文件、哪一处', () {
      void rejects(String id, String text, String hint) => expect(() => parseDeveloperNoteFile(id, text), throwsA(isA<FormatException>().having((error) => error.message, 'message', allOf(contains(id), contains(hint)))));
      rejects('a', '题目：x\n时间：2026-10-24 21:30\n\n正文', '标题');
      rejects('a', '标题：x\n时间：2026-10-24\n\n正文', '时间');
      rejects('a', '标题：x\n时间：2026-02-30 21:30\n\n正文', '时间');
      rejects('a', '标题：x\n时间：2026-10-24 25:30\n\n正文', '时间');
      rejects('a', '标题：x\n时间：2026-10-24 21:30\n正文', '空一行');
      rejects('a', '标题：x\n时间：2026-10-24 21:30\n\n  \n', '空');
      rejects('a', '标题：${'字' * 41}\n时间：2026-10-24 21:30\n\n正文', '40');
      rejects('a', '标题：x\n时间：2026-10-24 21:30\n\n${'字' * 4001}', '4000');
      rejects('../a', '标题：x\n时间：2026-10-24 21:30\n\n正文', '文件名');
    });

    test('整个目录按时刻从新到旧、只取最近 30 封，生成的清单客户端能原样读回', () async {
      final directory = await Directory.systemTemp.createTemp('notes');
      addTearDown(() => directory.delete(recursive: true));
      for (var index = 0; index < 32; index++) {
        await File('${directory.path}/n$index.txt').writeAsString('标题：第$index封\n时间：2026-10-${(index % 28 + 1).toString().padLeft(2, '0')} 08:${index.toString().padLeft(2, '0')}\n\n正文$index');
      }
      await File('${directory.path}/README.md').writeAsString('不是信');
      final notes = await readDeveloperNotes(directory);
      expect(notes, hasLength(developerNoteLimit));
      expect(notes.first.publishedAt.isAfter(notes.last.publishedAt), isTrue);
      final decoded = decodeDeveloperNotes(jsonDecode(encodeDeveloperNotesFile(notes)));
      expect([for (final item in decoded) item.id], [for (final item in notes) item.id]);
      expect(decoded.first.body, notes.first.body);
    });

    // 仓库里真实的信：格式不对的 PR 在 CI 就失败，不等合并后流水线才发现。
    test('仓库 notes 目录里的信都合格', () async {
      final notes = await readDeveloperNotes(Directory('notes'));
      encodeDeveloperNotesFile(notes);
    });
  });

  group('客户端解析与弹信规则', () {
    test('清单是外部输入：超长、编号不合法、重复、超条数都拒绝', () {
      Map<String, Object?> item(String id, {String title = 't', String body = 'b'}) => {'id': id, 'title': title, 'publishedAt': '2026-10-24T13:30:00Z', 'body': body};
      expect(decodeDeveloperNotes({'notes': [item('a')]}).single.publishedAt, now);
      for (final bad in [
        {'notes': [item('a', body: '字' * 4001)]},
        {'notes': [item('a', title: ' ')]},
        {'notes': [item('../a')]},
        {'notes': [item('a'), item('a')]},
        {'notes': [for (var index = 0; index < 31; index++) item('n$index')]},
        {'notes': 'x'},
      ]) {
        expect(() => decodeDeveloperNotes(bad), throwsFormatException);
      }
    });

    test('只弹最新一封、没弹过、发出不满 14 天的', () {
      final latest = note('b', now), older = note('a', now.subtract(const Duration(days: 1)));
      expect(developerNoteLetter([latest, older], {}, now)?.id, 'b');
      expect(developerNoteLetter([latest, older], {'b'}, now), isNull);
      expect(developerNoteLetter([latest], {}, now.add(developerNoteLetterFresh)), isNull);
      expect(developerNoteLetter([], {}, now), isNull);
    });
  });

  group('上下课安静期', () {
    final start = DateTime.utc(2026, 10, 26, 0, 0), end = DateTime.utc(2026, 10, 26, 1, 35);
    final classes = [lesson(start, end)];

    test('开课前 20 分钟到开课后 5 分钟、下课前 5 分钟到下课后 10 分钟', () {
      expect(classQuietUntil(start.subtract(const Duration(minutes: 21)), classes), isNull);
      expect(classQuietUntil(start.subtract(const Duration(minutes: 20)), classes), start.add(quietAfterStart));
      expect(classQuietUntil(start.add(const Duration(minutes: 4)), classes), start.add(quietAfterStart));
      expect(classQuietUntil(start.add(const Duration(minutes: 5)), classes), isNull);
      expect(classQuietUntil(end.subtract(const Duration(minutes: 5)), classes), end.add(quietAfterEnd));
      expect(classQuietUntil(end.add(const Duration(minutes: 9)), classes), end.add(quietAfterEnd));
      expect(classQuietUntil(end.add(const Duration(minutes: 10)), classes), isNull);
    });

    test('课间相连的并成一段，安静到下一节开课后 5 分钟', () {
      final next = lesson(end.add(const Duration(minutes: 10)), end.add(const Duration(minutes: 105)));
      expect(classQuietUntil(end, [next, ...classes]), next.start.add(quietAfterStart));
      expect(classQuietUntil(end, []), isNull);
    });
  });

  group('本机记录', () {
    test('写下再读回；读过与弹过只留还在清单里的；坏文件当没有记录', () async {
      final directory = await Directory.systemTemp.createTemp('note_memory');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/developer_notes.json');
      final memory = await FileDeveloperNoteMemory.open(file);
      await memory.save(DeveloperNoteRecord(notes: [note('a', now)], read: {'a', 'gone'}, shown: {'gone'}, fetchedAt: now));
      final reopened = (await FileDeveloperNoteMemory.open(file)).record;
      expect([for (final item in reopened.notes) item.id], ['a']);
      expect(reopened.read, {'a'});
      expect(reopened.shown, isEmpty);
      expect(reopened.fetchedAt, now);
      await file.writeAsString('{坏');
      expect((await FileDeveloperNoteMemory.open(file)).record.notes, isEmpty);
    });
  });

  group('拉取与已读（DeveloperNotes）', () {
    test('自动拉取间隔不到一小时不联网，下拉刷新不受限；失败照旧显示上次的', () async {
      var clock = now;
      final feed = FakeNoteFeed([note('a', now)]);
      final notes = DeveloperNotes(feed: feed, memory: FileDeveloperNoteMemory.memory(), clock: () => clock);
      await notes.autoRefresh();
      await notes.autoRefresh();
      expect(feed.calls, 1);
      expect(notes.unread, isTrue);
      clock = now.add(developerNoteRefreshGap);
      feed.failure = const DeveloperNoteException('连不上');
      await notes.autoRefresh();
      expect(feed.calls, 2);
      expect([for (final item in notes.notes) item.id], ['a']);
      await expectLater(notes.refresh(), throwsA(isA<DeveloperNoteException>()));
      expect(feed.calls, 3);
    });

    test('同一时刻只拉一次', () async {
      final feed = FakeNoteFeed([note('a', now)])..gate = Completer<void>();
      final notes = DeveloperNotes(feed: feed, memory: FileDeveloperNoteMemory.memory(), clock: () => now);
      final first = notes.refresh(), second = notes.refresh();
      feed.gate!.complete();
      await Future.wait([first, second]);
      expect(feed.calls, 1);
    });

    test('弹出一封：当时的信都记成弹过，只有这封记成读过；点开别的再记读过', () async {
      final notes = DeveloperNotes(feed: FakeNoteFeed([note('b', now), note('a', now.subtract(const Duration(hours: 1)))]), memory: FileDeveloperNoteMemory.memory(), clock: () => now);
      await notes.refresh();
      expect(notes.letter?.id, 'b');
      await notes.markLetterShown(notes.letter!);
      expect(notes.letter, isNull);
      expect(notes.isRead(notes.notes.first), isTrue);
      expect(notes.unread, isTrue);
      await notes.markRead(notes.notes.last);
      expect(notes.unread, isFalse);
    });
  });

  group('打扰时机（AppMoments）', () {
    Future<(AppMoments, DeveloperNotes)> setup({List<CourseOccurrence> classes = const [], DateTime Function()? clock}) async {
      final notes = DeveloperNotes(feed: FakeNoteFeed([note('b', now)]), memory: FileDeveloperNoteMemory.memory(), clock: clock ?? () => now);
      await notes.refresh();
      final moments = AppMoments(notes: notes, timetable: () async => CampusTimetable(classes), clock: clock ?? () => now);
      addTearDown(moments.dispose);
      return (moments, notes);
    }

    test('有新信就出现；出现过之后这次前台不再出现，回到前台重新计', () async {
      final (moments, notes) = await setup();
      final moment = await moments.next();
      expect(moment, isA<NoteLetterMoment>());
      moments.begin(moment!);
      expect(await moments.next(), isNull);
      await notes.refresh();
      moments.foreground();
      // 信已经记成弹过，回到前台也没有该弹的了。
      expect(await moments.next(), isNull);
    });

    test('从快捷入口进来的这次前台不出现（系统先报回到前台还是先交入口都算），下次回到前台照常', () async {
      var clock = now;
      final (moments, _) = await setup(clock: () => clock);
      moments.taskLaunch();
      clock = clock.add(const Duration(seconds: 1));
      moments.foreground();
      expect(await moments.next(), isNull);
      clock = clock.add(const Duration(minutes: 10));
      moments.foreground();
      expect(await moments.next(), isA<NoteLetterMoment>());
    });

    // testWidgets 的假时钟里推进计时器：安静期的结束提醒是一个 Timer。
    testWidgets('上下课安静期里不出现，安静期结束时提醒再看一眼', (tester) async {
      var elapsed = Duration.zero;
      final start = now.add(const Duration(minutes: 10));
      final (moments, _) = await setup(classes: [lesson(start, start.add(const Duration(minutes: 95)))], clock: () => now.add(elapsed));
      var asked = 0;
      moments.addListener(() => asked++);
      expect(await moments.next(), isNull);
      elapsed = const Duration(minutes: 14, seconds: 59);
      await tester.pump(elapsed);
      expect(asked, 0);
      elapsed += const Duration(seconds: 2);
      await tester.pump(const Duration(seconds: 2));
      expect(asked, 1);
      expect(await moments.next(), isA<NoteLetterMoment>());
    });
  });

  group('中转客户端（RelayNoteFeed）', () {
    test('解析清单；限流与格式不对给可读的原因；响应超过上限不往下读', () async {
      Future<List<DeveloperNote>> fetch(http.Response Function(http.Request request) handler) => RelayNoteFeed('http://relay.test', client: MockClient((request) async => handler(request))).fetch();
      final body = jsonEncode({'notes': [{'id': 'a', 'title': '近况', 'publishedAt': '2026-10-24T13:30:00.000Z', 'body': '正文'}]});
      final notes = await fetch((request) {
        expect(request.url.path, '/v1/app/notes');
        expect(request.url.query, isEmpty);
        return http.Response.bytes(utf8.encode(body), 200);
      });
      expect(notes.single.title, '近况');
      await expectLater(fetch((_) => http.Response('{"code":"RATE_LIMITED"}', 429)), throwsA(isA<DeveloperNoteException>().having((error) => error.message, 'message', contains('频繁'))));
      await expectLater(fetch((_) => http.Response('{"notes":"x"}', 200)), throwsA(isA<DeveloperNoteException>().having((error) => error.message, 'message', contains('格式'))));
      await expectLater(fetch((_) => http.Response('x' * (developerNoteResponseMaxBytes + 1), 200)), throwsA(isA<DeveloperNoteException>()));
    });
  });
}
