import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

// 人脸照片的取图：相册或现场拍摄，选完进 3:4 裁剪页（可旋转翻转，对齐参考项目），
// 认可后把裁剪结果作为 JPEG 字节返回；任一步取消返回空。
Future<Uint8List?> pickChaoxingFacePhoto(BuildContext context, {required ImageSource source}) async {
  final picked = await ImagePicker().pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 95);
  if (picked == null) return null;
  final cropped = await ImageCropper().cropImage(
    sourcePath: picked.path,
    aspectRatio: const CropAspectRatio(ratioX: 3, ratioY: 4),
    compressFormat: ImageCompressFormat.jpg,
    uiSettings: [
      AndroidUiSettings(toolbarTitle: '调整人脸照片', lockAspectRatio: true),
    ],
  );
  if (cropped == null) return null;
  return cropped.readAsBytes();
}

// 拍照签到与补拍的现场拍摄：不经裁剪（拍照签到上传前会统一风格化处理），拍完即返回字节。
Future<Uint8List?> shootChaoxingPhoto({required ImageSource source}) async {
  final picked = await ImagePicker().pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 95);
  if (picked == null) return null;
  return picked.readAsBytes();
}
