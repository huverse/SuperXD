import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 多人连签：本人与导入的代签账号勾选后按顺序逐个签，每个人的状态在原位显示。
// 规则照学习通客户端（参考项目）的连签：
// - 相邻两人之间隔 200 毫秒；上一位刚过了人工验证码就不再等（人已经花了时间）；
// - 二维码过期不算失败，等新扫到的码接着签当前这个人；
// - 位置刚出界时收紧偏移（一场共享一次），后面的人用收紧档接着签；收紧档仍超范围才把余下的人全停；
// - 签到前检查判定「已签到 / 不在班级」的人可以单独「强制签到」，跳过这些检查直接提交；
// - 会话彻底失效（自动重登也失败）的人要重新输密码修复，修好后可单独重试。
const chaoxingSignInterval = Duration(milliseconds: 200);

// 单人签完后的队列处置：继续、把余下的人标失败停队、取消（余下的人回到待签）。
enum _BatchStop { none, failed, cancelled }

enum ChaoxingTargetState { idle, waiting, signing, succeeded, failed }

class ChaoxingSignTarget {
  ChaoxingSignTarget(this.record, {this.selected = false});
  final ChaoxingAccountRecord record;
  bool selected;
  ChaoxingTargetState state = ChaoxingTargetState.idle;
  String? message;
  bool late = false;

  // 签到前检查拦下的，可以强制签到。
  bool forceAvailable = false;
  bool needsRepair = false;

  // 拍照签到每人一张照片；上传后记下 objectId，验证码重试时不重传。
  List<int>? photoBytes;
  String? photoName;
  String? photoObjectId;

  // 人脸签到这次选用的照片（空表示用这个人存着的那张）。
  String? faceObjectId;

  String get phoneNumber => record.phoneNumber;
  bool get done => state == ChaoxingTargetState.succeeded;
}

// 一个人的完整签到流程由调用方给（控制器里按账号取会话、检查、上传、提交）；这里只管顺序、间隔与状态。
typedef ChaoxingTargetSigner = Future<ChaoxingSignResult> Function(ChaoxingSignTarget target, {required bool force});

class ChaoxingBatchSigning extends ChangeNotifier {
  ChaoxingBatchSigning(this.targets);
  final List<ChaoxingSignTarget> targets;
  bool running = false;
  String? currentPhone;
  bool _disposed = false;

  // 这一位刚走过人工验证码（下一位不用再等间隔）。
  bool lastNeededCaptcha = false;

  List<ChaoxingSignTarget> get pending => [for (final target in targets) if (target.selected && !target.done) target];

  bool get allSucceeded => targets.where((target) => target.selected).every((target) => target.done);

  // 按顺序签所有勾选且还没成功的人；返回是否全部成功。stopOnFailure 用于连续扫码：任何一人失败就停，
  // 后面的人不再签（对齐参考项目），而普通模式失败的人单独重试、其余照签。
  Future<bool> run(ChaoxingTargetSigner signer, {Duration interval = chaoxingSignInterval, bool stopOnFailure = false}) async {
    if (running) return false;
    final queue = pending;
    if (queue.isEmpty) return allSucceeded;
    running = true;
    for (final target in queue) {
      target
        ..state = ChaoxingTargetState.waiting
        ..message = null;
    }
    _notify();
    var first = true;
    try {
      for (final target in queue) {
        if (target.state != ChaoxingTargetState.waiting) continue;
        if (!first && !lastNeededCaptcha) await Future<void>.delayed(interval);
        first = false;
        lastNeededCaptcha = false;
        final stop = await _signOne(target, signer, force: false);
        if (stop != _BatchStop.none || (stopOnFailure && !target.done)) {
          for (final rest in queue) {
            if (rest.state != ChaoxingTargetState.waiting) continue;
            if (stop == _BatchStop.cancelled) {
              // 扫码被取消：余下的人回到待签，不标「失败」（对齐参考项目）。
              rest
                ..state = ChaoxingTargetState.idle
                ..message = null;
            } else {
              rest
                ..state = ChaoxingTargetState.failed
                ..message = target.message;
            }
          }
          break;
        }
      }
    } finally {
      running = false;
      currentPhone = null;
      _notify();
    }
    return allSucceeded;
  }

  // 单独重试一个人（可选强制）。
  Future<bool> retry(ChaoxingSignTarget target, ChaoxingTargetSigner signer, {required bool force}) async {
    if (running) return false;
    running = true;
    try {
      await _signOne(target, signer, force: force);
    } finally {
      running = false;
      currentPhone = null;
      _notify();
    }
    return target.done;
  }

  // 返回这条签完后的队列处置：继续、停队标失败、取消复位。
  Future<_BatchStop> _signOne(ChaoxingSignTarget target, ChaoxingTargetSigner signer, {required bool force}) async {
    currentPhone = target.phoneNumber;
    target
      ..state = ChaoxingTargetState.signing
      ..message = null
      ..forceAvailable = false
      ..needsRepair = false;
    _notify();
    try {
      final result = await signer(target, force: force);
      target
        ..state = ChaoxingTargetState.succeeded
        ..late = result.late
        ..message = chaoxingSignedText(late: result.late);
      return _BatchStop.none;
    } on ChaoxingFailure catch (failure) {
      target
        ..state = ChaoxingTargetState.failed
        ..message = failure.message
        // 已截止不给行内的强制签到（参考项目只给「已签到 / 不在班级」），打开页面的三选里仍可强制。
        ..forceAvailable = failure.predicted && failure.code != ChaoxingFailureCode.expired
        ..needsRepair = failure.code == ChaoxingFailureCode.sessionExpired;
      if (failure.code == ChaoxingFailureCode.cancelled) return _BatchStop.cancelled;
      // 位置出界：刚收紧的第一次不停队（后面的人用收紧档接着签，对齐参考项目），收紧档仍出界才全停。
      if (failure.code == ChaoxingFailureCode.wrongPosition && failure.locationTightened) return _BatchStop.failed;
      return _BatchStop.none;
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=batch_sign errorType=${failure.runtimeType}\n$stack');
      target
        ..state = ChaoxingTargetState.failed
        ..message = chaoxingSignRetryMessage;
      return _BatchStop.none;
    } finally {
      _notify();
    }
  }

  void notifyChanged() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
