package com.superxd.superxd

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private var toolboxFiles: ToolboxFileExporter? = null
    private var chaoxingDevice: ChaoxingDeviceChannel? = null
    private var shortcuts: AppShortcuts? = null
    private var shortcutChannel: MethodChannel? = null
    private var powerSave: PowerSaveChannel? = null
    private var sensitiveClipboard: SensitiveClipboard? = null
    private var pangguaiCaptcha: PangguaiCaptcha? = null

    // 系统启动图（Android 12 起由系统画，图标设成透明、只有底色，见 res/values-v31/styles.xml）在 Flutter 画出第一帧时淡出，露出下面的开屏画作（lib/page/painting_splash.dart），不一下切走。
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view ->
                view.animate().alpha(0f).setDuration(220L).withEndAction { view.remove() }.start()
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        toolboxFiles = ToolboxFileExporter(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/toolbox_files")
            .setMethodCallHandler(toolboxFiles)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/glass")
            .setMethodCallHandler(GlassGuard(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/calendar_export")
            .setMethodCallHandler(CalendarExporter(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/course_widget")
            .setMethodCallHandler(CourseWidgetChannel(applicationContext))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/course_live")
            .setMethodCallHandler(CourseLiveChannel(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/app_update")
            .setMethodCallHandler(AppUpdateInstaller(this))
        chaoxingDevice = ChaoxingDeviceChannel(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/chaoxing_device")
            .setMethodCallHandler(chaoxingDevice)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/location_settings")
            .setMethodCallHandler(LocationSettingsChannel(this))
        // 胖乖生活取一次当前位置（见 DeviceLocation.kt）与登录前的人机验证（见 PangguaiCaptcha.kt）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/location")
            .setMethodCallHandler(DeviceLocation(applicationContext))
        pangguaiCaptcha = PangguaiCaptcha(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/pangguai_captcha")
            .setMethodCallHandler(pangguaiCaptcha)
        // 住理生活蓝牙连上设备后调高连接优先级（见 ZhuliBleBoost.kt）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/zhuli_ble")
            .setMethodCallHandler(ZhuliBleBoost(flutterEngine))
        sensitiveClipboard = SensitiveClipboard(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/sensitive_clipboard")
            .setMethodCallHandler(sensitiveClipboard)
        // 快捷入口：冷启动带来的入口 id 先记下，Dart 启动时来取（Dart 入口在 onStart 才开始跑，这里已经记好）。
        shortcuts = AppShortcuts(this).also { it.pending = it.launched(intent) }
        shortcutChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/app_shortcuts").apply { setMethodCallHandler(shortcuts) }
        // 启动时人人都调一次：查系统记录（跨进程）、读 ANR 堆栈文件，放后台线程，不占主线程（主线程卡住会推迟出帧）。
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "superxd/diagnostics", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
            .setMethodCallHandler(ProcessExitReasons(applicationContext))
        // 同 iOS 的系统界面通道 superxd/native_ui，安卓上只有省电模式这一项。
        val nativeUi = MethodChannel(messenger, "superxd/native_ui")
        powerSave = PowerSaveChannel(this, nativeUi).also { nativeUi.setMethodCallHandler(it) }
    }

    // 应用在后台时点了快捷入口：界面不重建，把入口 id 交给 Dart 跳过去。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shortcuts?.launched(intent)?.let { shortcutChannel?.invokeMethod("launch", it) }
    }

    // 复制的恢复码到点时应用在后台、读不到剪贴板：拿回焦点时再看一次要不要清（见 SensitiveClipboard.kt）。
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) sensitiveClipboard?.clearIfDue()
    }

    override fun onDestroy() {
        sensitiveClipboard?.close()
        toolboxFiles?.close()
        chaoxingDevice?.close()
        powerSave?.close()
        pangguaiCaptcha?.close()
        super.onDestroy()
    }
}
