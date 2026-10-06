import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as picture;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingCloudTokenUri = 'https://pan-yz.chaoxing.com/api/token/uservalid';
const chaoxingCloudUploadUri = 'https://pan-yz.chaoxing.com/upload?_from=mobilelearn&_token=';

// 解码器碰到坏文件是自己抛异常（例如 PSD 头越界会 RangeError），一律当成读不出来。
picture.Image? decodeChaoxingPhoto(List<int> bytes) {
  try {
    return picture.decodeImage(Uint8List.fromList(bytes));
  } catch (error, stack) {
    campusLog('[Chaoxing] action=decode_photo errorType=${error.runtimeType}\n$stack');
    return null;
  }
}

// 上传前把照片随机裁一刀、转一个小角度，再按旋转后的安全内接矩形裁齐：
// 同一张照片反复用会被教师端比对出来，转过的像素也骗过按文件哈希查重的做法。
Uint8List chaoxingStylizePhoto(List<int> bytes, {Random? random}) {
  final source = decodeChaoxingPhoto(bytes);
  if (source == null || source.width < 16 || source.height < 16) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '照片读取失败，请重新选择');
  }
  final dice = random ?? Random();
  final cropRatio = 0.90 + dice.nextDouble() * 0.09;
  final cropWidth = max(1, (source.width * cropRatio).round());
  final cropHeight = max(1, (source.height * cropRatio).round());
  final cropped = picture.copyCrop(
    source,
    x: dice.nextInt(source.width - cropWidth + 1),
    y: dice.nextInt(source.height - cropHeight + 1),
    width: cropWidth,
    height: cropHeight,
  );
  final degrees = dice.nextDouble() * 10 - 5;
  final rotated = picture.copyRotate(cropped, angle: degrees, interpolation: picture.Interpolation.linear);
  final radians = degrees.abs() * pi / 180;
  final heightRatio = cropHeight / cropWidth;
  // 旋转后能容下的最大同比例矩形：两条边分别不许超出。
  final safeWidth = min(
    cropWidth / (cos(radians) + sin(radians) * heightRatio),
    cropHeight / (sin(radians) + cos(radians) * heightRatio),
  ).clamp(1, cropWidth.toDouble());
  final safeHeight = (safeWidth * heightRatio).clamp(1, cropHeight.toDouble());
  final result = picture.copyCrop(
    rotated,
    x: max(0, ((rotated.width - safeWidth) / 2).round()),
    y: max(0, ((rotated.height - safeHeight) / 2).round()),
    width: safeWidth.round(),
    height: safeHeight.round(),
  );
  return picture.encodeJpg(result, quality: 90);
}

// 拍照签到先把照片传到学习通云盘，拿 objectId 再提交。
Future<String> chaoxingUploadPhoto(ChaoxingClient client, {required List<int> bytes}) async {
  if (bytes.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '照片读取失败，请重新选择');
  }
  final token = await chaoxingCloudToken(client);
  final response = await client.http.postMultipart(
    Uri.parse('$chaoxingCloudUploadUri$token'),
    fields: {'puid': '${client.account!.puid}'},
    filename: '${chaoxingMd5('${bytes.length}-${DateTime.now().microsecondsSinceEpoch}')}.jpg',
    bytes: bytes,
    contentType: 'image/jpeg',
    timeout: const Duration(seconds: 25),
  );
  final objectId = chaoxingString(chaoxingJson(response.body)['objectId']);
  if (objectId.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.server, '照片上传失败，请重试');
  }
  return objectId;
}

Future<String> chaoxingCloudToken(ChaoxingClient client) async {
  final response = await client.http.get(Uri.parse(chaoxingCloudTokenUri));
  final token = chaoxingString(chaoxingJson(response.body)['_token']);
  if (token.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.server, '云盘凭证获取失败，请重试');
  }
  return token;
}
