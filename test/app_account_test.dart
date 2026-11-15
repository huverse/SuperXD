import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/page/account_page.dart';
import 'package:superxd/page/app_account_join_page.dart';
import 'package:superxd/page/app_account_page.dart';
import 'package:superxd/page/sensitive_clipboard.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';
import 'package:superxd/theme/campus_theme.dart';

// 应用账号（人工决策见 domain/app_account.dart 的 11-15 16:40:33 那条）：自己的账号体系，用户名加密码；中转客户端、编排、账号页与应用账号页。合成数据。
const _accountId = 'AAAAAAAAAAAAAAAAAAAAAA';
const _ticketId = 'TTTTTTTTTTTTTTTTTTTTTT';
const _code = 'ABCD0123EFGH4567JKMN89PQ';
// 编排测试里替身给的把手（slot 只是替身里的一个名字）。
const _account = AppAccountRef(accountId: _accountId, slot: 'fake-slot');
const _session = AppAccountSession(account: _account, username: 'tester_one');

void main() {
  group('恢复码与用户名', () {
    test('恢复码 24 位 Crockford base32，四位一组显示；输入时容错 O、I、L 与分隔符', () {
      final code = generateRecoveryCode();
      expect(code, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{24}$')));
      expect(generateRecoveryCode(), isNot(code));
      expect(formatRecoveryCode(_code), 'ABCD-0123-EFGH-4567-JKMN-89PQ');
      expect(normalizeRecoveryCode(' abcd-0123-efgh-4567-jkmn-89pq '), _code);
      expect(normalizeRecoveryCode('OOOO-IIII-LLLL-2222-3333-4444'), '000011111111222233334444');
      expect(normalizeRecoveryCode('ABCD'), isNull);
      expect(validAppUsername('Tester_1'), isTrue);
      expect(validAppUsername('ab'), isFalse);
      expect(validAppUsername('用户名'), isFalse);
      expect(validAppPassword('1234567'), isFalse);
      expect(validAppPassword('12345678'), isTrue);
    });
  });

  group('中转客户端', () {
    late _Relay relay;
    late MemoryAppAccountVault vault;
    late RelayAppAccountClient client;
    late SimpleKeyPair sealPair;
    setUp(() async {
      relay = _Relay();
      vault = MemoryAppAccountVault();
      sealPair = await X25519().newKeyPairFromSeed(List<int>.generate(32, (index) => index + 1));
      client = RelayAppAccountClient(vault: vault, transport: relay, sealKey: (await sealPair.extractPublicKey()).bytes);
    });

    test('注册：只发用户名与封装好的秘密（只有中转打得开、只认这台设备）；成功才把密钥、账号号与用户名存本机', () async {
      relay.reply = (request) => const RelayResponse(200, {'accountId': _accountId, 'username': 'tester_one', 'serverTime': 1});
      final session = await client.register('Tester_One', 'synthetic-pass', _code);
      final request = relay.requests.single;
      expect(request.path, '/v1/account/register');
      expect(request.body.keys.toSet(), {'signPublicKey', 'boxPublicKey', 'username', 'sealed'});
      expect(request.body['username'], 'tester_one');
      expect(request.headers['x-sxd-device'], request.deviceIdOfBody);
      expect(jsonEncode(request.body), isNot(contains('synthetic-pass')));
      final opened = await _open(sealPair, decodeBase64UrlNoPad(request.body['sealed'] as String), request.deviceIdOfBody);
      expect(jsonDecode(utf8.decode(opened)), {'password': 'synthetic-pass', 'recoveryCode': _code});
      expect((session.account, session.username), (const AppAccountRef(accountId: _accountId, slot: appAccountSlot), 'tester_one'));
      final saved = (await vault.read(appAccountSlot))!;
      expect((saved.accountId, saved.username, saved.identity.deviceId), (_accountId, 'tester_one', request.deviceIdOfBody));
      expect((await client.accountOf())!.username, 'tester_one');
    });

    test('登录与用恢复码重设各发各的秘密；中转的错误码换成给用户看的原因，失败不存本机', () async {
      relay.reply = (request) => const RelayResponse(200, {'accountId': _accountId, 'username': 'tester_one', 'serverTime': 1});
      await client.recover('tester_one', _code, 'new-synthetic', 'ZZZZ0123EFGH4567JKMN89PQ');
      final opened = await _open(sealPair, decodeBase64UrlNoPad(relay.requests.last.body['sealed'] as String), relay.requests.last.deviceIdOfBody);
      expect(relay.requests.last.path, '/v1/account/recover');
      expect(jsonDecode(utf8.decode(opened)), {'recoveryCode': _code, 'password': 'new-synthetic', 'newRecoveryCode': 'ZZZZ0123EFGH4567JKMN89PQ'});
      await vault.delete(appAccountSlot);
      final cases = <(Map<String, Object?>, int, AppAccountFailure, String)>[
        ({'code': 'CREDENTIALS_INVALID'}, 403, AppAccountFailure.credentialsInvalid, '用户名或密码不对'),
        ({'code': 'USERNAME_TAKEN'}, 409, AppAccountFailure.usernameTaken, '用户名已被占用'),
        ({'code': 'RATE_LIMITED', 'retryAfter': 60}, 429, AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
      ];
      for (final (body, status, failure, message) in cases) {
        relay.reply = (request) => RelayResponse(status, body);
        await expectLater(client.login('tester_one', 'synthetic-pass'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', failure).having((error) => error.message, 'message', message)));
      }
      expect(relay.requests.last.path, '/v1/account/login');
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await expectLater(client.login('tester_one', 'synthetic-pass'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.network)));
      relay.reply = (request) => const RelayResponse(200, {'accountId': 'bad id', 'username': 'tester_one'});
      await expectLater(client.login('tester_one', 'synthetic-pass'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.failed)));
      expect(await client.accountOf(), isNull);
    });

    test('扫码登录：出示用临时密钥，批准了才存本机；登录着的设备批准时带核对码', () async {
      final expiresAt = DateTime.utc(2026, 11, 15, 12, 5);
      relay.reply = (request) => RelayResponse(200, {'ticketId': _ticketId, 'code': '012345', 'expiresAt': expiresAt.millisecondsSinceEpoch});
      final join = await client.startJoin();
      final shown = relay.requests.single;
      expect(shown.path, '/v1/account/joins');
      expect((join.payload, join.expiresAt), ('superxd-join:$_ticketId:012345', expiresAt));
      expect(AppAccountJoin.parse(join.payload), (ticketId: _ticketId, code: '012345'));
      expect(AppAccountJoin.parse('SXD1F:ABC'), isNull);
      relay.reply = (request) => const RelayResponse(200, {'state': 'pending', 'account': null});
      expect(await client.joinState(join), isNull);
      expect(await client.accountOf(), isNull);
      relay.reply = (request) => const RelayResponse(200, {'state': 'approved', 'account': {'accountId': _accountId, 'username': 'tester_one', 'serverTime': 1}});
      expect((await client.joinState(join))!.username, 'tester_one');
      expect(relay.requests.last.headers['x-sxd-device'], shown.headers['x-sxd-device']);
      expect((await vault.read(appAccountSlot))!.identity.deviceId, shown.headers['x-sxd-device']);

      relay.reply = (request) => const RelayResponse(204, {});
      await client.approveJoin(join.payload);
      expect(relay.requests.last.path, '/v1/account/joins/$_ticketId/approve');
      expect(relay.requests.last.body, {'code': '012345'});
      expect(relay.requests.last.headers['x-sxd-device'], shown.headers['x-sxd-device']);
      await expectLater(client.approveJoin('https://example.com'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.joinExpired)));
      relay.reply = (request) => const RelayResponse(404, {'code': 'JOIN_NOT_FOUND'});
      await expectLater(client.approveJoin(join.payload), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.joinExpired)));
    });

    // [人工决策-2026-11-15 19:18:31] 扫码登录批准前看请求方的机型与属地、离开出示页作废票据（用户选推荐）。
    test('扫码登录：出示时带上机型，批准方批准前先看请求方的机型与属地；离开出示页作废还没批准的票据，没出示过或已批准的不发', () async {
      final modeled = RelayAppAccountClient(vault: vault, transport: relay, sealKey: (await sealPair.extractPublicKey()).bytes, deviceModel: () async => ' Xiaomi 23127PN0CC ');
      relay.reply = (request) => RelayResponse(200, {'ticketId': _ticketId, 'code': '012345', 'expiresAt': DateTime.now().millisecondsSinceEpoch + 300000});
      final join = await modeled.startJoin();
      expect(relay.requests.single.body['device'], 'Xiaomi 23127PN0CC');
      expect((await client.startJoin()).ticketId, _ticketId);
      expect(relay.requests.last.body.containsKey('device'), isFalse, reason: '取不到机型就不带');

      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      relay.reply = (request) => const RelayResponse(200, {'device': 'Xiaomi 23127PN0CC', 'region': '广东省深圳市'});
      final request = await client.inspectJoin(join.payload);
      expect((request.device, request.region), ('Xiaomi 23127PN0CC', '广东省深圳市'));
      expect('${relay.requests.last.method} ${relay.requests.last.path}', 'POST /v1/account/joins/$_ticketId/inspect');
      expect(relay.requests.last.body, {'code': '012345'});
      relay.reply = (request) => const RelayResponse(200, {'device': null, 'region': null});
      expect((await client.inspectJoin(join.payload)).device, isNull);
      relay.reply = (request) => RelayResponse(200, {'device': 'x' * 65, 'region': null});
      await expectLater(client.inspectJoin(join.payload), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.failed)));
      await expectLater(client.inspectJoin('https://example.com'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.joinExpired)));

      relay.reply = (request) => const RelayResponse(204, {});
      final count = relay.requests.length;
      await modeled.cancelJoin(join);
      expect('${relay.requests.last.method} ${relay.requests.last.path}', 'DELETE /v1/account/joins/$_ticketId');
      expect(relay.requests.last.headers['x-sxd-device'], relay.requests.first.headers['x-sxd-device'], reason: '用出示时那把临时密钥签名');
      final fresh = RelayAppAccountClient(vault: MemoryAppAccountVault(), transport: relay, sealKey: (await sealPair.extractPublicKey()).bytes);
      await fresh.cancelJoin(join);
      expect(relay.requests, hasLength(count + 1), reason: '没出示过不发');
    });

    test('扫码登录：手机时钟快了 10 分钟（中转校时后重发）时，二维码的失效时刻换成本机时钟，出示页照样倒数 5 分钟', () async {
      int serverNow() => DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
      relay.reply = (request) => (int.parse(request.headers['x-sxd-time']!) - serverNow()).abs() > 5 * 60000
          ? RelayResponse(401, {'code': 'CLOCK_SKEW', 'serverTime': serverNow()})
          : RelayResponse(200, {'ticketId': _ticketId, 'code': '012345', 'expiresAt': serverNow() + 5 * 60000});
      final join = await client.startJoin();
      expect(relay.requests, hasLength(2), reason: '校时后重发一次');
      expect(join.expiresAt.difference(DateTime.now()).inSeconds, inInclusiveRange(290, 300));
    });

    test('改密码、换恢复码：用登录着的密钥签名、秘密封装；没登录不发', () async {
      await expectLater(client.changePassword('changed-synthetic'), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.notSignedIn)));
      expect(relay.requests, isEmpty);
      final key = await SocialIdentity.generate();
      await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: _accountId, username: 'tester_one'));
      relay.reply = (request) => const RelayResponse(204, {});
      await client.changePassword('changed-synthetic');
      expect((relay.requests.last.path, relay.requests.last.headers['x-sxd-device']), ('/v1/account/password', key.deviceId));
      expect(jsonDecode(utf8.decode(await _open(sealPair, decodeBase64UrlNoPad(relay.requests.last.body['sealed'] as String), key.deviceId))), {'password': 'changed-synthetic'});
      await client.changeRecoveryCode(_code);
      expect(relay.requests.last.path, '/v1/account/recovery-code');
      expect(jsonDecode(utf8.decode(await _open(sealPair, decodeBase64UrlNoPad(relay.requests.last.body['sealed'] as String), key.deviceId))), {'recoveryCode': _code});
    });

    test('查看账号：别处注销了就删本机记录；退出连不上也删本机；注销要服务端删成才算', () async {
      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      relay.reply = (request) => const RelayResponse(200, {'accountId': _accountId, 'username': 'tester_one', 'deviceCount': 2, 'createdAt': 1763000000000});
      expect((await client.summary()).deviceCount, 2);
      relay.reply = (request) => const RelayResponse(404, {'code': 'ACCOUNT_NOT_FOUND'});
      await expectLater(client.summary(), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.notSignedIn)));
      expect(await client.accountOf(), isNull);

      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      relay.reply = (request) => throw const RelayException(RelayCode.network);
      await client.signOut();
      expect('${relay.requests.last.method} ${relay.requests.last.path}', 'DELETE /v1/devices');
      expect(await vault.read(appAccountSlot), isNull);

      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      await expectLater(client.delete(), throwsA(isA<AppAccountException>()));
      expect(await client.accountOf(), isNotNull);
      relay.reply = (request) => const RelayResponse(204, {});
      await client.delete();
      expect(relay.requests.map((request) => '${request.method} ${request.path}').toList().reversed.take(2).toList(), ['DELETE /v1/devices', 'DELETE /v1/account']);
      expect(await client.accountOf(), isNull);
    });

    // [人工决策-2026-11-15 19:18:31] 区分「账号已注销」与「这把密钥不在账号里」（用户选推荐）。
    test('查看账号：账号已注销（ACCOUNT_DELETED）同样删本机记录，失败分类是账号已注销', () async {
      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      relay.reply = (request) => const RelayResponse(410, {'code': 'ACCOUNT_DELETED'});
      await expectLater(client.summary(), throwsA(isA<AppAccountException>().having((error) => error.failure, 'failure', AppAccountFailure.deleted)));
      expect(await client.accountOf(), isNull);
    });

    test('11-15 以前每个教务账号一把的旧密钥：删掉并交出把手，新的那把不动', () async {
      final legacy = await SocialIdentity.generate();
      await vault.write('account.AAAA', AppAccountKey(identity: legacy, accountId: 'OLDOLDOLDOLDOLDOLDOLDO'));
      await vault.write(appAccountSlot, AppAccountKey(identity: await SocialIdentity.generate(), accountId: _accountId, username: 'tester_one'));
      expect(await client.dropLegacy(), [const AppAccountRef(accountId: 'OLDOLDOLDOLDOLDOLDOLDO', slot: 'account.AAAA')]);
      expect(await vault.slots(), [appAccountSlot]);
      expect(await client.dropLegacy(), isEmpty);
    });
  });

  group('编排', () {
    late _Client client;
    late AppAccounts appAccounts;
    late DateTime now;
    late List<AppAccountRef> deleted;
    setUp(() async {
      now = DateTime.utc(2026, 11, 15, 12);
      client = _Client();
      deleted = [];
      appAccounts = AppAccounts(client: client, onDeleted: deleted.add, now: () => now, recoveryCode: () => _code);
      await appAccounts.load();
    });
    tearDown(() => appAccounts.dispose());

    test('启动时清掉旧密钥并交给 onDeleted（清那些账号的本机私信），再读本机账号', () async {
      client.legacy = [const AppAccountRef(accountId: 'OLDOLDOLDOLDOLDOLDOLDO', slot: 'account.AAAA')];
      client.session = _session;
      await appAccounts.load();
      expect(deleted.map((account) => account.accountId), ['OLDOLDOLDOLDOLDOLDOLDO']);
      expect((appAccounts.accountId, appAccounts.username), (_accountId, 'tester_one'));
    });

    test('本机记录读不出（安全存储出错、格式认不出）：照样读完、当没登录（账号页那一行能点、私信能切过去），重新登录就覆盖它；清旧密钥出错不挡读本机账号', () async {
      final broken = _Client()..loadFailure = const FormatException('保存的应用账号不可用');
      final accounts = AppAccounts(client: broken, now: () => now, recoveryCode: () => _code);
      addTearDown(accounts.dispose);
      await accounts.load();
      expect((accounts.loaded, accounts.current), (true, null));
      broken.loadFailure = null;
      expect(await accounts.login('tester_one', 'synthetic-pass'), isA<AppAccountDone>());
      expect(accounts.username, 'tester_one');

      final legacyBroken = _Client()..legacyFailure = Exception('安全存储出错')..session = _session;
      final second = AppAccounts(client: legacyBroken, now: () => now, recoveryCode: () => _code);
      addTearDown(second.dispose);
      await second.load();
      expect((second.loaded, second.username), (true, 'tester_one'));
    });

    test('注册把生成的恢复码交给页面；登录；用恢复码重设时先规范写法，不像恢复码的不联网，成功换新恢复码', () async {
      expect(await appAccounts.register('tester_one', 'synthetic-pass'), isA<AppAccountRecoveryCode>().having((result) => result.code, 'code', _code));
      expect(client.registered, [('tester_one', 'synthetic-pass', _code)]);
      expect(appAccounts.username, 'tester_one');
      await appAccounts.signOut();
      expect(appAccounts.current, isNull);
      expect(await appAccounts.login('tester_one', 'synthetic-pass'), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已登录应用账号'));
      await appAccounts.signOut();
      expect(await appAccounts.recover('tester_one', 'ABCD', 'new-synthetic'), isA<AppAccountError>());
      expect(client.recovered, isEmpty);
      expect(await appAccounts.recover('tester_one', 'abcd-0123-efgh-4567-jkmn-89pq', 'new-synthetic'), isA<AppAccountRecoveryCode>());
      expect(client.recovered, [('tester_one', _code, 'new-synthetic', _code)]);
      client.failure = const AppAccountException(AppAccountFailure.credentialsInvalid, '用户名或密码不对');
      await appAccounts.signOut();
      expect(await appAccounts.login('tester_one', 'wrong-pass'), isA<AppAccountError>().having((result) => result.message, 'message', '用户名或密码不对'));
      expect(await appAccounts.recover('tester_one', _code, 'new-synthetic'), isA<AppAccountError>().having((result) => result.message, 'message', '用户名或恢复码不对'));
      expect(appAccounts.current, isNull);
    });

    test('改密码、换恢复码要登录着；扫码登录：出示、连不上照旧等、过期报错、批准了就登录', () async {
      expect(await appAccounts.changePassword('changed-synthetic'), isA<AppAccountError>());
      client.session = _session;
      await appAccounts.load();
      expect(await appAccounts.changePassword('changed-synthetic'), isA<AppAccountDone>());
      expect(await appAccounts.renewRecoveryCode(), isA<AppAccountRecoveryCode>().having((result) => result.code, 'code', _code));
      expect(client.changes, ['password changed-synthetic', 'recovery $_code']);
      await appAccounts.signOut();

      final join = (await appAccounts.startJoin() as AppAccountJoinStarted).join;
      expect(await appAccounts.pollJoin(join), isA<AppAccountWaiting>());
      client.joinFailure = const AppAccountException(AppAccountFailure.network, '连不上服务器');
      expect(await appAccounts.pollJoin(join), isA<AppAccountWaiting>());
      client.joinFailure = const AppAccountException(AppAccountFailure.joinExpired, '二维码已过期或不对，请刷新');
      expect(await appAccounts.pollJoin(join), isA<AppAccountError>());
      client.joinFailure = null;
      client.joinApproved = true;
      expect(await appAccounts.pollJoin(join), isA<AppAccountDone>());
      expect(appAccounts.username, 'tester_one');
      expect(await appAccounts.approveJoin(join.payload), isA<AppAccountDone>().having((result) => result.notice, 'notice', '已让新设备登录'));
      expect(client.approved, [join.payload]);
    });

    test('中转说这台设备不在账号里了：马上核一次，退回未登录', () async {
      client.session = _session;
      await appAccounts.load();
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      expect(await appAccounts.approveJoin('superxd-join:$_ticketId:012345'), isA<AppAccountError>());
      await pumpEventQueue();
      expect(client.summaries, 1);
      expect(appAccounts.current, isNull);
    });

    test('每天最多看一次账号；别处注销了就退回未登录', () async {
      client.session = _session;
      await appAccounts.load();
      await appAccounts.check();
      await appAccounts.check();
      expect(client.summaries, 1);
      now = now.add(AppAccounts.checkGap);
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      await appAccounts.check();
      expect(client.summaries, 2);
      expect(appAccounts.current, isNull);
      now = now.add(AppAccounts.checkGap);
      await appAccounts.check();
      expect(client.summaries, 2, reason: '没登录不联网');
    });

    // [人工决策-2026-11-15 19:18:31] 只有中转说账号已注销才清本机那个账号的私信；只是不在账号里（被顶掉、恢复码重设踢下线）只退回未登录。
    test('别处注销了（ACCOUNT_DELETED）：退回未登录并把账号交给 onDeleted；只是不在账号里了不交；操作中遇到也马上核一次', () async {
      client.session = _session;
      await appAccounts.load();
      client.failure = const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出');
      await appAccounts.check(force: true);
      expect(appAccounts.current, isNull);
      expect(deleted, isEmpty);
      client.session = _session;
      await appAccounts.load();
      client.failure = const AppAccountException(AppAccountFailure.deleted, '应用账号已注销');
      await appAccounts.check(force: true);
      expect(appAccounts.current, isNull);
      expect(deleted, [_account]);
      client.session = _session;
      await appAccounts.load();
      expect(await appAccounts.changePassword('changed-synthetic'), isA<AppAccountError>());
      await pumpEventQueue();
      expect(deleted, [_account, _account]);
    });

    test('批准前看请求方：登录着才看，结果交给页面；离开出示页作废票据，出错只记日志', () async {
      expect(await appAccounts.inspectJoin('superxd-join:$_ticketId:012345'), isA<AppAccountError>());
      client.session = _session;
      await appAccounts.load();
      expect(await appAccounts.inspectJoin('superxd-join:$_ticketId:012345'), isA<AppAccountJoinRequested>().having((result) => result.request.region, 'region', '广东省深圳市'));
      final join = AppAccountJoin(ticketId: _ticketId, code: '012345', expiresAt: DateTime.utc(2026, 11, 15, 12, 5));
      await appAccounts.cancelJoin(join);
      client.cancelFailure = const AppAccountException(AppAccountFailure.network, '连不上服务器');
      await appAccounts.cancelJoin(join);
      expect(client.cancelled, [_ticketId, _ticketId]);
    });

    // 人工决策见 social/social_service.dart（11-14 17:56:46）：注销成了才通知组合根清掉这台手机上那个账号的私信；注销失败不通知。
    test('注销成功后把注销的账号交给 onDeleted，失败不交', () async {
      client.session = _session;
      await appAccounts.load();
      client.failure = const AppAccountException(AppAccountFailure.network, '连不上服务器');
      expect(await appAccounts.deleteAccount(), isA<AppAccountError>());
      expect(deleted, isEmpty);
      client.failure = null;
      expect(await appAccounts.deleteAccount(), isA<AppAccountDone>());
      expect(deleted, [_account]);
      expect(appAccounts.current, isNull);
    });
  });

  group('页面', () {
    late _Client client;
    late AppAccounts appAccounts;
    setUp(() async {
      client = _Client();
      appAccounts = AppAccounts(client: client, recoveryCode: () => _code);
      await appAccounts.load();
    });
    tearDown(() => appAccounts.dispose());

    Future<void> pumpPage(WidgetTester tester, {AccountDiagnostics? diagnostics, JoinScanner? scan}) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AppAccountPage(appAccounts: appAccounts, diagnostics: diagnostics, scanJoin: scan ?? scanJoinWithCamera)));
      await tester.pumpAndSettle();
    }

    Future<void> clearToast(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester, String label, String text) async {
      await tester.enterText(find.widgetWithText(TextField, label), text);
      await tester.pump();
    }

    testWidgets('账号页：应用账号一行写用户名或未登录，点了推入应用账号页；没配中转时不显示', (tester) async {
      final session = AppSession(_Accounts());
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: AccountPage(session: session, name: '同学甲', appAccounts: appAccounts)));
      await tester.pumpAndSettle();
      expect(find.text('未登录'), findsOneWidget);
      client.session = _session;
      await appAccounts.load();
      await tester.pumpAndSettle();
      expect(find.text('tester_one'), findsOneWidget);
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('修改密码'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(key: const ValueKey('bare'), theme: campusTheme(), home: AccountPage(session: session, name: '同学甲')));
      await tester.pumpAndSettle();
      expect(find.text('应用账号'), findsNothing);
      expect(find.text('退出登录'), findsOneWidget);
    });

    testWidgets('注册：格式不对原地说明、不联网；注册成功弹出恢复码（按返回不关，可复制），点「我已保存」后显示用户名', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/sensitive_clipboard'), (call) async {
        copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/sensitive_clipboard'), null));
      await pumpPage(tester);
      await tester.tap(find.text('注册'));
      await tester.pumpAndSettle();
      await fill(tester, '用户名', 'ab');
      await fill(tester, '新密码', 'short');
      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();
      expect(find.text('3–20 位字母、数字或下划线'), findsOneWidget);
      expect(find.text('8–64 个字符'), findsOneWidget);
      expect(client.registered, isEmpty);
      await fill(tester, '用户名', 'tester_one');
      await fill(tester, '新密码', 'synthetic-pass');
      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();
      expect(client.registered, [('tester_one', 'synthetic-pass', _code)]);
      expect(find.text('保存恢复码'), findsOneWidget);
      expect(find.text('ABCD-0123-EFGH\n4567-JKMN-89PQ'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('保存恢复码'), findsOneWidget, reason: '没点「我已保存」不关');
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, 'ABCD-0123-EFGH-4567-JKMN-89PQ');
      await tester.tap(find.text('我已保存'));
      await tester.pumpAndSettle();
      expect(find.text('tester_one'), findsOneWidget);
      expect(find.text('已注册并登录'), findsOneWidget);
      await clearToast(tester);
    });

    // [人工决策-2026-11-15 19:18:31] 恢复码的「复制」标成敏感内容、一分钟后清掉（用户选推荐）：安卓、iOS 走原生通道，别的平台退回普通复制。
    testWidgets('恢复码的「复制」走敏感剪贴板：交给原生的是一行的写法与一分钟后清掉', (tester) async {
      final calls = <MethodCall>[];
      var plain = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/sensitive_clipboard'), (call) async {
        calls.add(call);
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') plain = true;
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/sensitive_clipboard'), null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Builder(builder: (context) => TextButton(onPressed: () => showRecoveryCode(context, _code), child: const Text('打开')))));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'copy');
      expect(calls.single.arguments, {'text': 'ABCD-0123-EFGH-4567-JKMN-89PQ', 'clearAfterMs': 60000});
      expect(plain, isFalse);
      expect(find.text('已复制恢复码'), findsOneWidget);
      await tester.tap(find.text('我已保存'));
      await clearToast(tester);
      // 没有这个通道的平台（测试、桌面）退回普通复制。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('superxd/sensitive_clipboard'), (call) async => throw MissingPluginException());
      await copySensitive('ABCD-0123-EFGH-4567-JKMN-89PQ');
      expect(plain, isTrue);
    });

    testWidgets('登录：密码不对写明原因；忘记密码凭恢复码重设，成功弹出新的恢复码', (tester) async {
      await pumpPage(tester);
      client.failure = const AppAccountException(AppAccountFailure.credentialsInvalid, '用户名或密码不对');
      await fill(tester, '用户名', 'tester_one');
      await fill(tester, '密码', 'wrong-pass');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();
      expect(find.text('用户名或密码不对'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('wrong-pass'), findsOneWidget, reason: '失败不清输入，改一处再交');
      client.failure = null;
      await tester.tap(find.text('忘记密码'));
      await tester.pumpAndSettle();
      expect(find.text('用恢复码重设密码'), findsOneWidget);
      await fill(tester, '用户名', 'tester_one');
      await fill(tester, '恢复码', 'abcd 0123 efgh 4567 jkmn 89pq');
      await fill(tester, '新密码', 'new-synthetic');
      await tester.tap(find.widgetWithText(FilledButton, '重设并登录'));
      await tester.pumpAndSettle();
      expect(client.recovered, [('tester_one', _code, 'new-synthetic', _code)]);
      expect(find.text('保存恢复码'), findsOneWidget);
      await tester.tap(find.text('我已保存'));
      await tester.pumpAndSettle();
      expect(find.text('tester_one'), findsOneWidget);
      await clearToast(tester);
      // 退出后回到的是「登录」那一段，不停在重设。
      await tester.tap(find.text('退出应用账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      expect(find.text('用恢复码重设密码'), findsNothing);
      await clearToast(tester);
    });

    // [人工决策-2026-11-15 19:18:31] 离开出示页时作废票据（用户选推荐）：刷新二维码时旧的那张也作废。
    testWidgets('扫码登录：刷新二维码作废旧的那张，离开出示页作废当前那张', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await pumpPage(tester);
      await tester.tap(find.text('扫码登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新二维码'));
      await tester.pumpAndSettle();
      expect(client.cancelled, [_ticketId]);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(client.cancelled, [_ticketId, _ticketId]);
      expect(find.text('扫码登录'), findsOneWidget);
    });

    testWidgets('扫码登录：出示二维码与核对码，批准后回来显示已登录', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('扫码登录'));
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
      expect(find.text('tester_one'), findsOneWidget);
      expect(find.text('已登录应用账号'), findsOneWidget);
      await clearToast(tester);
    });

    testWidgets('登录着：让新设备登录（扫码、核对码确认）、修改密码、换新的恢复码要确认，退出与注销都要确认', (tester) async {
      client.session = _session;
      await appAccounts.load();
      await pumpPage(tester, scan: (context) async => 'superxd-join:$_ticketId:012345');
      await tester.tap(find.text('让新设备登录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('012345'), findsOneWidget);
      // 人工决策见 server/src/modules/account/account.service.ts 的 19:18:31 那条：批准前写出请求方的机型、属地与提醒。
      expect(find.textContaining('Xiaomi 23127PN0CC'), findsOneWidget);
      expect(find.textContaining('广东省深圳市'), findsOneWidget);
      expect(find.textContaining('不是你本人操作就不要确认'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(client.approved, ['superxd-join:$_ticketId:012345']);
      expect(find.text('已让新设备登录'), findsOneWidget);
      await clearToast(tester);

      await tester.tap(find.text('修改密码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'changed-synthetic');
      await tester.tap(find.widgetWithText(FilledButton, '修改'));
      await tester.pumpAndSettle();
      expect(client.changes, ['password changed-synthetic']);
      await clearToast(tester);

      await tester.tap(find.text('换新的恢复码'));
      await tester.pumpAndSettle();
      expect(find.text('原来的恢复码会作废。'), findsOneWidget);
      await tester.tap(find.text('换新的'));
      await tester.pumpAndSettle();
      expect(find.text('保存恢复码'), findsOneWidget);
      await tester.tap(find.text('我已保存'));
      await tester.pumpAndSettle();
      expect(client.changes.last, 'recovery $_code');
      await clearToast(tester);

      await tester.tap(find.text('注销应用账号'));
      await tester.pumpAndSettle();
      expect(find.text('注销应用账号？'), findsOneWidget);
      // 人工决策见 social/social_service.dart（11-14 17:56:46）：注销连同私信一起删，确认框写明。
      expect(find.textContaining('私信好友'), findsOneWidget);
      await tester.tap(find.text('注销'));
      await tester.pumpAndSettle();
      expect(client.deleted, 1);
      expect(find.text('应用账号已注销'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      await clearToast(tester);
    });

    // 人工决策见 domain/diagnostic_upload.dart：登录着应用账号时，看与删记在账号下的诊断包。
    testWidgets('登录着多一项「我上传的诊断包」：列出记在账号下的包，点一行复制编号，⋯里删除要确认', (tester) async {
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
      client.session = _session;
      await appAccounts.load();
      await pumpPage(tester, diagnostics: diagnostics);
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
      await clearToast(tester);
    });
  });
}

// 按服务端的布局解开信封（同 server/src/modules/account/account_keys.ts），验证只有中转私钥、而且只按发起的设备号打得开。
Future<List<int>> _open(SimpleKeyPair recipient, List<int> sealed, String deviceId) async {
  final recipientPublic = (await recipient.extractPublicKey()).bytes;
  final ephemeral = sealed.sublist(1, 33);
  final shared = await X25519().sharedSecretKey(keyPair: recipient, remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519));
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, nonce: [...ephemeral, ...recipientPublic], info: utf8.encode('SXD1-account-sign-in'));
  final box = SecretBox(sealed.sublist(45, sealed.length - 16), nonce: sealed.sublist(33, 45), mac: Mac(sealed.sublist(sealed.length - 16)));
  final aes = AesGcm.with256bits();
  await expectLater(aes.decrypt(box, secretKey: key, aad: [1, ...ephemeral, ...utf8.encode('CCCCCCCCCCCCCCCCCCCCCC')]), throwsA(isA<SecretBoxAuthenticationError>()));
  return aes.decrypt(box, secretKey: key, aad: [1, ...ephemeral, ...utf8.encode(deviceId)]);
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
  AppAccountSession? session;
  List<AppAccountRef> legacy = const [];
  final registered = <(String, String, String)>[];
  final recovered = <(String, String, String, String)>[];
  final changes = <String>[];
  final approved = <String>[];
  int summaries = 0;
  int joinPolls = 0;
  int deleted = 0;
  bool joinApproved = false;
  AppAccountException? failure;
  AppAccountException? joinFailure;
  AppAccountException? cancelFailure;
  final cancelled = <String>[];
  Object? loadFailure;
  Object? legacyFailure;

  void _fail() {
    if (failure case final error?) throw error;
  }

  AppAccountSession _signIn(String username) => session = AppAccountSession(account: _account, username: normalizeAppUsername(username));

  @override
  Future<AppAccountSession?> accountOf() async {
    if (loadFailure case final error?) throw error;
    return session;
  }
  @override
  Future<List<AppAccountRef>> dropLegacy() async {
    if (legacyFailure case final error?) throw error;
    final dropped = legacy;
    legacy = const [];
    return dropped;
  }
  @override
  Future<AppAccountSession> register(String username, String password, String recoveryCode) async {
    _fail();
    registered.add((username, password, recoveryCode));
    return _signIn(username);
  }
  @override
  Future<AppAccountSession> login(String username, String password) async {
    _fail();
    return _signIn(username);
  }
  @override
  Future<AppAccountSession> recover(String username, String recoveryCode, String password, String newRecoveryCode) async {
    _fail();
    recovered.add((username, recoveryCode, password, newRecoveryCode));
    return _signIn(username);
  }
  @override
  Future<void> changePassword(String password) async {
    _fail();
    changes.add('password $password');
  }
  @override
  Future<void> changeRecoveryCode(String recoveryCode) async {
    _fail();
    changes.add('recovery $recoveryCode');
  }
  @override
  Future<AppAccountJoin> startJoin() async {
    _fail();
    return AppAccountJoin(ticketId: _ticketId, code: '012345', expiresAt: DateTime.now().add(const Duration(minutes: 5)));
  }
  @override
  Future<AppAccountSession?> joinState(AppAccountJoin join) async {
    joinPolls++;
    if (joinFailure case final error?) throw error;
    return joinApproved ? _signIn('tester_one') : null;
  }
  @override
  Future<void> approveJoin(String payload) async {
    _fail();
    approved.add(payload);
  }
  @override
  Future<AppAccountJoinRequest> inspectJoin(String payload) async {
    _fail();
    return const AppAccountJoinRequest(device: 'Xiaomi 23127PN0CC', region: '广东省深圳市');
  }
  @override
  Future<void> cancelJoin(AppAccountJoin join) async {
    cancelled.add(join.ticketId);
    if (cancelFailure case final error?) throw error;
  }
  @override
  Future<AppAccountSummary> summary() async {
    summaries++;
    _fail();
    return AppAccountSummary(accountId: session!.account.accountId, username: session!.username, deviceCount: 1, createdAt: DateTime.utc(2026));
  }
  @override
  Future<void> signOut() async => session = null;
  @override
  Future<void> delete() async {
    _fail();
    deleted++;
    session = null;
  }
}

// 账号页只用到的几项，其余交给 noSuchMethod。
class _Accounts extends AccountAccess {
  @override
  AccountIdentity? get activeIdentity => const AccountIdentity(source: 'http://school.example', loginId: '20260000001');
  @override
  SessionView? get activeSession => const SessionView(loginId: '20260000001', name: '同学甲', className: '');
  @override
  int get generation => 1;
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
