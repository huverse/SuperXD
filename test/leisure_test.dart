import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/leisure.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 游乐场与积分的删除数据（人工决策见 lib/domain/leisure.dart；11-16 起开关并进联网偏好，见 network_mode_test.dart）；界面在 app_account_test.dart。
void main() {
  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('leisure_test'));
  tearDown(() => directory.delete(recursive: true));

  group('游乐场的本机记录', () {
    test('游乐场的本机记录清空：成绩、上次的档、最近玩过与笔记都没了，文件一起删', () async {
      final file = File(path.join(directory.path, 'playground', 'playground.json'));
      final store = PlaygroundStore(() async => file);
      await store.finish('hanoi', PuzzleTier.hard, millis: 12000, at: DateTime.utc(2026, 11, 15));
      await store.chooseTier('hanoi', PuzzleTier.hard);
      await store.opened('hanoi');
      await store.saveNotes('run', 'A = 7');
      expect(await file.exists(), isTrue);
      await store.clear();
      expect(store.best('hanoi', PuzzleTier.hard), isNull);
      expect(store.tierOf('hanoi'), PuzzleTier.entry);
      expect(store.recent, isEmpty);
      expect(store.notesOf('run'), isEmpty);
      expect(await file.exists(), isFalse);
      final reopened = PlaygroundStore(() async => file);
      await reopened.ready;
      expect(reopened.recent, isEmpty);
    });
  });

  test('游乐场记录写盘失败只记日志：完成一局照常返回新纪录，内存里的成绩照旧', () async {
    final blocker = File(path.join(directory.path, 'blocked'));
    await blocker.writeAsString('不是目录');
    final store = PlaygroundStore(() async => File(path.join(blocker.path, 'playground.json')));
    expect(await store.finish('hanoi', PuzzleTier.entry, millis: 900, at: DateTime.utc(2026, 11, 15)), isTrue);
    expect(store.best('hanoi', PuzzleTier.entry)?.millis, 900);
  });

  group('编排', () {
    test('删除数据：登录着先删服务器上的再清本机；服务器没删成本机不动、原样报错；没登录或没配中转只清本机', () async {
      final steps = <String>[];
      var signedIn = true;
      Object? failure;
      final leisure = Leisure(
        clearLocal: () async => steps.add('local'),
        deleteRemote: () async {
          if (failure case final error?) throw error;
          steps.add('remote');
        },
        signedIn: () => signedIn,
      );
      expect(leisure.signedIn, isTrue);
      expect(await leisure.deleteData(), isTrue);
      expect(steps, ['remote', 'local']);

      steps.clear();
      failure = const ChallengeException(ChallengeFailure.network, '连不上服务器');
      await expectLater(leisure.deleteData(), throwsA(isA<ChallengeException>()));
      expect(steps, isEmpty, reason: '只删一半不如不删');

      failure = null;
      signedIn = false;
      expect(await leisure.deleteData(), isFalse);
      expect(steps, ['local']);

      final offline = Leisure(clearLocal: () async => steps.add('offline'), signedIn: () => true);
      expect(offline.signedIn, isFalse, reason: '没配中转');
      expect(await offline.deleteData(), isFalse);
      expect(steps.last, 'offline');
    });
  });
}
