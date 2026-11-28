import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_protocol.dart';

// 人机验证端口：胖乖登录前要验证时弹网易易盾的验证（滑块、点选），过了交回 validate 串，用户关掉了交回空。
abstract interface class PangguaiCaptcha {
  Future<String?> verify({required bool dark});
}

// 易盾的原生 SDK 经通道 superxd/pangguai_captcha（安卓 PangguaiCaptcha.kt 用 io.github.yidun:captcha，iOS PangguaiCaptcha.swift 用 NTESVerifyCode；
// 用户 11-27 选了接原生 SDK，人工决策见 pangguai_service.dart 文件头）。两边都关掉 SDK 的上报（disableReport），不装它的崩溃收集。
class ChannelPangguaiCaptcha implements PangguaiCaptcha {
  static const _channel = MethodChannel('superxd/pangguai_captcha');

  @override
  Future<String?> verify({required bool dark}) async {
    try {
      final validate = await _channel.invokeMethod<String>('verify', {'captchaId': pangguaiCaptchaId, 'dark': dark});
      return validate == null || validate.isEmpty ? null : validate;
    } on PlatformException catch (error, stack) {
      campusLog('[Pangguai] action=captcha errorType=${error.code}\n$stack');
      throw const PangguaiException(PangguaiFailure.rejected, '人机验证没加载出来，稍后再试', code: 'captcha');
    }
  }
}
