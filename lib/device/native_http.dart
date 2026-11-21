import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';

// 系统原生网络栈的客户端（对比试验，人工决策见 domain/feature_flags.dart 的 cinemaNativeHttpFlag）：交给共用内核 CampusHttp 用，
// 超时、上限、取消与请求记录都还在内核里。安卓是 Cronet（Google Play 服务提供，不打包进安装包；不缓存、开 HTTP/2 与 QUIC），
// iOS 是 URLSession（ephemeral，不落盘缓存与 Cookie）。建不起来（安卓没有 Play 服务、桌面与测试）为空，调用方照旧用 Dart 自带的；名字进诊断日志。
(http.Client, String)? nativeHttpClient() {
  try {
    if (Platform.isAndroid) return (CronetClient.fromCronetEngine(CronetEngine.build(cacheMode: CacheMode.disabled, enableHttp2: true, enableQuic: true, enableBrotli: true), closeEngine: true), 'cronet');
    if (Platform.isIOS) return (CupertinoClient.fromSessionConfiguration(URLSessionConfiguration.ephemeralSessionConfiguration()), 'urlsession');
  } catch (error, stack) {
    campusLog('[NativeHttp] action=create errorType=${error.runtimeType}\n$stack');
  }
  return null;
}
