import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 多人连签：本人与导入的代签账号勾选后按顺序逐个签，每个人的状态在原位显示。
// 规则照学习通客户端（参考项目）的连签：
// - 相邻两人之间隔 200 毫秒；上一位刚过了人工验证码就不再等（人已经花了时间）；
// - 二维码过期不算失败，等新扫到的码接着签当前这个人；
// - 位置收紧偏移后仍超范围时，后面的人一律停下（位置本身选错了，继续签也是同样结果）；
// - 签到前检查判定「已签到 / 已截止 / 不在班级」的人可以单独「强制签到」，跳过这些检查直接提交；
// - 会话彻底失效（自动重登也失败）的人要重新输密码修复，修好后可单独重试。
const chaoxingSignInterval = Duration(milliseconds: 200);

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
        if (stop || (stopOnFailure && !target.done)) {
          for (final rest in queue) {
            if (rest.state == ChaoxingTargetState.waiting) {
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

  // 返回 true 表示后面的人不用再签了。
  Future<bool> _signOne(ChaoxingSignTarget target, ChaoxingTargetSigner signer, {required bool force}) async {
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
        ..message = result.late ? '签到成功，不过已经迟到' : '签到成功';
      return false;
    } on ChaoxingFailure catch (failure) {
      target
        ..state = ChaoxingTargetState.failed
        ..message = failure.message
        ..forceAvailable = failure.predicted
        ..needsRepair = failure.code == ChaoxingFailureCode.sessionExpired;
      return failure.code == ChaoxingFailureCode.wrongPosition || failure.code == ChaoxingFailureCode.cancelled;
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=batch_sign errorType=${failure.runtimeType}\n$stack');
      target
        ..state = ChaoxingTargetState.failed
        ..message = '签到没完成，请稍后重试';
      return false;
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
