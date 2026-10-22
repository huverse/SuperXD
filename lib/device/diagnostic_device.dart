import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';

// 诊断日志用到的系统能力，由组合根交给 local/diagnostic_log.dart 与 app_diagnostics.dart：
// 读系统版本与机型，写进日志包的运行环境；打好的日志包经原生一次性导出（ToolboxFileExporter.kt，与百宝箱共用，只认缓存目录里的文件）存进 Download/SuperXD；
// 读系统记下的上次进程退出原因（ProcessExitReasons.kt）。
const _files = MethodChannel('superxd/toolbox_files');
const _diagnostics = MethodChannel('superxd/diagnostics');

// 上次进程为什么结束：时刻（毫秒）、原因名（CRASH、ANR、LOW_MEMORY 等）、状态码、内存与系统说明，ANR 附线程堆栈摘要。只要 since 之后的。
typedef ProcessExit = ({int timestamp, String reason, int status, int importance, int pssKb, int rssKb, String description, String trace});

Future<List<ProcessExit>> readExitReasons(int since) async {
  final exits = await _diagnostics.invokeListMethod<Map<Object?, Object?>>('exitReasons', {'since': since}) ?? const [];
  return [
    for (final exit in exits)
      (
        timestamp: exit['timestamp']! as int,
        reason: exit['reason']! as String,
        status: exit['status']! as int,
        importance: exit['importance']! as int,
        pssKb: exit['pssKb']! as int,
        rssKb: exit['rssKb']! as int,
        description: exit['description']! as String,
        trace: exit['trace']! as String,
      ),
  ];
}

Future<Map<String, String>> readDeviceEnvironment() async {
  final info = await DeviceInfoPlugin().androidInfo;
  return {'os': 'Android ${info.version.release}', 'sdk': '${info.version.sdkInt}', 'device': '${info.manufacturer} ${info.model}'};
}

Future<bool> publishDiagnosticArchive(File archive, String filename) async =>
    await _files.invokeMethod<String>('publishExternal', {'source': archive.path, 'filename': filename, 'mimeType': 'application/zip'}) != null;
