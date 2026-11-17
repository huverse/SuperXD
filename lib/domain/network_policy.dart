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

// [人工决策-2026-11-16 22:24:59] 联网偏好（用户 17:05:21 选定与「娱乐与积分」开关合成一个、放应用账号页，22:24 从完整清单里选定本地化要关的服务）：
// 默认联网化（全部服务）；本地化关掉下面这几项会主动连开发者中转的服务：应用账号、私信经中转、挑战积分与解锁、节日抽奖与红包、健康回报
// （第一轮说过本地化不发，用户追问时确认）。其余照常（开发者的话、灰度、自动检查更新、字体包、教务、学习通、视频解析、快递、地图），
// 用户自己点的操作（手动检查更新、上传诊断包、提交反馈）也不禁止。登录着应用账号时切到本地化保留登录、只是不联网（用户选定），切回联网化接着用；
// 游乐场自由模式照常，不再单独有收起游乐场（取代 domain/leisure.dart 的 11-15 两条开关）。
enum NetworkMode { online, local }

const localModeDenied = {NetworkService.appAccount, NetworkService.social, NetworkService.challenge, NetworkService.unlock, NetworkService.festival, NetworkService.appHealth};

bool networkModeAllows(NetworkMode mode, NetworkService service) => mode == NetworkMode.online || !localModeDenied.contains(service);

// 联网偏好的本机记录（local 实现）：读不到或坏文件当联网化。
abstract interface class NetworkModeMemory {
  NetworkMode get mode;
  Future<void> saveMode(NetworkMode mode);
}
