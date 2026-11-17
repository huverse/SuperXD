// 联网服务登记表与联网策略（[人工决策-2026-11-16 17:26:21] 组合根统一联网策略入口，用户选定架构推荐方案）：应用里每一项会主动联网的服务登记一项，
// 组合根按策略决定做不做（application 层之上的钩子与工厂都经这里问）；偏向开关的本地化只改策略、不改各服务。
// 新增会联网的服务要先在这里登记；名字发出后不改（以后本机会按它记用户关掉了哪些）。
enum NetworkService {
  // 教务：登录、手动同步课表成绩作息。
  edu,
  // 教务自动同步（含系统后台任务）。
  eduAuto,
  // 应用账号：注册、登录、扫码登录、找回、隔一天核一次账号。
  appAccount,
  // 私信：经中转收发卡片、好友、接管。
  social,
  // 游乐场挑战、积分与等级。
  challenge,
  // 解锁：隐藏服务与新游戏抢先玩。
  unlock,
  // 节日抽奖与红包。
  festival,
  // 开发者的话。
  developerNotes,
  // 灰度配置。
  rollout,
  // 应用内更新：检查与下载安装包。
  appUpdate,
  // 下载的字体包。
  fontPack,
  // 诊断包上传与认领。
  diagnostics,
  // 学习通签到（学习通服务器）。
  chaoxing,
  // 学习通代签凭据包（经中转）。
  chaoxingPack,
  // 视频解析与下载（第三方解析来源与作品所在平台）。
  videoParse,
  // 快递：拼多多身份码与快递查询。
  express,
  // 网页版高德地图（学习通位置签到选点）。
  map,
  // 分批更新的匿名健康回报（每天最多一次，人工决策见 server/src/modules/app_health/app_health_rules.ts）。
  appHealth,
  // 新版本的匿名意见反馈（用户点了提交才发）。
  appFeedback,
}

// 联网策略：这项服务现在能不能联网。
abstract interface class NetworkPolicy {
  bool allows(NetworkService service);
}

// 联网化（默认）：全部服务都能联网。
class OnlineNetworkPolicy implements NetworkPolicy {
  const OnlineNetworkPolicy();
  @override
  bool allows(NetworkService service) => true;
}
