import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/local/network_mode_memory.dart';

class _Policy extends ChangeNotifier implements NetworkPolicy {
  final denied = <NetworkService>{};
  @override
  bool allows(NetworkService service) => !denied.contains(service);
  void allowAll() {
    denied.clear();
    notifyListeners();
  }
}

// 切到后台再回来，按系统真实的先后一步步走（监听器只认合法的相邻状态）。
void _cycle(WidgetTester tester) {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('同意之后才做一次、回到前台每次都做；没同意时只做不看同意的钩子；已经同意后再登记的马上做', (tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final agreed = Completer<void>();
    final hooks = AppHooks(agreed: agreed.future);
    final calls = <String>[];
    hooks.afterAgreed('Once', () => calls.add('once'));
    hooks.onResume('Resume', () => calls.add('resume'));
    hooks.onResume('Local', () => calls.add('local'), agreedOnly: false);
    hooks.onShow('Show', () => calls.add('show'));
    _cycle(tester);
    expect(calls, ['local'], reason: '同意之前只有本机的那个钩子做');
    agreed.complete();
    await tester.pump();
    expect(calls, ['local', 'once']);
    calls.clear();
    _cycle(tester);
    expect(calls, containsAll(['resume', 'local', 'show']));
    expect(calls.where((call) => call == 'once'), isEmpty, reason: '同意之后的只做一次');
    calls.clear();
    hooks.afterAgreed('Late', () => calls.add('late'));
    expect(calls, ['late']);
  });

  // 11-17 加：切到后台的收尾（健康回报把内存里攒的帧数写盘），每次不再可见时做一次，先于回到前台的钩子。
  testWidgets('切到后台的钩子每次不再可见时做一次；不看同意的同意前也做', (tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final hooks = AppHooks(agreed: Completer<void>().future);
    final calls = <String>[];
    hooks.onHide('Frames', () => calls.add('hide'), agreedOnly: false);
    hooks.onHide('Agreed', () => calls.add('agreed'));
    hooks.onResume('Local', () => calls.add('resume'), agreedOnly: false);
    _cycle(tester);
    expect(calls, ['hide', 'resume']);
  });

  testWidgets('联网策略不允许的服务钩子不做；一个钩子出错只记日志，别的照常做', (tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final logged = <String>[];
    final previous = campusLog;
    campusLog = logged.add;
    addTearDown(() => campusLog = previous);
    final policy = _Policy()..denied.add(NetworkService.rollout);
    final hooks = AppHooks(agreed: Future.value(), policy: policy);
    final calls = <String>[];
    hooks.onResume('Rollouts', () => calls.add('rollout'), service: NetworkService.rollout);
    hooks.onResume('Broken', () => throw StateError('坏了'));
    hooks.onResume('Failing', () => Future<void>.error(StateError('也坏了')));
    hooks.onResume('Notes', () => calls.add('notes'), service: NetworkService.developerNotes);
    await tester.pump();
    _cycle(tester);
    await tester.pump();
    expect(calls, ['notes']);
    expect(logged.where((line) => line.startsWith('[Broken] action=hook errorType=StateError')), hasLength(1));
    expect(logged.where((line) => line.startsWith('[Failing] action=hook errorType=StateError')), hasLength(1));
    policy.denied.clear();
    calls.clear();
    _cycle(tester);
    expect(calls, ['rollout', 'notes']);
  });

  // 11-17 审查发现：仅本机启动时被挡下的一次性钩子（私信切账号、应用账号核对、解锁、节日补抽）改回联网后不补做，要重启才恢复。
  testWidgets('同意时被联网策略挡下的一次性钩子，策略放行时补做一次；之后再变不重复做', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final policy = _Policy()..denied.add(NetworkService.appAccount);
    final agreed = Completer<void>();
    final hooks = AppHooks(agreed: agreed.future, policy: policy);
    final calls = <String>[];
    hooks.afterAgreed('AppAccounts', () => calls.add('account'), service: NetworkService.appAccount);
    hooks.afterAgreed('Rollouts', () => calls.add('rollout'), service: NetworkService.rollout);
    agreed.complete();
    await tester.pump();
    expect(calls, ['rollout'], reason: '同意时仅本机挡下了账号核对');
    hooks.afterAgreed('Late', () => calls.add('late'), service: NetworkService.appAccount);
    expect(calls, ['rollout'], reason: '同意后再登记的也先挡下');
    policy.allowAll();
    expect(calls, ['rollout', 'account', 'late'], reason: '改回联网补做一次');
    policy.denied.add(NetworkService.appAccount);
    policy.allowAll();
    expect(calls, ['rollout', 'account', 'late'], reason: '已经做过的不重复做');
  });

  testWidgets('真的联网偏好：仅本机启动时挡下应用账号核对，改回联网马上补做', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final network = NetworkPreference(memory: FileNetworkModeMemory.memory(mode: NetworkMode.local));
    final hooks = AppHooks(agreed: Future.value(), policy: network);
    await tester.pump();
    final calls = <String>[];
    hooks.afterAgreed('AppAccounts', () => calls.add('account'), service: NetworkService.appAccount);
    expect(calls, isEmpty);
    await network.setMode(NetworkMode.online);
    expect(calls, ['account']);
  });
}
