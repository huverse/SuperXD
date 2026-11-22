import 'dart:io';

// 安装包体积预算（11-18 性能审查 P2-6：11-11 到 11-15 一周涨了约 2MB 没人看到）：CI 的 Android build 编完开发包后调用，也可手动运行：
//   flutter build apk --profile --flavor production --target-platform android-arm64
//   dart run tool/apk_size_check.dart build/app/outputs/flutter-apk/app-production-profile.apk
// 口径：就是 CI 编的那一份（arm64、profile、开发包、调试签名、不带 dart-define）的文件字节数。发版的 release 分包（去掉调试符号、正式签名）
// 比它小，两者一起涨落，这里只管趋势。预算 apkBudgetBytes = 当时这一份的大小加 apkBudgetSlack 的余量（本机与 CI 的构建差异、依赖补丁版本的正常浮动）。
// 超了就失败：有意变大（新功能、新依赖、新资源）在同一个 PR 里调高 apkBudgetBytes 并在提交信息写明原因；包体变小了顺手调低（只往下拧的棘轮，
// 同 test/code_conventions_test.dart 的字面量个数），比预算小出两倍余量以上时这里提醒一句。
// 11-18 定的初值：本机按上面的命令编出 96,891,642 字节（Flutter 3.47.2，本工作包的包体瘦身之后）加余量。CI 的机器与本机工具链路径不同、
// 未裁剪的原生库里调试信息长短会差一点，余量取 1MB（约 1%）；第一次在 CI 上跑完，以它打印的 bytes 为准校准一次。
// 11-19 电影院接入 media_kit（libmpv）调高：arm64 的 libmpv.so 约 12.4MB；它的原生库按 jar 带全部架构，这份单架构 profile 包里另夹带 armeabi-v7a 与 x86_64 两套约 36.5MB，
// 发版按架构分包时各包只带自己的那套（用户的 arm64 包实际多约 12.5MB）。
// 11-22 住理生活两轮（第一轮的 flutter_svg 与登录、券、订单约 0.92MB，第二轮的洗浴与蓝牙开关水约 0.13MB）调高：基数改成本机编出的 140,679,880 字节。
const apkBudgetBytes = 140679880 + apkBudgetSlack;
const apkBudgetSlack = 1024 * 1024;

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('[ApkSize] failed reason=usage hint="dart run tool/apk_size_check.dart <apk>"');
    exitCode = 2;
    return;
  }
  final apk = File(args.single);
  if (!apk.existsSync()) {
    stderr.writeln('[ApkSize] failed reason=missing_apk path=${args.single}');
    exitCode = 2;
    return;
  }
  final bytes = apk.lengthSync();
  String mb(int value) => (value / 1024 / 1024).toStringAsFixed(2);
  stdout.writeln('[ApkSize] bytes=$bytes mb=${mb(bytes)} budget=$apkBudgetBytes budgetMb=${mb(apkBudgetBytes)}');
  if (bytes > apkBudgetBytes) {
    stderr.writeln('[ApkSize] failed reason=over_budget over=${bytes - apkBudgetBytes} hint="有意变大就在同一个 PR 里调高 tool/apk_size_check.dart 的 apkBudgetBytes 并写明原因"');
    exitCode = 1;
  } else if (apkBudgetBytes - bytes > 2 * apkBudgetSlack) {
    stdout.writeln('[ApkSize] note=shrunk under=${apkBudgetBytes - bytes} hint="包体变小了，可以把 apkBudgetBytes 调低到 ${bytes + apkBudgetSlack}"');
  }
}
