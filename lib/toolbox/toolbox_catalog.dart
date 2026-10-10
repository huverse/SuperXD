import 'package:superxd/domain/share_card.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
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
    name: '短视频去水印解析【聚合】',
    icon: CampusIcons.video,
    resource: runtime.resourceSpecifications[ShortVideoService.serviceId],
    builder: (context) => ShortVideoPage(runtime: runtime),
    openService: ShortVideoService.open,
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
  ),
];
