import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/download_pack.dart';

// 按需下载文件包的自建中转实现（字体包、星空素材包共用，模型见 domain/download_pack.dart）：GET /v1/app/files/<文件名>（免签名、不带任何标识，同安装包下载），
// 经共用请求内核 CampusHttp 发：每个文件整次最多 timeout（默认 3 分钟，约 4MB 的文件够每秒 25KB 的慢网下完），响应上限就是登记的大小，
// 取消即中断连接，请求记录在内核里记（module）；边收边报进度，收完写进目标文件。不自动重试，SHA-256 由调用方（local/pack_library.dart）核对。
// tag 是日志模块名（FontPack、SkyPack），noun 是给用户看的东西（「字体」「星空」），用在失败说明里。
class RelayPackSource implements PackSource {
  RelayPackSource(this.baseUrl, {required String module, required this.tag, required this.noun, http.Client? client, this.timeout = const Duration(minutes: 3)}) : _http = CampusHttp(module, client: client);
  final String baseUrl;
  final String tag;
  final String noun;
  final Duration timeout;
  final CampusHttp _http;

  @override
  Future<void> download(PackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort}) async {
    if (!packFileName.hasMatch(file.name)) throw ArgumentError.value(file.name, 'file');
    final uri = Uri.parse('$baseUrl/v1/app/files/${file.name}');
    final http.Response response;
    try {
      response = await _http.send('GET', uri, timeout: timeout, limit: file.size, cancel: abort, collect: (stream, limit) async {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          bytes.add(chunk);
          if (bytes.length > limit) throw CampusHttpTooLarge(limit);
          onProgress(bytes.length);
        }
        return bytes.takeBytes();
      });
    } on http.RequestAbortedException {
      throw const PackCancelled();
    } on CampusHttpTooLarge {
      throw PackException('$noun文件不对，请稍后再试');
    } on TimeoutException catch (error, stack) {
      campusLog('[$tag] action=download file=${file.name} errorType=${error.runtimeType}\n$stack');
      throw const PackException('下载超时，请换个网络后重试');
    } catch (error, stack) {
      campusLog('[$tag] action=download file=${file.name} errorType=${error.runtimeType}\n$stack');
      throw const PackException('连不上服务器，请检查网络后重试');
    }
    if (response.statusCode != 200) throw PackException(_statusMessage(response.statusCode));
    await File(target).writeAsBytes(response.bodyBytes, flush: true);
  }

  String _statusMessage(int status) => switch (status) {
    404 => '服务器上还没有这个$noun，请稍后再试',
    429 || 503 => '下载的人太多，请稍后再试',
    _ => '服务器暂时不可用，请稍后再试',
  };
}

// 字体包的下载源（人工决策见 domain/font_pack.dart）：请求记录的模块名 font_pack。
class RelayFontPackSource extends RelayPackSource {
  RelayFontPackSource(super.baseUrl, {super.client, super.timeout}) : super(module: 'font_pack', tag: 'FontPack', noun: '字体');
}
