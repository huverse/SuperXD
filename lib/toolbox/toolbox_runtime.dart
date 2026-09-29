import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/toolbox/download/android_file_publisher.dart';
import 'package:superxd/toolbox/download/background_transfer.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/short_video/bugpk_video_parser.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_store.dart';
import 'package:superxd/domain/campus_log.dart';

class ToolboxRuntime with WidgetsBindingObserver {
  ToolboxRuntime({this.resourceSpecifications = const {}})
    : coordinator = ParseCoordinator([BugpkVideoParser()]);
  ToolboxRuntime.testing({
    required ToolboxStore store,
    required ToolboxDownloadManager downloads,
    required ParseProvider parser,
  }) : coordinator = ParseCoordinator([parser]),
       resourceSpecifications = downloads.resources.specifications {
    _store = store;
    _downloads = downloads;
    _initialization = SynchronousFuture<void>(null);
  }
  final Map<String, ToolboxResource> resourceSpecifications;
  final ParseCoordinator coordinator;
  ToolboxStore? _store;
  ToolboxDownloadManager? _downloads;
  Future<void>? _initialization;
  ToolboxStore get store => _store!;
  ToolboxDownloadManager get downloads => _downloads!;
  bool get initialized => _downloads != null;

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
  }
}
