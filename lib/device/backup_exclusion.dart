import 'dart:io';

import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';

// iOS 默认把应用数据带进 iCloud 备份与换机迁移，没有安卓 data_extraction_rules.xml 那样的规则文件：只属于这台设备的目录与文件经原生 DeviceOnlyData.swift 逐个标记排除。
// 目录标记后里面新建的文件也不进备份；文件被整个替换（先写临时文件再改名）会丢掉标记，所以会被替换的文件要放进标记过的目录里。
const _channel = MethodChannel('superxd/backup');

Future<void> excludeFromBackup({required List<Directory> folders, required List<File> files}) async {
  try {
    for (final folder in folders) {
      await folder.create(recursive: true);
    }
    await _channel.invokeMethod<void>('exclude', [for (final folder in folders) folder.path, for (final file in files) file.path]);
  } catch (error, stack) {
    campusLog('[Backup] action=exclude errorType=${error.runtimeType}\n$stack');
  }
}
