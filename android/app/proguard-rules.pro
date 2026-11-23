# release 构建由 Flutter Gradle 插件开启 R8，并自动读取本文件。
# 接入不带混淆规则的原生 SDK（jar 里按固定类名经 JNI 或反射找类的）时在这里写 keep 规则，否则 release 包里一用就崩，debug 包看不出来。
# 2026-11-10 学习通地图改用网页版高德，原生高德 SDK 与它的 keep 规则一起删掉了（test/legal_page_test.dart 守护两者同进同出）。

# 2026-11-19 电影院的播放器 media_kit（libmpv）：插件的 Java 类有 JNI 原生方法与按类名回调（mediakitandroidhelper），整包保留，免得 release 包里一播就崩。
-keep class com.alexmercerind.** { *; }

# 2026-11-23 住理生活蓝牙调高连接优先级经反射读蓝牙插件的两个私有字段（ZhuliBleBoost.kt），release 包里保留这两个字段名（test/zhuli_bath_test.dart 守护）。
-keepclassmembers class dev.zeekr.bluetooth_low_energy_android.BluetoothLowEnergyAndroidPlugin { private ** mCentralManager; }
-keepclassmembers class dev.zeekr.bluetooth_low_energy_android.CentralManagerImpl { private ** mGATTs; }
