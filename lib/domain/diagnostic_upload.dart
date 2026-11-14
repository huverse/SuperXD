import 'package:superxd/domain/app_account.dart';

// [人工决策-2026-11-10 13:06:24] 诊断包上传（用户选定「用户同意后一键上传诊断包到中转」）：应用不做远程崩溃上报，
// 排查原来只能靠用户在开发者选项里导出日志、再自己发给开发者，闭环太长（iOS 闪退排查卡在这一步）。没选自动上传或崩溃上报（不经用户确认就发出去），
// 也没选维持只能导出（用户还得自己找渠道发文件）。做法：
// 入口在开发者选项「导出日志」旁边，每次点了先确认（写明内容、传到哪、保留多久）才传；内容与导出的日志包相同，不新增采集项；
// 包在本机用开发者的公钥加密（X25519 一次性密钥协商、HKDF-SHA256、AES-256-GCM，见 device/diagnostic_seal.dart），中转是明文 HTTP，
// 路上的人与服务器都只见密文；服务器只存不发（没有下载接口，开发者经 ssh 取），diagnosticUploadKeepDays 天后自动删除；
// 传完给一个短的诊断编号，用户把它告诉开发者，要提前删除也凭它联系开发者。
//
// [人工决策-2026-11-14 16:47:34] 诊断包并入应用账号（第 4 阶段，用户选「服务器记到账号下」）：上传照旧免签名、照旧匿名完成（没开私信、没登录的人也要能传），
// 回执另带一次性认领口令；登录着应用账号时紧接着凭它把包认领到账号下（不对几 MB 的边传边发请求体签名），开发者能把它和这个账号在服务器上的记录对上，
// 用户在账号页（应用账号那一行的菜单）能看到、删除自己认领过的包，注销应用账号一并删除。认领没成只是这个包仍是匿名的，不影响上传。
// 只认当前应用账号（AppAccountRef），不认是用什么登录的。

// 服务器保存诊断包的天数，与服务端 server/src/common/relay_limits.ts 的 diagnosticKeepDays 一致（确认弹窗与隐私政策照它写）。
const diagnosticUploadKeepDays = 30;

class DiagnosticUploadException implements Exception {
  const DiagnosticUploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 中转说这把密钥已不属于任何应用账号（别处注销、被清理）：本机的应用账号随之核一次。
class DiagnosticNotSignedIn extends DiagnosticUploadException {
  const DiagnosticNotSignedIn() : super('应用账号已经退出，请重新登录');
}

// 上传回执：诊断编号、认领口令（旧中转不给时为空）与是否已记到应用账号下（application/account_diagnostics.dart 认领后标上）。
class DiagnosticReceipt {
  const DiagnosticReceipt({required this.id, this.claim, this.claimed = false});
  final String id;
  final String? claim;
  final bool claimed;
}

// 把打好的日志包加密后交给开发者（device 实现：自建中转），成功返回回执；sent 是已发出的比例（0–1），加密时还没有。
// 连不上、限流、服务器存满或返回格式不对抛 DiagnosticUploadException。
abstract class DiagnosticUploader {
  Future<DiagnosticReceipt> upload(String archivePath, {void Function(double sent)? onProgress});
}

// 记在应用账号下的一个诊断包：编号、密文大小、上传时刻与大约删除的时刻（UTC）。
class DiagnosticRecord {
  const DiagnosticRecord({required this.id, required this.bytes, required this.uploadedAt, required this.expiresAt});
  final String id;
  final int bytes;
  final DateTime uploadedAt;
  final DateTime expiresAt;
}

// 应用账号下的诊断包（social 实现：用这个应用账号的设备密钥签名）：凭回执认领、列出（从新到旧）、删除。
// 连不上、限流、包不在了抛 DiagnosticUploadException，账号已不在抛 DiagnosticNotSignedIn。
abstract interface class DiagnosticAccountClient {
  Future<DiagnosticRecord> claim(AppAccountRef account, String id, String claim);
  Future<List<DiagnosticRecord>> list(AppAccountRef account);
  Future<void> delete(AppAccountRef account, String id);
}
