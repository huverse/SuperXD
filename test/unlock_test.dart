import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/rollouts.dart';
import 'package:superxd/application/unlocks.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/local/rollout_memory.dart';
import 'package:superxd/playground/challenge/points_page.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/relay_unlock_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/toolbox_page.dart';

import 'toolbox_test_support.dart';

// 解锁（隐藏服务与新游戏抢先玩，规则见服务端 src/modules/unlock/unlock_rules.ts）：编排、中转客户端与三处界面。合成数据。
final _now = DateTime.utc(2026, 11, 20);

RolloutConfig _config(List<RolloutUnlock> unlocks) => RolloutConfig(const {}, unlocks: unlocks);

void main() {
  group('编排', () {
    late _AppClient appClient;
    late AppAccounts appAccounts;
    late FileRolloutMemory memory;
    late Rollouts rollouts;
    late _Client client;
    late Unlocks unlocks;
    setUp(() async {
      appClient = _AppClient();
      appAccounts = AppAccounts(client: appClient);
      memory = FileRolloutMemory.memory(
        config: _config([
          RolloutUnlock(id: 'game.open', title: '已公开', publicAt: _now.subtract(const Duration(days: 1))),
          RolloutUnlock(id: 'game.early', title: '抢先玩', minLevel: 2, publicAt: _now.add(const Duration(days: 10))),
          const RolloutUnlock(id: 'toolbox.paid', title: '付费', price: 300),
          const RolloutUnlock(id: 'toolbox.gone', title: '下架', minLevel: 1, retired: true),
        ]),
      );
      rollouts = Rollouts(memory: memory, channel: 'alpha', accountId: () => appAccounts.accountId, now: () => _now);
      client = _Client();
      unlocks = Unlocks(rollouts: rollouts, appAccounts: appAccounts, client: client, now: () => _now);
    });

    test('下架的锁着、公开的开着（没登录也开）、其余看服务器；没登记的不受影响；同意前与没登录时不联网', () async {
      expect(unlocks.locked('game.open'), isFalse);
      expect(unlocks.locked('game.early'), isTrue);
      expect(unlocks.locked('toolbox.gone'), isTrue);
      expect(unlocks.offer('toolbox.gone'), isNull, reason: '下架的不给条件，页面直接藏起来');
      expect(unlocks.locked('game.unknown'), isFalse);
      expect(unlocks.purchasable.map((unlock) => unlock.id), ['toolbox.paid']);

      appClient.accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
      await appAccounts.load();
      await pumpEventQueue();
      expect(client.calls, isEmpty, reason: '同意协议与政策之前不联网');
      client.next = const UnlockState(level: 2, open: {'game.open', 'game.early'});
      unlocks.start();
      await pumpEventQueue();
      expect(client.calls, ['state']);
      expect(unlocks.locked('game.early'), isFalse);
      expect(unlocks.offer('game.early'), isNull);
      expect(unlocks.locked('toolbox.paid'), isTrue);

      await unlocks.foreground();
      expect(client.calls, ['state'], reason: '回前台隔一小时才再问');
    });

    test('买了马上更新；换了应用账号旧账号的状态不作数；中转说账号不在了马上核一次；没有要账号才开的项不联网', () async {
      appClient.accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
      await appAccounts.load();
      unlocks.start();
      await pumpEventQueue();
      client.next = const UnlockState(level: 0, open: {'toolbox.paid'});
      final changes = <void>[];
      final subscription = unlocks.changes.listen(changes.add);
      await unlocks.buy('toolbox.paid');
      expect(client.calls.last, 'buy toolbox.paid');
      expect(unlocks.locked('toolbox.paid'), isFalse);
      await pumpEventQueue();
      expect(changes, isNotEmpty);

      appClient.accountId = 'BBBBBBBBBBBBBBBBBBBBBB';
      client.next = const UnlockState(level: 0, open: {});
      await appAccounts.load();
      await pumpEventQueue();
      expect(unlocks.locked('toolbox.paid'), isTrue);

      client.failure = const UnlockException(UnlockFailure.notSignedIn, '应用账号已经退出');
      appClient.lost = true;
      await unlocks.refresh();
      await pumpEventQueue();
      expect(appClient.summaries, 1);
      await expectLater(unlocks.buy('toolbox.paid'), throwsA(isA<UnlockException>()));
      await subscription.cancel();

      final calls = client.calls.length;
      await memory.save(_config([RolloutUnlock(id: 'game.open', title: '已公开', publicAt: _now.subtract(const Duration(days: 1)))]), _now);
      client.failure = null;
      await unlocks.refresh();
      expect(client.calls, hasLength(calls), reason: '只剩已公开的，不用问服务器');
    });
  });

  group('中转客户端', () {
    test('签名、按协议解码；等级越界、编号不合法报失败；错误码换成失败', () async {
      final vault = MemoryAppAccountVault();
      final relay = _Relay();
      final client = RelayUnlockClient(vault: vault, transport: relay);
      final ref = AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: appAccountSlot);
      await expectLater(client.state(ref), throwsA(isA<UnlockException>().having((error) => error.failure, 'failure', UnlockFailure.notSignedIn)));
      final key = await SocialIdentity.fromSeeds(List<int>.generate(32, (index) => index + 1), List<int>.generate(32, (index) => index + 33));
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: 'AAAAAAAAAAAAAAAAAAAAAA'));
      relay.reply = const RelayResponse(200, {'level': 3, 'open': ['game.early'], 'serverTime': 1});
      final state = await client.state(ref);
      expect(relay.paths.last, 'GET /v1/unlocks');
      expect(state.level, 3);
      expect(state.open, {'game.early'});
      relay.reply = const RelayResponse(200, {'level': 3, 'open': ['toolbox.paid'], 'serverTime': 1});
      await client.buy(ref, 'toolbox.paid');
      expect(relay.paths.last, 'POST /v1/unlocks/toolbox.paid/buy');
      for (final body in [
        {'level': 6, 'open': <Object?>[]},
        {'level': 1, 'open': ['Bad Id']},
        {'level': 1, 'open': 'game.early'},
      ]) {
        relay.reply = RelayResponse(200, body);
        await expectLater(client.state(ref), throwsA(isA<UnlockException>().having((error) => error.failure, 'failure', UnlockFailure.failed)), reason: '$body');
      }
      relay.reply = const RelayResponse(409, {'code': 'POINTS_SHORT', 'price': 300, 'balance': 20});
      await expectLater(client.buy(ref, 'toolbox.paid'), throwsA(isA<UnlockException>().having((error) => error.message, 'message', '积分不够，要 300 分')));
      relay.reply = const RelayResponse(409, {'code': 'UNLOCK_UNAVAILABLE'});
      await expectLater(client.buy(ref, 'game.open'), throwsA(isA<UnlockException>().having((error) => error.failure, 'failure', UnlockFailure.unavailable)));
      relay.reply = const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.state(ref), throwsA(isA<UnlockException>().having((error) => error.failure, 'failure', UnlockFailure.notSignedIn)));
    });
  });

  group('界面', () {
    testWidgets('游乐场：锁着的游戏卡写开放条件，点了只能等的说明条件、能买的确认花积分；下架的不显示、不进最近玩过', (tester) async {
      final access = _Access()..specs.add(RolloutUnlock(id: 'game.queens', title: '八皇后', minLevel: 2, publicAt: DateTime.utc(2026, 12, 1)));
      final store = PlaygroundStore.memory();
      await store.opened('queens');
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PlaygroundPage(store: store, games: playgroundCatalog, groups: playgroundGroups, unlocks: access)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Lv2'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '八皇后'), findsNothing, reason: '锁着的不进最近玩过');
      await tester.tap(find.text('八皇后'));
      await tester.pumpAndSettle();
      expect(find.text('八皇后还没开放'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      access.specs
        ..clear()
        ..add(const RolloutUnlock(id: 'game.queens', title: '八皇后', price: 300));
      access.emit();
      await tester.pumpAndSettle();
      expect(find.textContaining('300 分'), findsOneWidget);
      await tester.tap(find.text('八皇后'));
      await tester.pumpAndSettle();
      expect(find.text('解锁「八皇后」？'), findsOneWidget);
      expect(find.textContaining('花 300 积分'), findsOneWidget);
      await tester.tap(find.text('解锁').last);
      await tester.pumpAndSettle();
      expect(access.bought, ['game.queens']);
      expect(find.text('已解锁「八皇后」'), findsOneWidget);
      expect(find.textContaining('300 分'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '八皇后'), findsOneWidget, reason: '开了就回到最近玩过');

      access.specs
        ..clear()
        ..add(const RolloutUnlock(id: 'game.queens', title: '八皇后', minLevel: 1, retired: true));
      access.open.clear();
      access.emit();
      await tester.pumpAndSettle();
      expect(find.text('八皇后'), findsNothing);
    });

    testWidgets('百宝箱：锁着的工具不显示入口，开了才出现', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      final tool = fixture.runtime.modules.first;
      final access = _Access()..specs.add(RolloutUnlock(id: toolboxUnlockId(tool.id), title: tool.name, percent: 10));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ToolboxPage(runtime: fixture.runtime, unlocks: access)));
      await tester.pumpAndSettle();
      expect(find.text(tool.name), findsNothing);
      access.open.add(toolboxUnlockId(tool.id));
      access.emit();
      await tester.pumpAndSettle();
      expect(find.text(tool.name), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.close);
    });

    testWidgets('积分页：列能用积分买的解锁与条件，确认后买、提示已解锁；不够时提示原因', (tester) async {
      final access = _Access()
        ..specs.addAll([
          RolloutUnlock(id: 'toolbox.paid', title: '内测工具', price: 300, minLevel: 3, publicAt: DateTime.utc(2027, 1, 1)),
          const RolloutUnlock(id: 'game.level', title: '只看等级', minLevel: 2),
        ]);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: PointsPage(hub: _Hub(), unlocks: access)));
      await tester.pumpAndSettle();
      expect(find.text('内测工具'), findsOneWidget);
      expect(find.text('只看等级'), findsNothing, reason: '不能用积分买的不列');
      for (final item in ['300 分', 'Lv3', '2027年1月1日']) {
        expect(find.textContaining(item), findsOneWidget, reason: item);
      }
      // 「解锁」先是这一栏的标题，第二个是按钮；弹窗里的按钮在最后。
      final button = find.text('解锁').at(1);
      access.failure = const UnlockException(UnlockFailure.pointsShort, '积分不够，要 300 分');
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('解锁').last);
      await tester.pumpAndSettle();
      expect(find.text('积分不够，要 300 分'), findsOneWidget);
      access.failure = null;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('解锁「内测工具」？'), findsOneWidget);
      expect(find.textContaining('花 300 积分'), findsOneWidget);
      await tester.tap(find.text('解锁').last);
      await tester.pumpAndSettle();
      expect(access.bought, ['toolbox.paid']);
      expect(find.text('已解锁「内测工具」'), findsOneWidget);
      expect(find.text('内测工具'), findsNothing);
    });
  });
}

class _Access implements UnlockAccess {
  final specs = <RolloutUnlock>[];
  final open = <String>{};
  final bought = <String>[];
  UnlockException? failure;
  final _controller = StreamController<void>.broadcast();

  void emit() => _controller.add(null);

  RolloutUnlock? _spec(String id) => specs.where((spec) => spec.id == id).firstOrNull;

  @override
  Stream<void> get changes => _controller.stream;
  @override
  bool locked(String id) => switch (_spec(id)) {
    null => false,
    final spec => spec.retired || !open.contains(id),
  };
  @override
  RolloutUnlock? offer(String id) => switch (_spec(id)) {
    final spec? when !spec.retired && locked(id) => spec,
    _ => null,
  };
  @override
  List<RolloutUnlock> get purchasable => [for (final spec in specs) if (spec.price != null && offer(spec.id) != null) spec];
  @override
  Future<void> refresh() async {}
  @override
  Future<void> buy(String id) async {
    if (failure case final error?) throw error;
    bought.add(id);
    open.add(id);
    emit();
  }
}

class _Client implements UnlockClient {
  final calls = <String>[];
  UnlockState next = const UnlockState(level: 0, open: {});
  UnlockException? failure;

  @override
  Future<UnlockState> state(AppAccountRef account) async {
    calls.add('state');
    if (failure case final error?) throw error;
    return next;
  }

  @override
  Future<UnlockState> buy(AppAccountRef account, String id) async {
    calls.add('buy $id');
    if (failure case final error?) throw error;
    return next;
  }
}

class _Relay implements RelayTransport {
  RelayResponse reply = const RelayResponse(200, {});
  final paths = <String>[];
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    paths.add('$method $pathWithQuery');
    return reply;
  }
}

class _Hub implements ChallengeHub {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  bool get signedIn => true;
  @override
  Future<PointsSummary> points() async => const PointsSummary(balance: 500, expiring: 0, expiringAt: null, earned: 500, level: 1, nextLevelAt: 3000);
  @override
  Future<PointsBatch> pointsEntries({String? before}) async => const PointsBatch(entries: [], next: null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

