package com.superxd.superxd

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 取一次当前位置（通道 superxd/location，胖乖生活找附近门店与下单用，Dart 侧 lib/toolbox/life/pangguai/pangguai_location.dart；iOS 是 DeviceLocation.swift）。
// 只用系统的 LocationManager，不带谷歌服务的闭源库（国内不少手机没有谷歌服务；geolocator 的安卓端带 play-services-location，用户 11-27 选了自己写）。
// 权限由 Dart 侧先问好；先用两分钟内的最近位置，没有再现取，最多等 timeoutMs，取不到回空。只在调用时取一次，不持续、不在后台定位。
class DeviceLocation(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "current") return result.notImplemented()
        val timeout = (call.argument<Int>("timeoutMs") ?: 10000).toLong().coerceIn(1000L, 30000L)
        try {
            current(result, timeout)
        } catch (error: SecurityException) {
            Log.e("DeviceLocation", "action=current errorType=${error.javaClass.simpleName}", error)
            result.error("denied", error.javaClass.simpleName, null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun current(result: MethodChannel.Result, timeout: Long) {
        val manager = context.getSystemService(LocationManager::class.java) ?: return result.error("unavailable", "LocationManager", null)
        if (!manager.isLocationEnabled) return result.error("disabled", "location off", null)
        // 安卓 12 起系统自带的融合定位（不是谷歌服务那个）优先，其次网络、卫星。
        val candidates = listOfNotNull(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) LocationManager.FUSED_PROVIDER else null, LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
        val providers = candidates.filter { manager.allProviders.contains(it) && manager.isProviderEnabled(it) }
        if (providers.isEmpty()) return result.error("disabled", "no provider", null)
        val recent = providers.mapNotNull { manager.getLastKnownLocation(it) }.filter { System.currentTimeMillis() - it.time in 0..120_000 }.maxByOrNull { it.time }
        if (recent != null) return result.success(fields(recent))
        val signal = CancellationSignal()
        var done = false
        val finish = { location: Location? ->
            if (!done) {
                done = true
                signal.cancel()
                result.success(location?.let(::fields))
            }
        }
        main.postDelayed({ finish(null) }, timeout)
        manager.getCurrentLocation(providers.first(), signal, context.mainExecutor) { location -> finish(location) }
    }

    private fun fields(location: Location) = mapOf("latitude" to location.latitude, "longitude" to location.longitude, "accuracy" to location.accuracy.toDouble())
}
