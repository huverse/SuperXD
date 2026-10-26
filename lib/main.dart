import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/app_shortcuts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/device/app_installer_channel.dart';
import 'package:superxd/device/app_shortcuts.dart';
import 'package:superxd/device/app_package_files.dart';
import 'package:superxd/device/backup_exclusion.dart';
import 'package:superxd/device/diagnostic_device.dart';
import 'package:superxd/device/home_widget_publisher.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/device/picture_export.dart';
import 'package:superxd/device/relay_note_feed.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/device/relay_reward_client.dart';
import 'package:superxd/domain/app_shortcut.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/domain/painting.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_update_memory.dart';
import 'package:superxd/local/developer_note_memory.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/local/festival_memory.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/local/painting_library.dart';
import 'package:superxd/page/app_update_dialog.dart';
import 'package:superxd/page/developer_notes_page.dart';
import 'package:superxd/page/developer_page.dart';
import 'package:superxd/page/festival/festival_catalog.dart';
import 'package:superxd/page/festival/festival_reward.dart';
import 'package:superxd/page/festival/festival_stage.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/router.dart';
import 'package:superxd/page/image_copy_pick.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/page/painting_splash.dart';
import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/page/share_target_sheet.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/status_bar_scroll.dart';
import 'package:superxd/theme/third_party_licenses.dart';
import 'package:superxd/theme/wallpaper_tone.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

void main() async {
  final launch = Stopwatch()..start();
  // 日志出口注入debugPrint，Android上才进入logcat，见campus_log.dart。
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  // 没被接住的异步错误（火忘式调用漏了 catch）也带堆栈走 campusLog，不只由引擎打到控制台。
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    campusLog('[App] action=uncaught errorType=${error.runtimeType}\n$stack');
    return true;
  };
  // 框架报的错（构建、布局、绘制）同样带堆栈走 campusLog、进本机错误记录；控制台照旧打印详情。
  FlutterError.onError = (details) {
    campusLog('[App] action=flutter_error errorType=${details.exception.runtimeType}\n${details.stack ?? StackTrace.current}');
    FlutterError.presentError(details);
  };
  // 本机诊断日志（见 local/diagnostic_log.dart）：尽早接上，之后的 campusLog 同时进 logcat 与文件；应用专属外部目录取不到时退回应用支持目录。
  // iOS 没有应用专属外部目录：日志与开发者设置放进只属于这台设备的 device_only（启动后排除出备份，见下面的 excludeFromBackup）。
  final support = await getApplicationSupportDirectory();
  // iOS 上 sqflite 默认把库放在 Documents，那里开放给「文件」App 放导出的文件（会话 Cookie 在账号库里，不能露出去）：库改放应用支持目录的 databases。
  if (Platform.isIOS) await databaseFactory.setDatabasesPath(path.join(support.path, 'databases'));
  final deviceOnly = Platform.isIOS ? Directory(path.join(support.path, 'device_only')) : support;
  final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
  final logs = await DiagnosticLog.open(
    directory: Directory(path.join((external ?? deviceOnly).path, 'logs')),
    exports: Directory(path.join((await getTemporaryDirectory()).path, 'diagnostics_export')),
    publish: publishDiagnosticArchive,
  );
  campusLog = logs.tee(debugPrint);
  // 开屏画作（人工决策见 page/painting_splash.dart）：按清单顺序取这次的一幅，马上开始解码（和下面几步初始化同时进行），开屏第一帧多半就有图。
  final paintings = await PaintingLibrary.open(
    bundle: rootBundle,
    memory: File(path.join(support.path, 'splash_painting.json')),
    temporary: Directory(path.join((await getTemporaryDirectory()).path, 'paintings')),
    publish: publishPicture,
  );
  // 从快捷入口冷启动：跳过开屏画作直达（人工决策见 toolbox/express/express_page.dart 的 _openIdentity），这次也不轮换画作。
  final shortcuts = ChannelAppShortcuts();
  final launched = await shortcuts.takeLaunch().catchError((Object error, StackTrace stack) {
    campusLog('[Shortcuts] action=take_launch errorType=${error.runtimeType}\n$stack');
    return null;
  });
  final painting = launched == null ? paintings.next() : null;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final splashImage = painting == null ? null : paintingSplashImage(painting, view.physicalSize / view.devicePixelRatio, view.devicePixelRatio);
  if (splashImage != null) {
    final stream = splashImage.resolve(ImageConfiguration.empty);
    late final ImageStreamListener decoded;
    decoded = ImageStreamListener((_, _) => stream.removeListener(decoded), onError: (Object error, StackTrace? stack) {
      stream.removeListener(decoded);
      campusLog('[Painting] action=decode errorType=${error.runtimeType}\n$stack');
    });
    stream.addListener(decoded);
  }
  final developer = await DeveloperSettings.open(File(path.join(deviceOnly.path, 'developer.json')));
  watchDeveloperMode(developer, logs, environment: appEnvironment);
  unawaited(recordExitReasons(marker: File(path.join(support.path, 'last_exit_seen')), read: readExitReasons));
  // Android 10–14默认不绘制到导航栏后，透明导航栏会露出原生窗口底色（浅色为白条）；15+系统已强制全面屏。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  final store = await AccountStore.open();
  final session = AppSession(AccountGateway(store: store, credentials: SecureCredentialStore()));
  final display = await DisplaySettings.open(wallpaperDirectory: Directory(path.join(support.path, 'display', 'wallpaper')));
  // 选壁纸走系统照片选择器：不申请存储权限，只拿到用户选中的那一张（API 36 起插件默认如此，更低版本须显式打开）。
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  await CampusGlassGuard.load();
  final reminders = CampusReminders(gateway: session.gateway, port: NotificationReminders());
  final widgetPort = HomeWidgetPublisher();
  final widgets = CampusWidgets(gateway: session.gateway, port: widgetPort);
  final socialDatabase = path.join(await getDatabasesPath(), 'social.db');
  final social = SocialService(
    store: await SocialStore.open(socialDatabase),
    vault: SecureIdentityVault(),
    transport: relayTransport(),
    polling: true,
  );
  // iOS 默认把应用数据带进 iCloud 备份与换机迁移：与安卓 data_extraction_rules.xml 排除的同一批（百宝箱、下载记录、日志与开发者设置、私信库）在这里标记排除；钥匙串见 ios/Runner/DeviceOnlyData.swift。
  if (Platform.isIOS) {
    unawaited(excludeFromBackup(
      folders: [
        for (final folder in ['toolbox', 'backgroundDownloaderTaskRecords', 'backgroundDownloaderResumeData', 'backgroundDownloaderDatabase']) Directory(path.join(support.path, folder)),
        deviceOnly,
      ],
      files: [File(socialDatabase)],
    ));
  }
  final updates = await appUpdates(support);
  final legal = await LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
  final notes = await developerNotes(support);
  final festivals = await festivalsOf(support);
  // 打扰时机（人工决策见 application/app_moments.dart）：上下课的安静期按当前账号本机今天的课算，只读本地。
  final moments = AppMoments(notes: notes, festivals: festivals, timetable: () => campusTimetableToday(session.gateway, signedIn: session.loggedIn));
  final splashed = painting != null && splashImage != null;
  final splashGone = ValueNotifier(!splashed);
  final restored = Completer<void>();
  final app = SuperXdApp(session: session, display: display, reminders: reminders, social: social, updates: updates, legal: legal, developer: developer, logs: logs, paintings: paintings, shortcuts: shortcuts, launch: launched, notes: notes, festivals: festivals, moments: moments, splashGone: splashGone);
  runApp(splashed ? PaintingSplash(painting: painting, image: splashImage, ready: restored.future, onGone: () => splashGone.value = true, child: app) : app);
  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    if (campusDiagnostics) campusLog('[App] action=first_frame ms=${launch.elapsedMilliseconds}');
  }));
  unawaited(initializeCampusGlass());
  // 私信是设备级的，与教务会话无关；初始化失败只影响私信（状态 failed），不影响应用。已开启私信的会立即联网收取，所以等用户同意协议与政策之后再初始化。
  unawaited(legal.agreed.then((_) => social.initialize()));
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
  restored.complete();
  unawaited(checkLegalNotice(legal));
  watchLocalSchedule(session, reminders: reminders, widgets: widgets);
  watchWidgetTheme(display, widgetPort);
  if (updates != null) watchAppUpdates(updates, agreed: legal.agreed);
  watchMoments(moments, notes: notes, festivals: festivals, agreed: legal.agreed);
}

// 中转服务地址来自构建参数 SUPERXD_RELAY；未配置或格式不对时私信与应用更新都不可用，不猜默认地址。
String? relayBase() {
  if (relayBaseUrl.isEmpty) return null;
  final uri = Uri.tryParse(relayBaseUrl);
  if (uri == null || !uri.isScheme('http') && !uri.isScheme('https') || uri.host.isEmpty || relayBaseUrl.endsWith('/')) {
    campusLog('[Relay] action=config errorType=INVALID_RELAY_URL');
    return null;
  }
  return relayBaseUrl;
}

RelayTransport? relayTransport() => switch (relayBase()) {
  final base? => HttpRelayTransport(base),
  null => null,
};

// 应用内更新走同一个自建中转，渠道就是构建渠道（appFlavor，如 alpha）；没配中转、不是渠道构建（测试）或认不出架构时不检查更新。
Future<AppUpdates?> appUpdates(Directory support) async {
  final base = relayBase(), channel = appFlavor, abi = appAbiName(Abi.current());
  if (base == null || channel == null || abi == null) return null;
  final installed = int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
  if (installed == null) return null;
  return AppUpdates(
    feed: RelayReleaseFeed(base, channel: channel, abi: abi),
    files: CacheAppPackageFiles(),
    installer: ChannelAppInstaller(),
    memory: await FileAppUpdateMemory.open(File(path.join(support.path, 'app_update.json'))),
    installedVersionCode: installed,
    foreground: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
}

// 应用更新：启动先清掉装好后的旧安装包，用户同意协议与政策、首屏稳下来后再自动检查（每个校园日一次，查到由账号应用弹窗）；
// 回到前台时接着做被搁下的安装（去开启了授权，或下载在后台完成）。三者都自己兜住异常，只记日志。
void watchAppUpdates(AppUpdates updates, {required Future<void> agreed}) {
  unawaited(updates.prune());
  AppLifecycleListener(onResume: () => unawaited(updates.resume()));
  unawaited(agreed.then((_) => Future<void>.delayed(appUpdateAutoCheckDelay, updates.autoCheck)));
}

// 开发者的话走同一个自建中转；没配中转时为空，「我的」页不显示这一行。
Future<DeveloperNotes?> developerNotes(Directory support) async {
  final base = relayBase();
  if (base == null) return null;
  return DeveloperNotes(feed: RelayNoteFeed(base), memory: await FileDeveloperNoteMemory.open(File(path.join(support.path, 'developer_notes.json'))));
}

// 节日（人工决策见 domain/festival.dart）：登记在 page/festival/festival_catalog.dart；没配中转时只播动画、不抽签。
Future<Festivals> festivalsOf(Directory support) async => Festivals(
  occasions: [for (final scene in festivalCatalog) scene.occasion],
  memory: await FileFestivalMemory.open(File(path.join(support.path, 'festival.json'))),
  client: switch (relayBase()) {
    final base? => RelayRewardClient(base),
    null => null,
  },
);

// 奖品二维码存进相册（Download/SuperXD），用支付宝扫一扫从相册识别；临时文件放缓存、用完即删。
Future<bool> saveRewardPicture(Uint8List png) async {
  final file = File(path.join((await getTemporaryDirectory()).path, 'festival_reward.png'));
  try {
    await file.writeAsBytes(png, flush: true);
    return await publishPicture(file, 'SuperXD-reward-${DateTime.now().millisecondsSinceEpoch}.png');
  } catch (error, stack) {
    campusLog('[Festival] action=save_qr errorType=${error.runtimeType}\n$stack');
    return false;
  } finally {
    if (await file.exists()) await file.delete();
  }
}

// 开发者的话、节日与打扰时机：同意协议与政策之后拉一次信、补抽上次没连上的签，之后每次回到前台再看一眼（信距上次不到一小时不联网）；
// 启动与回到前台记今天打开过（活跃天数只在本机）；回到前台重新计这一次前台。
void watchMoments(AppMoments moments, {DeveloperNotes? notes, Festivals? festivals, required Future<void> agreed}) {
  var ready = false;
  unawaited(festivals?.recordActive());
  unawaited(agreed.then((_) {
    ready = true;
    unawaited(festivals?.drawPending());
    return notes?.autoRefresh();
  }));
  AppLifecycleListener(onShow: () {
    moments.foreground();
    unawaited(festivals?.recordActive());
    if (!ready) return;
    unawaited(notes?.autoRefresh());
    unawaited(festivals?.drawPending());
  });
}

// 协议与政策的同意与更新提示：会话恢复之后再核对（没同意过的先征得同意，同意过的有实质变化时提示一次）。
// 恢复会换账号代次、下一帧整个账号应用重建，所以先等这一帧过去，不等就弹在要被拆掉的旧应用上、跟着消失。
Future<void> checkLegalNotice(LegalNoticeMemory legal) async {
  await WidgetsBinding.instance.endOfFrame;
  legal.check(legalRevision);
}

// 课前提醒与桌面小组件的对账时机：启动恢复会话后、回到前台、切换账号或退出登录、本机课表相关写入后；1秒防抖合并连续写入。
// 两者都只读本地数据，失败只记日志，不影响应用。
void watchLocalSchedule(AppSession session, {required CampusReminders reminders, required CampusWidgets widgets}) {
  Timer? pending;
  void schedule() {
    pending?.cancel();
    pending = Timer(const Duration(seconds: 1), () {
      reminders.reconcile().then<void>((_) {}).catchError((Object error, StackTrace stack) {
        campusLog('[Reminder] action=reconcile errorType=${error.runtimeType}\n$stack');
      });
      widgets.refresh(signedIn: session.loggedIn).catchError((Object error, StackTrace stack) {
        campusLog('[Widget] action=refresh errorType=${error.runtimeType}\n$stack');
      });
    });
  }

  var generation = session.generation, loggedIn = session.loggedIn;
  session.addListener(() {
    if (session.generation == generation && session.loggedIn == loggedIn) return;
    generation = session.generation;
    loggedIn = session.loggedIn;
    schedule();
  });
  session.gateway.scheduleChanges.addListener(schedule);
  AppLifecycleListener(onResume: schedule);
  schedule();
}

// 小组件衬底不透明度：叠在任意桌面壁纸上，正文与次要文字仍不低于 4.5:1（见 home_widget_test）。
const widgetBackgroundAlpha = .92;

// 小组件配色取当前配色方案的卡片底色与文字色，浅色深色各一套，深浅色跟随“界面”设置。
WidgetTheme widgetThemeOf(DisplaySettings display) {
  WidgetPalette colors(Brightness brightness) {
    final palette = CampusPalette.byId(display.paletteId, brightness: brightness);
    return WidgetPalette(background: palette.surface.withValues(alpha: widgetBackgroundAlpha).toARGB32(), text: palette.onSurface.toARGB32(), secondary: palette.onSurfaceVariant.toARGB32());
  }
  return WidgetTheme(light: colors(Brightness.light), dark: colors(Brightness.dark), mode: display.themeMode.name);
}

// 只在配色或深浅色变化时重发，字号、字体、壁纸等变化不影响小组件。
void watchWidgetTheme(DisplaySettings display, CourseWidgetPort port) {
  String? applied;
  void apply() {
    final signature = '${display.paletteId}|${display.themeMode.name}';
    if (signature == applied) return;
    applied = signature;
    port.applyTheme(widgetThemeOf(display)).catchError((Object error, StackTrace stack) {
      campusLog('[Widget] action=theme errorType=${error.runtimeType}\n$stack');
    });
  }

  display.addListener(apply);
  apply();
}

class SuperXdApp extends StatefulWidget {
  const SuperXdApp({super.key, required this.session, this.display, this.backgroundPhase, this.toolbox, this.reminders, this.social, this.updates, this.legal, this.developer, this.logs, this.paintings, this.shortcuts, this.launch, this.notes, this.festivals, this.moments, this.splashGone});
  // 开发者的话（设备级）；为空时「我的」页不显示这一行。
  final DeveloperNotes? notes;
  // 节日（设备级）；为空时不播节日动画、「我的」页没有节日红包。
  final Festivals? festivals;
  // 打扰时机（设备级，人工决策见 application/app_moments.dart）；为空时节日动画、新信都不出现。splashGone 为开屏是否走完，为空当作没有开屏。
  final AppMoments? moments;
  final ValueListenable<bool>? splashGone;
  // 常用功能的快捷入口（设备级，见 app_shortcuts.dart）；为空时不发布入口、页面不显示「添加到桌面」。launch 是这次冷启动点的入口 id。
  final AppShortcutPort? shortcuts;
  final String? launch;
  final CampusReminders? reminders;
  // 设备级私信服务，切换账号不重建；为空时私信入口显示未配置。
  final SocialService? social;
  // 应用内更新（设备级）；为空时关于页不显示检查更新、也不弹更新。
  final AppUpdates? updates;
  // 协议与政策看过哪一版（设备级）；为空时不做更新提示。
  final LegalNoticeMemory? legal;
  // 开发者模式与本机日志（设备级）；为空时关于页不能开启开发者模式。
  final DeveloperSettings? developer;
  final DiagnosticLog? logs;
  // 开屏画作（设备级）；为空时关于页不显示「开屏画作」。
  final PaintingGallery? paintings;
  final ToolboxRuntime? toolbox;
  final AppSession session;
  final DisplaySettings? display;
  // 测试/截图固定装饰相位，不关闭业务转场或图标动画。
  final double? backgroundPhase;

  @override
  State<SuperXdApp> createState() => _SuperXdAppState();
}

class _SuperXdAppState extends State<SuperXdApp> {
  late final _toolbox = widget.toolbox ?? ToolboxRuntime(
    shareVideo: switch (widget.social) {
      final social? => (context, video) => showShareSheet(context, social: social, card: video),
      null => null,
    },
    // 课堂签到二维码、代签二维码与好友二维码共用扫码页，认不认由调用方给的 accept 决定。
    scanQrCode: (context, hint, accept) => Navigator.of(context).push<String>(
      CampusPageRoute(builder: (_) => QrScanPage(hint: hint, accept: accept)),
    ),
    // 多人连签的二维码签到：取景页一直开着，签完所有人自动关。
    watchQrCode: (context, {required hint, required accept, required onCode, required until, required status}) =>
        Navigator.of(context).push<void>(
          CampusPageRoute(
            builder: (_) => QrScanPage(hint: hint, accept: accept, onCode: onCode, until: until, status: status),
          ),
        ),
    // 人脸与签到照片的取图：与壁纸共用 page 层的取图，缓存副本用完即删。
    pickImage: pickImageCopy,
    // 多人拍照签到从相册一次选多张。
    pickImages: pickImagesCopy,
    // 工具与各自的服务都登记在注册表里；代签凭据包与私信共用同一个自建中转，地址同样只从构建参数来。
    catalog: toolboxCatalog,
    relayUrl: relayBaseUrl.isEmpty ? null : Uri.tryParse(relayBaseUrl),
    // 学习通签到按课表推断正在上的课：默认用当前教务账号本机的课表（只读本地、不联网），百宝箱不依赖教务相关的层。
    campusTimetable: () => campusTimetableToday(widget.session.gateway, signedIn: widget.session.loggedIn),
    // 工具页的「添加到桌面」：入口登记在注册表里，图标与名字由快捷入口接线统一给。
    // iOS 没有「添加到桌面」的接口，不给入口。
    pinShortcut: widget.shortcuts == null || Platform.isIOS ? null : (toolId, shortcutId) => _shortcuts!.pin(toolId, shortcutId),
  );
  late final AppShortcuts? _shortcuts = switch (widget.shortcuts) {
    final port? => AppShortcuts(port: port, tools: _toolbox.modules, pixelRatio: WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio),
    null => null,
  };

  @override
  void initState() {
    super.initState();
    final shortcuts = _shortcuts;
    if (shortcuts == null) return;
    // 从快捷入口进来的这次前台不打扰（见 application/app_moments.dart）。
    shortcuts.pending.addListener(_onShortcutLaunch);
    final launch = widget.launch;
    if (launch != null) shortcuts.open(launch);
    // 图标在首帧之后再画、再发布，不和启动抢主线程。
    WidgetsBinding.instance.addPostFrameCallback((_) => shortcuts.start().catchError((Object error, StackTrace stack) {
      campusLog('[Shortcuts] action=publish errorType=${error.runtimeType}\n$stack');
    }));
  }

  void _onShortcutLaunch() {
    if (_shortcuts?.pending.value != null) widget.moments?.taskLaunch();
  }

  @override
  void dispose() {
    _shortcuts?.pending.removeListener(_onShortcutLaunch);
    _shortcuts?.dispose();
    if (widget.toolbox == null) {
      _toolbox.close().catchError((Object error, StackTrace stack) {
        campusLog('[Toolbox] action=close errorType=${error.runtimeType}\n$stack');
      });
    }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      // [人工决策-2026-09-24 20:40:27] 账号切换成功才替换页面上下文；旧账号路由和内存状态不能带入新账号。
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, display: widget.display, backgroundPhase: widget.backgroundPhase, toolbox: _toolbox, reminders: widget.reminders, social: widget.social, updates: widget.updates, legal: widget.legal, developer: widget.developer, logs: widget.logs, paintings: widget.paintings, shortcuts: _shortcuts, notes: widget.notes, festivals: widget.festivals, moments: widget.moments, splashGone: widget.splashGone),
    );
  }
}

// 根导航器上推入、退出页面（含命令式推入的二级页，路由配置看不到它们）时提醒打扰时机重看一眼。
class _MomentObserver extends NavigatorObserver {
  _MomentObserver(this.changed);
  final VoidCallback changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => changed();
}

class _AccountApp extends StatefulWidget {
  const _AccountApp({super.key, required this.session, required this.toolbox, this.display, this.backgroundPhase, this.reminders, this.social, this.updates, this.legal, this.developer, this.logs, this.paintings, this.shortcuts, this.notes, this.festivals, this.moments, this.splashGone});
  final AppShortcuts? shortcuts;
  final DeveloperNotes? notes;
  final Festivals? festivals;
  final AppMoments? moments;
  final ValueListenable<bool>? splashGone;
  final CampusReminders? reminders;
  final SocialService? social;
  final AppUpdates? updates;
  final LegalNoticeMemory? legal;
  final DeveloperSettings? developer;
  final DiagnosticLog? logs;
  final PaintingGallery? paintings;
  final ToolboxRuntime toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final double? backgroundPhase;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(gateway: widget.session.gateway, session: widget.session, toolbox: widget.toolbox, reminders: widget.reminders, social: widget.social, updates: widget.updates, developer: widget.developer, logs: widget.logs, paintings: widget.paintings, notes: widget.notes, festivals: widget.festivals, saveRewardPicture: saveRewardPicture, observers: [_MomentObserver(_onMoment)]);
  late final VoidCallback _unwatchRoutes;
  late final _display = widget.display ?? DisplaySettings.memory();

  // 协议与政策的更新提示开着时，更新弹窗先等它关掉再弹，不叠两层。
  bool _legalOpen = false;

  @override
  void initState() {
    super.initState();
    widget.updates?.addListener(_promptUpdate);
    widget.legal?.addListener(_onLegal);
    widget.shortcuts?.pending.addListener(_onShortcut);
    _router.routerDelegate.addListener(_onShortcut);
    _onShortcut();
    _unwatchRoutes = watchRoutes(_router);
    for (final source in _momentSources) {
      source?.addListener(_onMoment);
    }
    // 换了账号代次时，上一个账号应用没来得及弹的提示由这里接着弹。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onLegal();
      _promptUpdate();
      _onMoment();
    });
  }

  // 打扰时机的界面条件（业务条件与人工决策见 application/app_moments.dart）：只在首页（底栏四个根页，未登录时是登录页）且上面没有推入别的页面
  // （各页都推在根导航器上）、没有弹窗弹层、协议与政策已同意且没有待弹的提示、开屏走完、应用在前台；这些一有变化就重新计时，
  // 停稳 _momentSettle（转场、弹窗收起都走完）再看。
  static const _homes = {'/today', '/service', '/message', '/mine', '/login'};
  static const _momentSettle = Duration(milliseconds: 900);
  late final _momentSources = <Listenable?>[widget.moments, _router.routerDelegate, campusOverlayDepth, widget.splashGone, widget.legal];
  Timer? _momentTimer;
  bool _momentOpen = false;

  void _onMoment() {
    if (widget.moments == null) return;
    _momentTimer?.cancel();
    _momentTimer = Timer(_momentSettle, () => unawaited(_promptMoment()));
  }

  bool get _momentIdle {
    final legal = widget.legal, lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted && !_legalOpen && !_momentOpen && campusOverlayDepth.value == 0 && (widget.splashGone?.value ?? true) &&
        (legal == null || legal.agreedRevision != null && !legal.pending) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        _homes.contains(_router.routerDelegate.currentConfiguration.uri.path) && !(_router.routerDelegate.navigatorKey.currentState?.canPop() ?? true);
  }

  Future<void> _promptMoment() async {
    final moments = widget.moments;
    if (moments == null || !_momentIdle) return;
    final moment = await moments.next();
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (moment == null || context == null || !context.mounted || !_momentIdle) return;
    moments.begin(moment);
    _momentOpen = true;
    try {
      switch (moment) {
        case CelebrationMoment(:final occasion):
          await _celebrate(context, occasion);
        case RewardMoment(:final prize):
          await _reveal(context, prize);
        case NoteLetterMoment(:final note):
          await showDeveloperNoteLetter(context, notes: widget.notes!, note: note);
      }
    } finally {
      _momentOpen = false;
    }
  }

  // 节日：边播动画边抽签，抽中的放完动画接着揭晓；动画放完时结果还没回来的最多再等 _drawWait，等不到的抽中了下次回到前台再揭晓。
  static const _drawWait = Duration(seconds: 3);

  Future<void> _celebrate(BuildContext context, FestivalOccasion occasion) async {
    final festivals = widget.festivals!;
    final drawing = festivals.draw(occasion).catchError((Object error, StackTrace stack) {
      campusLog('[Festival] action=draw errorType=${error.runtimeType}\n$stack');
      return null;
    });
    final scene = festivalCatalog.where((item) => item.occasion.id == occasion.id).firstOrNull;
    if (scene != null) await showFestivalCelebration(context, scene);
    final result = await drawing.timeout(_drawWait, onTimeout: () => null);
    if (result case FestivalWon(:final prize) when context.mounted) await _reveal(context, prize);
  }

  Future<void> _reveal(BuildContext context, FestivalPrize prize) {
    final festivals = widget.festivals!;
    unawaited(festivals.markRevealed(prize));
    return showFestivalReward(context, prize: prize, title: festivals.occasionName(prize.occasion), saveQrCode: saveRewardPicture);
  }

  void _onLegal() => unawaited(_promptLegal());

  // 快捷入口要去的页面（见 app_shortcuts.dart 的 openShortcut）：入口来了、路由变了都看一眼；在这一帧之后做，不在路由的通知里改路由。
  void _onShortcut() {
    final shortcuts = widget.shortcuts;
    if (shortcuts?.pending.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openShortcut(_router, shortcuts!.pending, home: widget.session.loggedIn ? '/today' : '/login');
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // 协议与政策：没同意过的先征得同意，同意过的有实质变化后提示一次；同更新弹窗挂在根导航器上。
  // 点「同意」「知道了」才记下，关掉后接着弹被搁下的更新；选了退出应用就什么也不记。
  Future<void> _promptLegal() async {
    final legal = widget.legal;
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (legal == null || context == null || !mounted) return;
    final pending = legal.takePending();
    if (pending == null) return;
    _legalOpen = true;
    final accepted = pending.consent ? await askLegalConsent(context) : await showLegalUpdateNotice(context);
    _legalOpen = false;
    if (pending.consent && !accepted) return;
    if (accepted) {
      try {
        await (pending.consent ? legal.markAgreed(pending.revision) : legal.markSeen(pending.revision));
      } catch (error, stack) {
        campusLog('[Legal] action=mark errorType=${error.runtimeType}\n$stack');
      }
    }
    _promptUpdate();
    _onMoment();
  }

  // 自动检查查到新版时弹更新弹窗：挂在根导航器上，登录页与已登录页面都能弹；一个提示只弹一次。
  void _promptUpdate() {
    final updates = widget.updates;
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (updates == null || context == null || !mounted || _legalOpen) return;
    if (updates.takePrompt() == null) return;
    unawaited(showAppUpdateDialog(context, updates));
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_promptUpdate);
    widget.legal?.removeListener(_onLegal);
    widget.shortcuts?.pending.removeListener(_onShortcut);
    _router.routerDelegate.removeListener(_onShortcut);
    for (final source in _momentSources) {
      source?.removeListener(_onMoment);
    }
    _momentTimer?.cancel();
    _unwatchRoutes();
    _router.dispose();
    if (widget.display == null) _display.dispose();
    super.dispose();
  }

  // 色调网格缺失或损坏时按未设置壁纸处理，回到云雾；同一份网格只解码一次。
  (String, WallpaperTone)? _tone;
  CampusWallpaper? _wallpaper() {
    final file = _display.wallpaperFile, encoded = _display.wallpaperTone;
    if (file == null || encoded == null) return null;
    if (_tone?.$1 != encoded) {
      final tone = WallpaperTone.decode(encoded);
      if (tone == null) return null;
      _tone = (encoded, tone);
    }
    return CampusWallpaper(image: FileImage(file), tone: _tone!.$2, look: _display.wallpaperLook);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: Listenable.merge([_display, campusGlassCapped]), builder: (context, _) => MaterialApp.router(
      title: 'SuperXD', theme: campusTheme(palette: CampusPalette.byId(_display.paletteId), fontFamily: _display.fontFamily),
      darkTheme: campusTheme(palette: CampusPalette.byId(_display.paletteId, brightness: Brightness.dark), fontFamily: _display.fontFamily),
      themeMode: _display.themeMode, routerConfig: _router, scrollBehavior: const CampusScrollBehavior(),
      themeAnimationDuration: WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
      locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => DisplayScope(settings: _display, child: CampusTextScale(
        multiplier: _display.scale,
        child: AnnotatedRegion<SystemUiOverlayStyle>(value: campusSystemOverlay(CampusPalette.of(context)), child: NativeAppearanceSync(child: CampusStatusBarScroll(child: CampusGlassScope.wrap(mode: CampusGlassMode.values.byName(_display.glassMode), capped: campusGlassCapped.value, child: CampusMotion(child: CampusAtmosphere(phase: widget.backgroundPhase, wallpaper: _wallpaper(), overlays: campusOverlayDepth, child: CampusEntryFade(child: LiveClock(child: switch ((widget.developer, widget.logs)) {
        // 开发者模式下浮在所有页面上的开发者工具按钮（见 page/developer_page.dart 的 DeveloperOverlay）。
        (final developer?, final logs?) => DeveloperOverlay(developer: developer, logs: logs, navigator: _router.routerDelegate.navigatorKey, location: () => _router.routerDelegate.currentConfiguration.uri.path, child: child!),
        _ => child!,
      })))))))),
      )),
    ));
  }
}
