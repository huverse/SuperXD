# release 构建由 Flutter Gradle 插件开启 R8，并自动读取本文件。
# 高德 SDK（amap_map 引入的 3dmap-location-search）是不带混淆规则的 jar：原生库加载时按固定类名查找 Java 类，
# 被 R8 删改后进程直接中止（JNI java_class == null），规则照高德官方文档的地图、定位、搜索三段。
-keep class com.amap.api.maps.** { *; }
-keep class com.autonavi.** { *; }
-keep class com.amap.api.trace.** { *; }
-keep class com.amap.api.location.** { *; }
-keep class com.amap.api.fence.** { *; }
-keep class com.loc.** { *; }
-keep class com.autonavi.aps.amapapi.model.** { *; }
-keep class com.amap.api.services.** { *; }
