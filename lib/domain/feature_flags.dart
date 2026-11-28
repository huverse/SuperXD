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

// [人工决策-2026-11-23 22:09:09] 电影院、生活与住理生活全量（用户要求「解禁所有灰度测试功能」，选「配置放到 100%」，没选「代码里删掉开关」）：
// 灰度配置里这三个开关写 100%，代码与 fallback 不动，开关留作远程急停（住理碰真钱与私有接口，出事改配置一小时内关掉）；
// 稳定一两个版本后照上面的规矩删掉这三项、代码里的判断与配置里的同名开关。电影院的解析不在内（用户选「继续关着」，见 cinemaParseFlag）。
// [人工决策-2026-11-27 13:14:15] 照上一条删掉 toolbox.cinema、toolbox.life、toolbox.life.zhuli（用户选「现在删代码」，没选「再等几天数据」：
// 41–44 四个版本全量下没用到急停，用户量小、再等也攒不出能说明问题的数据）。电影院、生活与住理生活从此不经开关、一直显示。
// 私有灰度配置里的三项先留着：44 及以前的版本 fallback 是关，配置里没了就会藏起这三个工具，等它们都低于最低可用版本再删。
// 生活下面以后的子模块碰真钱的，照 11-22 那条仍各自登记开关、先点名给开发者测（框架照旧按 ToolboxModule.flag 判）。

// [人工决策-2026-11-20 22:39:37] 电影院的「解析」（播放页地址交给云解析）先不向用户开放、优化完再说：用户选「开关加规则包」：
// 开关默认关，关着时电影院只有找片、不显示找片与解析的切换，代码留着；规则包第 4 版拿掉解析源，已装 1.0.0-alpha.34 的也解析不了（直链照样能播）。
// 没选「只靠规则包」（没法先点名给自己测）与「直接删代码」（以后要从历史捞回来重接）。重新开放：规则包加回解析源，先点名给自己测再放量。
const cinemaParseFlag = FeatureFlag('toolbox.cinema.parse', fallback: false);

// [人工决策-2026-11-22 18:46:09] 百宝箱的「生活」与它的子模块两层灰度（用户选「两层灰度，先给你测」，没选「生活直接上、子模块灰度」「都直接全量」）：
// 生活的开关 toolbox.life 与每个子模块自己的开关（住理生活是 toolbox.life.zhuli，随子模块登记）都默认关，先在灰度配置里点名给开发者测再放量；
// 子模块会动真钱（充值、买券、洗浴扣费），不随版本直接发给所有人。生活下面一个看得见的子模块都没有时，生活本身也不出现（toolboxVisible）。
// 11-27 这两个开关随全量删掉（见上面 11-27 那条），子模块各自登记开关的规矩不变。

// [人工决策-2026-11-27 23:34:29] 胖乖生活（生活的第二个子模块，碰真钱：洗衣机、吹风机下单付款，饮水机扣水卡）照 11-27 13:14:15 那条的最后一句登记自己的开关：
// 默认关，先在中转点名给开发者测，再看要不要放量（用户 11-27 晚确认照上一轮）。人工决策的其余部分见 toolbox/life/pangguai/pangguai_service.dart 文件头。
const pangguaiFlag = FeatureFlag('toolbox.life.pangguai', fallback: false);

const featureFlags = <FeatureFlag>[cinemaParseFlag, pangguaiFlag];
