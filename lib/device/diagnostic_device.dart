import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';

// 诊断日志用到的两项系统能力，由组合根交给 local/diagnostic_log.dart：
// 读系统版本与机型，写进日志包的运行环境；打好的日志包经原生一次性导出（ToolboxFileExporter.kt，与百宝箱共用，只认缓存目录里的文件）存进 Download/SuperXD。
const _files = MethodChannel('superxd/toolbox_files');

Future<Map<String, String>> readDeviceEnvironment() async {
  final info = await DeviceInfoPlugin().androidInfo;
  return {'os': 'Android ${info.version.release}', 'sdk': '${info.version.sdkInt}', 'device': '${info.manufacturer} ${info.model}'};
}

Future<bool> publishDiagnosticArchive(File archive, String filename) async =>
    await _files.invokeMethod<String>('publishExternal', {'source': archive.path, 'filename': filename, 'mimeType': 'application/zip'}) != null;
