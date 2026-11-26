// 按需下载的文件包：不随安装包、用户选用时才从自建中转下载的一组文件（字体包、星空素材包共用这一套）。
// 每个文件的名字、大小与 SHA-256 写死在各自的登记表里，下载后逐个核对，核对不过就不用；文件名带内容哈希，换了内容就是新名字，
// 中转上同名文件永远是同一份。本机文件、核对与下载状态在 local/pack_library.dart，下载经 device 层的 PackSource。

class PackFile {
  const PackFile({required this.name, required this.size, required this.sha256});
  // 中转发布目录与本机目录里的文件名（只许字母数字与 . _ -，见 packFileName）。
  final String name;
  final int size;
  // 小写十六进制。
  final String sha256;
}

abstract interface class DownloadPack {
  // 包的 id（字体 id、星空画风 id），本机状态按它记。
  String get id;
  List<PackFile> get files;
}

int packSize(DownloadPack pack) => pack.files.fold(0, (sum, file) => sum + file.size);

// 文件名的规则（同中转下载接口 server 的 appDownloadFileName）：字体是 .ttf，星空素材是 .webp。
final packFileName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(ttf|webp)$');

// stored 是文件齐全（按大小看）但这次运行还没核对装好：选它时核对，不用联网。
enum PackPhase { missing, downloading, stored, ready, failed }

class PackStatus {
  const PackStatus(this.phase, {this.received = 0, this.total = 0, this.error});
  static const missing = PackStatus(PackPhase.missing);
  static const stored = PackStatus(PackPhase.stored);
  static const ready = PackStatus(PackPhase.ready);
  final PackPhase phase;
  // 下载中：这个包已收到与总共的字节数（已经在本机、核对通过的文件算作收到）。
  final int received;
  final int total;
  // 下载失败时给用户看的原因。
  final String? error;
  double get progress => total == 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

// 下载一个文件的端口（device 层经自建中转实现）：把文件写到 target（覆盖），onProgress 报这个文件已收到的字节；
// abort 完成时尽快停下并抛 PackCancelled。只管传输、超时与响应上限（不超过 file.size），SHA-256 由调用方核对。
abstract interface class PackSource {
  Future<void> download(PackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort});
}

class PackException implements Exception {
  const PackException(this.message);
  final String message;
  @override
  String toString() => 'PackException: $message';
}

class PackCancelled implements Exception {
  const PackCancelled();
}
