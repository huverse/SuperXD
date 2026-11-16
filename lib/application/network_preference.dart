import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';

// 联网偏好 NetworkPreference（设备级，人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）：本身就是联网策略，
// 组合根交给 AppHooks（自动联网的钩子按它做不做）与各功能（私信、挑战、抽奖、解锁、灰度点名、诊断包认领在本地化时不联网）；
// 应用账号页读写；变了通知，组合根跟着让私信停下或接着用、解锁重新判定。不认识具体功能。
class NetworkPreference extends ChangeNotifier implements NetworkPolicy {
  NetworkPreference({required this.memory});
  final NetworkModeMemory memory;

  NetworkMode get mode => memory.mode;
  bool get online => mode == NetworkMode.online;

  @override
  bool allows(NetworkService service) => networkModeAllows(mode, service);

  Future<void> setMode(NetworkMode value) async {
    if (value == mode) return;
    final saving = memory.saveMode(value);
    notifyListeners();
    campusLog('[NetworkMode] action=switch mode=${value.name}');
    await saving;
  }
}
