import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:superxd/app_background_sync.dart';
import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/app_lifecycle.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/device/background_sync.dart';
import 'package:superxd/device/ble_nearby_radio.dart';
import 'package:superxd/device/backup_exclusion.dart';
import 'package:superxd/device/campus_notifications.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/device/app_shortcuts.dart';
import 'package:superxd/device/home_widget_publisher.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/device/picture_export.dart';
import 'package:superxd/device/relay_font_pack_source.dart';
import 'package:superxd/device/sync_notifications.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/local/font_packs.dart';
import 'package:superxd/local/network_mode_memory.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/local/painting_library.dart';
import 'package:superxd/page/painting_splash.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/social/nearby_service.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_spaces.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_glass_probe.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/third_party_licenses.dart';

// 启动（组合根）：服务的造法在 app_services.dart，各时机的接线在 app_lifecycle.dart，应用外壳在 app_shell.dart。
// 互不依赖的本机文件与系统调用同时发出、一起等（[人工决策-2026-11-16 17:26:21] 启动并行，用户选定架构推荐方案）；用 Future.wait 等，出错时原样带出那一个的堆栈。
void main() async {
  final launch = Stopwatch()..start();
  // 日志出口注入debugPrint，Android上才进入logcat，见campus_log.dart。
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  // 致命错误也记进分批更新的健康回报（人工决策见 domain/app_health.dart）：健康记录打开前先放进缓冲，打开后补记、之后直接记。
  final fatalBefore = <DateTime>[];
  void Function(DateTime at) markFatal = fatalBefore.add;
  // 没被接住的异步错误（火忘式调用漏了 catch）也带堆栈走 campusLog，不只由引擎打到控制台。
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    campusLog('[App] action=uncaught errorType=${error.runtimeType}\n$stack');
    markFatal(DateTime.now());
    return true;
  };
  // 框架报的错（构建、布局、绘制）同样带堆栈走 campusLog、进本机错误记录；控制台照旧打印详情。
  FlutterError.onError = (details) {
    campusLog('[App] action=flutter_error errorType=${details.exception.runtimeType}\n${details.stack ?? StackTrace.current}');
    markFatal(DateTime.now());
    FlutterError.presentError(details);
  };
  // 本机诊断日志（见 local/diagnostic_log.dart）：尽早接上，之后的 campusLog 同时进 logcat 与文件；应用专属外部目录取不到时退回应用支持目录。
  // iOS 没有应用专属外部目录：日志与开发者设置放进只属于这台设备的 device_only（启动后排除出备份，见下面的 excludeFromBackup）。
  final support = await getApplicationSupportDirectory();
  // iOS 上 sqflite 默认把库放在 Documents，那里开放给「文件」App 放导出的文件（会话 Cookie 在账号库里，不能露出去）：库改放应用支持目录的 databases。
  if (Platform.isIOS) await databaseFactory.setDatabasesPath(path.join(support.path, 'databases'));
  final deviceOnly = Platform.isIOS ? Directory(path.join(support.path, 'device_only')) : support;
  final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
  final temporary = await getTemporaryDirectory();
  // 诊断包上传走同一个自建中转（人工决策见 domain/diagnostic_upload.dart）；没配中转时为空，开发者选项里不出现上传。
  // 登录着应用账号时传完紧接着认领到账号下（application/account_diagnostics.dart 包一层）；应用账号在后面才建好，认领只在用户点了上传以后才读它。
  late final AppAccounts? appAccounts;
  // 联网偏好（人工决策见 domain/network_policy.dart 的 11-16 22:24:59 那条）在下面第一批里打开；诊断包认领只在用户点了上传以后才读它。
  late final NetworkPreference network;
  bool networkOnline() => network.online;
  // 自建中转：地址与签名请求的传输只建一份，下面各个造法共用（没配中转时为空，见 app_services.dart 的 RelayWiring）；
  // 签名请求的出口策略按联网偏好拒掉仅本机时不许的服务，发请求时才问它（那时联网偏好早已打开）。
  final relay = relayWiring(allows: (service) => network.allows(service));
  final diagnostics = diagnosticsOf(relay, () => appAccounts, online: networkOnline);
  final logs = await DiagnosticLog.open(
    directory: Directory(path.join((external ?? deviceOnly).path, 'logs')),
    exports: Directory(path.join(temporary.path, 'diagnostics_export')),
    publish: publishDiagnosticArchive,
    uploader: diagnostics,
  );
  campusLog = logs.tee(debugPrint);

  // 第一批：互不依赖的本机文件与系统调用同时发出。
  // 开屏画作（人工决策见 page/painting_splash.dart）：按清单顺序取这次的一幅，取到就马上开始解码，开屏第一帧多半就有图；
  // 从快捷入口冷启动则跳过开屏画作直达（人工决策见 toolbox/express/express_page.dart 的 _openIdentity），这次也不轮换画作。
  final shortcuts = ChannelAppShortcuts();
  final paintingsOpen = PaintingLibrary.open(
    bundle: rootBundle,
    memory: File(path.join(support.path, 'splash_painting.json')),
    temporary: Directory(path.join(temporary.path, 'paintings')),
    publish: publishPicture,
  );
  final launchTake = shortcuts.takeLaunch().catchError((Object error, StackTrace stack) {
    campusLog('[Shortcuts] action=take_launch errorType=${error.runtimeType}\n$stack');
    return null;
  });
  final splashOpen = Future.wait([paintingsOpen, launchTake]).then((_) async {
    final launched = await launchTake;
    final painting = launched == null ? (await paintingsOpen).next() : null;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final image = painting == null ? null : paintingSplashImage(painting, view.physicalSize / view.devicePixelRatio, view.devicePixelRatio);
    if (image != null) {
      final stream = image.resolve(ImageConfiguration.empty);
      late final ImageStreamListener decoded;
      decoded = ImageStreamListener((_, _) => stream.removeListener(decoded), onError: (Object error, StackTrace? stack) {
        stream.removeListener(decoded);
        campusLog('[Painting] action=decode errorType=${error.runtimeType}\n$stack');
      });
      stream.addListener(decoded);
    }
    return (launched: launched, painting: painting, image: image);
  });
  final developerOpen = DeveloperSettings.open(File(path.join(deviceOnly.path, 'developer.json')));
  // Android 10–14默认不绘制到导航栏后，透明导航栏会露出原生窗口底色（浅色为白条）；15+系统已强制全面屏。
  final edgeToEdge = SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 接管同一进程里旧引擎遗留的账号库连接、回滚停在中间的事务（人工决策见 local/account_store.dart 的 open）。
  final storeOpen = AccountStore.open(reclaim: true);
  // 衬线等要下载的字体（人工决策见 domain/font_pack.dart）：文件在应用支持目录的 font_packs（排除备份）；选着的在显示设置打开时（首帧前）核对并注册，
  // 升级上来还没下的等同意协议与政策之后自动下回来（见下面 ensureFontPack）；没配中转时下不了。
  final fontPacks = FontPackLibrary(directory: Directory(path.join(support.path, 'font_packs')), source: switch (relay) {
    final relay? => RelayFontPackSource(relay.base),
    null => null,
  });
  final displayOpen = DisplaySettings.open(wallpaperDirectory: Directory(path.join(support.path, 'display', 'wallpaper')), fontPacks: fontPacks);
  final glassLoad = CampusGlassGuard.load();
  final databasesPath = getDatabasesPath();
  final networkOpen = FileNetworkModeMemory.open(File(path.join(support.path, 'network_mode.json')), legacy: File(path.join(support.path, 'leisure.json')));
  final legalOpen = LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  await Future.wait<Object?>([splashOpen, developerOpen, edgeToEdge, storeOpen, displayOpen, glassLoad, databasesPath, networkOpen, legalOpen]);
  final (:launched, :painting, image: splashImage) = await splashOpen;
  final paintings = await paintingsOpen, developer = await developerOpen, store = await storeOpen, display = await displayOpen;
  final socialDirectory = await databasesPath, legal = await legalOpen;
  network = NetworkPreference(memory: await networkOpen);

  watchDeveloperMode(developer, logs, environment: appEnvironment);
  unawaited(recordExitReasons(marker: File(path.join(support.path, 'last_exit_seen')), read: readExitReasons, onAbnormal: (at) => markFatal(at)));
  final session = AppSession(AccountGateway(store: store, credentials: SecureCredentialStore()));
  // 选壁纸走系统照片选择器：不申请存储权限，只拿到用户选中的那一张（API 36 起插件默认如此，更低版本须显式打开）。
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  // 玻璃显示自检只在安卓上截图（iOS 是系统组件与固定磨砂档），人工决策见 theme/campus_glass_tier.dart 的 11-16 那条。
  if (!campusIos) campusGlassProbe = CampusGlassGuard.probe;
  final reminders = CampusReminders(gateway: session.gateway, port: NotificationReminders());
  final widgetPort = HomeWidgetPublisher();
  final widgets = CampusWidgets(gateway: session.gateway, port: widgetPort);
  // 私信（人工决策见 social/social_service.dart）：每个应用账号一份，库在数据库目录（旧版的 social.db 与 social 文件夹，见 social/social_spaces.dart）；
  // 挂账号用应用账号的设备密钥签名，中转说账号不在了让应用账号马上核一次。
  final social = SocialService(
    spaces: SocialSpaces(vault: const SecureIdentityVault(), directory: socialDirectory),
    accountKeys: relay?.accountKeys ?? const SecureAppAccountVault(),
    transport: relay?.transportFor(NetworkService.social),
    accountGone: () => unawaited(appAccounts?.check(force: true)),
    polling: true,
  );
  // 面对面私信（蓝牙，人工决策见 social/nearby_service.dart）：设备级，身份在私信的安全存储命名空间（nearby 一项），库是 social 文件夹里的 nearby.db（同私信排除备份）；
  // 蓝牙插件只在面对面页打开时才创建，这里只造服务、不碰蓝牙。
  final nearby = NearbyService(radio: BleNearbyRadio(), vault: const SecureIdentityVault(), openStore: () async {
    final folder = Directory(path.join(socialDirectory, SocialSpaces.accountFolder));
    await folder.create(recursive: true);
    return SocialStore.open(path.join(folder.path, 'nearby.db'));
  });
  // iOS 默认把应用数据带进 iCloud 备份与换机迁移：与安卓 data_extraction_rules.xml 排除的同一批（百宝箱、下载记录、字体包、日志与开发者设置、私信库）在这里标记排除；钥匙串见 ios/Runner/DeviceOnlyData.swift。
  if (Platform.isIOS) {
    unawaited(excludeFromBackup(
      folders: [
        for (final folder in ['toolbox', 'backgroundDownloaderTaskRecords', 'backgroundDownloaderResumeData', 'backgroundDownloaderDatabase', 'font_packs']) Directory(path.join(support.path, folder)),
        deviceOnly,
        Directory(path.join(socialDirectory, SocialSpaces.accountFolder)),
      ],
      files: [File(path.join(socialDirectory, SocialSpaces.legacyDatabase))],
    ));
  }
  appAccounts = appAccountsOf(relay, onDeleted: (account) {
    unawaited(social.forgetAccount(account));
    unawaited(nearby.forgetAccount(account.accountId));
  });
  // 仅本机时（联网偏好）解锁只认公开与下架、不联网，灰度与节日抽签不按等级加权、不问点名（11-16 起取代娱乐与积分的开关，见 domain/leisure.dart）。
  final challenges = challengesOf(relay, appAccounts);
  final rollouts = await rolloutsOf(support, relay, appAccounts, challenges, online: networkOnline);
  final unlocks = unlocksOf(relay, rollouts, appAccounts, accountOn: networkOnline);
  final playground = PlaygroundStore.inSupportDirectory();
  // 删除数据清本机的游乐场记录与记着的等级（服务器上的由 Leisure 经挑战与积分先删，仅本机时只删本机）；联网偏好变了、删了数据，解锁都重新判定。
  final leisure = Leisure(deleteRemote: challenges?.deleteData, signedIn: () => network.online && (challenges?.signedIn ?? false), clearLocal: () async {
    await playground.clear();
    await rollouts.forgetLevel();
  });
  if (unlocks != null) {
    leisure.addListener(unlocks.reconsider);
    network.addListener(unlocks.reconsider);
  }
  // 第二批：要等灰度与应用账号造好的几份本机记录同时打开。
  final updatesOpen = appUpdates(support, relay, rollouts), notesOpen = developerNotes(support, relay), festivalsOpen = festivalsOf(support, relay, appAccounts, online: networkOnline);
  await Future.wait<Object?>([updatesOpen, notesOpen, festivalsOpen]);
  final updates = await updatesOpen, notes = await notesOpen, festivals = await festivalsOpen;
  final health = await appHealthOf(support, relay);
  for (final at in fatalBefore) {
    unawaited(health.markFatal(at));
  }
  markFatal = (at) => unawaited(health.markFatal(at));
  // 自动同步（人工决策见 domain/auto_sync.dart）：设备级，经账号门面跟着当前账号；后台任务的入口与时机在 app_background_sync.dart。
  final autoSync = AutoSync(gateway: session.gateway, generation: () => session.generation, scheduler: WorkmanagerSyncScheduler(autoSyncDispatcher), notices: SyncNotifications());
  // 点了同步结果通知进同步记录（人工决策见 domain/sync_record.dart）：冷启动由通知拉起时取一次，开着或在后台时点了经流交来；
  // 都等会话恢复好、先回首页再推入（同快捷入口，见 app_shell.dart 的 _AccountAppState._onShortcut）。
  void openNotification(String? payload) {
    if (payload == syncRecordsPayload) notificationRoute.value = '/academic/records';
  }
  campusNotificationTaps.stream.listen(openNotification);
  unawaited(campusNotificationLaunch().then(openNotification).catchError((Object error, StackTrace stack) => campusLog('[Notifications] action=launch errorType=${error.runtimeType}\n$stack')));
  // 打扰时机（人工决策见 application/app_moments.dart）：上下课的安静期按当前账号本机今天的课算，只读本地。
  final moments = AppMoments(notes: notes, festivals: festivals, autoSync: autoSync, timetable: () => campusTimetableToday(session.gateway, signedIn: session.loggedIn));
  final splashed = painting != null && splashImage != null;
  final splashGone = ValueNotifier(!splashed);
  final restored = Completer<void>();
  final services = AppServices(display: display, reminders: reminders, social: social, nearby: nearby, updates: updates, legal: legal, developer: developer, logs: logs, paintings: paintings, shortcuts: shortcuts, notes: notes, festivals: festivals, appAccounts: appAccounts, diagnostics: diagnostics, challenges: challenges, unlocks: unlocks, playground: playground, leisure: leisure, moments: moments, autoSync: autoSync, health: health, network: network);
  final app = SuperXdApp(session: session, services: services, launch: launched, splashGone: splashGone);
  runApp(splashed ? PaintingSplash(painting: painting, image: splashImage, ready: restored.future, onGone: () => splashGone.value = true, child: app) : app);
  // 首帧上屏：健康回报的启动档按这段时长记（只记档位次数，人工决策见 domain/app_health.dart 的 11-17 那条）。
  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    if (campusDiagnostics) campusLog('[App] action=first_frame ms=${launch.elapsedMilliseconds}');
    return health.markLaunch(launch.elapsed);
  }));
  unawaited(initializeCampusGlass());
  // 低电量（iOS）与省电模式（安卓）时装饰动效停下，先要一次当前状态（见 theme/native_glass.dart 的 nativeLowPower）。
  unawaited(watchNativeLowPower());
  // 各功能在同意协议与政策之后、回到前台时做什么，统一挂在生命周期钩子上（见 app_lifecycle.dart）。
  final hooks = AppHooks(agreed: legal.agreed, policy: network);
  // 私信跟着当前应用账号；打开失败只影响私信（状态 failed），不影响应用。已开启私信的会立即联网收取，所以等用户同意协议与政策之后再打开。
  watchSocial(social, appAccounts, hooks, network: network);
  watchNearby(nearby, appAccounts);
  // 选着字体包而本机没有（升级上来原先就选着衬线的）：同意之后下回来，装好界面就换过去；失败下次启动再试。
  hooks.afterAgreed('FontPacks', display.ensureFontPack, service: NetworkService.fontPack);
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
  restored.complete();
  unawaited(checkLegalNotice(legal));
  watchLocalSchedule(session, hooks, reminders: reminders, widgets: widgets);
  watchWidgetTheme(display, widgetPort);
  if (updates != null) watchAppUpdates(updates, hooks);
  watchMoments(moments, hooks, notes: notes, festivals: festivals, appAccounts: appAccounts);
  watchAutoSync(session, autoSync, hooks);
  if (appAccounts != null) watchAppAccounts(appAccounts, hooks);
  watchRollouts(rollouts, hooks);
  watchAppHealth(health, hooks);
  if (unlocks != null) watchUnlocks(unlocks, hooks);
}
