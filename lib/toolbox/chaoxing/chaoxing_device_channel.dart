import 'package:flutter/services.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_device.dart';

// 设备信息端口的原生实现（ChaoxingDevice.kt）。单独成文件，协议链路才不带 Flutter，tool 下的联调入口能用纯 Dart 跑。
class ChannelChaoxingDeviceProbe implements ChaoxingDeviceProbe {
  static const _channel = MethodChannel('superxd/chaoxing_device');

  @override
  Future<ChaoxingDeviceFacts> facts(String packageName) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('deviceInfo', {'packageName': packageName});
    if (result == null) throw StateError('设备信息为空');
    return ChaoxingDeviceFacts.fromMap(result);
  }

  @override
  Future<String> oaid() async => await _channel.invokeMethod<String>('oaid') ?? '';
}
