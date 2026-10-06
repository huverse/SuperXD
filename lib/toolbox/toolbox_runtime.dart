import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';
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

// 把作品分享给好友：百宝箱不感知私信，由组合根注入（为空时不显示分享入口）。
typedef ToolboxVideoShare = Future<void> Function(BuildContext context, VideoShare video);

// 扫码：相机页面在 page 层，百宝箱不依赖它，由组合根注入。
// hint 是取景页的提示语，accept 返回非空表示不认这个内容（原地提示），认下就把原文交回来；取消返回空。
typedef ToolboxQrScan = Future<String?> Function(BuildContext context, String hint, String? Function(String raw) accept);

class ToolboxRuntime with WidgetsBindingObserver {
  ToolboxRuntime({
    this.resourceSpecifications = const {},
    this.shareVideo,
    this.scanQrCode,
    ChaoxingAccounts? chaoxing,
    this.chaoxingHub,
  }) : coordinator = ParseCoordinator([BugpkVideoParser()]) {
    _chaoxing = chaoxing;
  }
  ToolboxRuntime.testing({
    required ToolboxStore store,
    required ToolboxDownloadManager downloads,
    required ParseProvider parser,
    this.shareVideo,
    this.scanQrCode,
    ChaoxingAccounts? chaoxing,
    this.chaoxingHub,
  }) : coordinator = ParseCoordinator([parser]),
       resourceSpecifications = downloads.resources.specifications {
    _chaoxing = chaoxing;
    _store = store;
    _downloads = downloads;
    _initialization = SynchronousFuture<void>(null);
  }
  final Map<String, ToolboxResource> resourceSpecifications;
  final ParseCoordinator coordinator;
  final ToolboxVideoShare? shareVideo;
  final ToolboxQrScan? scanQrCode;

  // 代签凭据包的中转，与私信共用同一个自建服务（地址由组合根从构建参数取）；为空时代签码不可用。
  final ChaoxingPackHub? chaoxingHub;
  // 学习通签到的账号闭环，随应用支持目录一起打开；测试可直接注入。
  ChaoxingAccounts? _chaoxing;
  ChaoxingAccounts? get chaoxing => _chaoxing;
  ToolboxStore? _store;
  ToolboxDownloadManager? _downloads;
  Future<void>? _initialization;
  ToolboxStore get store => _store!;
  ToolboxDownloadManager get downloads => _downloads!;

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
    _chaoxing ??= ChaoxingAccounts(
      store: await ChaoxingStore.open(path.join(base.path, 'chaoxing.db')),
      vault: SecureChaoxingVault(),
    );
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
    await _chaoxing?.store.close();
    chaoxingHub?.close();
  }
}
