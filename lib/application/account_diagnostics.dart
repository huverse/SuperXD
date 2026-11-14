import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/diagnostic_upload.dart';

// 记在应用账号下的诊断包（人工决策见 domain/diagnostic_upload.dart）：只认当前的应用账号（组合根注入 account）。
// 它本身也是上传：包住原来的上传（device），传完登录着就凭回执里的口令认领，回执标上 claimed；认领没成只记日志、包照旧匿名留着。
// 账号页经它看与删自己认领过的包；中转说账号已不在时调 accountGone（组合根让应用账号马上核一次）。
class AccountDiagnostics implements DiagnosticUploader {
  AccountDiagnostics({required this.uploader, required this.client, required this._account, this._accountGone});
  final DiagnosticUploader uploader;
  final DiagnosticAccountClient client;
  final AppAccountRef? Function() _account;
  final void Function()? _accountGone;

  @override
  Future<DiagnosticReceipt> upload(String archivePath, {void Function(double sent)? onProgress}) async {
    final receipt = await uploader.upload(archivePath, onProgress: onProgress);
    final account = _account(), claim = receipt.claim;
    if (account == null || claim == null) return receipt;
    try {
      await client.claim(account, receipt.id, claim);
      campusLog('[DiagnosticAccount] action=claim id=${receipt.id}');
      return DiagnosticReceipt(id: receipt.id, claim: claim, claimed: true);
    } on DiagnosticUploadException catch (error) {
      campusLog('[DiagnosticAccount] action=claim id=${receipt.id} errorType=${error.runtimeType} message=$error');
      if (error is DiagnosticNotSignedIn) _accountGone?.call();
      return receipt;
    }
  }

  // 自己认领过的包，从新到旧；没登录或失败抛 DiagnosticUploadException（页面原样显示原因）。
  Future<List<DiagnosticRecord>> list() => _with((account) => client.list(account));

  Future<void> delete(String id) => _with((account) => client.delete(account, id));

  Future<T> _with<T>(Future<T> Function(AppAccountRef account) work) async {
    final account = _account();
    if (account == null) throw const DiagnosticNotSignedIn();
    try {
      return await work(account);
    } on DiagnosticNotSignedIn {
      _accountGone?.call();
      rethrow;
    }
  }
}
