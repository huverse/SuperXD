import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

// 人脸照片：照片本身在学习通云盘，本机只记 objectId 与使用情况（每个账号最多 5 张）。
// 这里管列表、上传、预览缓存、保存到本机与默认照片重处理；会话由页面控制器注入（clientOf 按账号取、currentClient 取当前账号）。
class ChaoxingFaceController {
  ChaoxingFaceController({required this.accounts, required this.clientOf, required this.currentClient, this.filePublisher});
  final ChaoxingAccounts accounts;
  final Future<ChaoxingClient> Function(ChaoxingAccountRecord record) clientOf;
  final ChaoxingClient Function() currentClient;

  // 公共下载目录的文件导出（保存到本机用）；为空时保存入口不可用（测试环境）。
  final ToolboxFilePublisher Function()? filePublisher;

  // 预览只在内存里留最近的，按总字节数封顶（单张原图最大 10MB，按张数限不住内存）。
  static const faceImageCacheBytes = 20 * 1024 * 1024;
  final _faceBytes = <String, Uint8List>{};

  // 学习通账号资料里存的人脸照片 objectId（补给缺照的人之前先问一声用不用它）；没有为空。
  Future<String?> profileFaceId(ChaoxingAccountRecord record) async {
    final client = await clientOf(record);
    return accounts.run(client, () => chaoxingProfileFaceObjectId(client));
  }

  // 人脸照片（补拍、相册选或裁剪好的，不做风格化，要认得出人）上传到这个账号自己的云盘换 objectId，
  // 并记进本机的人脸照片索引供以后复用。
  Future<String> uploadFaceImage(ChaoxingAccountRecord record, List<int> bytes) async {
    final client = await clientOf(record);
    final objectId = await accounts.run(client, () => chaoxingUploadPhoto(client, bytes: bytes));
    await accounts.store.putFaceImage(record.phoneNumber, objectId);
    return objectId;
  }

  // 把学习通里存的默认人脸照片重处理一张再上传换新的 objectId（同一张照片直接反复用会被教师端比对），
  // 重处理后的记进本机索引，返回新 objectId；学习通里没存过时返回空。
  Future<String?> reprocessProfileFace(ChaoxingAccountRecord record) async {
    final profile = await profileFaceId(record);
    if (profile == null) return null;
    final client = await clientOf(record);
    final bytes = await client.http.getBytes(Uri.parse(chaoxingFaceImageUrl(profile)), payloadLimit: chaoxingFacePreviewLimit);
    final stylized = await compute(chaoxingStylizePhoto, Uint8List.fromList(bytes));
    final objectId = await accounts.run(client, () => chaoxingUploadPhoto(client, bytes: stylized));
    await accounts.store.putFaceImage(record.phoneNumber, objectId);
    return objectId;
  }

  // 把云盘里的人脸照片原图导出到公共下载目录（JPEG 文件）。
  // 文件名带 objectId：原生导出按文件名幂等，同一张照片重复保存直接返回已有文件，换照片不会互相覆盖。
  Future<Uri> saveFaceImage(String objectId) async {
    final makePublisher = filePublisher;
    if (makePublisher == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '当前环境不能保存文件');
    }
    final publisher = makePublisher();
    // objectId 来自学习通云盘（外部输入），临时文件与导出文件名都只保留安全字符。
    final safeId = objectId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '');
    final suffix = safeId.length > 32 ? safeId.substring(0, 32) : safeId;
    final bytes = await faceImageBytes(objectId);
    final temp = File(path.join(Directory.systemTemp.path, 'chaoxing-face-$suffix.jpg'));
    await temp.writeAsBytes(bytes, flush: true);
    try {
      final uri = await publisher.publishExternal(source: temp.path, filename: '人脸照片${suffix.isEmpty ? '' : '-$suffix'}.jpg', mimeType: 'image/jpeg');
      if (uri == null) {
        throw const ChaoxingFailure(ChaoxingFailureCode.server, '保存失败，请重试');
      }
      return uri;
    } finally {
      unawaited(
        temp.delete().then((_) {}, onError: (Object error, StackTrace stack) {
          campusLog('[Chaoxing] action=face_temp_clean errorType=${error.runtimeType}\n$stack');
        }),
      );
    }
  }

  // 人脸照片：每个账号最多存 5 张（照片在学习通云盘，本机只记 objectId 与使用情况）。
  Future<List<ChaoxingFaceImage>> faceImages(ChaoxingAccountRecord record) => accounts.store.faceImages(record.phoneNumber);

  // 学习通里已经存着的人脸照片：取回来记进本机，之后签人脸签到默认用它。
  Future<String?> importProfileFace(ChaoxingAccountRecord record) async {
    final objectId = await profileFaceId(record);
    if (objectId != null) await accounts.store.putFaceImage(record.phoneNumber, objectId);
    return objectId;
  }

  Future<void> removeFaceImage(ChaoxingAccountRecord record, String objectId) async {
    await accounts.store.removeFaceImage(record.phoneNumber, objectId);
    _faceBytes.remove(objectId);
  }

  // 人脸照片预览：从学习通云盘取原图，内存里留最近几张。
  Future<Uint8List> faceImageBytes(String objectId) async {
    final cached = _faceBytes.remove(objectId);
    if (cached != null) return _faceBytes[objectId] = cached;
    final bytes = await currentClient().http.getBytes(Uri.parse(chaoxingFaceImageUrl(objectId)), payloadLimit: chaoxingFacePreviewLimit);
    _faceBytes[objectId] = bytes;
    var total = _faceBytes.values.fold<int>(0, (sum, item) => sum + item.length);
    // 最新这张总是留着，超出的从最久没看的开始丢。
    while (total > faceImageCacheBytes && _faceBytes.length > 1) {
      total -= _faceBytes.remove(_faceBytes.keys.first)!.length;
    }
    return bytes;
  }
}
