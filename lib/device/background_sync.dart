import 'package:workmanager/workmanager.dart';

import 'package:superxd/domain/auto_sync.dart';

// 自动同步的系统后台任务（人工决策见 domain/auto_sync.dart）：安卓是 WorkManager 周期任务，只在联网时跑；
// iOS 是后台刷新（BGAppRefreshTask），这个标识同时登记在 ios/Runner/Info.plist 与 AppDelegate.swift，时机由系统定。
// 任务到点后跑的是组合根 app_background_sync.dart 的入口（dispatcher），由组合根传进来。
const autoSyncTaskId = 'com.superxd.superxd.autoSync';

class WorkmanagerSyncScheduler implements BackgroundSyncScheduler {
  WorkmanagerSyncScheduler(this.dispatcher);
  final void Function() dispatcher;
  Future<void>? _initialized;

  Future<void> _ready() => _initialized ??= Workmanager().initialize(dispatcher);

  // 同一个任务改间隔时只更新，不重排已经排好的时间（WorkManager 的 UPDATE）。
  @override
  Future<void> schedule(Duration interval, {required Duration delay}) async {
    await _ready();
    await Workmanager().registerPeriodicTask(
      autoSyncTaskId,
      autoSyncTaskId,
      frequency: interval,
      initialDelay: delay,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  @override
  Future<void> cancel() async {
    await _ready();
    await Workmanager().cancelByUniqueName(autoSyncTaskId);
  }
}
