import 'package:superxd/domain/share_card.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
import 'package:superxd/toolbox/express/express_page.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/short_video/short_video_service.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// [人工决策-2026-09-27 20:12:08] 轻量逻辑随应用发布，只有重型纯资源按需；解析器无大资源，不显示假下载。
// [人工决策-2026-10-09 20:32:45] 工具只在这一处登记（名称、图标、页面、资源与自己的服务），工具 id 全处统一：
// 路由、服务与同意记录都用同一个 id；增删工具不改组合根。用户选定「收拢」。
List<ToolboxModule> toolboxCatalog(ToolboxRuntime runtime) => [
  ToolboxModule(
    id: ShortVideoService.serviceId,
    name: '视频解析',
    icon: CampusIcons.video,
    resource: runtime.resourceSpecifications[ShortVideoService.serviceId],
    builder: (context) => ShortVideoPage(runtime: runtime),
    openService: ShortVideoService.open,
    clearedData: '下载记录、解析历史、来源设置与来源同意（再用要重新同意）',
    // [人工决策-2026-10-10 16:22:46] 好友分享的卡片经注册表的 openShared 找工具打开，组合根不再直接认识短视频页；用户选定「走注册表」。
    // 好友分享的作品：带着链接直接开始解析（首次使用来源仍先征得本人同意）。
    openShared: (card) => card is VideoShare ? ShortVideoPage(runtime: runtime, initialInput: card.sourceUrl, autoParse: true) : null,
  ),
  ToolboxModule(
    id: ChaoxingService.serviceId,
    name: '学习通签到',
    icon: CampusIcons.success,
    builder: (context) => ChaoxingPage(runtime: runtime),
    openService: ChaoxingService.open,
    clearedData: '学习通账号、密码、收藏位置与设置（再用要重新登录）',
  ),
  // [人工决策-2026-10-19 23:35:59] 新增快递工具（拼多多身份码与快递查询）：用户选定照做并接受公开仓库接入私有接口的风险、
  // 由移交 SDK 源码改造进 lib/toolbox/express（不原样引入）、复用项目已有 http 与 pretty_qr_code 只补 webview_flutter 与 barcode_widget。
  ToolboxModule(
    id: ExpressService.serviceId,
    name: '快递',
    icon: CampusIcons.parcel,
    builder: (context) => ExpressPage(runtime: runtime),
    openService: ExpressService.open,
    clearedData: '拼多多登录会话与来源同意（再用要重新登录并同意）',
    // 取件身份码天天用、要快：长按应用图标或桌面快捷方式直达全屏身份码，返回是快递首页（人工决策见 express_page.dart 的 _openIdentity）。
    shortcuts: [
      ToolboxShortcut(id: ExpressPage.identityShortcut, label: '取件身份码', icon: CampusIcons.qrCode, builder: (context) => ExpressPage(runtime: runtime, openIdentity: true)),
    ],
  ),
];
