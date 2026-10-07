package com.superxd.superxd

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var toolboxFiles: ToolboxFileExporter? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "superxd/chaoxing_device")
            .setMethodCallHandler(ChaoxingDeviceChannel(applicationContext))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (toolboxFiles?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDestroy() {
        toolboxFiles?.close()
        super.onDestroy()
    }
}
