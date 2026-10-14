# release 构建由 Flutter Gradle 插件开启 R8，并自动读取本文件。
# 高德 SDK（amap_map 引入的 3dmap-location-search）是不带混淆规则的 jar：原生库加载时按固定类名查找 Java 类，
# 被 R8 删改后进程直接中止（JNI java_class == null）。官方文档只列了地图、定位、搜索几个包，但它还用反射调自己
# com.amap.api.col.* 下已混淆的内部类（logo 位置、缩放按钮、定位按钮等设置，改名后 NoSuchMethodException），
# 所以整个 com.amap.api 都保住；jar 本身已混淆，交给 R8 再改名只有坏处。
-keep class com.amap.api.** { *; }
-keep class com.autonavi.** { *; }
-keep class com.loc.** { *; }
