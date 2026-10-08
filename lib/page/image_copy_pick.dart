import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

// 取到的一张图：path 是压缩后的副本，discard 删除这次取图在缓存里留下的全部副本，用完即删，不在缓存里累积。
typedef PickedImage = ({String path, Future<void> Function() discard});

// 插件在缓存根目录留下的副本都以随机 UUID 开头：相册选图拷进 UUID 文件夹，相机拍照存成「UUID+随机数.jpg」，
// 压缩版另存在缓存根目录（就是返回的 path），插件自己都不清理。取图前后对比，只删这次新出现的，不碰别的插件的缓存。
final _pickerCopy = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}');

// 系统取图（相册走系统照片选择器、只给选中的那一张，不申请存储权限；相机现拍）；长边压到 maxSide、转成 JPEG。
// 壁纸、相册识别二维码与百宝箱的人脸、签到照片共用这一处（百宝箱经组合根注入）。
Future<PickedImage?> pickImageCopy({required ImageSource source, required double maxSide, required int quality}) async {
  final cache = await getTemporaryDirectory();
  Future<Map<String, FileSystemEntity>> copies() async => {
    await for (final entity in cache.list())
      if (_pickerCopy.hasMatch(path.basename(entity.path))) entity.path: entity,
  };
  final before = await copies();
  final picked = await ImagePicker().pickImage(source: source, maxWidth: maxSide, maxHeight: maxSide, imageQuality: quality);
  final created = (await copies())..removeWhere((key, _) => before.containsKey(key));
  Future<void> discard() async {
    for (final entity in created.values) {
      if (await entity.exists()) await entity.delete(recursive: true);
    }
    if (picked != null && await File(picked.path).exists()) await File(picked.path).delete();
  }

  if (picked == null) {
    await discard();
    return null;
  }
  return (path: picked.path, discard: discard);
}
