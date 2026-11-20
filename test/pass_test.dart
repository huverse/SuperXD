import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/passes.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/pass.dart';
import 'package:superxd/local/pass_memory.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_pass_client.dart';

// 积分时长券（人工决策见 lib/domain/pass.dart 与服务端 src/modules/pass/pass.service.ts；预接好、不启用）：清单与自己的券的外部输入边界、
// 本机记录、编排的判定（清单里没有就不拦、没到期的放行、离线照本机记的）与中转客户端的清单请求。服务端的购买与续期在 server/test/pass.e2e.test.ts。
const cinema = PassOffer(id: 'toolbox.cinema', title: '电影院', price: 300, days: 7);
const account = AppAccountRef(accountId: 'acct-1', slot: 'slot-1');

class _Client implements PassClient {
  List<PassOffer> offerList = const [cinema];
  Map<String, DateTime> heldMap = const {};
  Object? failure;
  var calls = 0;
  @override
  Future<List<PassOffer>> offers() async {
    calls++;
    if (failure case final error?) throw error;
    return offerList;
  }

  @override
  Future<Map<String, DateTime>> held(AppAccountRef account) async {
    calls++;
    if (failure case final error?) throw error;
    return heldMap;
  }

  @override
  Future<Map<String, DateTime>> buy(AppAccountRef account, String id) async {
    calls++;
    if (failure case final error?) throw error;
    return heldMap = {id: DateTime.utc(2026, 11, 27)};
  }
}

class _Transport implements RelayTransport {
  _Transport(this.reply);
  final Future<RelayResponse> Function(String method, String path) reply;
  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) => reply(method, pathWithQuery);
}

void main() {
  test('清单与自己的券是外部输入：编号重复、价格天数越界、多余层级都整份拒收', () {
    expect(decodePassOffers({'offers': <Object?>[]}), isEmpty);
    expect(decodePassOffers({'offers': [{'id': 'toolbox.cinema', 'title': '电影院', 'price': 300, 'days': 7}]}).single.days, 7);
    for (final bad in [
      {'offers': [{'id': 'toolbox.cinema', 'title': '电影院', 'price': 300, 'days': 7}, {'id': 'toolbox.cinema', 'title': '又一个', 'price': 1, 'days': 1}]},
      {'offers': [{'id': 'toolbox.cinema', 'title': '电影院', 'price': 0, 'days': 7}]},
      {'offers': [{'id': 'toolbox.cinema', 'title': '电影院', 'price': 300, 'days': passDaysMax + 1}]},
      {'offers': [{'id': 'Bad Id', 'title': '电影院', 'price': 300, 'days': 7}]},
      {'list': <Object?>[]},
    ]) {
      expect(() => decodePassOffers(bad), throwsFormatException, reason: '$bad');
    }
    expect(decodePassHeld({'held': [{'id': 'toolbox.cinema', 'until': 1795000000000}]}).values.single.isUtc, isTrue);
    expect(() => decodePassHeld({'held': [{'id': 'toolbox.cinema', 'until': '明天'}]}), throwsFormatException);
  });

  test('本机记录：重开还在，只记一个账号，别的账号看不到；坏文件当没有', () async {
    final directory = await Directory.systemTemp.createTemp('pass_memory');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'pass.json'));
    final memory = await FilePassMemory.open(file);
    await memory.saveOffers(const [cinema]);
    await memory.saveHeld('acct-1', {'toolbox.cinema': DateTime.utc(2026, 11, 27)});
    final reopened = await FilePassMemory.open(file);
    expect(reopened.offers.single.price, 300);
    expect(reopened.heldOf('acct-1')['toolbox.cinema'], DateTime.utc(2026, 11, 27));
    expect(reopened.heldOf('acct-2'), isEmpty);
    await file.writeAsString('{坏');
    expect((await FilePassMemory.open(file)).offers, isEmpty);
  });

  group('编排', () {
    late _Client client;
    AppAccountRef? signedIn;
    var online = true;
    var now = DateTime.utc(2026, 11, 20);
    var gone = 0;
    Passes passes() => Passes(memory: FilePassMemory.memory(), client: client, account: () => signedIn, accountId: () => signedIn?.accountId, accountGone: () async => gone++, online: () => online, now: () => now);

    setUp(() {
      client = _Client();
      signedIn = account;
      online = true;
      now = DateTime.utc(2026, 11, 20);
      gone = 0;
    });

    test('中转没写这项（现在的状态）就不拦；写了而没买的拦住、能买；买到的到期前放行，过了到期又拦', () async {
      client.offerList = const [];
      final access = passes();
      await access.refresh();
      expect(access.locked('toolbox.cinema'), isFalse);
      client.offerList = const [cinema];
      await access.refresh();
      expect((access.locked('toolbox.cinema'), access.canBuy, access.offer('toolbox.cinema')?.price), (true, true, 300));
      await access.buy('toolbox.cinema');
      expect((access.locked('toolbox.cinema'), access.until('toolbox.cinema')), (false, DateTime.utc(2026, 11, 27)));
      now = DateTime.utc(2026, 11, 27, 0, 0, 1);
      expect(access.locked('toolbox.cinema'), isTrue);
    });

    test('仅本机时不联网、只认本机记的，也不能买；没登录看不到别人的券、不能买', () async {
      final access = passes();
      await access.refresh();
      online = false;
      final calls = client.calls;
      await access.refresh();
      expect(client.calls, calls);
      expect(access.canBuy, isFalse);
      await expectLater(access.buy('toolbox.cinema'), throwsA(isA<PassException>().having((error) => error.failure, 'failure', PassFailure.network)));
      online = true;
      signedIn = null;
      expect((access.locked('toolbox.cinema'), access.canBuy), (true, false));
      await expectLater(access.buy('toolbox.cinema'), throwsA(isA<PassException>().having((error) => error.failure, 'failure', PassFailure.notSignedIn)));
    });

    test('中转说账号不在了：让应用账号马上核一次，照旧用本机记的', () async {
      final access = passes();
      client.failure = const PassException(PassFailure.notSignedIn, '应用账号已经退出');
      await access.refresh();
      expect(gone, 1);
    });
  });

  test('中转客户端：清单免签名请求 /v1/app/passes，回复看不懂报失败，限流与连不上分开报', () async {
    RelayPassClient client(Future<RelayResponse> Function(String method, String path) reply) => RelayPassClient(vault: const _NoVault(), transport: _Transport(reply));
    expect((await client((method, path) async {
      expect((method, path), ('GET', '/v1/app/passes'));
      return const RelayResponse(200, {'offers': [{'id': 'toolbox.cinema', 'title': '电影院', 'price': 300, 'days': 7}]});
    }).offers()).single.id, 'toolbox.cinema');
    await expectLater(client((method, path) async => const RelayResponse(200, {'offers': 'x'})).offers(), throwsA(isA<PassException>().having((error) => error.failure, 'failure', PassFailure.failed)));
    await expectLater(client((method, path) async => throw const RelayException(RelayCode.rateLimited)).offers(), throwsA(isA<PassException>().having((error) => error.failure, 'failure', PassFailure.rateLimited)));
    await expectLater(client((method, path) async => throw const RelayException(RelayCode.network)).offers(), throwsA(isA<PassException>().having((error) => error.failure, 'failure', PassFailure.network)));
  });
}

// 清单请求不签名，用不到密钥。
class _NoVault implements AppAccountVault {
  const _NoVault();
  @override
  Future<AppAccountKey?> read(String slot) async => null;
  @override
  Future<void> write(String slot, AppAccountKey key) async {}
  @override
  Future<void> delete(String slot) async {}
  @override
  Future<List<String>> slots() async => const [];
}
