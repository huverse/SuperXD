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

// [人工决策-2026-11-20 22:39:37] 电影院的「解析」（播放页地址交给云解析）先不向用户开放、优化完再说：用户选「开关加规则包」：
// 开关默认关，关着时电影院只有找片、不显示找片与解析的切换，代码留着；规则包第 4 版拿掉解析源，已装 1.0.0-alpha.34 的也解析不了（直链照样能播）。
// 没选「只靠规则包」（没法先点名给自己测）与「直接删代码」（以后要从历史捞回来重接）。重新开放：规则包加回解析源，先点名给自己测再放量。
const cinemaParseFlag = FeatureFlag('toolbox.cinema.parse', fallback: false);

// [人工决策-2026-11-22 18:46:09] 百宝箱的「生活」与它的子模块两层灰度（用户选「两层灰度，先给你测」，没选「生活直接上、子模块灰度」「都直接全量」）：
// 生活的开关 toolbox.life 与每个子模块自己的开关（住理生活是 toolbox.life.zhuli，随子模块登记）都默认关，先在灰度配置里点名给开发者测再放量；
// 子模块会动真钱（充值、买券、洗浴扣费），不随版本直接发给所有人。生活下面一个看得见的子模块都没有时，生活本身也不出现（toolboxVisible）。
const lifeFlag = FeatureFlag('toolbox.life', fallback: false);

const featureFlags = <FeatureFlag>[cinemaFlag, cinemaParseFlag, lifeFlag];
