import 'dart:io';
import 'dart:typed_data';

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 取图本身由组合根注入（ToolboxImagePick，与壁纸共用、缓存副本用完即删）；人脸属于生物特征，
// 取图、裁剪留下的文件读成字节后一律删掉，不在缓存里留存。没注入取图能力（测试环境）时返回空。

// 人脸照片：相册或现场拍摄，选完进 3:4 裁剪页（可旋转翻转，对齐参考项目），认可后返回裁剪结果的 JPEG 字节；任一步取消返回空。
Future<Uint8List?> pickChaoxingFacePhoto(ToolboxImagePick? pickImage, {required ImageSource source}) async {
  final picked = await _pick(pickImage, source);
  if (picked == null) return null;
  try {
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 3, ratioY: 4),
      compressFormat: ImageCompressFormat.jpg,
      uiSettings: [
        AndroidUiSettings(toolbarTitle: '调整人脸照片', lockAspectRatio: true),
      ],
    );
    if (cropped == null) return null;
    final file = File(cropped.path);
    try {
      return await file.readAsBytes();
    } finally {
      if (await file.exists()) await file.delete();
    }
  } finally {
    await picked.discard();
  }
}

// 拍照签到与补拍：不经裁剪（拍照签到上传前会统一风格化处理），取到即返回字节。
Future<Uint8List?> shootChaoxingPhoto(ToolboxImagePick? pickImage, {required ImageSource source}) async {
  final picked = await _pick(pickImage, source);
  if (picked == null) return null;
  try {
    return await File(picked.path).readAsBytes();
  } finally {
    await picked.discard();
  }
}

Future<({String path, Future<void> Function() discard})?> _pick(ToolboxImagePick? pickImage, ImageSource source) async {
  if (pickImage == null) {
    campusLog('[Chaoxing] action=pick_image errorType=unavailable');
    return null;
  }
  return pickImage(source: source, maxSide: 1920, quality: 95);
}
