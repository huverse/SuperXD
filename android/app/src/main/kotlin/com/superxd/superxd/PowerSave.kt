package com.superxd.superxd

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 省电模式（lib/theme/native_glass.dart 的 nativeLowPower，同 iOS 的低电量模式）：开着时装饰动效（云雾流动等）停下。
// Dart 启动时来取一次当前状态，之后系统切换时把新状态发过去。
class PowerSaveChannel(private val context: Context, private val channel: MethodChannel) : MethodChannel.MethodCallHandler {
    private val power = context.getSystemService(PowerManager::class.java)
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            channel.invokeMethod("lowPower", power.isPowerSaveMode)
        }
    }

    init {
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "lowPower") result.success(power.isPowerSaveMode) else result.notImplemented()
    }

    fun close() = context.unregisterReceiver(receiver)
}
