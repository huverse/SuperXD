package com.superxd.superxd

import android.app.Activity
import android.util.Log
import com.netease.nis.captcha.Captcha
import com.netease.nis.captcha.CaptchaConfiguration
import com.netease.nis.captcha.CaptchaListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 胖乖生活登录前的人机验证（通道 superxd/pangguai_captcha，Dart 侧 lib/toolbox/life/pangguai/pangguai_captcha.dart；iOS 是 PangguaiCaptcha.swift）：
// 网易易盾行为式验证码 io.github.yidun:captcha（闭源 SDK，用户 11-27 选了接原生 SDK，人工决策见 lib/toolbox/life/pangguai/pangguai_service.dart）。
// 通过回 validate 串，用户关掉回空，加载失败回错误。disableReport：不让 SDK 装它的崩溃收集（会接管未捕获的异常、把堆栈发去易盾），也不上报运行日志。
class PangguaiCaptcha(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private var started = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "verify") return result.notImplemented()
        val captchaId = call.argument<String>("captchaId") ?: return result.error("ARGUMENT", "captchaId", null)
        // 上一次还没回的（连点）当作关掉。
        finish { it.success(null) }
        pending = result
        val configuration = CaptchaConfiguration.Builder()
            .captchaId(captchaId)
            .timeout(15000)
            .disableReport(true)
            .theme(if (call.argument<Boolean>("dark") == true) CaptchaConfiguration.Theme.DARK else CaptchaConfiguration.Theme.LIGHT)
            .listener(object : CaptchaListener {
                override fun onCaptchaShow() = Unit

                // 没过时 SDK 自己换一张，validate 为空，等下一次回调。
                override fun onValidate(result: String?, validate: String?, message: String?, captchaType: String?, errorValidate: String?) {
                    if (!validate.isNullOrEmpty()) finish { it.success(validate) }
                }

                override fun onError(code: Int, message: String?) {
                    Log.w("PangguaiCaptcha", "action=error code=$code")
                    finish { it.error("CAPTCHA_$code", "captcha error", null) }
                }

                override fun onClose(type: Captcha.CloseType?) {
                    if (type != Captcha.CloseType.VERIFY_SUCCESS_CLOSE) finish { it.success(null) }
                }
            })
            .build(activity)
        started = true
        Captcha.getInstance().apply {
            init(configuration)
            validate()
        }
    }

    private fun finish(reply: (MethodChannel.Result) -> Unit) {
        val result = pending ?: return
        pending = null
        reply(result)
    }

    // 页面销毁时收起还开着的验证窗口。
    fun close() {
        finish { it.success(null) }
        if (started) Captcha.getInstance().destroy()
    }
}
