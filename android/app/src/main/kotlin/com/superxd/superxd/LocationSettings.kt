package com.superxd.superxd

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 学习通签到的地图在系统定位关着时给「去打开」：跳到系统的定位设置页，回来由地图自己的定位图层接着定位。
class LocationSettingsChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") {
            result.notImplemented()
            return
        }
        try {
            activity.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            Log.e("LocationSettings", "action=open errorType=${error.javaClass.simpleName}", error)
            result.error("LOCATION_SETTINGS", error.javaClass.simpleName, null)
        }
    }
}
