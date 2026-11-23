package com.superxd.superxd

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.util.Log
import dev.zeekr.bluetooth_low_energy_android.BluetoothLowEnergyAndroidPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// [人工决策-2026-11-23 15:58:07] 住理生活蓝牙开关水调高连接优先级（用户在「调高连接优先级、预连接时顺便握手、开着水时一直连着、先不再提速」里选了第一项）：
// 11-23 真机预先连上后开水 1.5 秒里 4 次蓝牙来回各约 0.25 秒，连接间隔是系统默认的平衡档；原 App 没调（另一份分析按 dex 符号统计，没有 requestConnectionPriority）。
// 蓝牙插件 bluetooth_low_energy 没有这个接口，经反射读它的两个私有字段拿到连接对象（BluetoothLowEnergyAndroidPlugin.mCentralManager、CentralManagerImpl.mGATTs），
// 把当前所有连接调成 CONNECTION_PRIORITY_HIGH（同一时刻只连一台设备）；拿不到就返回 -1、Dart 记一行日志照常开关水。
// release 包的 R8 规则保留这两个字段名（android/app/proguard-rules.pro），test/zhuli_bath_test.dart 核对插件源码里还叫这两个名字、规则与通道还在。
class ZhuliBleBoost(private val engine: FlutterEngine) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "boost") return result.notImplemented()
        result.success(
            try {
                boost()
            } catch (error: Throwable) {
                Log.w("ZhuliBleBoost", "boost failed", error)
                -1
            },
        )
    }

    // 调高了几个连接；插件或字段不在为 -1。
    @SuppressLint("MissingPermission")
    private fun boost(): Int {
        val plugin = engine.plugins.get(BluetoothLowEnergyAndroidPlugin::class.java) ?: return -1
        val central = BluetoothLowEnergyAndroidPlugin::class.java.getDeclaredField("mCentralManager").apply { isAccessible = true }.get(plugin) ?: return -1
        val gatts = central.javaClass.getDeclaredField("mGATTs").apply { isAccessible = true }.get(central) as? Map<*, *> ?: return -1
        return gatts.values.count { gatt -> gatt is BluetoothGatt && gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
    }
}
