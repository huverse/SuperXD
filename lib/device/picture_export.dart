import 'dart:io';

import 'package:flutter/services.dart';

// 把一张图存进本机公共目录 Download/SuperXD（相册里可见）：经原生一次性导出（ToolboxFileExporter.kt，与百宝箱、诊断日志包共用通道 superxd/toolbox_files），
// 原生只放行图片与日志包、文件名按名幂等（同名已存过直接返回）。开屏画作的「保存到相册」用，由组合根交给 local/painting_library.dart。
const _files = MethodChannel('superxd/toolbox_files');

const _mimes = {'.jpg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp'};

Future<bool> publishPicture(File picture, String filename) async =>
    await _files.invokeMethod<String>('publishExternal', {'source': picture.path, 'filename': filename, 'mimeType': _mimes[filename.substring(filename.lastIndexOf('.'))]}) != null;
