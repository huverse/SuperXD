import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/challenges.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/puzzle/balance/balance_rules.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_page.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_rules.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle/loop/loop_rules.dart';
import 'package:superxd/playground/puzzle/queens/queens_page.dart';
import 'package:superxd/playground/puzzle/queens/queens_rules.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_page.dart';
import 'package:superxd/playground/puzzle/twentyfour/twentyfour_rules.dart';
import 'package:superxd/playground/challenge/challenge_home.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/challenge/challenge_run_page.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/challenge/points_page.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/knights/knights_page.dart';
import 'package:superxd/playground/puzzle/knights/knights_rules.dart';
import 'package:superxd/playground/puzzle/loop/loop_page.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_challenge_client.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'form_layout_support.dart';
import 'text_fit_support.dart';

// 挑战与积分的客户端（人工决策见 lib/playground/challenge/challenge_rules.dart）：中转客户端、编排、对局页的挑战模式与挑战页面。合成数据。
const _runId = 'RRRRRRRRRRRRRRRRRRRRRR';
// 中转客户端用例里登录着的应用账号：密钥存在 appAccountSlot。
final _ref = AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: appAccountSlot);
final _hanoi = const HanoiRules().generate(1, PuzzleTier.entry).puzzle;

Map<String, Object?> _levelJson(
  String id, {
  String game = 'hanoi',
  String state = 'open',
  String? letter,
  List<String> inputs = const [],
  String? output,
  int submissions = 0,
  Object? puzzle,
  Map<String, Object?>? gate,
  Map<String, Object?>? consume,
  int? minimum,
  String? extraOf,
}) => {
  'id': id,
  'game': game,
  'tier': 'entry',
  'difficulty': 4,
  'expected': 60,
  'inputs': inputs,
  'output': output,
  'letter': letter ?? (extraOf == null ? id.toUpperCase() : null),
  'state': state,
  'submissions': submissions,
  'errors': 0,
  'minimum': minimum,
  'gate': gate,
  'consume': consume,
  'extraOf': extraOf,
  'puzzle': puzzle,
};

Map<String, Object?> _runJson({bool running = true, List<Map<String, Object?>>? levels, Map<String, Object?>? result, int serverTime = 1000000, String ending = 'locked', int penalty = 0}) => {
  'runId': _runId,
  'challengeId': 'weekly.2026-11-09.trio',
  'title': '三连环',
  'label': '入门',
  'timeLimit': 600,
  'startedAt': serverTime,
  'deadline': serverTime + 600000,
  'serverTime': serverTime,
  'state': running ? 'running' : 'settled',
  'penaltySeconds': penalty,
  'final': ending,
  'levels': levels ??
      [
        _levelJson('a', output: 'c', puzzle: const HanoiRules().encodePuzzle(_hanoi)),
        _levelJson('b', game: 'ice', output: 'c', state: 'solved'),
        _levelJson('c', game: 'twentyfour', state: 'gated', inputs: ['a', 'b'], gate: {'op': 'product', 'value': null}, consume: {'kind': 'slot', 'at': 2, 'modulus': 9, 'offset': 1}),
      ],
  'result': result,
};

// 同一份局面直接建成领域对象（页面与编排的测试用；中转客户端的解码在「中转客户端」一组里测）。
ChallengeLevel _level(Map<String, Object?> json) {
  final gate = json['gate'] as Map<String, Object?>?, consume = json['consume'] as Map<String, Object?>?;
  return ChallengeLevel(
    id: json['id']! as String,
    game: json['game']! as String,
    tier: json['tier']! as String,
    difficulty: json['difficulty']! as int,
    expected: Duration(seconds: json['expected']! as int),
    inputs: (json['inputs']! as List).cast<String>(),
    output: json['output'] as String?,
    letter: json['letter'] as String?,
    state: ChallengeLevelState.values.byName(json['state']! as String),
    submissions: json['submissions']! as int,
    errors: json['errors']! as int,
    minimum: json['minimum'] as int?,
    gate: gate == null ? null : ChallengeGate(product: gate['op'] == 'product', value: gate['value'] as int?),
    consume: consume == null ? null : ChallengeConsume(slot: consume['kind'] == 'slot', at: consume['at']! as int, modulus: consume['modulus']! as int, offset: consume['offset']! as int),
    extraOf: json['extraOf'] as String?,
    puzzle: json['puzzle'],
  );
}

// 「甲 · 乙」说明行分项排在 Wrap 里，整句在读屏标签上。
Finder _line(String text) => find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == text);

ChallengeRun _run({bool running = true, List<Map<String, Object?>>? levels, Map<String, Object?>? result, ChallengeFinal ending = ChallengeFinal.locked, int penalty = 0}) {
  final json = _runJson(running: running, levels: levels, result: result);
  final now = DateTime.now().toUtc();
  return ChallengeRun(
    runId: _runId,
    challengeId: json['challengeId']! as String,
    title: '三连环',
    label: '入门',
    timeLimit: const Duration(minutes: 10),
    startedAt: now,
    deadline: now.add(const Duration(minutes: 10)),
    serverTime: now,
    running: running,
    penalty: Duration(seconds: penalty),
    ending: ending,
    levels: [for (final level in (json['levels']! as List).cast<Map<String, Object?>>()) _level(level)],
    result: result == null ? null : ChallengeResult(points: result['points']! as int, awarded: result['awarded']! as int, ending: result['ending']! as String),
  );
}

void main() {
  group('中转客户端', () {
    late _Relay relay;
    late MemoryAppAccountVault vault;
    late RelayChallengeClient client;
    late SocialIdentity key;
    setUp(() async {
      relay = _Relay();
      vault = MemoryAppAccountVault();
      key = await SocialIdentity.generate();
      client = RelayChallengeClient(vault: vault, transport: relay);
    });

    test('没登录应用账号不发请求；登录了用那个应用账号的设备密钥签名', () async {
      await expectLater(client.catalog(_ref, {'hanoi'}), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.notSignedIn)));
      expect(relay.requests, isEmpty);
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => const RelayResponse(200, {
        'serverTime': 1000,
        'activeRun': null,
        'challenges': [
          {'id': 'weekly.2026-11-09.six', 'title': '六连环', 'label': '入门', 'levels': 3, 'tiers': ['entry', 'entry', 'easy'], 'edges': [[0, 2], [1, 2]], 'timeLimit': 900, 'endsAt': 2000, 'best': 153, 'playable': true, 'ticket': 0},
          {'id': 'bonus.2026-11-09.bonus', 'title': '十二连环', 'label': '加赛', 'levels': 2, 'tiers': ['hard', 'expert'], 'edges': [[0, 1]], 'timeLimit': 3600, 'endsAt': 2000, 'best': null, 'playable': true, 'ticket': 300},
        ],
      });
      final catalog = await client.catalog(_ref, {'ice', 'hanoi'});
      expect(relay.requests.single.path, '/v1/challenges?games=hanoi,ice');
      expect(relay.requests.single.headers['x-sxd-device'], key.deviceId);
      expect(catalog.challenges.first, isA<ChallengeSummary>().having((item) => item.best, 'best', 153).having((item) => item.timeLimit, 'timeLimit', const Duration(minutes: 15)).having((item) => item.ticket, 'ticket', 0));
      expect(catalog.challenges.last.ticket, 300);
      expect(catalog.challenges.first.tiers, ['entry', 'entry', 'easy']);
      expect(catalog.challenges.first.edges, [(0, 2), (1, 2)]);
    });

    test('关卡图按服务端模板的规则核对：重复编号、引用不在的关、指向自己、一关的碎片交给两关、成环都当看不懂；缩略图的边同样', () async {
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      final failed = throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.failed));
      for (final levels in [
        [_levelJson('a'), _levelJson('a')],
        [_levelJson('a', inputs: ['x'])],
        [_levelJson('a', inputs: ['a'])],
        [_levelJson('a'), _levelJson('b', inputs: ['a']), _levelJson('c', inputs: ['a'])],
        [_levelJson('a', inputs: ['b']), _levelJson('b', inputs: ['a'])],
        [_levelJson('a'), _levelJson('x', extraOf: 'y')],
      ]) {
        relay.reply = (request) => RelayResponse(200, _runJson(levels: levels));
        await expectLater(client.run(_ref, _runId), failed, reason: '$levels');
      }
      for (final edges in [[[0, 0]], [[0, 3]], [[0, 1], [0, 2]], [[0, 1], [1, 0]]]) {
        relay.reply = (request) => RelayResponse(200, {
          'serverTime': 1000,
          'activeRun': null,
          'challenges': [{'id': 'weekly.x', 'title': '三连环', 'label': '入门', 'levels': 3, 'tiers': ['entry', 'entry', 'easy'], 'edges': edges, 'timeLimit': 900, 'endsAt': 2000, 'best': null, 'playable': true, 'ticket': 0}],
        });
        await expectLater(client.catalog(_ref, {'hanoi'}), failed, reason: '$edges');
      }
    });

    test('一局的局面、交答案带号码、开门与终章、积分与流水按协议解码；看不懂的回复报失败', () async {
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => RelayResponse(200, {'correct': true, 'fragment': 7, 'extra': 'xa', 'run': _runJson(penalty: 20)});
      final verdict = await client.answer(_ref, _runId, 'a', 2, [1, 2]);
      expect(relay.requests.last.path, '/v1/challenge-runs/$_runId/levels/a/answers');
      expect(relay.requests.last.body, {'attempt': 2, 'answer': [1, 2]});
      expect((verdict.correct, verdict.fragment, verdict.extra), (true, 7, 'xa'));
      expect(verdict.run.penalty, const Duration(seconds: 20));
      expect(verdict.run.ending, ChallengeFinal.locked);
      final consumer = verdict.run.level('c');
      expect((consumer.state, consumer.letter, consumer.gate?.product, consumer.gate?.value), (ChallengeLevelState.gated, 'C', true, null));
      expect((consumer.consume?.slot, consumer.consume?.at, consumer.consume?.valueOf(37)), (true, 2, 2));
      relay.reply = (request) => RelayResponse(200, {'correct': false, 'run': _runJson()});
      expect((await client.gate(_ref, _runId, 'c', 37)).correct, isFalse);
      expect(relay.requests.last.path, '/v1/challenge-runs/$_runId/gates/c');
      expect(relay.requests.last.body, {'value': 37});
      relay.reply = (request) => RelayResponse(200, {'correct': true, 'run': _runJson(running: false, ending: 'cleared', result: {'points': 99, 'awarded': 99, 'ending': 'cleared'})});
      expect((await client.finale(_ref, _runId, 40)).run.ending, ChallengeFinal.cleared);
      expect(relay.requests.last.path, '/v1/challenge-runs/$_runId/final');
      relay.reply = (request) => const RelayResponse(200, {'balance': 86, 'expiring': 20, 'expiringAt': 5000, 'earned': 620, 'level': 1, 'nextLevelAt': 3000, 'serverTime': 1});
      expect((await client.points(_ref)), isA<PointsSummary>().having((points) => points.expiringAt, 'expiringAt', DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true)).having((points) => points.earned, 'earned', 620).having((points) => points.level, 'level', 1).having((points) => points.nextLevelAt, 'nextLevelAt', 3000));
      relay.reply = (request) => const RelayResponse(200, {'balance': 86, 'expiring': 0, 'expiringAt': null, 'earned': 90000, 'level': 5, 'nextLevelAt': null, 'serverTime': 1});
      expect((await client.points(_ref)).nextLevelAt, isNull);
      relay.reply = (request) => const RelayResponse(200, {'balance': 86, 'expiring': 0, 'expiringAt': null, 'earned': 90000, 'level': 6, 'nextLevelAt': null, 'serverTime': 1});
      await expectLater(client.points(_ref), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.failed)));
      relay.reply = (request) => const RelayResponse(200, {'entries': [{'id': '9', 'kind': 'earn', 'amount': 86, 'note': '入门 · 三连环', 'at': 1}], 'next': '9'});
      final batch = await client.pointsEntries(_ref, before: '12');
      expect(relay.requests.last.path, '/v1/points/entries?before=12');
      expect(batch.next, '9');
      relay.reply = (request) => const RelayResponse(200, {'correct': 'yes'});
      await expectLater(client.answer(_ref, _runId, 'a', 0, []), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.failed)));
    });

    test('错误码换成挑战的失败：还有一局带编号、已结束带局面、应用账号不在了', () async {
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => const RelayResponse(409, {'code': 'RUN_ACTIVE', 'runId': _runId});
      await expectLater(client.start(_ref, 'weekly.2026-11-09.six', {'hanoi'}), throwsA(isA<ChallengeException>().having((error) => error.runId, 'runId', _runId)));
      relay.reply = (request) => RelayResponse(409, {'code': 'RUN_OVER', 'run': _runJson(running: false, result: {'points': 13, 'awarded': 13, 'ending': 'timeout'})});
      await expectLater(client.answer(_ref, _runId, 'a', 0, []), throwsA(isA<ChallengeException>().having((error) => error.run?.result?.ending, 'ending', 'timeout')));
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.points(_ref), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.notSignedIn)));
      relay.reply = (request) => const RelayResponse(409, {'code': 'POINTS_SHORT', 'price': 300, 'balance': 86});
      await expectLater(
        client.start(_ref, 'bonus.2026-11-09.bonus', {'hanoi'}),
        throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.pointsShort).having((error) => error.message, 'message', '积分不够，门票要 300 分')),
      );
    });
  });

  group('碎片与改目标的规则', () {
    test('碎片从解里来：汉诺塔最少步数、数回圈里几格、密码各位之和；天平称球用题面定的称几次', () {
      final hanoi = const HanoiRules().generate(2, PuzzleTier.easy);
      expect(challengeFragment('hanoi', hanoi.puzzle, hanoi.solution), hanoi.solution.length);
      // 2×2 的格子全在圈里：外圈 8 条边。
      const loop = LoopPuzzle(width: 2, height: 2, clues: [-1, -1, -1, -1]);
      final grid = LoopGrid.of(2, 2);
      final edges = List.filled(grid.edgeCount, false);
      for (final edge in [grid.horizontal(0, 0), grid.horizontal(0, 1), grid.horizontal(2, 0), grid.horizontal(2, 1), grid.vertical(0, 0), grid.vertical(1, 0), grid.vertical(0, 2), grid.vertical(1, 2)]) {
        edges[edge] = true;
      }
      expect(loopInside(loop, edges), 4);
      final cipher = const CipherRules().generate(3, PuzzleTier.normal);
      expect(challengeFragment('cipher', cipher.puzzle, cipher.solution), cipher.solution.fold<int>(0, (sum, digit) => sum + digit));
      expect(challengeFragment('balance', const BalanceRules().generate(1, PuzzleTier.entry).puzzle, null), 2);
      expect(challengeFragment('balance', const BalanceRules().generate(1, PuzzleTier.expert).puzzle, null), 3);
    });

    test('记忆闪光镜像：亮的照常亮，要点左右镜像的格；冰面滑行的出口只给页面画、判定只看终点', () {
      final draw = const FlashRules().generate(5, PuzzleTier.easy);
      final flash = draw.puzzle;
      final mirrored = FlashPuzzle(side: flash.side, showMillis: flash.showMillis, rounds: flash.rounds, mirror: true);
      expect(flashShown(mirrored, 0, 0), flashShown(flash, 0, 0));
      expect(flashPattern(mirrored, 0, 0), ([for (final cell in flashShown(flash, 0, 0)) cell ~/ flash.side * flash.side + flash.side - 1 - cell % flash.side]..sort()));
      expect(const FlashRules().solved(mirrored, draw.solution), isFalse);
      expect(const FlashRules().solved(mirrored, [for (var round = 0; round < flash.rounds.length; round++) flashPattern(mirrored, round, 0)]), isTrue);
      expect(const FlashRules().decodePuzzle(const FlashRules().encodePuzzle(mirrored)).mirror, isTrue);

      final ice = const IceRules().generate(7, PuzzleTier.normal);
      final exits = iceExits(ice.puzzle, PuzzleRandom(1));
      expect(exits, contains(ice.puzzle.goal));
      final labeled = IcePuzzle(width: ice.puzzle.width, height: ice.puzzle.height, rocks: ice.puzzle.rocks, start: ice.puzzle.start, goal: ice.puzzle.goal, exits: exits);
      expect(const IceRules().decodePuzzle(const IceRules().encodePuzzle(labeled)).exits, exits);
      expect(const IceRules().solved(labeled, ice.solution), isTrue);
      expect(() => const IceRules().decodePuzzle({...const IceRules().encodePuzzle(labeled) as Map<String, Object?>, 'exits': [ice.puzzle.start]}), throwsFormatException);
    });
  });

  group('编排', () {
    test('没登录应用账号直接报未登录；中转说应用账号不在了就马上核一次，本机退回未登录并通知页面', () async {
      final appClient = _AppClient();
      final appAccounts = AppAccounts(client: appClient);
      await appAccounts.load();
      final client = _Client();
      final challenges = Challenges(appAccounts: appAccounts, client: client);
      final changes = <void>[];
      final subscription = challenges.changes.listen(changes.add);
      expect(challenges.signedIn, isFalse);
      await expectLater(challenges.points(), throwsA(isA<ChallengeException>()));
      expect(client.calls, isEmpty);

      appClient.accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
      await appAccounts.load();
      await pumpEventQueue();
      expect(challenges.signedIn, isTrue);
      expect(changes, hasLength(1));
      client.failure = const ChallengeException(ChallengeFailure.notSignedIn, '应用账号已经退出');
      appClient.lost = true;
      await expectLater(challenges.points(), throwsA(isA<ChallengeException>()));
      await pumpEventQueue();
      expect(appClient.summaries, 1);
      expect(challenges.signedIn, isFalse);
      expect(changes, hasLength(2));
      await subscription.cancel();
    });

    test('直接从一个应用账号换成另一个也通知页面（挑战一栏要按新账号重读）', () async {
      final appClient = _AppClient()..accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
      final appAccounts = AppAccounts(client: appClient);
      await appAccounts.load();
      final challenges = Challenges(appAccounts: appAccounts, client: _Client());
      final changes = <void>[];
      final subscription = challenges.changes.listen(changes.add);
      appClient.accountId = 'BBBBBBBBBBBBBBBBBBBBBB';
      await appAccounts.load();
      await pumpEventQueue();
      expect(challenges.signedIn, isTrue);
      expect(changes, hasLength(1));
      appClient.accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
      await appAccounts.load();
      await pumpEventQueue();
      expect(changes, hasLength(2), reason: '换回来也通知');
      await subscription.cancel();
    });
  });

  group('对局页的挑战模式', () {
    // 挑战模式靠对局页把挑战交给会话、完成时带上答案（服务器按答案核对）；新游戏登记成 challengeable 时照做。
    test('能进挑战的对局页都把挑战交给会话、完成时带上答案', () {
      for (final game in playgroundCatalog.where((game) => game.challengeable)) {
        final source = File('lib/playground/puzzle/${game.id}/${game.id}_page.dart').readAsStringSync();
        expect(source, contains('challenge: widget.challenge);'), reason: game.id);
        expect(RegExp(r'_session\.finish\([^)]*answer: ').hasMatch(source), isTrue, reason: game.id);
      }
    });

    test('判对错：自由模式在本机判；挑战模式交服务器（编码后的答案），连不上返回空、不算数；判对过的完成时不再重交', () async {
      final store = PlaygroundStore.memory();
      final game = playgroundCatalog.firstWhere((game) => game.id == 'knights');
      final draw = const KnightsRules().generate(3, PuzzleTier.entry);
      final free = PlaySession(game: game, rules: const KnightsRules(), store: store, seeds: () => 3);
      expect(await free.judge(draw.solution), isTrue);

      final answers = <Object?>[];
      var offline = true;
      final challenge = PlayChallenge(
        level: _run(levels: [_levelJson('a', game: 'knights', puzzle: const KnightsRules().encodePuzzle(draw.puzzle))]).level('a'),
        name: 'A 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) async {
          answers.add(answer);
          if (offline) throw const ChallengeException(ChallengeFailure.network, '连不上服务器');
          return PlayVerdict(correct: jsonEncode(answer) == jsonEncode(const KnightsRules().encodeAnswer(draw.solution)), fragment: 5);
        },
      );
      final session = PlaySession(game: game, rules: const KnightsRules(), store: store, challenge: challenge);
      expect(session.reference, isNull);
      expect(session.tier, PuzzleTier.entry);
      expect(await session.judge(draw.solution), isNull);
      offline = false;
      expect(await session.judge([for (final knight in draw.solution) !knight]), isFalse);
      expect(await session.judge(draw.solution), isTrue);
      expect(answers, hasLength(3));
      expect(await session.finish(answer: draw.solution), isFalse);
      expect((await session.submission!).fragment, 5);
      expect(answers, hasLength(3));
      expect(store.best('knights', PuzzleTier.entry), isNull);
    });

    testWidgets('汉诺塔作为挑战的一关：写关名与剩下的时间、不能换题换档；走完交服务器，弹层大字写碎片（只这一次）与追加的加试题，回到挑战', (tester) async {
      final store = PlaygroundStore.memory();
      final game = playgroundCatalog.firstWhere((game) => game.id == 'hanoi');
      final answers = <Object?>[];
      final navigator = GlobalKey<NavigatorState>();
      final challenge = PlayChallenge(
        level: _run().level('a'),
        name: 'A 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) async {
          answers.add(answer);
          return const PlayVerdict(correct: true, fragment: 7, extra: 'xa');
        },
      );
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const Text('挑战总览')));
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) => HanoiPage(game: game, store: store, challenge: challenge))));
      // 推入的页先离屏建一帧（给 Hero 量位置），再推进转场。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('A 关 · 入门'), findsOneWidget);
      expect(find.textContaining('还有 4:5'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('更多操作'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('这一题从头来'), findsOneWidget);
      expect(find.text('换一道题'), findsNothing);
      await tester.tapAt(const Offset(10, 300));
      await tester.pump(const Duration(milliseconds: 500));

      for (final move in hanoiSolution(_hanoi)) {
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.from + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.to + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(answers.single, const HanoiRules().encodeAnswer(hanoiSolution(_hanoi)));
      expect(find.text('A 关过了'), findsOneWidget);
      expect(find.text('碎片 A = 7'), findsOneWidget);
      expect(find.text('最少步数'), findsOneWidget);
      expect(find.text('解得太快，加了一道加试题'), findsOneWidget);
      expect(store.best('hanoi', PuzzleTier.entry), isNull);
      await tester.tap(find.text('回到挑战'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('挑战总览'), findsOneWidget);
    });

    // 人工决策见 challenge_rules.dart 的 11-14 23:11 那条：门上的数改写的那一处写成 ?（补条件）或不标目标（改目标），页面写出算式，玩家自己算。
    testWidgets('收碎片的关：写出算式与最少步数；24 点的 ? 牌点了选数才能用；汉诺塔不标目标柱、柱子标 ①②③', (tester) async {
      Future<void> open(Widget page) async {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: page));
        await tester.pump(const Duration(milliseconds: 500));
      }

      PlayChallenge challenge(Map<String, Object?> json) => PlayChallenge(level: _level(json), name: 'C 关', deadline: DateTime.now().add(const Duration(minutes: 5)), submit: (answer) async => const PlayVerdict(correct: true));
      final cards = challenge(_levelJson('c', game: 'twentyfour', inputs: ['a', 'b'], gate: {'op': 'sum', 'value': 37}, consume: {'kind': 'slot', 'at': 2, 'modulus': 9, 'offset': 1}, puzzle: {'numbers': [3, 8, 2, 8], 'ops': [0, 1, 2, 3]}));
      await open(TwentyFourPage(game: playgroundCatalog.firstWhere((game) => game.id == 'twentyfour'), store: PlaygroundStore.memory(), challenge: cards));
      expect(find.text('第 3 张牌'), findsOneWidget);
      expect(find.text('= 37 ÷ 9 的余数 + 1'), findsOneWidget);
      expect(find.text('?'), findsOneWidget);
      expect(find.text('2'), findsNothing, reason: '那张牌的真值不露出来');
      await tester.tap(find.text('?'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('第 3 张牌'), findsNWidgets(2));
      expect([for (var value = 1; value <= 9; value++) find.widgetWithText(FilledButton, '$value').evaluate().length], List.filled(9, 1));
      await tester.tap(find.widgetWithText(FilledButton, '2'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('?'), findsNothing);
      expect(find.text('2'), findsOneWidget);

      final tower = challenge(_levelJson('c', inputs: ['a'], gate: {'op': 'sum', 'value': 7}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}, minimum: 7, puzzle: {'disks': 3, 'start': [0, 0, 0], 'target': 1}));
      await open(HanoiPage(game: playgroundCatalog.firstWhere((game) => game.id == 'hanoi'), store: PlaygroundStore.memory(), challenge: tower));
      expect(find.text('= 7 ÷ 3 的余数 + 1'), findsOneWidget);
      expect(find.text('最少 7 步'), findsOneWidget);
      expect(find.text('目标'), findsNothing);
      expect(find.text('②'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('柱子，目标')), findsNothing);
      // 目标藏起来了：全部盘子到了不是开局的那根柱就交（对不对由服务器按门上的数核对），这里搬到第 3 根。
      for (final move in hanoiSolution(const HanoiPuzzle(disks: 3, start: [0, 0, 0], target: 2))) {
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.from + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.to + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('C 关过了'), findsOneWidget);
    });

    testWidgets('补条件的那一处写成 ?：八皇后那一行不锁、数回那一格、密码破译那一行的「位置也对」、骑士与无赖那句话的人数', (tester) async {
      Future<void> open(Widget page) async {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: page));
        await tester.pump(const Duration(milliseconds: 500));
      }

      PlayChallenge slotted(String game, Object? puzzle, int at, int modulus) =>
          PlayChallenge(level: _level(_levelJson('c', game: game, inputs: ['a'], gate: {'op': 'sum', 'value': 11}, consume: {'kind': 'slot', 'at': at, 'modulus': modulus, 'offset': 0}, puzzle: puzzle)), name: 'C 关', deadline: DateTime.now().add(const Duration(minutes: 5)), submit: (answer) async => const PlayVerdict(correct: true));
      PlaygroundGame game(String id) => playgroundCatalog.firstWhere((item) => item.id == id);

      final queens = const QueensRules().generate(4, PuzzleTier.normal).puzzle;
      final row = challengeSlots('queens', queens).first.at;
      final given = queens.given.where((column) => column >= 0).length;
      await open(QueensPage(game: game('queens'), store: PlaygroundStore.memory(), challenge: slotted('queens', const QueensRules().encodePuzzle(queens), row, queens.size)));
      expect(find.textContaining('已放 ${given - 1}/'), findsOneWidget);

      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final loop = const LoopRules().generate(4, PuzzleTier.easy).puzzle;
      final cell = challengeSlots('loop', loop).first.at;
      await open(LoopPage(game: game('loop'), store: PlaygroundStore.memory(), challenge: slotted('loop', const LoopRules().encodePuzzle(loop), cell, 4)));
      expect(find.bySemanticsLabel(RegExp('第${cell ~/ loop.width + 1}行第${cell % loop.width + 1}列，数字是问号')), findsOneWidget);

      final cipher = const CipherRules().generate(4, PuzzleTier.easy).puzzle;
      final line = challengeSlots('cipher', cipher).first.at;
      await open(CipherPage(game: game('cipher'), store: PlaygroundStore.memory(), challenge: slotted('cipher', const CipherRules().encodePuzzle(cipher), line, 3)));
      expect(find.text('? 个数字对且位置对，'), findsOneWidget);

      final knights = [for (var seed = 0; seed < 20; seed++) const KnightsRules().generate(seed, PuzzleTier.normal).puzzle].firstWhere((puzzle) => challengeSlots('knights', puzzle).isNotEmpty);
      final speaker = challengeSlots('knights', knights).first.at;
      await open(KnightsPage(game: game('knights'), store: PlaygroundStore.memory(), challenge: slotted('knights', const KnightsRules().encodePuzzle(knights), speaker, knights.people - 1)));
      expect(find.textContaining('? 个骑士'), findsOneWidget);
    });

    // 人工决策见 knights_page.dart 的 _submit：填满即交的判对错类连不上时，提示条带「重交」原样再交；接着改一步提示就收起。
    testWidgets('骑士与无赖作为挑战的一关：定完就交，连不上时提示条的「重交」原样再交；取消一个人的标记提示就收起', (tester) async {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'knights');
      final draw = const KnightsRules().generate(3, PuzzleTier.entry);
      final answers = <String>[];
      var offline = true;
      final navigator = GlobalKey<NavigatorState>();
      final challenge = PlayChallenge(
        level: _run(levels: [_levelJson('a', game: 'knights', puzzle: const KnightsRules().encodePuzzle(draw.puzzle))]).level('a'),
        name: 'A 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) async {
          answers.add(jsonEncode(answer));
          if (offline) throw const ChallengeException(ChallengeFailure.network, '连不上服务器');
          return const PlayVerdict(correct: true);
        },
      );
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const Text('挑战总览')));
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) => KnightsPage(game: game, store: PlaygroundStore.memory(), challenge: challenge))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      Future<void> mark(int person, bool knight) async {
        final chip = find.widgetWithText(CampusGlassChip, knight ? '骑士' : '无赖').at(person);
        await tester.ensureVisible(chip);
        await tester.pump();
        await tester.tap(chip);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      for (final (person, knight) in draw.solution.indexed) {
        await mark(person, knight);
      }
      expect(answers, hasLength(1));
      expect(find.text('没交上，连不上服务器'), findsOneWidget);
      expect(find.text('重交'), findsOneWidget);
      // 再点一下取消第一个人的标记：局面没定完，过时的提示收起、不交。
      await mark(0, draw.solution[0]);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('重交'), findsNothing);
      expect(answers, hasLength(1));
      await mark(0, draw.solution[0]);
      expect(answers, hasLength(2));
      expect(find.text('重交'), findsOneWidget);

      offline = false;
      await tester.tap(find.text('重交'));
      await tester.pump();
      // 判对后卡片依次翻一下再弹结果。
      for (var second = 0; second < 3; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(answers, hasLength(3));
      expect(answers.toSet(), hasLength(1));
      expect(find.text('A 关过了'), findsOneWidget);
    });

    // 服务器给的题面是外部输入：建一关时就按这个游戏的规则解好（对局页直接用、不解第二次），这个版本认不得的不交给对局页。
    test('建一关时就解题面：认不得的游戏、档位、坏题面与不在题面上的 ? 都抛 FormatException', () {
      PlayChallenge make(Map<String, Object?> json) => PlayChallenge(level: _level(json), name: 'C 关', deadline: DateTime.now(), submit: (answer) async => const PlayVerdict(correct: true));
      Map<String, Object?> slotted(int at) => _levelJson('c', game: 'twentyfour', inputs: ['a'], gate: {'op': 'sum', 'value': 11}, consume: {'kind': 'slot', 'at': at, 'modulus': 9, 'offset': 1}, puzzle: {'numbers': [3, 8, 2, 8], 'ops': [0, 1, 2, 3]});
      expect(make(slotted(3)).puzzle, isA<TwentyFourPuzzle>());
      expect(make(_levelJson('a', puzzle: const HanoiRules().encodePuzzle(_hanoi))).puzzle, isA<HanoiPuzzle>());
      expect(() => make(slotted(4)), throwsFormatException);
      expect(() => make(slotted(-1)), throwsFormatException);
      expect(() => make({...slotted(0), 'game': 'hanoi', 'puzzle': const HanoiRules().encodePuzzle(_hanoi)}), throwsFormatException, reason: '汉诺塔不收补条件的碎片');
      expect(() => make(_levelJson('a', game: 'schulte', puzzle: const {'side': 3})), throwsFormatException);
      expect(() => make({..._levelJson('a', puzzle: const HanoiRules().encodePuzzle(_hanoi)), 'tier': 'master'}), throwsFormatException);
      expect(() => make(_levelJson('a', puzzle: const {'start': 'x'})), throwsFormatException);
    });

    // 到点退回挑战那一页：对局页上面开着弹层（玩法、24 点选数、逻辑网格选值）时连弹层一起收掉，不是只关弹层、留在 0:00 的棋盘上。
    testWidgets('到点退回挑战那一页：上面开着弹层也一起收掉；结果弹层开着时只退一层', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final game = playgroundCatalog.firstWhere((game) => game.id == 'hanoi');
      PlayChallenge challenge(Duration left, {Future<PlayVerdict> Function(Object? answer)? submit}) => PlayChallenge(
        level: _run().level('a'),
        name: 'A 关',
        deadline: DateTime.now().add(left),
        submit: submit ?? (answer) async => const PlayVerdict(correct: true, fragment: 7),
      );
      Future<void> open(PlayChallenge challenge) async {
        await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const Text('挑战总览')));
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) => HanoiPage(game: game, store: PlaygroundStore.memory(), challenge: challenge))));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      await open(challenge(const Duration(milliseconds: 1500)));
      await tester.tap(find.bySemanticsLabel('玩法'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(game.howToPlay), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1600)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(HanoiPage), findsNothing);
      expect(find.text('挑战总览'), findsOneWidget);

      // 走完交上去、结果弹层等着服务器时到点：退回挑战那一页，不多退一层。
      final reply = Completer<PlayVerdict>();
      await open(challenge(const Duration(milliseconds: 1500), submit: (answer) => reply.future));
      for (final move in hanoiSolution(_hanoi)) {
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.from + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tapAt(tester.getCenter(find.bySemanticsLabel(RegExp('^第${move.to + 1}根柱子'))));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('正在交给服务器核对'), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1600)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(HanoiPage), findsNothing);
      expect(find.text('挑战总览'), findsOneWidget);
      reply.complete(const PlayVerdict(correct: false, over: true));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('挑战总览'), findsOneWidget);
    });

    // 挑战到点时对局页会自己退回；等着服务器判定或结算局面时页面关了，回来的结果不再通知已经关掉的会话与控制器。
    test('等服务器回复时对局页或总览关了：回复回来不再通知、不报错', () async {
      final draw = const KnightsRules().generate(3, PuzzleTier.entry);
      final reply = Completer<PlayVerdict>();
      final challenge = PlayChallenge(
        level: _run(levels: [_levelJson('a', game: 'knights', puzzle: const KnightsRules().encodePuzzle(draw.puzzle))]).level('a'),
        name: 'A 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) => reply.future,
      );
      final session = PlaySession(game: playgroundCatalog.firstWhere((game) => game.id == 'knights'), rules: const KnightsRules(), store: PlaygroundStore.memory(), challenge: challenge);
      final judged = session.judge(draw.solution);
      session.dispose();
      reply.complete(const PlayVerdict(correct: true));
      expect(await judged, isTrue);

      final hub = _SlowHub();
      final controller = ChallengeRunController(hub: hub, run: _run());
      final refreshing = controller.refresh();
      controller.dispose();
      hub.runs.single.complete(_run(running: false, result: {'points': 13, 'awarded': 13, 'ending': 'timeout'}));
      expect(await refreshing, isNull);
      expect(controller.run.running, isFalse);
    });
  });

  group('挑战页面', () {
    testWidgets('这个版本认不得的一关：点了不进，提示更新应用', (tester) async {
      final run = _run(levels: [_levelJson('a', puzzle: const {'start': 'x'})]);
      final controller = ChallengeRunController(hub: _Hub(), run: run);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.bySemanticsLabel('A 关，汉诺塔，入门，进入'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(HanoiPage), findsNothing);
      expect(find.text('这一关的题看不懂，请更新应用后再试'), findsOneWidget);
    });

    // 到点拉一次局面让服务器结算；没拉到（断网）不逐帧重拉（以前每一帧都再发一次，断网时一秒几十个请求），回到前台再拉。
    testWidgets('到点只拉一次局面，没拉到等回到前台再拉；倒计时不逐帧出帧', (tester) async {
      final hub = _SlowHub();
      final base = _run();
      final now = DateTime.now().toUtc();
      final run = ChallengeRun(
        runId: base.runId, challengeId: base.challengeId, title: base.title, label: base.label, timeLimit: base.timeLimit,
        startedAt: now.subtract(base.timeLimit), deadline: now.subtract(const Duration(seconds: 1)), serverTime: now,
        running: true, penalty: Duration.zero, ending: base.ending, levels: base.levels, result: null,
      );
      final controller = ChallengeRunController(hub: hub, run: run);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump();
      expect(hub.runs, hasLength(1));
      hub.runs.single.completeError(const ChallengeException(ChallengeFailure.network, '连不上服务器'));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(hub.runs, hasLength(1), reason: '断网时不逐帧重拉');
      expect(find.text('还有 0:00'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(hub.runs, hasLength(2));
      hub.runs.last.complete(_run(running: false, result: {'points': 13, 'awarded': 13, 'ending': 'timeout'}));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('时间到了'), findsOneWidget);
    });

    // 登录状态变了、下拉刷新或从一局回来都会再读；先发的晚回来不盖掉后来的（换了应用账号不显示上一个账号的挑战）。
    testWidgets('挑战一栏只认最近一次读：退出登录前发出的读晚回来，不显示给后来登录的账号', (tester) async {
      final hub = _SlowHub()..signedIn = true;
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PlaygroundPage(store: PlaygroundStore.memory(), games: playgroundCatalog, groups: playgroundGroups, challenges: hub, openAccount: (_) {})));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pump();
      expect(hub.catalogs, hasLength(1));
      hub.signedIn = false;
      hub.emit();
      await tester.pump();
      expect(find.text('挑战要先登录'), findsOneWidget);
      hub.catalogs.single.complete(ChallengeCatalog(serverTime: DateTime.utc(2026, 11, 14), activeRun: null, challenges: [
        ChallengeSummary(id: 'old', title: '上一个账号的挑战', label: '入门', levels: 1, tiers: const ['entry'], edges: const [], timeLimit: const Duration(minutes: 5), endsAt: DateTime.now().add(const Duration(days: 2)), best: null, playable: true, ticket: 0),
      ]));
      await tester.pump();
      hub.signedIn = true;
      hub.emit();
      await tester.pump();
      expect(find.textContaining('上一个账号的挑战'), findsNothing);
      expect(find.text('正在读本周的挑战'), findsOneWidget);
    });

    testWidgets('总览是关卡流程图：给碎片的关并排、箭头写门上的数怎么来、下面是门后那一关；门前的点了输门上的数（错了扣时间），终章全部碎片相加；笔记存本机；结算后换成成绩', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.reset);
      final hub = _Hub();
      final store = PlaygroundStore.memory();
      final controller = ChallengeRunController(hub: hub, run: _run());
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: store)));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('已过 1/3 关'), findsOneWidget);
      expect(find.bySemanticsLabel('A 关，汉诺塔，入门，进入'), findsOneWidget);
      expect(find.bySemanticsLabel('B 关，冰面滑行，入门，过了'), findsOneWidget);
      expect(find.bySemanticsLabel('C 关，24 点，入门，开门'), findsOneWidget);
      expect(find.text('A × B'), findsOneWidget);
      expect(find.text('全部碎片相加'), findsOneWidget);

      // 门：输错扣 20 秒、原地清空再输；输对关掉、提示门开了，箭头写出门上的数。
      hub.entries = [false, true];
      await tester.tap(find.bySemanticsLabel('C 关，24 点，入门，开门'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('C 关的门'), findsOneWidget);
      Future<void> key(String label) async {
        await tester.tap(find.widgetWithText(FilledButton, label));
        await tester.pump();
      }

      await key('1');
      await key('8');
      await tester.tap(find.bySemanticsLabel('确认'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('不对 · 扣 20 秒'), findsOneWidget);
      expect(find.textContaining('罚时 20 秒'), findsOneWidget);
      await key('1');
      await key('8');
      await tester.tap(find.bySemanticsLabel('确认'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(hub.entered, [('c', 18), ('c', 18)]);
      expect(find.text('C 关的门'), findsNothing);
      expect(find.text('门开了'), findsOneWidget);
      expect(find.text('A × B = 18'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'A = 3');
      await tester.pump(const Duration(seconds: 1));
      expect(store.notesOf(_runId), 'A = 3');

      hub.ended = _run(running: false, result: {'points': 13, 'awarded': 0, 'ending': 'ended'});
      await tester.tap(find.bySemanticsLabel('更多操作'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('提前结束'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('结束'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('这一局结束了'), findsOneWidget);
      expect(find.text('13 分'), findsOneWidget);
      expect(find.textContaining('未超过最好成绩'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    test('流程图分段：收碎片的关紧接着给下一段碎片时只画一次（排进下一段第一个、箭头对准它），隔段用到的只在箭头上写字母', () {
      // 六连环：A、B → C；C、D → E；E → F。
      final six = _run(levels: [
        _levelJson('a', output: 'c'),
        _levelJson('b', output: 'c'),
        _levelJson('c', state: 'gated', inputs: ['a', 'b'], output: 'e', gate: {'op': 'sum', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
        _levelJson('d', output: 'e'),
        _levelJson('e', state: 'locked', inputs: ['c', 'd'], output: 'f', gate: {'op': 'sum', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
        _levelJson('f', state: 'locked', inputs: ['e'], gate: {'op': 'sum', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
      ]);
      String shape(List<ChallengeSection> sections) => [
        for (final section in sections)
          '${section.inputs.map((level) => level.letter).join()}>${section.sources.map((level) => level.letter).join('+')}>${section.consumer?.letter}${section.carried ? '^' : ''}${section.aim ? '*' : ''}',
      ].join(' ');
      expect(shape(challengeSections(six)), 'AB>A+B>C^* CD>C+D>E^ E>E>F');
      // 十连环的前半：A、B → E；C、D → F；E、F、I → G。E 隔一段才用到：照样画在自己那段，G 那段只画 F 与 I。
      final ten = _run(levels: [
        _levelJson('a', output: 'e'),
        _levelJson('b', output: 'e'),
        _levelJson('c', output: 'f'),
        _levelJson('d', output: 'f'),
        _levelJson('e', state: 'locked', inputs: ['a', 'b'], output: 'g', gate: {'op': 'sum', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
        _levelJson('f', state: 'locked', inputs: ['c', 'd'], output: 'g', gate: {'op': 'sum', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
        _levelJson('g', state: 'locked', inputs: ['e', 'f', 'i'], gate: {'op': 'product', 'value': null}, consume: {'kind': 'goal', 'at': 0, 'modulus': 3, 'offset': 1}),
        _levelJson('i', output: 'g'),
      ]);
      expect(shape(challengeSections(ten)), 'AB>A+B>E CD>C+D>F^* FI>E+F+I>G');
    });

    testWidgets('终章：全部过了才能点，输全部碎片之和；加试题排在终章前', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.reset);
      final hub = _Hub();
      final controller = ChallengeRunController(hub: hub, run: _run(ending: ChallengeFinal.ready, levels: [
        _levelJson('a', output: 'c', state: 'solved'),
        _levelJson('b', game: 'ice', output: 'c', state: 'solved'),
        _levelJson('c', game: 'twentyfour', state: 'solved', inputs: ['a', 'b'], gate: {'op': 'sum', 'value': 9}, consume: {'kind': 'slot', 'at': 2, 'modulus': 9, 'offset': 1}),
        _levelJson('xa', state: 'solved', extraOf: 'a'),
      ]));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('加试'), findsOneWidget);
      expect(find.bySemanticsLabel('加试，汉诺塔，入门，过了'), findsOneWidget);
      hub.entries = [true];
      await tester.tap(find.text('终章'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('全部碎片相加'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(FilledButton, '4'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '0'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('确认'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(hub.entered, [('final', 40)]);
    });

    testWidgets('积分页：余额、30 天内到期的提示、明细从新到旧，按需往下翻', (tester) async {
      final hub = _Hub()
        ..summary = PointsSummary(balance: 236, expiring: 50, expiringAt: DateTime.now().toUtc().add(const Duration(days: 3)), earned: 1200, level: 1, nextLevelAt: 3000)
        ..batches = [
          PointsBatch(entries: [PointsEntry(id: '9', kind: 'earn', amount: 186, note: '普通 · 八连环', at: DateTime.now().toUtc())], next: '9'),
          PointsBatch(entries: [PointsEntry(id: '3', kind: 'expire', amount: -20, note: '积分到期', at: DateTime.now().toUtc().subtract(const Duration(days: 2)))], next: null),
        ];
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PointsPage(hub: hub)));
      await tester.pumpAndSettle();
      expect(find.text('236'), findsOneWidget);
      expect(find.textContaining('30 天内 50 分到期'), findsOneWidget);
      expect(find.text('Lv1'), findsOneWidget);
      expect(find.text('离 Lv2 还差 1800 分'), findsOneWidget);
      expect(find.text('普通 · 八连环'), findsOneWidget);
      expect(find.text('+186'), findsOneWidget);
      await tester.tap(find.text('更早的'));
      await tester.pumpAndSettle();
      expect(hub.before, ['9']);
      expect(find.text('-20'), findsOneWidget);
      expect(find.text('更早的'), findsNothing);
    });

    testWidgets('积分页的等级：最高级写「最高等级」；服务器还没配门槛时不显示等级', (tester) async {
      final hub = _Hub()..summary = const PointsSummary(balance: 10, expiring: 0, expiringAt: null, earned: 90000, level: 5, nextLevelAt: null);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PointsPage(hub: hub)));
      await tester.pumpAndSettle();
      expect(find.text('Lv5'), findsOneWidget);
      expect(find.text('最高等级'), findsOneWidget);
      hub.summary = const PointsSummary(balance: 10, expiring: 0, expiringAt: null, earned: 90000, level: 0, nextLevelAt: null);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PointsPage(key: UniqueKey(), hub: hub)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Lv'), findsNothing);
      expect(find.text('最高等级'), findsNothing);
    });

    testWidgets('要门票的挑战：卡上写门票；积分不够不给开始；够了开始前写明开局扣、过没过都不退', (tester) async {
      final hub = _Hub()
        ..signedIn = true
        ..ticket = 300
        ..summary = const PointsSummary(balance: 86, expiring: 0, expiringAt: null, earned: 620, level: 1, nextLevelAt: 3000);
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: PlaygroundPage(store: PlaygroundStore.memory(), games: playgroundCatalog, groups: playgroundGroups, challenges: hub, openAccount: (_) {}),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pumpAndSettle();
      expect(find.text('积分 86 · Lv1'), findsOneWidget);
      expect(find.text('加赛 · 十二连环'), findsOneWidget);
      expect(_line('12 关 · 限时 60 分钟 · 门票 300 分 · 还剩 2 天'), findsOneWidget);
      expect(find.text('积分不够付门票'), findsOneWidget);
      expect(find.text('开始'), findsOneWidget);

      hub.summary = const PointsSummary(balance: 500, expiring: 0, expiringAt: null, earned: 620, level: 1, nextLevelAt: 3000);
      hub.emit();
      await tester.pumpAndSettle();
      expect(find.text('积分不够付门票'), findsNothing);
      await tester.tap(find.text('开始').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('门票 300 积分，不退'), findsOneWidget);
      await tester.tap(find.text('开始').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(hub.started, ['bonus.2026-11-09.bonus']);
    });

    testWidgets('游乐场首页：配了挑战才有「自由 | 挑战」；没登录应用账号引导去登录；登录后列本周挑战，开始前写明计时规则', (tester) async {
      final hub = _Hub();
      final store = PlaygroundStore.memory();
      var accountOpened = 0;
      Widget page(ChallengeHub? challenges) => MaterialApp(
        theme: campusTheme(),
        home: PlaygroundPage(store: store, games: playgroundCatalog, groups: playgroundGroups, challenges: challenges, openAccount: (_) => accountOpened++),
      );
      await tester.pumpWidget(page(null));
      await tester.pumpAndSettle();
      expect(find.text('挑战'), findsNothing);

      await tester.pumpWidget(page(hub));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pumpAndSettle();
      expect(find.text('挑战要先登录'), findsOneWidget);
      await tester.tap(find.text('登录应用账号'));
      expect(accountOpened, 1);

      hub.signedIn = true;
      hub.emit();
      await tester.pumpAndSettle();
      expect(find.text('积分 86'), findsOneWidget);
      expect(find.text('入门 · 六连环'), findsOneWidget);
      expect(_line('6 关 · 限时 15 分钟 · 还剩 2 天'), findsOneWidget);
      expect(hub.games, {for (final game in playgroundCatalog) if (game.challengeable) '${game.id}@1'}, reason: '报给服务器的是「游戏@题面写法版本」');
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();
      expect(find.textContaining('计时不暂停'), findsOneWidget);
      await tester.tap(find.text('开始').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(hub.started, ['weekly.2026-11-09.six']);
      expect(find.byType(ChallengeRunPage), findsOneWidget);
      expect(find.byType(ChallengeHome), findsNothing);
    });

    // 11-14 模拟器走查（1.3 倍字号）：挑战卡说明行折出孤字「天」。说明行按「 · 」分项放进 Wrap，放得下一行的一项不拆开。
    testWidgets('窄屏大字号：挑战卡的说明行按项换行、总览的门与收碎片的关的算式不拆开、不留孤字', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await loadCampusFonts(tester);
      List<String> problems() => [for (final issue in scanTexts(tester)) if (issue.kind != 'truncate') '$issue'];
      // 含这段文字的那一段只排成一行（同 scanTexts 的口径：不到 1.8 倍字号高算一行）。
      RenderParagraph paragraphOf(String phrase) => tester.renderObject<RenderParagraph>(find.byWidgetPredicate((widget) => widget is RichText && widget.text.toPlainText().contains(phrase)).first);
      void oneLine(String phrase) {
        final paragraph = paragraphOf(phrase);
        expect(paragraph.size.height, lessThan(paragraph.textScaler.scale(14) * 1.8), reason: '「$phrase」拆到了两行：${paragraph.text.toPlainText()}');
      }

      final hub = _Hub()
        ..signedIn = true
        ..best = 234;
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: PlaygroundPage(store: PlaygroundStore.memory(), games: playgroundCatalog, groups: playgroundGroups, challenges: hub, openAccount: (_) {}),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pumpAndSettle();
      for (final phrase in ['6 关', '限时 15 分钟', '最好 234 分', '还剩 2 天']) {
        oneLine(phrase);
      }
      expect(problems(), isEmpty, reason: '挑战一栏');

      final controller = ChallengeRunController(hub: hub, run: _run(levels: [
        _levelJson('a', output: 'd', puzzle: const HanoiRules().encodePuzzle(_hanoi)),
        _levelJson('b', game: 'ice', output: 'd', state: 'solved'),
        _levelJson('c', game: 'logicgrid', output: 'd', state: 'solved'),
        _levelJson('d', game: 'queens', state: 'gated', inputs: ['a', 'b', 'c'], gate: {'op': 'sum', 'value': null}, consume: {'kind': 'slot', 'at': 0, 'modulus': 8, 'offset': 1}),
      ]));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      oneLine('A + B + C');
      expect(problems(), isEmpty, reason: '总览');
      controller.dispose();

      // 数回 5×5，第 4 行第 3 格是门上的数改写的（题面取自走查那一局）。
      const puzzle = {'width': 5, 'height': 5, 'clues': [-1, 2, -1, -1, 3, -1, 2, 1, -1, -1, -1, 1, 1, 2, -1, 2, 0, 1, 3, 1, -1, -1, -1, -1, 0]};
      final level = _level(_levelJson('c', game: 'loop', inputs: ['a', 'b'], gate: {'op': 'product', 'value': 21}, consume: {'kind': 'slot', 'at': 17, 'modulus': 4, 'offset': 0}, puzzle: puzzle));
      final challenge = PlayChallenge(level: level, name: 'C 关', deadline: DateTime.now().add(const Duration(minutes: 5)), submit: (answer) async => const PlayVerdict(correct: true, fragment: 10));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: LoopPage(game: playgroundCatalog.firstWhere((game) => game.id == 'loop'), store: PlaygroundStore.memory(), challenge: challenge)));
      await tester.pump(const Duration(milliseconds: 500));
      oneLine('= 21 ÷ 4 的余数');
      expect(problems(), isEmpty, reason: '收碎片的关');
    });
  });
}

class _Request {
  _Request(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class _Relay implements RelayTransport {
  final requests = <_Request>[];
  RelayResponse Function(_Request request) reply = (request) => const RelayResponse(204, {});
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    final request = _Request(method, pathWithQuery, headers, body == null ? const {} : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>());
    requests.add(request);
    return reply(request);
  }
}

class _Hub implements ChallengeHub {
  final _controller = StreamController<void>.broadcast();
  @override
  bool signedIn = false;
  int? best;
  // 大于 0 时另列一场要这么多门票的加赛。
  int ticket = 0;
  Set<String>? games;
  final started = <String>[];
  ChallengeRun? ended;

  void emit() => _controller.add(null);

  @override
  Stream<void> get changes => _controller.stream;
  @override
  Future<ChallengeCatalog> catalog(Set<String> games) async {
    this.games = games;
    return ChallengeCatalog(serverTime: DateTime.utc(2026, 11, 14), activeRun: null, challenges: [
      ChallengeSummary(
        id: 'weekly.2026-11-09.six', title: '六连环', label: '入门', levels: 6, tiers: const ['entry', 'entry', 'easy', 'easy', 'normal', 'normal'], edges: const [(0, 2), (1, 2), (2, 4), (3, 4), (4, 5)],
        timeLimit: const Duration(minutes: 15), endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)), best: best, playable: true, ticket: 0,
      ),
      if (ticket > 0)
        ChallengeSummary(
          id: 'bonus.2026-11-09.bonus', title: '十二连环', label: '加赛', levels: 12, tiers: List.filled(12, 'hard'), edges: [for (var index = 0; index < 11; index++) (index, index + 1)],
          timeLimit: const Duration(minutes: 60), endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)), best: null, playable: true, ticket: ticket,
        ),
    ]);
  }

  @override
  Future<ChallengeRun> start(String challengeId, Set<String> games) async {
    started.add(challengeId);
    return _run();
  }

  @override
  Future<ChallengeRun> run(String runId) async => _run();
  @override
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer) async => ChallengeVerdict(correct: true, fragment: 7, extra: null, run: _run());
  // 开门与终章依次给的对错；输错的那次带 20 秒罚时、门还关着，输对的那次门开了（门上的数写进局面）。
  List<bool> entries = const [];
  final entered = <(String, int)>[];
  ChallengeEntry _enter(String id, int value) {
    final correct = entries[entered.length];
    entered.add((id, value));
    final levels = [
      _levelJson('a', output: 'c', puzzle: const HanoiRules().encodePuzzle(_hanoi)),
      _levelJson('b', game: 'ice', output: 'c', state: 'solved'),
      _levelJson('c', game: 'twentyfour', state: correct ? 'open' : 'gated', inputs: ['a', 'b'], gate: {'op': 'product', 'value': correct ? value : null}, consume: {'kind': 'slot', 'at': 2, 'modulus': 9, 'offset': 1}, puzzle: correct ? {'numbers': [3, 8, 2, 8], 'ops': [0, 1, 2, 3]} : null),
    ];
    return ChallengeEntry(correct: correct, run: _run(levels: levels, penalty: entries.take(entered.length).where((item) => !item).length * 20));
  }

  @override
  Future<ChallengeEntry> gate(String runId, String levelId, int value) async => _enter(levelId, value);
  @override
  Future<ChallengeEntry> finale(String runId, int value) async => _enter('final', value);
  @override
  Future<ChallengeRun> end(String runId) async => ended!;
  PointsSummary summary = const PointsSummary(balance: 86, expiring: 0, expiringAt: null, earned: 0, level: 0, nextLevelAt: null);
  List<PointsBatch> batches = const [PointsBatch(entries: [], next: null)];
  final before = <String?>[];
  @override
  Future<PointsSummary> points() async => summary;
  @override
  Future<PointsBatch> pointsEntries({String? before}) async {
    if (before != null) this.before.add(before);
    return before == null ? batches.first : batches.last;
  }
}

// 读本周挑战与拉局面都等测试来回复（看先发后到与断网时的重拉）。
class _SlowHub extends _Hub {
  final catalogs = <Completer<ChallengeCatalog>>[];
  final runs = <Completer<ChallengeRun>>[];

  @override
  Future<ChallengeCatalog> catalog(Set<String> games) {
    final reply = Completer<ChallengeCatalog>();
    catalogs.add(reply);
    return reply.future;
  }

  @override
  Future<ChallengeRun> run(String runId) {
    final reply = Completer<ChallengeRun>();
    runs.add(reply);
    return reply.future;
  }
}

class _Client implements ChallengeClient {
  final calls = <String>[];
  ChallengeException? failure;

  Future<T> _call<T>(String name, T value) async {
    calls.add(name);
    if (failure case final error?) throw error;
    return value;
  }

  @override
  Future<ChallengeCatalog> catalog(AppAccountRef account, Set<String> games) => _call('catalog', ChallengeCatalog(serverTime: DateTime.utc(2026), activeRun: null, challenges: const []));
  @override
  Future<ChallengeRun> start(AppAccountRef account, String challengeId, Set<String> games) => _call('start', _run());
  @override
  Future<ChallengeRun> run(AppAccountRef account, String runId) => _call('run', _run());
  @override
  Future<ChallengeVerdict> answer(AppAccountRef account, String runId, String levelId, int attempt, Object? answer) => _call('answer', ChallengeVerdict(correct: true, fragment: null, extra: null, run: _run()));
  @override
  Future<ChallengeEntry> gate(AppAccountRef account, String runId, String levelId, int value) => _call('gate', ChallengeEntry(correct: true, run: _run()));
  @override
  Future<ChallengeEntry> finale(AppAccountRef account, String runId, int value) => _call('final', ChallengeEntry(correct: true, run: _run()));
  @override
  Future<ChallengeRun> end(AppAccountRef account, String runId) => _call('end', _run());
  @override
  Future<PointsSummary> points(AppAccountRef account) => _call('points', const PointsSummary(balance: 0, expiring: 0, expiringAt: null, earned: 0, level: 0, nextLevelAt: null));
  @override
  Future<PointsBatch> pointsEntries(AppAccountRef account, {String? before}) => _call('entries', const PointsBatch(entries: [], next: null));
  @override
  Future<void> deleteData(AppAccountRef account) => _call('delete', null);
}

class _AppClient implements AppAccountClient {
  String? accountId;
  var summaries = 0;
  var lost = false;
  @override
  Future<AppAccountSession?> accountOf() async => accountId == null ? null : AppAccountSession(account: AppAccountRef(accountId: accountId!, slot: 'fake-slot'), username: 'tester');
  @override
  Future<List<AppAccountRef>> dropLegacy() async => const [];
  @override
  Future<AppAccountSummary> summary() async {
    summaries++;
    if (lost) throw const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
    return AppAccountSummary(accountId: accountId!, username: 'tester', deviceCount: 1, createdAt: DateTime.utc(2026));
  }
  @override
  Future<void> signOut() async {}
  // 编排测试用不到的几项交给 noSuchMethod。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

