import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

// 把作品分享给好友：百宝箱不感知私信，由组合根注入（为空时不显示分享入口）。
typedef ToolboxVideoShare = Future<void> Function(BuildContext context, VideoShare video);

// 扫码：相机页面在 page 层，百宝箱不依赖它，由组合根注入。
// hint 是取景页的提示语，accept 返回非空表示不认这个内容（原地提示），认下就把原文交回来；取消返回空。
typedef ToolboxQrScan = Future<String?> Function(BuildContext context, String hint, String? Function(String raw) accept);

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

class ToolboxRuntime with WidgetsBindingObserver {
  ToolboxRuntime({
    this.resourceSpecifications = const {},
    this.shareVideo,
    this.scanQrCode,
    this.watchQrCode,
    this.serviceOpeners = const {},
  }) : coordinator = ParseCoordinator([BugpkVideoParser()]);
  ToolboxRuntime.testing({
    required ToolboxStore store,
    required ToolboxDownloadManager downloads,
    required ParseProvider parser,
    this.shareVideo,
    this.scanQrCode,
    this.watchQrCode,
    // 外部已经打开好的服务（测试直接给实例）：runtime 只代为转交，不负责关闭。
    Map<String, ToolboxService>? services,
  }) : coordinator = ParseCoordinator([parser]),
       resourceSpecifications = downloads.resources.specifications,
       serviceOpeners = const {} {
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

  // 每个工具自己负责打开与关闭自己的服务：框架只提供目录与公共能力，打开函数由组合根注入，
  // 工具页面首次使用时经 service 取用（打开一次后缓存到应用退出）。
  final Map<String, Future<ToolboxService> Function(Directory base)> serviceOpeners;
  final _external = <String, ToolboxService>{};
  final _opened = <String, Future<ToolboxService>>{};
  Directory? _base;
  ToolboxStore? _store;
  ToolboxDownloadManager? _downloads;
  Future<void>? _initialization;
  ToolboxStore get store => _store!;
  ToolboxDownloadManager get downloads => _downloads!;

  Future<ToolboxService> _service(String id) => _opened.putIfAbsent(id, () {
    final opener = serviceOpeners[id];
    if (opener == null) throw ToolboxException('这个工具的服务还没有配置');
    if (_base == null) throw const ToolboxException('百宝箱还没有准备好，稍后再试');
    return opener(_base!);
  });

  // 取一个工具的服务：组合根没注册 opener 或还没初始化完成时抛错。
  // 测试注入的服务同步可得（SynchronousFuture）：await 它不占事件循环一轮，widget 测试里裸 await 普通 Future 会挂死。
  Future<T> service<T extends ToolboxService>(String id) {
    final external = _external[id];
    if (external != null) return SynchronousFuture<T>(external as T);
    return _service(id).then((service) => service as T);
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
