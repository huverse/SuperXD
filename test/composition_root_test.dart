import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/local/network_mode_memory.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_spaces.dart';

import 'fake_relay.dart';

// 组合根接线测试（审查 P1-5：各模块单测都对、接起来不对的缺陷以前只能在模拟器上走查发现，app_services.dart 几乎没被执行过）：
// 用 app_services.dart 的真实造法、app_lifecycle.dart 的真实钩子与 watchX，按 lib/main.dart 的先后接起来，中转换成内存版 FakeRelay、
// 应用账号与私信身份的密钥库换成内存版，不签名的设备侧客户端在测试绑定下一律拿到 400（失败只记日志）。main.dart 的这段接线改了，这里跟着改。
// 走的路径：同意之前不发签名请求；同意之后私信切到账号（还没开启）、看一眼账号、问点名，开启后挂到账号；本地化时私信停下、不再联网；改回联网化接着用；
// 本地化启动、改回联网化后被挡下的钩子补做（11-17 审查发现的缺陷，#310）；退出应用账号时私信跟着退。
class _App {
  _App({required this.relay, required this.keys, required this.network, required this.social, required this.appAccounts, required this.agreed});
  final FakeRelay relay;
  final MemoryAppAccountVault keys;
  final NetworkPreference network;
  final SocialService social;
  final AppAccounts appAccounts;
  final Completer<void> agreed;

  List<String> get calls => relay.calls;
}

late Directory _temporary;
var _apps = 0;
final _logged = <String>[];

Future<_App> _compose({required NetworkMode mode, bool signedIn = true}) async {
  final support = Directory(path.join(_temporary.path, 'app_${_apps++}'))..createSync();
  final relay = FakeRelay(), keys = MemoryAppAccountVault();
  if (signedIn) await relay.signIn(keys, slot: appAccountSlot);
  final wiring = RelayWiring(base: 'http://127.0.0.1:9', transport: relay.transport(), accountKeys: keys);
  final memory = FileNetworkModeMemory.memory();
  await memory.saveMode(mode);
  final network = NetworkPreference(memory: memory);
  bool networkOnline() => network.online;
  // 以下按 lib/main.dart 的先后。
  late final AppAccounts? appAccounts;
  final diagnostics = diagnosticsOf(wiring, () => appAccounts, online: networkOnline);
  final social = SocialService(
    spaces: SocialSpaces(vault: MemoryIdentityVault(), directory: path.join(support.path, 'databases')),
    accountKeys: wiring.accountKeys,
    transport: wiring.transport,
    accountGone: () => unawaited(appAccounts?.check(force: true)),
    serverKeys: FakeRelay.serverKeys,
  );
  appAccounts = appAccountsOf(wiring, onDeleted: (account) => unawaited(social.forgetAccount(account)));
  final challenges = challengesOf(wiring, appAccounts);
  final rollouts = await rolloutsOf(support, wiring, appAccounts, challenges, online: networkOnline);
  final unlocks = unlocksOf(wiring, rollouts, appAccounts, accountOn: networkOnline);
  network.addListener(unlocks!.reconsider);
  final updatesOpen = appUpdates(support, wiring, rollouts), notesOpen = developerNotes(support, wiring), festivalsOpen = festivalsOf(support, wiring, appAccounts, online: networkOnline);
  await Future.wait<Object?>([updatesOpen, notesOpen, festivalsOpen]);
  final updates = await updatesOpen, notes = await notesOpen, festivals = await festivalsOpen;
  final health = await appHealthOf(support, wiring);
  final moments = AppMoments(notes: notes, festivals: festivals, timetable: () async => const CampusTimetable([], gap: TimetableGap.signedOut));
  // 渠道（appFlavor）只在渠道构建里有，测试里不检查更新；诊断包只在用户点上传时才用，这里只核对造得出来。
  expect(updates, isNull);
  expect(diagnostics, isNotNull);
  expect(challenges, isNotNull);
  final agreed = Completer<void>();
  final hooks = AppHooks(agreed: agreed.future, policy: network);
  watchSocial(social, appAccounts, hooks, network: network);
  watchMoments(moments, hooks, notes: notes, festivals: festivals, appAccounts: appAccounts);
  watchAppAccounts(appAccounts!, hooks);
  watchRollouts(rollouts, hooks);
  watchAppHealth(health, hooks);
  watchUnlocks(unlocks, hooks);
  return _App(relay: relay, keys: keys, network: network, social: social, appAccounts: appAccounts, agreed: agreed);
}

// 切到后台再回来，按系统真实的先后一步步走（监听器只认合法的相邻状态）。
void _cycle() {
  final binding = TestWidgetsFlutterBinding.instance;
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    binding.handleAppLifecycleStateChanged(state);
  }
}

// 等异步的接线做完：条件成立就返回，最多等 5 秒。
Future<void> _until(bool Function() condition, String reason) async {
  for (var waited = 0; waited < 250 && !condition(); waited++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

// 让在途的异步工作跑完（用来确认「没有发生」）。
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousLog = campusLog;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PackageInfo.setMockInitialValues(appName: 'SuperXD', packageName: 'com.superxd.superxd', version: '1.0.0', buildNumber: '42', buildSignature: '');
    _temporary = await Directory.systemTemp.createTemp('superxd_composition_');
    campusLog = _logged.add;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDownAll(() async {
    campusLog = previousLog;
    await _temporary.delete(recursive: true);
  });

  setUp(_logged.clear);

  // 钩子与造法都不该把异常漏出来（AppHooks 接住的会记 action=hook）。
  void expectNoHookErrors() => expect(_logged.where((line) => line.contains('action=hook errorType=')), isEmpty);

  test('联网化：同意之前不发签名请求；同意之后看一眼账号、问点名，开启私信挂到账号；本地化停下、改回接着用；退出应用账号私信跟着退', () async {
    final app = await _compose(mode: NetworkMode.online);
    await _until(() => app.appAccounts.loaded, '启动就读本机的应用账号（不联网）');
    expect(app.appAccounts.current, isNotNull);
    await _settle();
    expect(app.calls, isEmpty, reason: '同意协议与政策之前不发任何签名请求');
    expect(app.social.status, SocialStatus.loading);

    app.agreed.complete();
    await _until(() => app.social.status == SocialStatus.disabled, '同意之后私信切到当前应用账号（这个账号还没开启私信）');
    await _until(() => app.calls.contains('GET /v1/account') && app.calls.contains('GET /v1/flags/mine'), '同意之后看一眼账号、问灰度点名');
    await app.social.enable('合成昵称');
    expect(app.social.status, SocialStatus.ready);
    expect(app.calls, contains('POST /v1/account/social'), reason: '开启私信即挂到当前应用账号');

    await app.network.setMode(NetworkMode.local);
    await _until(() => app.social.status == SocialStatus.offline, '本地化时私信停下');
    await _settle();
    app.calls.clear();
    _cycle();
    await _settle();
    expect(app.calls, isEmpty, reason: '本地化时回到前台不发签名请求（应用账号、私信、解锁、点名都不联网）');

    await app.network.setMode(NetworkMode.online);
    await _until(() => app.social.status == SocialStatus.ready, '改回联网化私信接着用');

    expect(await app.appAccounts.signOut(), isA<AppAccountDone>());
    await _until(() => app.social.status == SocialStatus.signedOut, '退出应用账号，私信跟着退回未登录');
    expect(app.calls, contains('DELETE /v1/devices'));
    expect(await app.keys.read(appAccountSlot), isNull);
    expectNoHookErrors();
  });

  test('本地化启动：同意之后私信照样切到账号但停着、不联网；改回联网化后被挡下的账号核对补做、私信接着打开', () async {
    final app = await _compose(mode: NetworkMode.local);
    app.agreed.complete();
    await _until(() => app.social.status == SocialStatus.offline, '本地化时私信切到账号、停着（消息页写得出本地化卡）');
    await _settle();
    _cycle();
    await _settle();
    expect(app.calls, isEmpty, reason: '本地化时同意之后、回到前台都不发签名请求');

    await app.network.setMode(NetworkMode.online);
    await _until(() => app.calls.contains('GET /v1/account'), '改回联网化后补做被挡下的应用账号核对（以前要重启应用）');
    await _until(() => app.social.status == SocialStatus.disabled, '改回联网化后私信按原账号重新打开');
    expectNoHookErrors();
  });

  test('没登录应用账号：同意之后私信是未登录，不发签名请求；联网策略本身就是联网偏好', () async {
    final app = await _compose(mode: NetworkMode.online, signedIn: false);
    app.agreed.complete();
    await _until(() => app.social.status == SocialStatus.signedOut, '没登录应用账号时私信是未登录');
    await _settle();
    _cycle();
    await _settle();
    expect(app.calls, isEmpty, reason: '没登录应用账号时没有要签名的请求');
    expect(app.network.allows(NetworkService.social), isTrue);
    expectNoHookErrors();
  });
}
