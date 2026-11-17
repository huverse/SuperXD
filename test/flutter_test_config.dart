import 'dart:async';

import 'package:superxd/playground/play_frame.dart';

// test 目录下每个测试文件的入口配置（flutter test 按约定自动套上）。
// 游乐场的「快得不正常不记纪录」（PlaySession 上 11-17 20:13:19 那条）按真实时间算，测试一下子就走完一局，默认关掉；专门测它的用例自己打开。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PlaySession.tooFastGuard = false;
  await testMain();
}
