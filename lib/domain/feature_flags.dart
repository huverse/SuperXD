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

// [人工决策-2026-11-21 14:20:18] 电影院改用系统原生网络栈的对比试验（11-21 Codex 总交接第 7.7 节，用户说按最佳实践做）：开着时电影院的接口、
// 播放清单与密钥请求改走安卓的 Cronet（Google Play 服务提供，没有 Play 服务的手机建不起来就照旧用 Dart 自带的）或 iOS 的 URLSession，
// 仍经共用内核 CampusHttp（超时、上限、取消与请求记录不变）；开发者模式的诊断带上 client= 好对比。只在试验分支：Cronet 让每个人的安卓包
// 多约 1.5–2MB，默认关、国内多数手机没有 Play 服务，正式接入要先有更快的证据。试验包用构建参数 SUPERXD_NATIVE_HTTP=true 强制打开。
const cinemaNativeHttpFlag = FeatureFlag('toolbox.cinema.native_http', fallback: false);

const featureFlags = <FeatureFlag>[cinemaFlag, cinemaParseFlag, cinemaNativeHttpFlag];
