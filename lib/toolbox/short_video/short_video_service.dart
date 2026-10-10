import 'package:path/path.dart' as path;

import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/short_video/bugpk_video_parser.dart';
import 'package:superxd/toolbox/short_video/media_resource.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/short_video_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

// [人工决策-2026-10-10 16:22:46] 短视频与学习通同构：解析来源、偏好与历史都归它自己（独立库 short_video.db，从框架库一次性迁移），
// 框架不再替它组装解析器；用户选定「服务化，数据迁独立库」。
// 短视频的服务：自己组装解析来源（现在只有 BugPK）、打开自己的库（偏好与解析历史），经框架的下载管理下载、
// 经框架库记各来源的同意。框架（ToolboxRuntime）不认识这里的任何类型。
class ShortVideoService implements ToolboxService {
  ShortVideoService({required this.coordinator, required this.store, required this.downloads, required this.consents});
  final ParseCoordinator coordinator;
  final ShortVideoStore store;
  final ToolboxDownloadManager downloads;
  // 框架库：各解析来源的同意按来源 id 记在这里（同意是框架的公共能力）。
  final ToolboxStore consents;

  // 工具 id：路由、服务与下载记录共用。
  static const serviceId = 'short_video';

  // 下载记录里本工具的附加信息：作品链接与解析来源，「重新解析」按它重开（键名与通用化之前的记录一致）。
  static const originSourceUrl = 'sourceUrl';
  static const originProviderId = 'providerId';

  static Future<ShortVideoService> open(ToolboxServiceContext context) async => ShortVideoService(
    coordinator: ParseCoordinator([BugpkVideoParser()]),
    store: await ShortVideoStore.open(path.join(context.base.path, 'short_video.db'), legacy: context.store),
    downloads: context.downloads,
    consents: context.store,
  );

  // 把解析结果里选中的媒体交给下载管理：同一作品（identity）的同一项不重复下。
  Future<List<String>> download(ParseResult result, List<MediaResource> media) => downloads.enqueue(
    toolId: serviceId,
    title: result.title,
    identity: result.identity,
    origin: {originSourceUrl: result.sourceUrl.toString(), originProviderId: result.providerId},
    items: [
      for (final item in media)
        ToolboxDownloadRequest(
          id: item.id,
          url: item.url,
          kind: switch (item.kind) {
            MediaKind.video => ToolboxDownloadKind.video,
            MediaKind.image => ToolboxDownloadKind.image,
            MediaKind.audio => ToolboxDownloadKind.audio,
          },
        ),
    ],
  );

  List<ToolboxDownload> get downloadTasks => downloads.forTool(serviceId);

  @override
  Future<void> close() async {
    coordinator.close();
    await store.close();
  }

  // [人工决策-2026-10-10 16:22:46] 清除数据：取消进行中的下载、删掉本工具的下载记录与临时文件、偏好与解析历史，
  // 撤掉各解析来源的同意（再用要重新同意）；已导出到相册与下载目录的文件归用户，不动。用户选定「全清本机记录」。
  @override
  Future<void> clearData() async {
    await downloads.clearTool(serviceId);
    for (final id in coordinator.providers.keys) {
      await consents.revokeConsent(id);
    }
    coordinator.close();
    await store.destroy();
  }
}
