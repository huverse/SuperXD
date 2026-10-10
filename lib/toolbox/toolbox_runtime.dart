import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/toolbox/download/android_file_publisher.dart';
import 'package:superxd/toolbox/download/background_transfer.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/short_video/bugpk_video_parser.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

// 把作品分享给好友：百宝箱不感知私信，由组合根注入（为空时不显示分享入口）。
typedef ToolboxVideoShare = Future<void> Function(BuildContext context, VideoShare video);

// 扫码：相机页面在 page 层，百宝箱不依赖它，由组合根注入。
// hint 是取景页的提示语，accept 返回非空表示不认这个内容（原地提示），认下就把原文交回来；取消返回空。
typedef ToolboxQrScan = Future<String?> Function(BuildContext context, String hint, String? Function(String raw) accept);

// 取一张图（相册或相机）：取图与缓存副本清理在 page 层，百宝箱不依赖它，由组合根注入。
// 返回压缩后的副本路径与 discard（删掉这次取图留在缓存里的副本），用完必须调用 discard；取消返回空。
typedef ToolboxImagePick = Future<({String path, Future<void> Function() discard})?> Function({
  required ImageSource source,
  required double maxSide,
  required int quality,
});

// 连续扫码：取景页一直开着，每认下一个新码就交给 onCode，until 完成后自动关上；status 是取景页上的进度文字。
// 用户按返回提前关掉时，返回的 Future 完成。
typedef ToolboxQrWatch =
    Future<void> Function(
      BuildContext context, {
      required String hint,
      required String? Function(String raw) accept,
      required void Function(String raw) onCode,
      required Future<void> until,
      required ValueListenable<String?> status,
    });

// 工具注册表：组合根传入（见 toolbox_catalog.dart），框架只按 ToolboxModule 认工具，不认识任何工具的类型。
typedef ToolboxCatalog = List<ToolboxModule> Function(ToolboxRuntime runtime);

class ToolboxRuntime with WidgetsBindingObserver {
  ToolboxRuntime({
    required this.catalog,
    this.resourceSpecifications = const {},
    this.shareVideo,
    this.scanQrCode,
    this.watchQrCode,
    this.pickImage,
    this.relayUrl,
  }) : coordinator = ParseCoordinator([BugpkVideoParser()]);
  ToolboxRuntime.testing({
    required this.catalog,
    required ToolboxStore store,
    required ToolboxDownloadManager downloads,
    required ParseProvider parser,
    this.shareVideo,
    this.scanQrCode,
    this.watchQrCode,
    this.pickImage,
    // 外部已经打开好的服务（测试直接给实例）：runtime 只代为转交，不负责关闭。
    Map<String, ToolboxService>? services,
    // 给了目录时按注册表的 openService 真的打开服务（测清除后重开、打开失败重试）。
    Directory? base,
  }) : coordinator = ParseCoordinator([parser]),
       resourceSpecifications = downloads.resources.specifications,
       relayUrl = null {
    _base = base;
    _external.addAll(services ?? const <String, ToolboxService>{});
    _store = store;
    _downloads = downloads;
    _initialization = SynchronousFuture<void>(null);
  }
  final Map<String, ToolboxResource> resourceSpecifications;
  final ParseCoordinator coordinator;
  final ToolboxVideoShare? shareVideo;
  final ToolboxQrScan? scanQrCode;
  final ToolboxQrWatch? watchQrCode;
  final ToolboxImagePick? pickImage;
  final ToolboxCatalog catalog;
  late final List<ToolboxModule> modules = catalog(this);

  // 自建中转（私信与学习通代签共用）的地址，只从构建参数来；没配时为空，用到它的工具自己退化。
  final Uri? relayUrl;

  // 每个工具自己负责打开、关闭与清除自己的服务：框架只提供目录与公共能力，打开函数登记在注册表，
  // 工具页面首次使用时经 service 取用（打开一次后缓存到应用退出，或清除数据时关掉）。
  final _external = <String, ToolboxService>{};
  final _opened = <String, Future<ToolboxService>>{};
  Directory? _base;
  ToolboxStore? _store;
  ToolboxDownloadManager? _downloads;
  Future<void>? _initialization;
  ToolboxStore get store => _store!;
  ToolboxDownloadManager get downloads => _downloads!;

  Future<ToolboxService> _service(String id) => _opened.putIfAbsent(id, () {
    final opener = modules.where((module) => module.id == id).firstOrNull?.openService;
    if (opener == null) throw const ToolboxException('这个工具的服务还没有配置');
    if (_base == null) throw const ToolboxException('百宝箱还没有准备好，稍后再试');
    // 打开失败不留在缓存里，页面上点「重试」才能真的再打开一次。
    return opener(ToolboxServiceContext(base: _base!, store: store, relayUrl: relayUrl)).catchError((Object error, StackTrace stack) {
      _opened.remove(id);
      Error.throwWithStackTrace(error, stack);
    });
  });

  // 取一个工具的服务：注册表里没登记 openService 或还没初始化完成时抛错。
  // 测试注入的服务同步可得（SynchronousFuture）：await 它不占事件循环一轮，widget 测试里裸 await 普通 Future 会挂死。
  Future<T> service<T extends ToolboxService>(String id) {
    final external = _external[id];
    if (external != null) return SynchronousFuture<T>(external as T);
    return _service(id).then((service) => service as T);
  }

  // 清除一个工具在本机的全部数据：服务自己清库与凭据并关闭，框架再撤掉它的同意记录（按工具 id 记）。
  // 清完从缓存里拿掉，下次打开工具时重新打开一份空的服务。
  Future<void> clearData(String id) async {
    final service = await this.service<ToolboxService>(id);
    _opened.remove(id);
    _external.remove(id);
    await service.clearData();
    await store.revokeConsent(id);
  }

  // [人工决策-2026-09-27 20:12:08] 百宝箱免教务登录，设备级任务独立于账号；不读取教务凭据，切账号不销毁下载。
  Future<void> initialize() => _initialization ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) {
    campusLog(
      '[Toolbox] action=initialize errorType=${error.runtimeType}\n$stack',
    );
    _initialization = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    if (!Platform.isAndroid) throw const ToolboxException('当前版本仅支持 Android 下载');
    final base = Directory(
      path.join((await getApplicationSupportDirectory()).path, 'toolbox'),
    );
    await base.create(recursive: true);
    _base = base;
    final store = await ToolboxStore.open(path.join(base.path, 'toolbox.db'));
    final resources = ToolboxResourceManager(
      directory: Directory(path.join(base.path, 'resources')),
      store: store,
      specifications: resourceSpecifications,
    );
    final directory = Directory(path.join(base.path, 'downloads'));
    final downloads = ToolboxDownloadManager(
      store: store,
      transfer: BackgroundTransfer(directory.path),
      publisher: AndroidFilePublisher(),
      directory: directory,
      resources: resources,
    );
    downloads.foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    try {
      await downloads.initialize();
    } catch (error, stack) {
      await downloads.close();
      await store.close();
      Error.throwWithStackTrace(error, stack);
    }
    _store = store;
    _downloads = downloads;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final manager = _downloads;
    if (manager == null) return;
    manager.foreground = state == AppLifecycleState.resumed;
    if (manager.foreground) {
      manager.resume().catchError((Object error, StackTrace stack) {
        campusLog(
          '[Toolbox] action=resume errorType=${error.runtimeType}\n$stack',
        );
      });
    }
  }

  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    coordinator.close();
    await _downloads?.close();
    await _store?.close();
    // 只关自己打开的服务；外部注入的（测试）由注入方关闭。
    for (final pending in _opened.values) {
      try {
        await (await pending).close();
      } catch (error, stack) {
        campusLog('[Toolbox] action=service_close errorType=${error.runtimeType}\n$stack');
      }
    }
  }
}
