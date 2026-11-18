import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/application/app_moments.dart';
import 'package:superxd/domain/app_update.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/device/relay_note_feed.dart';
import 'package:superxd/device/signed_content.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/domain/interruption.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/local/developer_note_memory.dart';

import '../tool/content_signing.dart';
import '../tool/developer_notes.dart';
import 'app_update_fakes.dart';
import 'content_signing_support.dart';

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
  late TestSigning signing;
  setUpAll(() async => signing = await TestSigning.create());

  group('信的格式（tool/developer_notes.dart）', () {
    test('标题、校园时区的时间、空行后的正文；换行原样保留', () {
      final parsed = parseDeveloperNoteFile('2026-10-24-hello', '﻿标题：今天想说的话\r\n时间：2026-10-24 21:30\r\n\r\n第一段\r\n\r\n第二段\r\n');
      expect(parsed.title, '今天想说的话');
      expect(parsed.publishedAt, DateTime.utc(2026, 10, 24, 13, 30));
      expect(parsed.body, '第一段\n\n第二段');
    });

    test('时间下面可以写几行「红包：活动编号」，成为信的附件；编号不合法、重复、超过 4 个、红包后没空行都说清楚', () {
      final parsed = parseDeveloperNoteFile('2026-11-16-sorry', '标题：故障补偿\n时间：2026-11-16 21:30\n红包：compensation-2026-11\n红包: bonus-1\n\n正文');
      expect(parsed.attachments.map((attachment) => (attachment.type, attachment.ref)), [('reward', 'compensation-2026-11'), ('reward', 'bonus-1')]);
      expect(parsed.body, '正文');
      expect(parseDeveloperNoteFile('a', '标题：x\n时间：2026-10-24 21:30\n\n红包：x\n').body, '红包：x', reason: '空行之后的都是正文');
      void rejects(String text, String hint) => expect(() => parseDeveloperNoteFile('a', text), throwsA(isA<FormatException>().having((error) => error.message, 'message', contains(hint))));
      rejects('标题：x\n时间：2026-10-24 21:30\n红包：Bad_Id\n\n正文', '红包编号');
      rejects('标题：x\n时间：2026-10-24 21:30\n红包：a\n红包：a\n\n正文', '两次');
      rejects('标题：x\n时间：2026-10-24 21:30\n${[for (var index = 0; index < 5; index++) '红包：r$index'].join('\n')}\n\n正文', '最多');
      rejects('标题：x\n时间：2026-10-24 21:30\n红包：a\n正文', '空一行');
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
      final file = jsonDecode(await encodeDeveloperNotesFile(notes, [signing.notes])) as Map<String, Object?>;
      // 新客户端读签好的载荷，旧客户端读明文 notes，两份一致；流水线的核对（check-notes）同样通过。
      for (final decoded in [await decodeSignedDeveloperNotes(file, keys: signing.keys), decodeDeveloperNotes(file)]) {
        expect([for (final item in decoded) item.id], [for (final item in notes) item.id]);
        expect(decoded.first.body, notes.first.body);
      }
      await checkDeveloperNotes(file, keys: signing.keys);
    });

    test('30 封都写满（标题 40 字、正文 4000 字），明文加签名载荷也在中转的上限内', () async {
      final notes = [for (var index = 0; index < developerNoteLimit; index++) note('n$index', now, title: '题' * developerNoteTitleMax, body: '字' * developerNoteBodyMax)];
      final bytes = utf8.encode(await encodeDeveloperNotesFile(notes, [signing.notes])).length;
      expect(bytes, lessThanOrEqualTo(developerNotesFileMaxBytes));
      expect(developerNoteResponseMaxBytes, developerNotesFileMaxBytes);
    });

    test('签名钥必须是源码里内置的受信公钥、且能签开发者的话；签好的文件没有信封或与明文不一致都不过核对', () async {
      await expectLater(SigningKey.fromSeed(List.filled(32, 9), SignedContent.notes, keys: signing.keys), throwsFormatException);
      await expectLater(SigningKey.fromSeed(List.filled(32, 1), SignedContent.notes, keys: signing.keys), throwsFormatException);
      final file = jsonDecode(await encodeDeveloperNotesFile([note('a', now)], [signing.notes])) as Map<String, Object?>;
      await expectLater(checkDeveloperNotes({...file, 'envelope': null}, keys: signing.keys), throwsFormatException);
      await expectLater(checkDeveloperNotes({...file, 'notes': <Object>[]}, keys: signing.keys), throwsFormatException);
      await expectLater(checkDeveloperNotes(file, keys: [for (final key in signing.keys) if (key.keyId != 'notes-test') key]), throwsA(isA<SignedEnvelopeException>()));
    });

    // 仓库里真实的信：格式不对的 PR 在 CI 就失败，不等合并后流水线才发现。
    test('仓库 notes 目录里的信都合格', () async {
      final notes = await readDeveloperNotes(Directory('notes'));
      await encodeDeveloperNotesFile(notes, [signing.notes]);
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
        {'notes': [{...item('a'), 'attachments': [{'type': 'Reward', 'ref': 'x'}]}]},
        {'notes': [{...item('a'), 'attachments': [{'type': 'reward', 'ref': '../x'}]}]},
        {'notes': [{...item('a'), 'attachments': [{'type': 'reward'}]}]},
        {'notes': [{...item('a'), 'attachments': [for (var index = 0; index < 5; index++) {'type': 'reward', 'ref': 'r$index'}]}]},
        {'notes': [{...item('a'), 'attachments': 'x'}]},
      ]) {
        expect(() => decodeDeveloperNotes(bad), throwsFormatException);
      }
      // 附件：认识的读出来、不认识的类型也留着（页面不显示），读回来再写一样；旧清单没有附件。
      final withAttachments = decodeDeveloperNotes({'notes': [{...item('a'), 'attachments': [{'type': 'reward', 'ref': 'c-1'}, {'type': 'poll', 'ref': 'p'}]}]});
      expect(withAttachments.single.attachments.map((attachment) => attachment.type), ['reward', 'poll']);
      expect(decodeDeveloperNotes(encodeDeveloperNotes(withAttachments)).single.attachments.map((attachment) => attachment.ref), ['c-1', 'p']);
      expect(encodeDeveloperNotes(decodeDeveloperNotes({'notes': [item('a')]}))['notes'], [item('a')..['publishedAt'] = '2026-10-24T13:30:00.000Z']);
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
      await memory.save(DeveloperNoteRecord(notes: [note('a', now)], read: {'a', 'gone'}, shown: {'a', 'gone'}, fetchedAt: now, fetchedBuild: 31));
      final reopened = (await FileDeveloperNoteMemory.open(file)).record;
      expect([for (final item in reopened.notes) item.id], ['a']);
      expect(reopened.read, {'a'});
      expect(reopened.shown, {'a'});
      expect(reopened.fetchedAt, now);
      expect(reopened.fetchedBuild, 31);
      // 11-18：旧版本一弹出就记在 shown 里（被强制更新盖住的也算了），新版不认，那封在新版里再弹一次。
      await file.writeAsString(jsonEncode({...encodeDeveloperNotes([note('a', now)]), 'read': ['a'], 'shown': ['a'], 'fetchedAt': now.toIso8601String()}));
      final legacy = (await FileDeveloperNoteMemory.open(file)).record;
      expect(legacy.read, {'a'});
      expect(legacy.shown, isEmpty);
      expect(legacy.fetchedBuild, isNull);
      await file.writeAsString('{坏');
      expect((await FileDeveloperNoteMemory.open(file)).record.notes, isEmpty);
    });
  });

  group('拉取与已读（DeveloperNotes）', () {
    test('自动拉取间隔不到一小时不联网，下拉刷新不受限；失败照旧显示上次的', () async {
      var clock = now;
      final feed = FakeNoteFeed([note('a', now)]);
      final notes = DeveloperNotes(build: 1, feed: feed, memory: FileDeveloperNoteMemory.memory(), clock: () => clock);
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

    // 11-18：alpha.28 拉到欢迎信时还不认红包附件，更新后一小时内不重拉、本机那份没有红包；换了版本要立刻重拉，重拉之前不弹旧版本拉的信。
    test('换了版本：一打开就重拉，不等一小时；重拉之前不弹旧版本拉的信', () async {
      final memory = FileDeveloperNoteMemory.memory(DeveloperNoteRecord(notes: [note('a', now)], fetchedAt: now, fetchedBuild: 30));
      final feed = FakeNoteFeed([note('a', now)]);
      final older = DeveloperNotes(build: 30, feed: feed, memory: memory, clock: () => now);
      expect(older.letter?.id, 'a');
      await older.autoRefresh();
      expect(feed.calls, 0, reason: '同一版本不到一小时不联网');
      final notes = DeveloperNotes(build: 31, feed: feed, memory: memory, clock: () => now);
      expect(notes.letter, isNull, reason: '本机的信是旧版本拉的，先不弹');
      expect([for (final item in notes.notes) item.id], ['a'], reason: '「我的」里照样列出');
      await notes.autoRefresh();
      expect(feed.calls, 1);
      expect(notes.letter?.id, 'a');
      expect(memory.record.fetchedBuild, 31);
    });

    test('同一时刻只拉一次', () async {
      final feed = FakeNoteFeed([note('a', now)])..gate = Completer<void>();
      final notes = DeveloperNotes(build: 1, feed: feed, memory: FileDeveloperNoteMemory.memory(), clock: () => now);
      final first = notes.refresh(), second = notes.refresh();
      feed.gate!.complete();
      await Future.wait([first, second]);
      expect(feed.calls, 1);
    });

    test('弹出一封：当时的信都记成弹过，只有这封记成读过；点开别的再记读过', () async {
      final notes = DeveloperNotes(build: 1, feed: FakeNoteFeed([note('b', now), note('a', now.subtract(const Duration(hours: 1)))]), memory: FileDeveloperNoteMemory.memory(), clock: () => now);
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
      final notes = DeveloperNotes(build: 1, feed: FakeNoteFeed([note('b', now)]), memory: FileDeveloperNoteMemory.memory(), clock: clock ?? () => now);
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
      moments.closed(moment);
      await pumpEventQueue();
      await notes.refresh();
      moments.foreground();
      // 用户关掉了，信记成弹过，回到前台也没有该弹的了。
      expect(await moments.next(), isNull);
    });

    // 11-18：信在旧版里刚弹出就被强制更新盖住、用户直接去更新，信没被关掉就不算弹过，下次照样弹。
    test('信弹出来没被关掉（被盖住、应用换了新版）不算弹过，下次照样弹', () async {
      final (moments, notes) = await setup();
      final moment = await moments.next();
      moments.begin(moment!);
      moments.foreground();
      expect(await moments.next(), isA<NoteLetterMoment>());
      expect(notes.letter?.id, 'b');
    });

    test('有强制更新还没装时不弹信，装上新版（重查不再强制）后照常', () async {
      final notes = DeveloperNotes(build: 1, feed: FakeNoteFeed([note('b', now)]), memory: FileDeveloperNoteMemory.memory(), clock: () => now);
      await notes.refresh();
      final fixture = UpdateFixture()..feed.next = fakeRelease(minSupported: 5);
      final moments = AppMoments(notes: notes, updates: fixture.updates, timetable: () async => const CampusTimetable([]), clock: () => now);
      addTearDown(moments.dispose);
      await fixture.updates.autoCheck();
      expect(fixture.updates.urgency, AppUpdateUrgency.forced);
      expect(await moments.next(), isNull);
      final upgraded = UpdateFixture(installed: 5)..feed.next = fakeRelease(minSupported: 5);
      final after = AppMoments(notes: notes, updates: upgraded.updates, timetable: () async => const CampusTimetable([]), clock: () => now);
      addTearDown(after.dispose);
      await upgraded.updates.autoCheck();
      expect(await after.next(), isA<NoteLetterMoment>());
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
    Future<List<DeveloperNote>> fetch(http.Response Function(http.Request request) handler) =>
        RelayNoteFeed('http://relay.test', keys: signing.keys, client: MockClient((request) async => handler(request))).fetch();
    http.Response reply(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);
    final item = {'id': 'a', 'title': '近况', 'publishedAt': '2026-10-24T13:30:00.000Z', 'body': '正文'};
    // 中转的返回：明文 notes 给旧客户端（这里故意写成别的内容，新客户端一律不用），envelope 是签好的信封。
    Future<Map<String, Object?>> signed(Map<String, Object?> payload, {List<SigningKey>? signers, SignedContent content = SignedContent.notes}) async => {
      'notes': [{...item, 'title': '明文'}],
      'envelope': await signing.seal(payload, content, signers ?? [signing.notes]),
    };
    Matcher failsWith(String hint) => throwsA(isA<DeveloperNoteException>().having((error) => error.message, 'message', contains(hint)));

    test('只认验过签的载荷；限流与格式不对给可读的原因；响应超过上限不往下读', () async {
      final body = await signed({'notes': [item]});
      final notes = await fetch((request) {
        expect(request.url.path, '/v1/app/notes');
        expect(request.url.query, isEmpty);
        return reply(body);
      });
      expect(notes.single.title, '近况');
      await expectLater(fetch((_) => http.Response('{"code":"RATE_LIMITED"}', 429)), failsWith('频繁'));
      final malformed = await signed({'notes': 'x'});
      await expectLater(fetch((_) => reply(malformed)), failsWith('格式'));
      await expectLater(fetch((_) => http.Response('x' * (developerNoteResponseMaxBytes + 1), 200)), throwsA(isA<DeveloperNoteException>()));
    });

    // 中间人能改明文 HTTP 上的任何字节：没有信封、拿发版清单的钥签、冒名的钥、签成发版清单的内容类型，都不认。
    test('没有签名或验不过：按失败处理，不用明文 notes；离线备用钥签的照样认', () async {
      for (final body in [
        {'notes': [item]},
        {'notes': [item], 'envelope': null},
        await signed({'notes': [item]}, signers: [signing.release]),
        await signed({'notes': [item]}, signers: [signing.stranger]),
        await signed({'notes': [item]}, content: SignedContent.release),
      ]) {
        await expectLater(fetch((_) => reply(body)), failsWith('校验'), reason: '$body');
      }
      final offline = await signed({'notes': [item]}, signers: [signing.offline]);
      expect((await fetch((_) => reply(offline))).single.title, '近况');
    });

    // 中转上还没放过信时给空列表、不带信封：和中间人扣下内容效果相同（签名挡不住扣下），按没有信处理，不记错误。
    test('中转还没有信：空列表不带信封按没有信处理', () async {
      expect(await fetch((_) => reply({'notes': <Object>[], 'envelope': null})), isEmpty);
      expect(await fetch((_) => reply({'notes': <Object>[]})), isEmpty);
    });
  });
}
