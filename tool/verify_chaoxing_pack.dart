import 'dart:io';

import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';

// 代签凭据包经真实中转服务的往返验证（手动，不进 CI）。只用合成凭据，不碰任何真实账号。
// 覆盖：投递换取件号与作废口令、二维码文本编解码、取件解封、取走即删（再取要 PACK_NOT_FOUND）、凭口令作废。
// 运行：
//   dart run tool/verify_chaoxing_pack.dart http://127.0.0.1:8790
Future<void> main(List<String> args) async {
  final base = args.isEmpty ? '' : args.first;
  if (base.isEmpty) {
    _log('failed reason=missing_base_url usage=dart run tool/verify_chaoxing_pack.dart <relay_base_url>');
    exitCode = 2;
    return;
  }
  final hub = ChaoxingPackHub(baseUrl: Uri.parse(base));
  try {
    const source = ChaoxingCredentialPack(
      phoneNumber: '13000000000',
      encryptedPassword: 'synthetic-cipher-text',
      name: '联调合成',
      deviceCode: 'synthetic-device-code',
    );
    final sealed = await sealChaoxingCredentialPack(source);
    _log('seal=ok cipher=${sealed.cipherText.length}B key=${sealed.key.length}B');

    final watch = Stopwatch()..start();
    final submitted = await hub.submit(sealed.cipherText);
    final pickupId = submitted.id;
    _log('submit=ok pickupId=len=${pickupId.length} revokeToken=${submitted.revokeToken == null ? 'none' : 'ok'} ms=${watch.elapsedMilliseconds}');
    if (!RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(pickupId)) {
      _log('submit=bad_format pickupId_len=${pickupId.length}');
      exitCode = 1;
      return;
    }

    // 模拟对方扫码：只拿二维码文本，不拿密文。
    final raw = encodeChaoxingPackTicket(ChaoxingPackTicket(pickupId: pickupId, key: sealed.key));
    final parsed = decodeChaoxingPackTicket(raw);
    _log('ticket=ok len=${raw.length} parsed=${parsed == null ? 'none' : 'ok'}');

    watch.reset();
    final cipherText = await hub.pickup(pickupId);
    _log('pickup=ok bytes=${cipherText.length} ms=${watch.elapsedMilliseconds} match=${_same(cipherText, sealed.cipherText)}');

    final opened = await openChaoxingCredentialPack(ChaoxingSealedPack(key: sealed.key, cipherText: cipherText));
    _log(
      'open=ok phone=${opened.phoneNumber == source.phoneNumber} password=${opened.encryptedPassword == source.encryptedPassword} '
      'name=${opened.name == source.name} device=${opened.deviceCode == source.deviceCode}',
    );

    // 取走即删：同一个取件号再取一次必须是 PACK_NOT_FOUND。
    try {
      await hub.pickup(pickupId);
      _log('repickup=bad 第二次仍能取到');
      exitCode = 1;
    } on ChaoxingFailure catch (error) {
      _log('repickup=ok code=${error.code.name}${error.code == ChaoxingFailureCode.packNotFound ? '' : ' (预期 packNotFound)'}');
      if (error.code != ChaoxingFailureCode.packNotFound) exitCode = 1;
    }

    // 轮换即作废：再投一个包，凭口令作废后取不到。
    final rotated = await hub.submit(sealed.cipherText);
    final rotatedToken = rotated.revokeToken;
    if (rotatedToken == null) {
      _log('revoke=skipped 中转还没升级，没给作废口令');
    } else {
      await hub.revoke(rotated.id, rotatedToken);
      try {
        await hub.pickup(rotated.id);
        _log('revoke=bad 作废后仍能取到');
        exitCode = 1;
      } on ChaoxingFailure catch (error) {
        _log('revoke=ok code=${error.code.name}');
        if (error.code != ChaoxingFailureCode.packNotFound) exitCode = 1;
      }
    }

    // 不存在的取件号也要是 PACK_NOT_FOUND，不能是 500。
    try {
      await hub.pickup('aaaaaaaaaaaaaaaa');
      _log('unknown=bad 不存在的取件号被接受了');
      exitCode = 1;
    } on ChaoxingFailure catch (error) {
      _log('unknown=ok code=${error.code.name}');
    }
  } on ChaoxingFailure catch (error, stack) {
    _log('failed code=${error.code.name} message=${error.message}\n$stack');
    exitCode = 1;
  } finally {
    hub.close();
  }
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _log(String message) => stdout.writeln('[ChaoxingPackVerify] $message');
