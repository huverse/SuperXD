import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/toolbox/short_video/short_video_page.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// [人工决策-2026-09-27 20:12:08] 轻量逻辑随应用发布，只有重型纯资源按需；解析器无大资源，不显示假下载。
List<ToolboxModule> toolboxCatalog(ToolboxRuntime runtime) => [
  ToolboxModule(
    id: 'short_video',
    name: '短视频去水印解析【聚合】',
    icon: CampusIcons.video,
    resource: runtime.resourceSpecifications['short_video'],
    builder: (context) => ShortVideoPage(runtime: runtime),
  ),
];
