package com.superxd.superxd

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private var toolboxFiles: ToolboxFileExporter? = null
    private var chaoxingDevice: ChaoxingDeviceChannel? = null

    // 系统启动图（Android 12 起由系统画应用图标）在 Flutter 画出第一帧时淡出，露出下面的开屏画作（lib/page/painting_splash.dart），不一下切走。
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
        // 启动时人人都调一次：查系统记录（跨进程）、读 ANR 堆栈文件，放后台线程，不占主线程（主线程卡住会推迟出帧）。
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "superxd/diagnostics", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
            .setMethodCallHandler(ProcessExitReasons(applicationContext))
    }

    override fun onDestroy() {
        toolboxFiles?.close()
        chaoxingDevice?.close()
        super.onDestroy()
    }
}
