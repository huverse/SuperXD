import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// [人工决策-2026-09-27 20:12:08] 轻量逻辑随应用发布，只有重型纯资源按需；解析器无大资源，不显示假下载。
// [人工决策-2026-10-09 20:32:45] 工具只在这一处登记（名称、图标、页面、资源与自己的服务），工具 id 全处统一：
// 路由、服务与同意记录都用同一个 id；增删工具不改组合根。用户选定「收拢」。
List<ToolboxModule> toolboxCatalog(ToolboxRuntime runtime) => [
  ToolboxModule(
    id: 'short_video',
    name: '短视频去水印解析【聚合】',
    icon: CampusIcons.video,
    resource: runtime.resourceSpecifications['short_video'],
    builder: (context) => ShortVideoPage(runtime: runtime),
  ),
  ToolboxModule(
    id: ChaoxingService.serviceId,
    name: '学习通签到',
    icon: CampusIcons.success,
    builder: (context) => ChaoxingPage(runtime: runtime),
    openService: ChaoxingService.open,
  ),
];
