import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/device/diagnostic_seal.dart';
import 'package:superxd/device/relay_diagnostic_upload.dart';
import 'package:superxd/domain/diagnostic_upload.dart';

void main() {
  // 测试钥每次现生成，私钥只在内存里；源码里的开发者公钥对应的私钥不在仓库，测试只核它的形状。
  late List<int> testSeed;
  late String testPublic;
  late Directory temp;
  setUpAll(() async {
    final keyPair = await X25519().newKeyPair();
    testSeed = await keyPair.extractPrivateKeyBytes();
    testPublic = base64UrlNoPad((await keyPair.extractPublicKey()).bytes);
  });
  setUp(() => temp = Directory.systemTemp.createTempSync('diagnostic_upload_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  Uint8List sample(int length) {
    final random = Random(7);
    return Uint8List.fromList([for (var index = 0; index < length; index++) random.nextInt(256)]);
  }

  group('信封', () {
    test('只有对应的私钥解得开，换了私钥或改过一个字节都解不开；长度只多一个信封头；同一份明文每次的密文都不同', () async {
      final plain = sample(5000);
      final sealed = await sealDiagnostic(plain, decodeDiagnosticKey(testPublic));
      expect(sealed.length, plain.length + diagnosticSealOverhead);
      expect(sealed[0], diagnosticSealVersion);
      expect(await openDiagnostic(sealed, testSeed), plain);

      final other = await X25519().newKeyPair();
      await expectLater(openDiagnostic(sealed, await other.extractPrivateKeyBytes()), throwsFormatException);
      for (final index in [1, 40, 100, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed)..[index] ^= 1;
        await expectLater(openDiagnostic(tampered, testSeed), throwsFormatException, reason: '改了第 $index 字节');
      }
      await expectLater(openDiagnostic(Uint8List.fromList([2, ...sealed.sublist(1)]), testSeed), throwsFormatException);
      await expectLater(openDiagnostic(sealed.sublist(0, diagnosticSealOverhead - 1), testSeed), throwsFormatException);

      final again = await sealDiagnostic(plain, decodeDiagnosticKey(testPublic));
      expect(again.sublist(1, 45), isNot(sealed.sublist(1, 45)));
    });

    test('源码里的开发者公钥是 32 字节的 X25519 公钥，编码往返不变', () {
      expect(decodeDiagnosticKey(diagnosticRecipientKey), hasLength(32));
      expect(base64UrlNoPad(decodeDiagnosticKey(diagnosticRecipientKey)), diagnosticRecipientKey);
      expect(() => decodeDiagnosticKey('AAAA'), throwsFormatException);
    });
  });

  group('上传到中转', () {
    File archive(int length) => File(path.join(temp.path, 'upload.zip'))..writeAsBytesSync(sample(length));
    List<String> left() => [for (final entity in temp.listSync()) path.basename(entity.path)];

    test('POST /v1/diagnostics 二进制请求体、声明长度不分块，用测试钥解开就是原包；进度报到 1，回诊断编号，临时密文删掉', () async {
      final zip = archive(300 * 1024);
      late http.BaseRequest seen;
      late Uint8List body;
      final upload = RelayDiagnosticUpload('http://relay.test', recipientKey: testPublic, client: MockClient.streaming((request, stream) async {
        seen = request;
        body = await stream.toBytes();
        // 发的时候密文就放在包旁边，传完才删。
        expect(left(), containsAll(['upload.zip', 'upload.zip.sealed']));
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'id': '7KQ2M9XD', 'keepDays': 30}))), 200);
      }));
      final progress = <double>[];
      expect(await upload.upload(zip.path, onProgress: progress.add), '7KQ2M9XD');
      expect((seen.method, seen.url.toString()), ('POST', 'http://relay.test/v1/diagnostics'));
      expect(seen.headers['content-type'], 'application/octet-stream');
      expect(seen.contentLength, body.length);
      expect(await openDiagnostic(body, testSeed), zip.readAsBytesSync());
      expect(progress.last, 1);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(left(), ['upload.zip']);
    });

    test('限流、存满、超限、服务器出错与回执不对各给一句说明，临时密文照样删掉', () async {
      final zip = archive(1024);
      Future<String> failure(int status, String body) async {
        final upload = RelayDiagnosticUpload('http://relay.test', recipientKey: testPublic, client: MockClient((request) async => http.Response(body, status)));
        try {
          await upload.upload(zip.path);
        } on DiagnosticUploadException catch (error) {
          return error.message;
        }
        fail('应当失败');
      }
      expect(await failure(429, '{"code":"RATE_LIMITED"}'), '上传太频繁，请过一会儿再试');
      expect(await failure(503, '{"code":"MAILBOX_FULL"}'), '服务器暂时存满了，请过几天再试，或改用导出日志');
      expect(await failure(413, '{"code":"ENVELOPE_TOO_LARGE"}'), '日志包超过上传上限，请改用导出日志');
      expect(await failure(500, '{"code":"INTERNAL"}'), '服务器暂时不可用，请稍后再试');
      expect(await failure(200, '{"id":"../../etc"}'), '服务器返回的格式不对');
      expect(await failure(200, 'not json'), '服务器返回的格式不对');
      expect(await failure(200, 'x' * (diagnosticResponseMaxBytes + 1)), '服务器暂时不可用，请稍后再试');
      expect(left(), ['upload.zip']);
    });

    test('连不上时说连不上；一直没有进展时到点中止、说网络太慢', () async {
      final zip = archive(1024);
      final offline = RelayDiagnosticUpload('http://relay.test', recipientKey: testPublic, client: MockClient((request) async => throw const SocketException('down')));
      await expectLater(offline.upload(zip.path), throwsA(isA<DiagnosticUploadException>().having((error) => error.message, 'message', '连不上服务器，请检查网络后再试')));
      // 服务器一直不回（也不读请求体）：看门狗到点就停，不会一直挂着。
      final stalled = RelayDiagnosticUpload('http://relay.test', recipientKey: testPublic, stallTimeout: const Duration(milliseconds: 100), client: MockClient.streaming((request, stream) => Completer<http.StreamedResponse>().future));
      await expectLater(stalled.upload(zip.path), throwsA(isA<DiagnosticUploadException>().having((error) => error.message, 'message', '网络太慢没传完，请换个网络再试')));
      expect(left(), ['upload.zip']);
    });

    test('回执只认 8 位 Crockford base32 的诊断编号', () {
      expect(parseDiagnosticReceipt({'id': '0123ABYZ', 'keepDays': 30}), '0123ABYZ');
      for (final id in ['0123ABIO', '0123abyz', '0123ABY', '0123ABYZ9', 123]) {
        expect(() => parseDiagnosticReceipt({'id': id}), throwsFormatException, reason: '$id');
      }
      expect(() => parseDiagnosticReceipt([]), throwsFormatException);
    });
  });
}
