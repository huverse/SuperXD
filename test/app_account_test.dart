import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/page/app_account_join_page.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/theme/campus_theme.dart';

// 应用账号（人工决策见 domain/app_account.dart 与 application/app_accounts.dart）：中转客户端、编排与账号页。合成数据。
const _identity = AccountIdentity(source: 'http://school.example', loginId: '20260000001');
const _other = AccountIdentity(source: 'http://school.example', loginId: '20260000002');
const _accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
const _ticketId = 'TTTTTTTTTTTTTTTTTTTTTT';
// 编排测试里替身给的把手（slot 只是替身里的一个名字）。
const _account = AppAccountRef(accountId: _accountId, slot: 'fake-slot');

void main() {
  group('中转客户端', () {
    late _Relay relay;
    late MemoryAppAccountVault vault;
    late RelayAppAccountClient client;
    final slot = appAccountSlot(_identity);
    setUp(() {
      relay = _Relay();
      vault = MemoryAppAccountVault();
      client = RelayAppAccountClient(vault: vault, transport: relay);
    });

    test('设备核对：签名、只交学号与两把公钥；学号已有账号时存成等待中，再核对沿用同一把密钥，登录成功才有把手', () async {
      relay.reply = (request) => const RelayResponse(200, {'status': 'exists', 'account': null});
      expect(await client.signInWithDevice(_identity), isA<AppAccountExists>());
      final first = relay.requests.single;
      expect(first.path, '/v1/account/device-sign-in');
      expect(first.headers['x-sxd-device'], first.deviceIdOfBody);
      expect(first.body.keys.toSet(), {'signPublicKey', 'boxPublicKey', 'loginId'});
      expect(first.body['loginId'], _identity.loginId);
      expect((await vault.read(slot))!.pending, isTrue);
      expect(await client.accountOf(_identity), isNull, reason: '等待中不算登录');
      relay.reply = (request) => const RelayResponse(200, {'status': 'signedIn', 'account': {'accountId': _accountId, 'created': false, 'serverTime': 1}});
      final signed = await client.signInWithDevice(_identity);
      expect(signed, isA<AppAccountSignedIn>().having((step) => step.account, 'account', AppAccountRef(accountId: _accountId, slot: slot)).having((step) => step.created, 'created', isFalse));
      expect(relay.requests.last.headers['x-sxd-device'], first.headers['x-sxd-device']);
      expect(await client.accountOf(_identity), AppAccountRef(accountId: _accountId, slot: slot));
      expect(await client.accountOf(_other), isNull);
      // 存储键里不出现学号。
      expect(slot, isNot(contains(_identity.loginId)));
    });

    test('扫码授权：没设备核对过不能出示；等待中的密钥出示、轮询到批准就登录；登录着的设备批准时带核对码', () async {
      await expectLater(client.startJoin(_identity), throwsA(isA<AppAccountException>()));
      expect(relay.requests, isEmpty);
      final pending = await SocialIdentity.generate();
      await vault.write(slot, AppAccountKey(identity: pending, accountId: ''));
      final expiresAt = DateTime.utc(2026, 11, 15, 12, 5);
      relay.reply = (request) => RelayResponse(200, {'ticketId': _ticketId, 'code': '012345', 'expiresAt': expiresAt.millisecondsSinceEpoch});
      final join = await client.startJoin(_identity);
      expect(relay.requests.last.path, '/v1/account/joins');
      expect(relay.requests.last.headers['x-sxd-device'], pending.deviceId);
      expect(join.payload, 'superxd-join:$_ticketId:012345');
      expect(join.expiresAt, expiresAt);
      expect(AppAccountJoin.parse(join.payload), (ticketId: _ticketId, code: '012345'));
      expect(AppAccountJoin.parse('SXD1F:ABC'), isNull);
      relay.reply = (request) => const RelayResponse(200, {'state': 'pending', 'account': null});
      expect(await client.joinState(_identity, join), isNull);
      expect(relay.requests.last.path, '/v1/account/joins/$_ticketId');
      relay.reply = (request) => const RelayResponse(200, {'state': 'approved', 'account': {'accountId': _accountId, 'created': false, 'serverTime': 1}});
      expect(await client.joinState(_identity, join), AppAccountRef(accountId: _accountId, slot: slot));
      expect((await vault.read(slot))!.identity.deviceId, pending.deviceId);

      final owner = await SocialIdentity.generate();
      await vault.write(appAccountSlot(_other), AppAccountKey(identity: owner, accountId: _accountId));
      relay.reply = (request) => const RelayResponse(204, {});
      await client.approveJoin(_other, join.payload);
      expect(relay.requests.last.path, '/v1/account/joins/$_ticketId/approve');
      expect(relay.requests.last.body, {'code': '012345'});
      expect(relay.requests.last.headers['x-sxd-device'], owner.deviceId);
      await expectLater(client.approveJoin(_other, 'https://example.com'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.joinExpired)));
    });

    test('找回：提交后记下申请号，之后接着问；生效了就登录；申请被清理了就忘掉它', () async {
      expect(await client.recoveryOf(_identity), isNull);
      expect(relay.requests, isEmpty, reason: '没有申请不联网');
      final pending = await SocialIdentity.generate();
      await vault.write(slot, AppAccountKey(identity: pending, accountId: ''));
      final grantAt = DateTime.utc(2026, 11, 18, 12);
      relay.reply = (request) => RelayResponse(200, {'recoveryId': '42', 'state': 'pending', 'grantAt': grantAt.millisecondsSinceEpoch, 'account': null});
      final recovery = await client.requestRecovery(_identity);
      expect(relay.requests.last.path, '/v1/account/recoveries');
      expect(relay.requests.last.body['loginId'], _identity.loginId);
      expect((recovery.id, recovery.state, recovery.grantAt), ('42', AppAccountRecoveryState.pending, grantAt));
      expect((await vault.read(slot))!.recoveryId, '42');
      // 等待中再设备核对：沿用这把密钥，申请号还在。
      relay.reply = (request) => const RelayResponse(200, {'status': 'exists', 'account': null});
      await client.signInWithDevice(_identity);
      expect(relay.requests.last.headers['x-sxd-device'], pending.deviceId);
      expect((await vault.read(slot))!.recoveryId, '42');
      relay.reply = (request) => RelayResponse(200, {'recoveryId': '42', 'state': 'denied', 'grantAt': grantAt.millisecondsSinceEpoch, 'account': null});
      expect((await client.recoveryOf(_identity))!.state, AppAccountRecoveryState.denied);
      expect(relay.requests.last.path, '/v1/account/recoveries/mine');
      relay.reply = (request) => RelayResponse(200, {'recoveryId': '42', 'state': 'granted', 'grantAt': grantAt.millisecondsSinceEpoch, 'account': {'accountId': _accountId, 'created': false, 'serverTime': 1}});
      expect((await client.recoveryOf(_identity))!.state, AppAccountRecoveryState.granted);
      expect(await client.accountOf(_identity), AppAccountRef(accountId: _accountId, slot: slot));

      await vault.write(slot, AppAccountKey(identity: pending, accountId: '', recoveryId: '42'));
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      expect(await client.recoveryOf(_identity), isNull);
      expect((await vault.read(slot))!.recoveryId, isNull);
      expect((await vault.read(slot))!.pending, isTrue);
    });

    test('中转的错误码换成给用户看的原因；看不懂的回复不存本机', () async {
      await vault.write(appAccountSlot(_other), AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      final payload = 'superxd-join:$_ticketId:012345';
      final cases = <(Map<String, Object?>, int, AppAccountFailure, String)>[
        ({'code': 'JOIN_NOT_FOUND'}, 404, AppAccountFailure.joinExpired, '二维码或申请已过期，请重新开始'),
        ({'code': 'JOIN_MISMATCH'}, 403, AppAccountFailure.joinMismatch, '这是别的学号的应用账号'),
        ({'code': 'RATE_LIMITED', 'retryAfter': 60}, 429, AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
        ({'code': 'ACCOUNT_NOT_FOUND'}, 404, AppAccountFailure.notSignedIn, '应用账号已经退出'),
      ];
      for (final (body, status, failure, message) in cases) {
        relay.reply = (request) => RelayResponse(status, body);
        await expectLater(client.approveJoin(_other, payload), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', failure).having((error) => error.message, 'message', message)));
      }
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await expectLater(client.signInWithDevice(_identity), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.network)));
      relay.reply = (request) => const RelayResponse(200, {'status': 'signedIn', 'account': {'accountId': 'bad id', 'created': true}});
      await expectLater(client.signInWithDevice(_identity), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.failed)));
      expect(await client.accountOf(_identity), isNull);
    });

    test('查看账号带回别的设备的找回申请，处理一条；别处注销了就删本机记录；退出连不上也删本机；注销要服务端删成才算', () async {
      await vault.write(slot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      relay.reply = (request) => const RelayResponse(200, {'accountId': _accountId, 'providers': ['kingo'], 'deviceCount': 2, 'createdAt': 1763000000000, 'recoveries': [
        {'recoveryId': '42', 'createdAt': 1763100000000, 'grantAt': 1763359200000},
        {'recoveryId': 'bad', 'createdAt': 1, 'grantAt': 2},
      ]});
      final summary = await client.summary(_identity);
      expect(summary.deviceCount, 2);
      expect([for (final item in summary.recoveries) (item.id, item.grantAt.millisecondsSinceEpoch)], [('42', 1763359200000)]);
      relay.reply = (request) => const RelayResponse(204, {});
      await client.decideRecovery(_identity, '42', approve: false);
      expect('${relay.requests.last.method} ${relay.requests.last.path}', 'POST /v1/account/recoveries/42/deny');
      await client.decideRecovery(_identity, '42', approve: true);
      expect(relay.requests.last.path, '/v1/account/recoveries/42/approve');
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.summary(_identity), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.notSignedIn)));
      expect(await client.accountOf(_identity), isNull);

      await vault.write(slot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await client.signOut(_identity);
      expect(relay.requests.last.method, 'DELETE');
      expect(relay.requests.last.path, '/v1/devices');
      expect(await vault.read(slot), isNull);

      await vault.write(slot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId));
      await expectLater(client.delete(_identity), throwsA(isA<AppAccountException>()));
      expect(await client.accountOf(_identity), AppAccountRef(accountId: _accountId, slot: slot));
      relay.reply = (request) => const RelayResponse(204, {});
      await client.delete(_identity);
      expect(relay.requests.map((request) => '${request.method} ${request.path}').toList().reversed.take(2).toList(), ['DELETE /v1/devices', 'DELETE /v1/account']);
      expect(await client.accountOf(_identity), isNull);
    });
  });

  group('编排', () {
    late _Accounts accounts;
    late _Client client;
    late AppAccounts appAccounts;
    late DateTime now;
    setUp(() async {
      accounts = _Accounts()..identity = _identity;
      now = DateTime.utc(2026, 11, 15, 12);
      client = _Client(() => now);
      appAccounts = AppAccounts(accounts: accounts, client: client, now: () => now);
      await appAccounts.load();
    });
    tearDown(() => appAccounts.dispose());

    test('设备核对：学号没有账号就登录；已有账号要授权，带上这台手机的找回申请；找回生效了直接登录', () async {
      client.steps.add(const AppAccountSignedIn(account: _account, created: true));
      expect(await appAccounts.signIn(), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已登录应用账号'));
      expect(appAccounts.accountId, _accountId);
      await appAccounts.signOut();
      client.steps.add(const AppAccountExists());
      expect(await appAccounts.signIn(), isA<AppAccountNeedsAuthorization>().having((result) => result.recovery, 'recovery', isNull));
      expect(appAccounts.accountId, isNull);
      client.recovery = AppAccountRecovery(id: '42', state: AppAccountRecoveryState.pending, grantAt: now.add(const Duration(days: 3)));
      client.steps.add(const AppAccountExists());
      expect(await appAccounts.signIn(), isA<AppAccountNeedsAuthorization>().having((result) => result.recovery?.id, 'recovery', '42'));
      expect(appAccounts.recovery?.state, AppAccountRecoveryState.pending);
      client.recovery = AppAccountRecovery(id: '42', state: AppAccountRecoveryState.granted, grantAt: now);
      client.steps.add(const AppAccountExists());
      expect(await appAccounts.signIn(), isA<AppAccountDone>());
      expect(appAccounts.accountId, _accountId);
      expect(appAccounts.recovery, isNull);
      expect(client.signIns, [_identity.loginId, _identity.loginId, _identity.loginId, _identity.loginId]);
    });

    test('扫码授权：出示、轮询到批准就登录；连不上照旧等，过期就报错', () async {
      final started = await appAccounts.startJoin();
      final join = (started as AppAccountJoinStarted).join;
      expect(await appAccounts.pollJoin(join), isA<AppAccountWaiting>());
      client.joinFailure = const AppAccountException(AppAccountFailure.network, '连不上服务器');
      expect(await appAccounts.pollJoin(join), isA<AppAccountWaiting>());
      client.joinFailure = const AppAccountException(AppAccountFailure.joinExpired, '二维码或申请已过期，请重新开始');
      expect(await appAccounts.pollJoin(join), isA<AppAccountError>());
      client.joinFailure = null;
      client.joinApproved = true;
      expect(await appAccounts.pollJoin(join), isA<AppAccountDone>());
      expect(appAccounts.accountId, _accountId);
      expect(await appAccounts.approveJoin(join.payload), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已授权新设备'));
      expect(client.approved, [join.payload]);
    });

    test('找回：申请后记着；check 隔一小时问一次，被拒绝后不再问，生效了就登录', () async {
      client.steps.add(const AppAccountExists());
      await appAccounts.signIn();
      expect(await appAccounts.requestRecovery(), isA<AppAccountDone>());
      expect(appAccounts.recovery?.state, AppAccountRecoveryState.pending);
      final asked = client.recoveryChecks;
      await appAccounts.check();
      await appAccounts.check();
      expect(client.recoveryChecks, asked, reason: '申请时已经看过，一小时内不再问');
      now = now.add(AppAccounts.checkGap);
      client.recovery = AppAccountRecovery(id: '7', state: AppAccountRecoveryState.denied, grantAt: now);
      await appAccounts.check();
      expect(appAccounts.recovery?.state, AppAccountRecoveryState.denied);
      now = now.add(AppAccounts.checkGap);
      await appAccounts.check();
      expect(client.recoveryChecks, asked + 1, reason: '被拒绝了不再问');
      // 重新申请，到点生效。
      expect(await appAccounts.requestRecovery(), isA<AppAccountDone>());
      now = now.add(const Duration(days: 3, hours: 1));
      client.recovery = AppAccountRecovery(id: '7', state: AppAccountRecoveryState.granted, grantAt: now);
      await appAccounts.check();
      expect(appAccounts.accountId, _accountId);
    });

    test('登录着：check 带回别的设备的找回申请，打扰时机弹一次（排在最前）；处理后从列表拿掉', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      final recovery = AppAccountPendingRecovery(id: '42', createdAt: now, grantAt: now.add(const Duration(days: 3)));
      client.pending = [recovery];
      await appAccounts.check();
      expect(appAccounts.recoveries.map((item) => item.id), ['42']);
      final moments = AppMoments(appAccounts: appAccounts, timetable: () async => const CampusTimetable(<CourseOccurrence>[]), clock: () => now);
      addTearDown(moments.dispose);
      final moment = await moments.next();
      expect(moment, isA<AccountRecoveryMoment>().having((moment) => moment.recovery.id, 'id', '42'));
      moments.begin(moment!);
      moments.foreground();
      expect(await moments.next(), isNull, reason: '这次启动弹过了');
      expect(appAccounts.recoveries, hasLength(1), reason: '账号页照样列着');
      expect(await appAccounts.decideRecovery('42', approve: false), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已拒绝找回'));
      expect(client.decisions, [('42', false)]);
      expect(appAccounts.recoveries, isEmpty);
    });

    test('中转说这台设备不在账号里了：马上核一次，退回未登录', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      expect(await appAccounts.approveJoin('superxd-join:$_ticketId:012345'), isA<AppAccountError>());
      await pumpEventQueue();
      expect(client.summaries, 1);
      expect(appAccounts.accountId, isNull);
    });

    test('跟着教务走：换账号读那个账号的；退出教务时退出那个账号的', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      expect(appAccounts.accountId, _accountId);
      accounts.identity = _other;
      expect(await appAccounts.signIn(), isA<AppAccountError>(), reason: '还没读完新账号的记录');
      await appAccounts.load();
      expect(appAccounts.accountId, isNull);
      accounts.identity = _identity;
      accounts.notify();
      await pumpEventQueue();
      expect(appAccounts.accountId, _accountId);
      await appAccounts.forget(_identity);
      expect(client.signedOut, [_identity.loginId]);
      expect(appAccounts.accountId, isNull);
    });

    test('每小时最多看一次账号；别处注销了就退回未登录', () async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await appAccounts.check();
      await appAccounts.check();
      expect(client.summaries, 1);
      now = now.add(AppAccounts.checkGap);
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      await appAccounts.check();
      expect(client.summaries, 2);
      expect(appAccounts.accountId, isNull);
      now = now.add(AppAccounts.checkGap);
      await appAccounts.check();
      expect(client.summaries, 2, reason: '没登录不联网');
    });

    // 人工决策见 social/social_service.dart（11-14 17:56:46）：注销成了才通知组合根清掉这台手机上那个账号的私信；注销失败不通知。
    test('注销成功后把注销的账号交给 onDeleted，失败不交', () async {
      final deleted = <AppAccountRef>[];
      final subject = AppAccounts(accounts: accounts, client: client, onDeleted: deleted.add, now: () => now);
      addTearDown(subject.dispose);
      client.records[_identity.loginId] = _accountId;
      await subject.load();
      client.failure = const AppAccountException(AppAccountFailure.network, '连不上服务器');
      expect(await subject.deleteAccount(), isA<AppAccountError>());
      expect(deleted, isEmpty);
      client.failure = null;
      final account = subject.current;
      expect(await subject.deleteAccount(), isA<AppAccountDone>());
      expect(deleted, [account]);
      expect(subject.current, isNull);
    });
  });

  group('账号页', () {
    late _Accounts accounts;
    late _Client client;
    late AppAccounts appAccounts;
    late AppSession session;
    setUp(() async {
      accounts = _Accounts()..identity = _identity;
      client = _Client(DateTime.now);
      appAccounts = AppAccounts(accounts: accounts, client: client);
      await appAccounts.load();
      session = AppSession(accounts);
    });
    tearDown(() { appAccounts.dispose(); session.dispose(); });

    Future<void> pumpPage(WidgetTester tester, {JoinScanner? scan}) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲', appAccounts: appAccounts, scanJoin: scan ?? scanJoinWithCamera)));
      await tester.pumpAndSettle();
    }

    Future<void> agree(WidgetTester tester) async {
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('登录应用账号？'), findsOneWidget);
      expect(find.textContaining('教务密码不出手机'), findsOneWidget);
      await tester.tap(find.text('同意并登录'));
      await tester.pumpAndSettle();
    }

    Future<void> clearToast(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    testWidgets('登录：先单独同意，设备核对，成功后显示已登录并给提示条', (tester) async {
      await pumpPage(tester);
      expect(find.text('未登录'), findsOneWidget);
      client.steps.add(const AppAccountSignedIn(account: _account, created: true));
      await agree(tester);
      expect(find.text('已登录'), findsOneWidget);
      expect(find.text('已登录应用账号'), findsOneWidget);
      await clearToast(tester);
    });

    testWidgets('学号已有账号：选扫码授权出示二维码与核对码，批准后回来显示已登录', (tester) async {
      await pumpPage(tester);
      client.steps.add(const AppAccountExists());
      await agree(tester);
      expect(find.text('这个学号已有应用账号'), findsOneWidget);
      await tester.tap(find.text('扫码授权'));
      await tester.pumpAndSettle();
      expect(find.text('核对码 012345'), findsOneWidget);
      expect(find.byType(PrettyQrView), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(client.joinPolls, 1);
      client.joinApproved = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('核对码 012345'), findsNothing);
      expect(find.text('已登录'), findsOneWidget);
      expect(find.text('已登录应用账号'), findsOneWidget);
      await clearToast(tester);
    });

    testWidgets('学号已有账号：申请找回，提示几时生效，行尾写找回中；再点只给扫码授权', (tester) async {
      await pumpPage(tester);
      client.steps.add(const AppAccountExists());
      await agree(tester);
      await tester.tap(find.text('申请找回'));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp('^已申请找回，.+起生效')), findsOneWidget);
      expect(find.text('找回中'), findsOneWidget);
      await clearToast(tester);
      client.steps.add(const AppAccountExists());
      await agree(tester);
      expect(find.textContaining('已申请找回，'), findsOneWidget);
      expect(find.text('申请找回'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('登录着：授权新设备扫码，核对码确认后批准', (tester) async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await pumpPage(tester, scan: (context) async => 'superxd-join:$_ticketId:012345');
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权新设备'));
      await tester.pumpAndSettle();
      expect(find.textContaining('012345'), findsOneWidget);
      await tester.tap(find.text('授权'));
      await tester.pumpAndSettle();
      expect(client.approved, ['superxd-join:$_ticketId:012345']);
      expect(find.text('已授权新设备'), findsOneWidget);
      await clearToast(tester);
    });

    testWidgets('别的设备申请找回：账号页列出一行，点了拒绝就拿掉', (tester) async {
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      final now = DateTime.now().toUtc();
      client.pending = [AppAccountPendingRecovery(id: '42', createdAt: now, grantAt: now.add(const Duration(days: 3)))];
      await appAccounts.check();
      await pumpPage(tester);
      await tester.tap(find.text('有设备在申请找回'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不是你本人请拒绝'), findsOneWidget);
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(client.decisions, [('42', false)]);
      expect(find.text('有设备在申请找回'), findsNothing);
      expect(find.text('已拒绝找回'), findsOneWidget);
      await clearToast(tester);
    });

    testWidgets('不同意就不核对；登录着点开是退出与注销，都要确认', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(client.signIns, isEmpty);

      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await tester.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('退出应用账号'), findsOneWidget);
      await tester.tap(find.text('注销应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('注销应用账号？'), findsOneWidget);
      // 人工决策见 social/social_service.dart（11-14 17:56:46）：注销连同私信一起删，确认框写明。
      expect(find.textContaining('私信好友'), findsOneWidget);
      await tester.tap(find.text('注销'));
      await tester.pumpAndSettle();
      expect(client.deleted, [_identity.loginId]);
      expect(find.text('未登录'), findsOneWidget);
      expect(find.text('应用账号已注销'), findsOneWidget);
      await clearToast(tester);
    });

    // 人工决策见 domain/diagnostic_upload.dart：登录着应用账号时，菜单里看与删记在账号下的诊断包。
    testWidgets('登录着点开多一项「我上传的诊断包」：列出记在账号下的包，点一行复制编号，⋯里删除要确认', (tester) async {
      final diagnosticsClient = _DiagnosticClient([
        // 刚传完：离删除差几分钟满 30 天，要写 30 天（同确认框），不能向下取整成 29。
        DiagnosticRecord(id: '7KQ2M9XD', bytes: 2 * 1024 * 1024, uploadedAt: DateTime.now().toUtc(), expiresAt: DateTime.now().toUtc().add(const Duration(days: 30, minutes: -1))),
      ]);
      final diagnostics = AccountDiagnostics(uploader: _NoUploader(), client: diagnosticsClient, account: () => appAccounts.current);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      client.records[_identity.loginId] = _accountId;
      await appAccounts.load();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲', appAccounts: appAccounts, diagnostics: diagnostics)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我上传的诊断包'));
      await tester.pumpAndSettle();
      expect(find.text('诊断编号 7KQ2M9XD'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('2.0 MB · 30 天后删除')), findsOneWidget);
      await tester.tap(find.text('诊断编号 7KQ2M9XD'));
      await tester.pumpAndSettle();
      expect(copied, '7KQ2M9XD');
      expect(find.text('已复制诊断编号'), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除诊断包 7KQ2M9XD？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(diagnosticsClient.deleted, ['7KQ2M9XD']);
      expect(find.text('诊断编号 7KQ2M9XD'), findsNothing);
      expect(find.text('应用账号下还没有诊断包'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('没配中转时不显示这一组', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲')));
      await tester.pumpAndSettle();
      expect(find.text('应用账号'), findsNothing);
      expect(find.text('退出登录'), findsOneWidget);
    });
  });
}

class _Request {
  _Request(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  String get deviceIdOfBody => deviceIdOf(decodeBase64UrlNoPad(body['signPublicKey'] as String? ?? ''));
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

class _Client implements AppAccountClient {
  _Client(this.now);
  final DateTime Function() now;
  final records = <String, String>{};
  final steps = <AppAccountStep>[];
  final signIns = <String>[];
  final signedOut = <String>[];
  final deleted = <String>[];
  final approved = <String>[];
  final decisions = <(String, bool)>[];
  int summaries = 0;
  int recoveryChecks = 0;
  int joinPolls = 0;
  bool joinApproved = false;
  AppAccountException? failure;
  AppAccountException? joinFailure;
  // 这台手机的找回申请（替身里跟着设备核对走，不分学号）。
  AppAccountRecovery? recovery;
  // 登录着时别的设备提交的找回申请。
  List<AppAccountPendingRecovery> pending = const [];

  void _fail() {
    if (failure case final error?) throw error;
  }

  @override
  Future<AppAccountRef?> accountOf(AccountIdentity identity) async => records[identity.loginId] == null ? null : AppAccountRef(accountId: records[identity.loginId]!, slot: _account.slot);
  @override
  Future<AppAccountStep> signInWithDevice(AccountIdentity identity) async {
    signIns.add(identity.loginId);
    _fail();
    final step = steps.removeAt(0);
    if (step is AppAccountSignedIn) records[identity.loginId] = step.account.accountId;
    return step;
  }
  @override
  Future<AppAccountJoin> startJoin(AccountIdentity identity) async {
    _fail();
    return AppAccountJoin(ticketId: _ticketId, code: '012345', expiresAt: now().add(const Duration(minutes: 5)));
  }
  @override
  Future<AppAccountRef?> joinState(AccountIdentity identity, AppAccountJoin join) async {
    joinPolls++;
    if (joinFailure case final error?) throw error;
    if (!joinApproved) return null;
    records[identity.loginId] = _accountId;
    return accountOf(identity);
  }
  @override
  Future<void> approveJoin(AccountIdentity identity, String payload) async {
    _fail();
    approved.add(payload);
  }
  @override
  Future<AppAccountRecovery> requestRecovery(AccountIdentity identity) async {
    _fail();
    return recovery = AppAccountRecovery(id: '7', state: AppAccountRecoveryState.pending, grantAt: now().add(const Duration(days: 3)));
  }
  @override
  Future<AppAccountRecovery?> recoveryOf(AccountIdentity identity) async {
    recoveryChecks++;
    _fail();
    if (recovery?.state == AppAccountRecoveryState.granted) records[identity.loginId] = _accountId;
    return recovery;
  }
  @override
  Future<void> decideRecovery(AccountIdentity identity, String recoveryId, {required bool approve}) async {
    _fail();
    decisions.add((recoveryId, approve));
  }
  @override
  Future<AppAccountSummary> summary(AccountIdentity identity) async {
    summaries++;
    _fail();
    return AppAccountSummary(accountId: records[identity.loginId]!, providers: const ['kingo'], deviceCount: 1, createdAt: DateTime.utc(2026), recoveries: pending);
  }
  @override
  Future<void> signOut(AccountIdentity identity) async {
    signedOut.add(identity.loginId);
    records.remove(identity.loginId);
  }
  @override
  Future<void> delete(AccountIdentity identity) async {
    _fail();
    deleted.add(identity.loginId);
    records.remove(identity.loginId);
  }
}

// 只实现应用账号与账号页用到的几项，其余交给 noSuchMethod。
class _Accounts extends AccountAccess {
  AccountIdentity? identity;
  final _loggedOut = StreamController<AccountIdentity>.broadcast();

  void notify() => notifyListeners();

  @override
  AccountIdentity? get activeIdentity => identity;
  @override
  SessionView? get activeSession => identity == null ? null : SessionView(loginId: identity!.loginId, name: '同学甲', className: '');
  @override
  int get generation => 1;
  @override
  Stream<AccountIdentity> get loggedOut => _loggedOut.stream;
  @override
  Future<LegacyImportState> legacyImportState() async => const LegacyImportState(available: false);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoUploader implements DiagnosticUploader {
  @override
  Future<DiagnosticReceipt> upload(String archivePath, {void Function(double sent)? onProgress}) => throw UnimplementedError();
}

class _DiagnosticClient implements DiagnosticAccountClient {
  _DiagnosticClient(this.records);
  final List<DiagnosticRecord> records;
  final deleted = <String>[];
  @override
  Future<DiagnosticRecord> claim(AppAccountRef account, String id, String claim) => throw UnimplementedError();
  @override
  Future<List<DiagnosticRecord>> list(AppAccountRef account) async => [...records];
  @override
  Future<void> delete(AppAccountRef account, String id) async {
    deleted.add(id);
    records.removeWhere((record) => record.id == id);
  }
}
