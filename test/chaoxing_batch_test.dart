import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

ChaoxingSignTarget _target(String phoneNumber, {bool selected = true}) => ChaoxingSignTarget(
  ChaoxingAccountRecord(
    phoneNumber: phoneNumber,
    uid: 1,
    puid: 2,
    fid: 3,
    name: '同学$phoneNumber',
    schoolName: '',
    deviceCode: 'd',
    isOtherUser: phoneNumber != 'a',
    createdAt: DateTime.utc(2026),
  ),
  selected: selected,
);

void main() {
  test('按顺序只签勾选且还没成功的人，状态逐个落位', () async {
    final targets = [_target('a'), _target('b', selected: false), _target('c')];
    final batch = ChaoxingBatchSigning(targets);
    final order = <String>[];
    final done = await batch.run((target, {required force}) async {
      order.add(target.phoneNumber);
      return ChaoxingSignResult(late: target.phoneNumber == 'c');
    }, interval: Duration.zero);
    expect(done, isTrue);
    expect(order, ['a', 'c']);
    expect(targets[0].state, ChaoxingTargetState.succeeded);
    expect(targets[1].state, ChaoxingTargetState.idle);
    expect(targets[2].late, isTrue);
    expect(targets[2].message, '签到成功，不过已经迟到');

    // 再跑一次不会重复签已经成功的人。
    order.clear();
    expect(await batch.run((target, {required force}) async => const ChaoxingSignResult(), interval: Duration.zero), isTrue);
    expect(order, isEmpty);
  });

  test('一人失败不拦后面的人；签到前检查拦下的可强制，会话失效的要修复', () async {
    final targets = [_target('a'), _target('b'), _target('c')];
    final batch = ChaoxingBatchSigning(targets);
    final done = await batch.run((target, {required force}) async {
      if (target.phoneNumber == 'a') throw const ChaoxingFailure(ChaoxingFailureCode.alreadySigned, '已签', predicted: true);
      if (target.phoneNumber == 'b') throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '登录已过期');
      return const ChaoxingSignResult();
    }, interval: Duration.zero);
    expect(done, isFalse);
    expect(targets[0].forceAvailable, isTrue);
    expect(targets[1].needsRepair, isTrue);
    expect(targets[1].forceAvailable, isFalse);
    expect(targets[2].done, isTrue);

    var forced = false;
    expect(
      await batch.retry(targets[0], (target, {required force}) async {
        forced = force;
        return const ChaoxingSignResult();
      }, force: true),
      isTrue,
    );
    expect(forced, isTrue);
    expect(targets[0].forceAvailable, isFalse);
  });

  test('位置刚出界不停队，后面的人接着签；收紧档仍出界才停下', () async {
    final targets = [_target('a'), _target('b'), _target('c')];
    final batch = ChaoxingBatchSigning(targets);
    final order = <String>[];
    await batch.run((target, {required force}) async {
      order.add(target.phoneNumber);
      // 刚收紧的第一次出界：不带收紧标志，后面的人用收紧档接着签。
      throw const ChaoxingFailure(ChaoxingFailureCode.wrongPosition, '位置不在签到范围内');
    }, interval: Duration.zero);
    expect(order, ['a', 'b', 'c']);
    expect(targets.map((target) => target.state), everyElement(ChaoxingTargetState.failed));

    final more = [_target('a'), _target('b'), _target('c')];
    final batch2 = ChaoxingBatchSigning(more);
    final order2 = <String>[];
    await batch2.run((target, {required force}) async {
      order2.add(target.phoneNumber);
      // 收紧档仍出界（locationTightened）：位置本身选错了，余下的人全停。
      throw const ChaoxingFailure(ChaoxingFailureCode.wrongPosition, '位置不在签到范围内', locationTightened: true);
    }, interval: Duration.zero);
    expect(order2, ['a']);
    expect(more.map((target) => target.state), everyElement(ChaoxingTargetState.failed));
    expect(more.last.message, '位置不在签到范围内');
  });

  test('连续扫码模式下一人失败就停，后面的人不再签', () async {
    final targets = [_target('a'), _target('b'), _target('c')];
    final batch = ChaoxingBatchSigning(targets);
    final order = <String>[];
    await batch.run((target, {required force}) async {
      order.add(target.phoneNumber);
      if (target.phoneNumber == 'a') throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '需要完成安全验证');
      return const ChaoxingSignResult();
    }, interval: Duration.zero, stopOnFailure: true);
    expect(order, ['a']);
    expect(targets[0].state, ChaoxingTargetState.failed);
    // 后面的人没轮到，与失败的人同样的提示，不算成功。
    expect(targets[1].state, ChaoxingTargetState.failed);
    expect(targets[1].message, targets[0].message);
    expect(targets.every((target) => !target.done), isTrue);
  });

  test('相邻两人之间隔开，刚过人工验证码的不再等', () async {
    final targets = [_target('a'), _target('b'), _target('c')];
    final batch = ChaoxingBatchSigning(targets);
    final stamps = <DateTime>[];
    await batch.run((target, {required force}) async {
      stamps.add(DateTime.now());
      if (target.phoneNumber == 'b') batch.lastNeededCaptcha = true;
      return const ChaoxingSignResult();
    }, interval: const Duration(milliseconds: 120));
    expect(stamps[1].difference(stamps[0]).inMilliseconds, greaterThanOrEqualTo(100));
    expect(stamps[2].difference(stamps[1]).inMilliseconds, lessThan(100));
  });
}
