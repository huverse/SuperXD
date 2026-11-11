// 字体包：不随安装包、用户选用时才从自建中转下载的字体。
// [人工决策-2026-11-10 13:15:54] 用户选定字体裁剪（见 tool/font_subset.py 文件头），衬线字体（非默认）改为选用时再下载：
// 安装包只带默认的 Maple；选衬线时在界面页原地下载、可取消，装好再换上；升级上来原先选着衬线的，首帧先用默认字体，同意协议与政策后自动下回来再切回去，失败下次启动再试。
// 没选「衬线仍打包」（安装包大、更新慢）与「改用系统里的宋体」（各家安卓不一定有、字形不一）。
// [人工决策-2026-11-11 13:04:38] 下载的字体包可以删除（用户 2026-11-10 追加的决定）：界面页衬线一项的⋯菜单里「删除字体包」，确认后删；正在用就先换回默认字体再删文件，删完回到未下载、可再下载。
// Maple 打在安装包里不能删、也不做成下载包（用户接受主会话的建议）。
//
// 一个字体 id 对应一组字重文件，每个文件的名字、大小与 SHA-256 写死在这里，下载后逐个核对（中转是明文 HTTP，内容可能被改，核对不过就不用）。
// 文件就是仓库 font_packs 目录里的同名文件（tool/font_subset.py 生成，test/code_conventions_test.dart 核对一致），发版流水线随安装包传到中转的发布目录。
// 文件名带内容哈希前 12 位：换了内容就是新名字，中转上同名文件永远是同一份。重新裁剪后旧文件留在 font_packs 里（流水线只保留那里有的），
// 直到用旧文件的版本都低于最低可用版本（release.yml 的 RELEASE_MIN_SUPPORTED）再删。
// 以后要把别的字体也做成包（如默认字体），在 fontPacks 里加一项即可，下载、核对、注册与删除都按 id 走。

class FontPackFile {
  const FontPackFile({required this.name, required this.weight, required this.size, required this.sha256});
  // 中转发布目录与本机目录里的文件名（只许字母数字与 . _ -，以 .ttf 结尾）。
  final String name;
  // 字重（400、500、600），注册时与 pubspec 里内置字体的写法一致。
  final int weight;
  final int size;
  // 小写十六进制。
  final String sha256;
}

class FontPack {
  const FontPack({required this.id, required this.family, required this.files});
  // 与显示设置里的字体 id 一致（如 serif）。
  final String id;
  // 注册给引擎的字体族名，界面按它取字体（与 DisplaySettings.fontFamilies 一致）。
  final String family;
  final List<FontPackFile> files;
  int get size => files.fold(0, (sum, file) => sum + file.size);
}

// Noto Serif SC 2.003 三个静态字重，裁到 tool/font_charset.txt（tool/font_subset.py）。
const fontPacks = <String, FontPack>{
  'serif': FontPack(id: 'serif', family: 'Noto Serif SC', files: [
    FontPackFile(name: 'noto_serif_sc_regular-6749e5e6e30a.ttf', weight: 400, size: 4405112, sha256: '6749e5e6e30a00d2d9cc69e72cc7b8ef4cb9a99c768d984c633137c86b09acd7'),
    FontPackFile(name: 'noto_serif_sc_medium-02c86556249e.ttf', weight: 500, size: 4405168, sha256: '02c86556249efe02f5ec1102e65172b01651c6f0859e70d69f6dffcf2b9bee98'),
    FontPackFile(name: 'noto_serif_sc_semibold-4e0287fcab77.ttf', weight: 600, size: 4405456, sha256: '4e0287fcab77e9bc079e45f90ccfdb549001515b4c1076a686b33890cef58f71'),
  ]),
};

// 字体包文件名的规则（同中转下载接口）。
final fontPackFileName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.ttf$');

// stored 是文件齐全（按大小看）但这次运行还没注册：选它时核对、注册，不用联网。
enum FontPackPhase { missing, downloading, stored, ready, failed }

class FontPackStatus {
  const FontPackStatus(this.phase, {this.received = 0, this.total = 0, this.error});
  static const missing = FontPackStatus(FontPackPhase.missing);
  static const stored = FontPackStatus(FontPackPhase.stored);
  static const ready = FontPackStatus(FontPackPhase.ready);
  final FontPackPhase phase;
  // 下载中：这个包已收到与总共的字节数（已经在本机、核对通过的文件算作收到）。
  final int received;
  final int total;
  // 下载失败时给用户看的原因。
  final String? error;
  double get progress => total == 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

// 下载一个字体包文件的端口（device 层经自建中转实现）：把文件写到 target（覆盖），onProgress 报这个文件已收到的字节；
// abort 完成时尽快停下并抛 FontPackCancelled。只管传输、超时与响应上限（不超过 file.size），SHA-256 由调用方核对。
abstract interface class FontPackSource {
  Future<void> download(FontPackFile file, String target, {required void Function(int received) onProgress, required Future<void> abort});
}

class FontPackException implements Exception {
  const FontPackException(this.message);
  final String message;
  @override
  String toString() => 'FontPackException: $message';
}

class FontPackCancelled implements Exception {
  const FontPackCancelled();
}
