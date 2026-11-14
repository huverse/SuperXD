import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/diagnostic_upload.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';

// 应用账号下的诊断包的中转实现（人工决策见 domain/diagnostic_upload.dart，协议见 server/README.md）：用这个应用账号的设备密钥签名
// （安全存储 superxd_account 的 account.slot，没有这把密钥算没登录）；超时、请求记录与校时重发一次沿用 RelayClient，不重试；回复逐项校验。
class RelayDiagnosticAccountClient implements DiagnosticAccountClient {
  RelayDiagnosticAccountClient({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final AppAccountVault vault;
  final RelayClient _relay;

  static final _idPattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$');

  Future<Map<String, Object?>> _send(AppAccountRef account, String method, String path, [Map<String, Object?>? payload]) async {
    final saved = await vault.read(account.slot);
    if (saved == null) throw const DiagnosticNotSignedIn();
    try {
      return await _relay.request(saved.identity, method, path, payload);
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.accountNotFound || RelayCode.unauthorized => const DiagnosticNotSignedIn(),
        RelayCode.diagnosticNotFound => const DiagnosticUploadException('诊断包不存在或已经删除'),
        RelayCode.network || RelayCode.timeout => const DiagnosticUploadException('连不上服务器'),
        RelayCode.rateLimited => const DiagnosticUploadException('操作太频繁，请稍后再试'),
        _ => DiagnosticUploadException('服务器暂时不可用（${error.code}）'),
      };
    }
  }

  static DiagnosticRecord _record(Object? json) => switch (json) {
    {'id': final String id, 'bytes': final int bytes, 'uploadedAt': final int uploadedAt, 'expiresAt': final int expiresAt} when _idPattern.hasMatch(id) && bytes >= 0 =>
      DiagnosticRecord(id: id, bytes: bytes, uploadedAt: DateTime.fromMillisecondsSinceEpoch(uploadedAt, isUtc: true), expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true)),
    _ => _bad(),
  };

  static Never _bad() {
    campusLog('[DiagnosticAccount] action=decode code=${RelayCode.badResponse}');
    throw const DiagnosticUploadException('服务器的回复看不懂，请更新应用后再试');
  }

  @override
  Future<DiagnosticRecord> claim(AppAccountRef account, String id, String claim) async => _record(await _send(account, 'POST', '/v1/account/diagnostics/$id/claim', {'claim': claim}));

  @override
  Future<List<DiagnosticRecord>> list(AppAccountRef account) async => switch ((await _send(account, 'GET', '/v1/account/diagnostics'))['uploads']) {
    final List<Object?> uploads => [for (final item in uploads) _record(item)],
    _ => _bad(),
  };

  @override
  Future<void> delete(AppAccountRef account, String id) async {
    await _send(account, 'DELETE', '/v1/account/diagnostics/$id');
  }
}
