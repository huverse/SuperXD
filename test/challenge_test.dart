import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/challenges.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/gateway/account_access.dart';
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
const _identity = AccountIdentity(source: 'http://school.example', loginId: '20260000001');
const _runId = 'RRRRRRRRRRRRRRRRRRRRRR';
// 中转客户端用例里登录着的应用账号：密钥存在这个教务身份算出的 slot。
final _ref = AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: appAccountSlot(_identity));
final _hanoi = const HanoiRules().generate(1, PuzzleTier.entry).puzzle;

Map<String, Object?> _levelJson(String id, {String game = 'hanoi', String state = 'open', List<String> inputs = const [], String? output, int submissions = 0, int? key, String? teaser, Object? puzzle, List<Object?> keyed = const []}) => {
  'id': id,
  'game': game,
  'tier': 'entry',
  'difficulty': 2,
  'inputs': inputs,
  'output': output,
  'state': state,
  'submissions': submissions,
  'errors': 0,
  'key': key,
  'teaser': teaser,
  'puzzle': puzzle,
  'keyed': keyed,
};

Map<String, Object?> _runJson({bool running = true, List<Map<String, Object?>>? levels, Map<String, Object?>? result, int serverTime = 1000000}) => {
  'runId': _runId,
  'challengeId': 'weekly.2026-11-09.trio',
  'title': '三连环',
  'label': '入门',
  'timeLimit': 600,
  'startedAt': serverTime,
  'deadline': serverTime + 600000,
  'serverTime': serverTime,
  'state': running ? 'running' : 'settled',
  'levels': levels ??
      [
        _levelJson('a', output: 'c', puzzle: const HanoiRules().encodePuzzle(_hanoi)),
        _levelJson('b', game: 'ice', output: 'c', puzzle: null, state: 'solved', key: 8),
        _levelJson('c', game: 'twentyfour', state: 'locked', inputs: ['a', 'b'], teaser: '四张牌：? 8 3 ?'),
      ],
  'result': result,
};

// 同一份局面直接建成领域对象（页面与编排的测试用；中转客户端的解码在「中转客户端」一组里测）。
ChallengeLevel _level(Map<String, Object?> json) => ChallengeLevel(
  id: json['id']! as String,
  game: json['game']! as String,
  tier: json['tier']! as String,
  difficulty: json['difficulty']! as int,
  inputs: (json['inputs']! as List).cast<String>(),
  output: json['output'] as String?,
  state: ChallengeLevelState.values.byName(json['state']! as String),
  submissions: json['submissions']! as int,
  errors: json['errors']! as int,
  key: json['key'] as int?,
  teaser: json['teaser'] as String?,
  puzzle: json['puzzle'],
  keyed: const [],
);

// 「甲 · 乙」说明行分项排在 Wrap 里，整句在读屏标签上。
Finder _line(String text) => find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == text);

ChallengeRun _run({bool running = true, List<Map<String, Object?>>? levels, Map<String, Object?>? result}) {
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
      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => const RelayResponse(200, {
        'serverTime': 1000,
        'activeRun': null,
        'challenges': [
          {'id': 'weekly.2026-11-09.six', 'title': '六连环', 'label': '入门', 'levels': 6, 'timeLimit': 900, 'endsAt': 2000, 'best': 153, 'playable': true},
        ],
      });
      final catalog = await client.catalog(_ref, {'ice', 'hanoi'});
      expect(relay.requests.single.path, '/v1/challenges?games=hanoi,ice');
      expect(relay.requests.single.headers['x-sxd-device'], key.deviceId);
      expect(catalog.challenges.single, isA<ChallengeSummary>().having((item) => item.best, 'best', 153).having((item) => item.timeLimit, 'timeLimit', const Duration(minutes: 15)));
    });

    test('一局的局面、交答案带号码、积分与流水按协议解码；看不懂的回复报失败', () async {
      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => RelayResponse(200, {'correct': true, 'key': 7, 'run': _runJson()});
      final verdict = await client.answer(_ref, _runId, 'a', 2, [1, 2]);
      expect(relay.requests.last.path, '/v1/challenge-runs/$_runId/levels/a/answers');
      expect(relay.requests.last.body, {'attempt': 2, 'answer': [1, 2]});
      expect(verdict.correct, isTrue);
      expect(verdict.key, 7);
      expect(verdict.run.level('c'), isA<ChallengeLevel>().having((level) => level.state, 'state', ChallengeLevelState.locked).having((level) => level.teaser, 'teaser', '四张牌：? 8 3 ?'));
      relay.reply = (request) => const RelayResponse(200, {'balance': 86, 'expiring': 20, 'expiringAt': 5000, 'serverTime': 1});
      expect((await client.points(_ref)).expiringAt, DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true));
      relay.reply = (request) => const RelayResponse(200, {'entries': [{'id': '9', 'kind': 'earn', 'amount': 86, 'note': '入门 · 三连环', 'at': 1}], 'next': '9'});
      final batch = await client.pointsEntries(_ref, before: '12');
      expect(relay.requests.last.path, '/v1/points/entries?before=12');
      expect(batch.next, '9');
      relay.reply = (request) => const RelayResponse(200, {'correct': 'yes'});
      await expectLater(client.answer(_ref, _runId, 'a', 0, []), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.failed)));
    });

    test('错误码换成挑战的失败：还有一局带编号、已结束带局面、应用账号不在了', () async {
      await vault.write(appAccountSlot(_identity), AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = (request) => const RelayResponse(409, {'code': 'RUN_ACTIVE', 'runId': _runId});
      await expectLater(client.start(_ref, 'weekly.2026-11-09.six', {'hanoi'}), throwsA(isA<ChallengeException>().having((error) => error.runId, 'runId', _runId)));
      relay.reply = (request) => RelayResponse(409, {'code': 'RUN_OVER', 'run': _runJson(running: false, result: {'points': 13, 'awarded': 13, 'ending': 'timeout'})});
      await expectLater(client.answer(_ref, _runId, 'a', 0, []), throwsA(isA<ChallengeException>().having((error) => error.run?.result?.ending, 'ending', 'timeout')));
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.points(_ref), throwsA(isA<ChallengeException>().having((error) => error.failure, 'failure', ChallengeFailure.notSignedIn)));
    });
  });

  group('编排', () {
    test('没登录应用账号直接报未登录；中转说应用账号不在了就马上核一次，本机退回未登录并通知页面', () async {
      final accounts = _Accounts()..identity = _identity;
      final appClient = _AppClient();
      final appAccounts = AppAccounts(accounts: accounts, client: appClient);
      await appAccounts.load();
      final client = _Client();
      final challenges = Challenges(accounts: accounts, appAccounts: appAccounts, client: client);
      final changes = <void>[];
      final subscription = challenges.changes.listen(changes.add);
      expect(challenges.signedIn, isFalse);
      await expectLater(challenges.points(), throwsA(isA<ChallengeException>()));
      expect(client.calls, isEmpty);

      appClient.records[_identity.loginId] = 'AAAAAAAAAAAAAAAAAAAAAA';
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
        name: '第 1 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) async {
          answers.add(answer);
          if (offline) throw const ChallengeException(ChallengeFailure.network, '连不上服务器');
          return PlayVerdict(correct: jsonEncode(answer) == jsonEncode(const KnightsRules().encodeAnswer(draw.solution)), key: 5);
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
      expect((await session.submission!).key, 5);
      expect(answers, hasLength(3));
      expect(store.best('knights', PuzzleTier.entry), isNull);
    });

    testWidgets('汉诺塔作为挑战的一关：写关名与剩下的时间、不能换题换档；走完交服务器，弹层写拿到的钥匙，回到挑战', (tester) async {
      final store = PlaygroundStore.memory();
      final game = playgroundCatalog.firstWhere((game) => game.id == 'hanoi');
      final answers = <Object?>[];
      final navigator = GlobalKey<NavigatorState>();
      final challenge = PlayChallenge(
        level: _run().level('a'),
        name: '第 1 关',
        target: '第 3 关',
        deadline: DateTime.now().add(const Duration(minutes: 5)),
        submit: (answer) async {
          answers.add(answer);
          return const PlayVerdict(correct: true, key: 7);
        },
      );
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const Text('挑战总览')));
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (context) => HanoiPage(game: game, store: store, challenge: challenge))));
      // 推入的页先离屏建一帧（给 Hero 量位置），再推进转场。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('第 1 关 · 入门'), findsOneWidget);
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
      expect(find.text('第 1 关过了'), findsOneWidget);
      expect(find.textContaining('拿到钥匙 7，交给第 3 关'), findsOneWidget);
      expect(store.best('hanoi', PuzzleTier.entry), isNull);
      await tester.tap(find.text('回到挑战'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('挑战总览'), findsOneWidget);
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
        name: '第 1 关',
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
      expect(find.text('第 1 关过了'), findsOneWidget);
    });
  });

  group('挑战页面', () {
    testWidgets('总览：开着的能点、锁着的写预告与在等谁的钥匙、过了的写钥匙交给哪一关；结算后换成成绩与加了多少积分', (tester) async {
      final hub = _Hub();
      final controller = ChallengeRunController(hub: hub, run: _run());
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('已过 1/3 关'), findsOneWidget);
      expect(find.text('第 1 关 · 汉诺塔'), findsOneWidget);
      expect(_line('入门 · 可以做'), findsOneWidget);
      expect(_line('入门 · 过了 · 钥匙 8 交给第 3 关'), findsOneWidget);
      expect(_line('入门 · 等第 1、2 关的钥匙'), findsOneWidget);
      expect(find.text('四张牌：? 8 3 ?'), findsOneWidget);

      hub.ended = _run(running: false, result: {'points': 13, 'awarded': 0, 'ending': 'ended'});
      await tester.tap(find.bySemanticsLabel('更多操作'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('提前结束'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('结束'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('这一局结束了'), findsOneWidget);
      expect(find.text('13 分'), findsOneWidget);
      expect(find.textContaining('没超过这个挑战的最好成绩，不加积分'), findsOneWidget);
    });

    testWidgets('积分页：余额、30 天内到期的提示、明细从新到旧，按需往下翻', (tester) async {
      final hub = _Hub()
        ..summary = PointsSummary(balance: 236, expiring: 50, expiringAt: DateTime.now().toUtc().add(const Duration(days: 3)))
        ..batches = [
          PointsBatch(entries: [PointsEntry(id: '9', kind: 'earn', amount: 186, note: '普通 · 八连环', at: DateTime.now().toUtc())], next: '9'),
          PointsBatch(entries: [PointsEntry(id: '3', kind: 'expire', amount: -20, note: '积分到期', at: DateTime.now().toUtc().subtract(const Duration(days: 2)))], next: null),
        ];
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PointsPage(hub: hub)));
      await tester.pumpAndSettle();
      expect(find.text('236'), findsOneWidget);
      expect(find.textContaining('30 天内有 50 分到期'), findsOneWidget);
      expect(find.text('普通 · 八连环'), findsOneWidget);
      expect(find.text('+186'), findsOneWidget);
      await tester.tap(find.text('更早的'));
      await tester.pumpAndSettle();
      expect(hub.before, ['9']);
      expect(find.text('-20'), findsOneWidget);
      expect(find.text('更早的'), findsNothing);
    });

    testWidgets('游乐场首页：配了挑战才有「自由 | 挑战」；没登录应用账号引导去登录；登录后列本周挑战，开始前写明计时规则', (tester) async {
      final hub = _Hub();
      final store = PlaygroundStore.memory();
      var accountOpened = 0;
      Widget page(ChallengeHub? challenges) => MaterialApp(
        theme: campusTheme(),
        home: PlaygroundPage(store: store, games: playgroundCatalog, groups: playgroundGroups, challenges: challenges, openAccount: (_) => accountOpened++, openLogin: (_) {}),
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
      expect(hub.games, {for (final game in playgroundCatalog) if (game.challengeable) game.id});
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();
      expect(find.textContaining('切到后台、来电话也照走'), findsOneWidget);
      await tester.tap(find.text('开始').last);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(hub.started, ['weekly.2026-11-09.six']);
      expect(find.byType(ChallengeRunPage), findsOneWidget);
      expect(find.byType(ChallengeHome), findsNothing);
    });

    // 11-14 模拟器走查（1.3 倍字号）：挑战卡说明行折出孤字「天」、总览把「交给第 / 4 关」拆开，预告与钥匙行把「第 ? / 列」「第 5 格 / 是 3」拆到两行。
    // 说明行按「 · 」分项、预告与钥匙按「，」分句放进 Wrap，放得下一行的一项不拆开；一句本身比一行长时自成一段、均衡折行，不留孤字。
    testWidgets('窄屏大字号：挑战卡、总览与收钥匙的关里，说明行按项、预告与钥匙按句换行，不拆开、不留孤字', (tester) async {
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
      // 这一句自成一段（后面最多挂一个逗号），不和别的句挤在一段里折行。
      void ownClause(String phrase) => expect(paragraphOf(phrase).text.toPlainText(), anyOf(phrase, '$phrase，'));

      final hub = _Hub()
        ..signedIn = true
        ..best = 234;
      await tester.pumpWidget(MaterialApp(
        theme: campusTheme(),
        home: PlaygroundPage(store: PlaygroundStore.memory(), games: playgroundCatalog, groups: playgroundGroups, challenges: hub, openAccount: (_) {}, openLogin: (_) {}),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pumpAndSettle();
      for (final phrase in ['6 关', '限时 15 分钟', '最好 234 分', '还剩 2 天']) {
        oneLine(phrase);
      }
      expect(problems(), isEmpty, reason: '挑战一栏');

      final controller = ChallengeRunController(hub: hub, run: _run(levels: [
        _levelJson('a', output: 'c', puzzle: const HanoiRules().encodePuzzle(_hanoi)),
        _levelJson('b', game: 'ice', output: 'c', state: 'solved', key: 8),
        _levelJson('c', game: 'queens', state: 'locked', inputs: ['a', 'b'], teaser: '8×8，第 1 行的锁定皇后在第 ? 列，第 6 行的锁定皇后在第 8 列，第 2 行的锁定皇后在第 ? 列'),
      ]));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      for (final phrase in ['钥匙 8 交给第 3 关', '等第 1、2 关的钥匙']) {
        oneLine(phrase);
      }
      // 「第 1 行的锁定皇后在第 ? 列，」在 360dp 加 1.3 倍下比一行长：自成一段均衡折成两行（以前折出孤字「列，」）。
      for (final phrase in ['第 1 行的锁定皇后在第 ? 列', '第 6 行的锁定皇后在第 8 列', '第 2 行的锁定皇后在第 ? 列']) {
        ownClause(phrase);
      }
      expect(problems(), isEmpty, reason: '总览');
      controller.dispose();

      // 数回 5×5，第 4 行第 3 格与第 1 行第 5 格是前两关给的钥匙（题面取自走查那一局）。
      const puzzle = {'width': 5, 'height': 5, 'clues': [-1, 2, -1, -1, 3, -1, 2, 1, -1, -1, -1, 1, 1, 2, -1, 2, 0, 1, 3, 1, -1, -1, -1, -1, 0]};
      final level = ChallengeLevel(
        id: 'c', game: 'loop', tier: 'easy', difficulty: 4, inputs: const ['a', 'b'], output: 'e', state: ChallengeLevelState.open, submissions: 0, errors: 0, key: null, teaser: null, puzzle: puzzle,
        keyed: const [ChallengeKeyed(from: 'a', at: 17, key: 1), ChallengeKeyed(from: 'b', at: 4, key: 3)],
      );
      final challenge = PlayChallenge(level: level, name: '第 3 关', target: '第 5 关', deadline: DateTime.now().add(const Duration(minutes: 5)), submit: (answer) async => const PlayVerdict(correct: true, key: 10));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: LoopPage(game: playgroundCatalog.firstWhere((game) => game.id == 'loop'), store: PlaygroundStore.memory(), challenge: challenge)));
      await tester.pump(const Duration(milliseconds: 500));
      for (final phrase in ['第 4 行第 3 格是 1', '第 1 行第 5 格是 3']) {
        oneLine(phrase);
      }
      expect(problems(), isEmpty, reason: '收钥匙的关');
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
  @override
  bool get campusSignedIn => true;
  int? best;
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
      ChallengeSummary(id: 'weekly.2026-11-09.six', title: '六连环', label: '入门', levels: 6, timeLimit: const Duration(minutes: 15), endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)), best: best, playable: true),
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
  Future<ChallengeVerdict> answer(String runId, String levelId, int attempt, Object? answer) async => ChallengeVerdict(correct: true, key: 7, run: _run());
  @override
  Future<ChallengeRun> end(String runId) async => ended!;
  PointsSummary summary = const PointsSummary(balance: 86, expiring: 0, expiringAt: null);
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
  Future<ChallengeVerdict> answer(AppAccountRef account, String runId, String levelId, int attempt, Object? answer) => _call('answer', ChallengeVerdict(correct: true, key: null, run: _run()));
  @override
  Future<ChallengeRun> end(AppAccountRef account, String runId) => _call('end', _run());
  @override
  Future<PointsSummary> points(AppAccountRef account) => _call('points', const PointsSummary(balance: 0, expiring: 0, expiringAt: null));
  @override
  Future<PointsBatch> pointsEntries(AppAccountRef account, {String? before}) => _call('entries', const PointsBatch(entries: [], next: null));
}

class _AppClient implements AppAccountClient {
  final records = <String, String>{};
  var summaries = 0;
  var lost = false;
  @override
  Future<AppAccountRef?> accountOf(AccountIdentity identity) async => records[identity.loginId] == null ? null : AppAccountRef(accountId: records[identity.loginId]!, slot: 'fake-slot');
  @override
  Future<AppAccountStep> signInWithKingo(AccountIdentity identity, KingoSignInProof proof, {String? captcha}) => throw UnimplementedError();
  @override
  void abandon(AccountIdentity identity) {}
  @override
  Future<AppAccountSummary> summary(AccountIdentity identity) async {
    summaries++;
    if (lost) throw const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
    return AppAccountSummary(accountId: records[identity.loginId]!, providers: const ['kingo'], deviceCount: 1, createdAt: DateTime.utc(2026));
  }
  @override
  Future<void> signOut(AccountIdentity identity) async {}
  @override
  Future<void> delete(AccountIdentity identity) async {}
}

// 只实现编排用到的几项，其余交给 noSuchMethod。
class _Accounts extends AccountAccess {
  AccountIdentity? identity;
  @override
  AccountIdentity? get activeIdentity => identity;
  @override
  SessionView? get activeSession => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
