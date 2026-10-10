import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/local/display_settings.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/download/android_file_publisher.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/download/background_transfer.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_resource_manager.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_store.dart';
import 'package:superxd/domain/campus_log.dart';

// 验证入口的下载记录单独归一个工具 id，不混进短视频的下载管理。
const _verifyTool = 'verify_toolbox';

// 仅手动运行的Android合成视频验证入口，不进入正式main或CI；不连接教务或第三方解析。
// 主机端使用本地fixture_server.py监听8765，adb reverse tcp:8765 tcp:8765。
Future<void> main() async {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  final root = Directory(
    path.join((await getApplicationSupportDirectory()).path, 'toolbox'),
  );
  await root.create(recursive: true);
  final directory = Directory(path.join(root.path, 'downloads', 'verify'));
  final store = await ToolboxStore.open(path.join(root.path, 'verify.db'));
  final transfer = _LocalTransfer(BackgroundTransfer(directory.path));
  final resources = ToolboxResourceManager(
    directory: Directory(path.join(root.path, 'verify_resources')),
    store: store,
    specifications: const {},
  );
  final manager = ToolboxDownloadManager(
    store: store,
    transfer: transfer,
    publisher: AndroidFilePublisher(),
    directory: directory,
    resources: resources,
  );
  await manager.initialize();
  final runtime = ToolboxRuntime.testing(
    catalog: toolboxCatalog,
    store: store,
    downloads: manager,
  );
  WidgetsBinding.instance.addObserver(runtime);
  final display = await DisplaySettings.open();
  runApp(
    MaterialApp(
      theme: campusTheme(
        palette: CampusPalette.byId(display.paletteId),
        fontFamily: display.fontFamily,
      ),
      darkTheme: campusTheme(
        palette: CampusPalette.byId(
          display.paletteId,
          brightness: Brightness.dark,
        ),
        fontFamily: display.fontFamily,
      ),
      themeMode: display.themeMode,
      home: _VerifyPage(runtime),
    ),
  );
}

class _VerifyPage extends StatelessWidget {
  const _VerifyPage(this.runtime);
  final ToolboxRuntime runtime;
  ToolboxDownloadManager get manager => runtime.downloads;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('合成视频验证')),
    body: ListenableBuilder(
      listenable: manager,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FilledButton(
            onPressed: () async {
              try {
                final id = await manager.enqueue(
                  toolId: _verifyTool,
                  title: '本机合成视频',
                  identity: 'synthetic',
                  items: [ToolboxDownloadRequest(id: 'video', url: Uri.parse('https://example.com/synthetic.mp4'), kind: ToolboxDownloadKind.video)],
                );
                debugPrint('[VerifyToolbox] task=$id');
              } catch (error, stack) {
                debugPrint('[VerifyToolbox] error=$error\n$stack');
              }
            },
            child: const Text('下载合成视频'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await manager.enqueue(
                  toolId: _verifyTool,
                  title: '本机合成图集',
                  identity: 'synthetic_images',
                  items: List.generate(
                    3,
                    (index) => ToolboxDownloadRequest(id: 'image_$index', url: Uri.parse('https://example.com/synthetic.png'), kind: ToolboxDownloadKind.image),
                  ),
                );
              } catch (error, stack) {
                debugPrint('[VerifyToolbox] error=$error\n$stack');
              }
            },
            child: const Text('下载合成图集'),
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              CampusPageRoute<ToolboxDownload>(
                builder: (_) => DownloadsPage(runtime: runtime, toolId: _verifyTool),
              ),
            ),
            child: const Text('下载管理'),
          ),
          for (final task in manager.forTool(_verifyTool))
            ListTile(
              title: Text(task.state.name),
              subtitle: Text(
                '${task.id}\n${task.error ?? task.savedUri?.toString() ?? task.progress.toString()}',
              ),
              trailing: task.canCancel
                  ? TextButton(
                      onPressed: () => manager.cancel(task.id).catchError((
                        Object error,
                        StackTrace stack,
                      ) {
                        debugPrint('[VerifyToolbox] error=$error\n$stack');
                      }),
                      child: const Text('取消'),
                    )
                  : task.state == ToolboxDownloadState.saved
                  ? TextButton(
                      onPressed: () => manager.open(task.id).catchError((
                        Object error,
                        StackTrace stack,
                      ) {
                        debugPrint('[VerifyToolbox] error=$error\n$stack');
                      }),
                      child: const Text('打开'),
                    )
                  : null,
            ),
        ],
      ),
    ),
  );
}

class _LocalTransfer implements ToolboxTransfer {
  _LocalTransfer(this.inner);
  final BackgroundTransfer inner;
  @override
  Stream<ToolboxTransferUpdate> get updates => inner.updates;
  @override
  Future<void> initialize() => inner.initialize();
  @override
  Future<void> enqueue(ToolboxDownload download) => inner.enqueue(
    ToolboxDownload.fromJson({
      ...download.toJson(),
      'url':
          'http://127.0.0.1:8765/${download.kind == ToolboxDownloadKind.image ? 'synthetic.png' : 'synthetic.mp4'}',
    }),
  );
  @override
  Future<void> cancel(String id) => inner.cancel(id);
  @override
  Future<bool> pause(String id) => inner.pause(id);
  @override
  Future<bool> resume(String id) => inner.resume(id);
  @override
  Future<ToolboxTransferUpdate?> lookup(String id) => inner.lookup(id);
  @override
  Future<void> forget(String id) => inner.forget(id);
  @override
  Future<void> requestNotifications() => inner.requestNotifications();
  @override
  Future<void> close() => inner.close();
}

