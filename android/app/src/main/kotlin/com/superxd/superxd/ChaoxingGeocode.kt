package com.superxd.superxd

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.amap.api.services.core.ServiceSettings
import com.amap.api.services.geocoder.GeocodeQuery
import com.amap.api.services.geocoder.GeocodeResult
import com.amap.api.services.geocoder.GeocodeSearch
import com.amap.api.services.geocoder.RegeocodeResult
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// 学习通「按地址设点」的位置签到：详情不回坐标，只给地址文字。把地址交给高德地理编码换成坐标（GCJ-02），
// 供 Dart 侧画范围圈与取「签到点附近」。搜索类随 amap_map 的 3dmap-location-search 一起打包，这里只多用它；
// key 复用地图那把 app key，由 Dart 传入、运行时设给搜索 SDK（ServiceSettings.setApiKey），不写进清单、不另申请。
// 只在这里联网换坐标，不在原生侧保存地址与结果；地理编码是异步回调，超时与结果谁先到谁回，只回一次。
class ChaoxingGeocodeChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "geocode" -> geocode(call, result)
            else -> result.notImplemented()
        }
    }

    private fun geocode(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key").orEmpty()
        val address = call.argument<String>("address").orEmpty()
        if (key.isEmpty() || address.isEmpty()) {
            result.success(null)
            return
        }
        val done = AtomicBoolean(false)
        // Dart 侧有 8 秒超时，这里给 7 秒兜底，避免监听器一直不回导致回复悬着。
        val timeout = Runnable { finish(done, result, null) }
        try {
            // 隐私合规：与地图同口径，已同意过才会走到这里（位置签到入口已征得同意）。
            ServiceSettings.updatePrivacyShow(context, true, true)
            ServiceSettings.updatePrivacyAgree(context, true)
            ServiceSettings.getInstance().setApiKey(key)
            val search = GeocodeSearch(context)
            search.setOnGeocodeSearchListener(object : GeocodeSearch.OnGeocodeSearchListener {
                override fun onGeocodeSearched(geocode: GeocodeResult?, code: Int) {
                    mainHandler.removeCallbacks(timeout)
                    val point = geocode?.geocodeAddressList?.firstOrNull()?.latLonPoint
                    if (code == 1000 && point != null) {
                        finish(done, result, mapOf("latitude" to point.latitude, "longitude" to point.longitude))
                    } else {
                        finish(done, result, null)
                    }
                }

                override fun onRegeocodeSearched(regeocode: RegeocodeResult?, code: Int) {}
            })
            mainHandler.postDelayed(timeout, 7000)
            // 不带城市限定：地址文字一般已含城市；带错城市反而筛空。
            search.getFromLocationNameAsyn(GeocodeQuery(address, ""))
        } catch (error: Throwable) {
            Log.e("ChaoxingGeocode", "action=geocode errorType=${error.javaClass.simpleName}", error)
            mainHandler.removeCallbacks(timeout)
            finish(done, result, null)
        }
    }

    // 只回复一次：超时与高德回调谁先到算谁的。
    private fun finish(done: AtomicBoolean, result: MethodChannel.Result, value: Map<String, Any?>?) {
        if (done.compareAndSet(false, true)) mainHandler.post { result.success(value) }
    }
}
