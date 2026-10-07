import 'package:flutter/foundation.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 一次签到里所有人共用的输入：签到码、位置、二维码（每人各自的照片与人脸照片在 ChaoxingSignTarget 上）。
class ChaoxingSignInputs {
  const ChaoxingSignInputs({this.signCode, this.location, this.qrCode});
  final String? signCode;
  final ChaoxingLocation? location;
  final ChaoxingQrCode? qrCode;
}

// 需要验证码时由界面弹出滑块，拿回 validate；返回空表示用户放弃。
typedef ChaoxingCaptchaSolver = Future<String?> Function(ChaoxingClient client, ChaoxingActivity activity);

// 二维码签到时拿最新扫到的码：传入刚过期的那个，返回一个不同的新码。
typedef ChaoxingFreshQrCode = Future<ChaoxingQrCode> Function(ChaoxingQrCode expired);

// 签到流程要用的会话与存储能力：流程本身不持有页面状态，由调用方注入（controller 是现在唯一的实现来源）。
class ChaoxingSignContext {
  const ChaoxingSignContext({
    required this.clientOf,
    required this.currentPhone,
    required this.run,
    required this.faceImages,
    required this.putFaceImage,
    required this.markFaceImageUsed,
    required this.refreshAccount,
  });
  final Future<ChaoxingClient> Function(ChaoxingAccountRecord record) clientOf;

  // 页面当前打开的账号（本人的判断依据）：给别的账号签时按课程号换成他自己所在的班级。
  final String? Function() currentPhone;
  final Future<T> Function<T>(ChaoxingClient client, Future<T> Function() action) run;
  final Future<List<ChaoxingFaceImage>> Function(String phoneNumber) faceImages;
  final Future<void> Function(String phoneNumber, String objectId) putFaceImage;
  final Future<void> Function(String phoneNumber, String objectId, {required bool failed}) markFaceImageUsed;
  final Future<void> Function(ChaoxingClient client) refreshAccount;
}

// 一个人的完整签到流程：签到前检查（可强制跳过）→ 拍照上传 → 人脸 → 提交
// （要验证码就弹、二维码过期就换新码、位置出界收紧重试一次）。从页面状态类抽出，页面只管状态与输入；
// 打开签到页时的检查（check）与提交共用同一段判定。
class ChaoxingSignFlow {
  const ChaoxingSignFlow(this.context);
  final ChaoxingSignContext context;

  Future<ChaoxingSignResult> sign(
    ChaoxingSignTarget target,
    ChaoxingActivity activity, {
    required ChaoxingActiveInfo info,
    required ChaoxingSignInputs inputs,
    required ChaoxingCaptchaSolver solveCaptcha,
    ChaoxingFreshQrCode? freshQrCode,
    bool force = false,
  }) async {
    final client = await context.clientOf(target.record);
    var signed = activity;
    if (force) {
      // 强制签到跳过全部签到前检查；给别的账号签时按课程号换成他自己所在的班级。
      if (target.phoneNumber != context.currentPhone()) {
        final classId = await context.run(client, () => chaoxingClassIdOfCourse(client, activity.courseId));
        if (classId != null) signed = activity.change(classId: classId);
      }
    } else {
      final blocked = await _presignFailure(client, signed);
      if (blocked != null) throw blocked;
    }
    if (signed.signType == ChaoxingSignType.photo && info.needPhoto && target.photoObjectId == null) {
      final bytes = target.photoBytes;
      if (bytes == null) throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这场签到要照片，请先选一张');
      final photo = await compute(chaoxingStylizePhoto, Uint8List.fromList(bytes));
      target.photoObjectId = await context.run(client, () => chaoxingUploadPhoto(client, bytes: photo));
    }
    final faceObjectId = chaoxingFaceApplies(signed.signType, info) ? await _faceFor(client, target) : null;
    var qrCode = inputs.qrCode;
    var tightened = false;
    String? validate;
    String? enc2;
    for (var attempt = 0; ; attempt++) {
      final faceEnc = faceObjectId == null
          ? null
          : await context.run(client, () => chaoxingFaceEnc(client, activeId: signed.activeId, objectId: faceObjectId));
      final submission = ChaoxingSignSubmission(
        activity: signed,
        activeId: qrCode?.activeId,
        signCode: inputs.signCode,
        location: inputs.location,
        enc: qrCode?.enc,
        objectId: target.photoObjectId,
        faceObjectId: faceObjectId,
        faceEnc: faceEnc,
        captchaValidate: validate,
        enc2: enc2,
        tightenLocation: tightened,
      );
      try {
        final result = await context.run(client, () => chaoxingSubmit(client, submission));
        if (faceObjectId != null) await context.markFaceImageUsed(client.phoneNumber, faceObjectId, failed: false);
        return result;
      } on ChaoxingFailure catch (failure) {
        switch (failure.code) {
          case ChaoxingFailureCode.captchaRequired when attempt < 3:
            final answer = await solveCaptcha(client, signed);
            if (answer == null) {
              throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '需要完成安全验证才能签到');
            }
            validate = answer;
            enc2 = failure.payload ?? enc2;
          case ChaoxingFailureCode.wrongPosition when !tightened && inputs.location != null:
            tightened = true;
          case ChaoxingFailureCode.qrCodeExpired when freshQrCode != null && qrCode != null:
            await Future<void>.delayed(const Duration(milliseconds: 500));
            qrCode = await freshQrCode(qrCode);
          case ChaoxingFailureCode.faceRequired when faceObjectId != null:
            await context.markFaceImageUsed(client.phoneNumber, faceObjectId, failed: true);
            rethrow;
          default:
            rethrow;
        }
      }
    }
  }

  // 打开签到页时的检查入口：按这个人的会话查，结果只用来提示与给三选，不产生副作用。
  Future<ChaoxingFailure?> check(ChaoxingSignTarget target, ChaoxingActivity activity) async {
    final client = await context.clientOf(target.record);
    return _presignFailure(client, activity);
  }

  // 签到前检查（preSign 与班级检查）：拦下时返回带 predicted 的失败，可签返回 null。
  // 提交前必查；打开签到页时也先查一次（对齐参考项目，别等提交后才知道已签到或已截止）。
  Future<ChaoxingFailure?> _presignFailure(ChaoxingClient client, ChaoxingActivity activity) async {
    final presign = await context.run(client, () => chaoxingPreSign(client, activity));
    if (presign == ChaoxingPreSignStatus.alreadySigned) {
      return const ChaoxingFailure(ChaoxingFailureCode.alreadySigned, '这场签到已经完成了', predicted: true);
    }
    if (presign == ChaoxingPreSignStatus.expired) {
      return const ChaoxingFailure(ChaoxingFailureCode.expired, '签到已截止', predicted: true);
    }
    if (await context.run(client, () => chaoxingClassValid(client, activity.classId)) == false) {
      return const ChaoxingFailure(ChaoxingFailureCode.noPermission, '这个账号不在该班级里', predicted: true);
    }
    return null;
  }

  // 人脸照片：这次选了就用选的，其次本机记着的第一张，再其次学习通里存的那张；都没有就让用户先选一张。
  Future<String> _faceFor(ChaoxingClient client, ChaoxingSignTarget target) async {
    final chosen = target.faceObjectId;
    if (chosen != null) return chosen;
    final stored = await context.faceImages(client.phoneNumber);
    if (stored.isNotEmpty) return stored.first.objectId;
    // clientId 是签名要用的，库里没有就先补一次用户信息（会话过期时 run 会先重登）。
    if ((client.account?.clientId ?? '').isEmpty) await context.refreshAccount(client);
    final profile = await context.run(client, () => chaoxingProfileFaceObjectId(client));
    if (profile == null) {
      throw ChaoxingFailure(ChaoxingFailureCode.faceRequired, '${target.record.name} 还没有人脸照片，请先选一张');
    }
    await context.putFaceImage(client.phoneNumber, profile);
    return profile;
  }
}
