// 功能开关登记（[人工决策-2026-11-16 17:05:21] 灰度改「混合判定」，规则见 rollout.dart 文件头）：要灰度的功能、逻辑或界面在这里登记一项，
// 代码只经登记的开关问 Rollouts.isOn 与 Rollouts.param，不散落字符串。id 发出后不改（公共配置与服务器的点名都按它认）；
// fallback 是配置里没写这个开关时的值（新功能一般关，要逐步关停的老功能开）。全量或下线后删掉这一项、代码里的判断与配置里的同名开关。
class FeatureFlag {
  const FeatureFlag(this.id, {required this.fallback});
  final String id;
  final bool fallback;
}

// 页面与百宝箱问开关的端口（application 的 Rollouts 实现，组合根经 AppServices.features 注入）：配置、点名或等级变了 changes 发一次。
abstract interface class FeatureGate {
  bool isOn(FeatureFlag flag);
  Stream<void> get changes;
}

// 百宝箱的电影院（灰度测试，人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头）：开着才显示入口、才能进路由。
const cinemaFlag = FeatureFlag('toolbox.cinema', fallback: false);

const featureFlags = <FeatureFlag>[cinemaFlag];
