package com.superxd.superxd

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var toolboxFiles: ToolboxFileExporter? = null
    private var chaoxingDevice: ChaoxingDeviceChannel? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/diagnostics")
            .setMethodCallHandler(ProcessExitReasons(applicationContext))
    }

    override fun onDestroy() {
        toolboxFiles?.close()
        chaoxingDevice?.close()
        super.onDestroy()
    }
}
