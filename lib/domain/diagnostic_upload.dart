// [人工决策-2026-11-10 13:06:24] 诊断包上传（用户选定「用户同意后一键上传诊断包到中转」）：应用不做远程崩溃上报，
// 排查原来只能靠用户在开发者选项里导出日志、再自己发给开发者，闭环太长（iOS 闪退排查卡在这一步）。没选自动上传或崩溃上报（不经用户确认就发出去），
// 也没选维持只能导出（用户还得自己找渠道发文件）。做法：
// 入口在开发者选项「导出日志」旁边，每次点了先确认（写明内容、传到哪、保留多久）才传；内容与导出的日志包相同，不新增采集项；
// 包在本机用开发者的公钥加密（X25519 一次性密钥协商、HKDF-SHA256、AES-256-GCM，见 device/diagnostic_seal.dart），中转是明文 HTTP，
// 路上的人与服务器都只见密文；服务器只存不发（没有下载接口，开发者经 ssh 取），diagnosticUploadKeepDays 天后自动删除；
// 传完给一个短的诊断编号，用户把它告诉开发者，要提前删除也凭它联系开发者。

// 服务器保存诊断包的天数，与服务端 server/src/common/relay_limits.ts 的 diagnosticKeepDays 一致（确认弹窗与隐私政策照它写）。
const diagnosticUploadKeepDays = 30;

class DiagnosticUploadException implements Exception {
  const DiagnosticUploadException(this.message);
  final String message;
  @override
  String toString() => message;
}

// 把打好的日志包加密后交给开发者（device 实现：自建中转），成功返回诊断编号；sent 是已发出的比例（0–1），加密时还没有。
// 连不上、限流、服务器存满或返回格式不对抛 DiagnosticUploadException。
abstract class DiagnosticUploader {
  Future<String> upload(String archivePath, {void Function(double sent)? onProgress});
}
