import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';

class _Policy implements NetworkPolicy {
  final denied = <NetworkService>{};
  @override
  bool allows(NetworkService service) => !denied.contains(service);
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
}
