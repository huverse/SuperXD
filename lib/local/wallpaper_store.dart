import 'dart:io';

import 'package:path/path.dart' as path;

// 自定义壁纸文件：放在应用支持目录 display/wallpaper 下，只保留当前一份，单图上限 20MB。
// 每次导入用新文件名，图片缓存不会拿到旧图；旧文件在设置落库后由 prune 删除，中途失败也不丢当前壁纸。
class WallpaperStore {
  WallpaperStore(this.directory);
  final Directory directory;
  static const maxBytes = 20 * 1024 * 1024;

  Future<String> import(String source) async {
    final file = File(source);
    final length = await file.length();
    if (length > maxBytes) throw ArgumentError.value(length, 'wallpaper', '超过 $maxBytes 字节');
    await directory.create(recursive: true);
    final name = 'wallpaper_${DateTime.now().toUtc().microsecondsSinceEpoch}${path.extension(source).toLowerCase()}';
    await file.copy(path.join(directory.path, name));
    return name;
  }

  File file(String name) => File(path.join(directory.path, name));

  // 只留下 keep，keep 为 null 时全部删除。目录里只有本类写入的文件，条目数有界。
  Future<void> prune(String? keep) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File && path.basename(entity.path) != keep) await entity.delete();
    }
  }
}
