import Flutter
import UIKit
import VerifyCode

// 胖乖生活登录前的人机验证（通道 superxd/pangguai_captcha），对应安卓 PangguaiCaptcha.kt：网易易盾 NTESVerifyCode（闭源 SDK，经 ios/Podfile 的 CocoaPods 引入；
// 用户 11-27 选了接原生 SDK，人工决策见 lib/toolbox/life/pangguai/pangguai_service.dart）。通过回 validate 串，用户关掉回空，加载失败回错误；关掉 SDK 的上报（disableReport）。
final class PangguaiCaptcha: NSObject, NTESVerifyCodeManagerDelegate {
  private var pending: FlutterResult?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/pangguai_captcha", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "verify", let arguments = call.arguments as? [String: Any], let captchaId = arguments["captchaId"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.verify(captchaId: captchaId, dark: arguments["dark"] as? Bool ?? false, result: result)
    }
  }

  private func verify(captchaId: String, dark: Bool, result: @escaping FlutterResult) {
    // 上一次还没回的（连点）当作关掉。
    finish(nil)
    pending = result
    let manager = NTESVerifyCodeManager.getInstance()
    manager.delegate = self
    manager.disableReport = true
    manager.lang = .CN
    manager.userInterfaceStyle = dark ? .dark : .light
    manager.configureVerifyCode(captchaId, timeout: 15)
    manager.openVerifyCodeView(UIApplication.shared.topViewController?.view)
  }

  // 没过时 SDK 自己换一张，等下一次回调。
  func verifyCodeValidateFinish(_ result: Bool, validate: String?, message: String?) {
    if result, let validate, !validate.isEmpty { finish(validate) }
  }

  func verifyCodeInitFailed(_ error: [Any]?) {
    NSLog("[PangguaiCaptcha] action=init_failed")
    guard let result = pending else { return }
    pending = nil
    result(FlutterError(code: "CAPTCHA_INIT", message: "captcha init failed", details: nil))
  }

  func verifyCodeCloseWindow(_ close: NTESVerifyCodeClose) {
    if close == .manual { finish(nil) }
  }

  private func finish(_ validate: String?) {
    guard let result = pending else { return }
    pending = nil
    result(validate)
  }
}
