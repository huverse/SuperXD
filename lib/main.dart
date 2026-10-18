import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/device/app_installer_channel.dart';
import 'package:superxd/device/app_package_files.dart';
import 'package:superxd/device/home_widget_publisher.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/device/relay_release_feed.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_update_memory.dart';
import 'package:superxd/local/legal_notice_memory.dart';
import 'package:superxd/page/app_update_dialog.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/router.dart';
import 'package:superxd/page/image_copy_pick.dart';
import 'package:superxd/page/live_clock.dart';
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
import 'package:superxd/theme/third_party_licenses.dart';
import 'package:superxd/theme/wallpaper_tone.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

void main() async {
  // 日志出口注入debugPrint，Android上才进入logcat，见campus_log.dart。
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  // 没被接住的异步错误（火忘式调用漏了 catch）也带堆栈走 campusLog，不只由引擎打到控制台。
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    campusLog('[App] action=uncaught errorType=${error.runtimeType}\n$stack');
    return true;
  };
  // Android 10–14默认不绘制到导航栏后，透明导航栏会露出原生窗口底色（浅色为白条）；15+系统已强制全面屏。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  final store = await AccountStore.open();
  final session = AppSession(AccountGateway(store: store, credentials: SecureCredentialStore()));
  final support = await getApplicationSupportDirectory();
  final display = await DisplaySettings.open(wallpaperDirectory: Directory(path.join(support.path, 'display', 'wallpaper')));
  // 选壁纸走系统照片选择器：不申请存储权限，只拿到用户选中的那一张（API 36 起插件默认如此，更低版本须显式打开）。
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  await CampusGlassGuard.load();
  final reminders = CampusReminders(gateway: session.gateway, port: NotificationReminders());
  final widgetPort = HomeWidgetPublisher();
  final widgets = CampusWidgets(gateway: session.gateway, port: widgetPort);
  final social = SocialService(
    store: await SocialStore.open(path.join(await getDatabasesPath(), 'social.db')),
    vault: SecureIdentityVault(),
    transport: relayTransport(),
    polling: true,
  );
  final updates = await appUpdates(support);
  final legal = await LegalNoticeMemory.open(File(path.join(support.path, 'legal_notice.json')));
  runApp(SuperXdApp(session: session, display: display, reminders: reminders, social: social, updates: updates, legal: legal));
  unawaited(initializeCampusGlass());
  // 私信是设备级的，与教务会话无关；初始化失败只影响私信（状态 failed），不影响应用。
  unawaited(social.initialize());
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
  unawaited(checkLegalNotice(legal));
  watchLocalSchedule(session, reminders: reminders, widgets: widgets);
  watchWidgetTheme(display, widgetPort);
  if (updates != null) watchAppUpdates(updates);
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

// 应用更新：启动先清掉装好后的旧安装包，等首屏稳下来再自动检查（每个校园日一次，查到由账号应用弹窗）；
// 回到前台时接着做被搁下的安装（去开启了授权，或下载在后台完成）。三者都自己兜住异常，只记日志。
void watchAppUpdates(AppUpdates updates) {
  unawaited(updates.prune());
  AppLifecycleListener(onResume: () => unawaited(updates.resume()));
  unawaited(Future<void>.delayed(appUpdateAutoCheckDelay, updates.autoCheck));
}

// 协议与政策的更新提示：会话恢复之后再核对；新装与升级按系统记的首次安装、最近更新时刻区分。
// 恢复会换账号代次、下一帧整个账号应用重建，所以先等这一帧过去：安装信息已缓存、立即返回，不等就弹在要被拆掉的旧应用上、跟着消失。
Future<void> checkLegalNotice(LegalNoticeMemory legal) async {
  try {
    final package = await PackageInfo.fromPlatform();
    await WidgetsBinding.instance.endOfFrame;
    await legal.check(legalRevision, freshInstall: package.installTime == package.updateTime);
  } catch (error, stack) {
    campusLog('[Legal] action=check errorType=${error.runtimeType}\n$stack');
  }
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
  const SuperXdApp({super.key, required this.session, this.display, this.backgroundPhase, this.toolbox, this.reminders, this.social, this.updates, this.legal});
  final CampusReminders? reminders;
  // 设备级私信服务，切换账号不重建；为空时私信入口显示未配置。
  final SocialService? social;
  // 应用内更新（设备级）；为空时关于页不显示检查更新、也不弹更新。
  final AppUpdates? updates;
  // 协议与政策看过哪一版（设备级）；为空时不做更新提示。
  final LegalNoticeMemory? legal;
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
  );
  @override
  void dispose() {
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
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, display: widget.display, backgroundPhase: widget.backgroundPhase, toolbox: _toolbox, reminders: widget.reminders, social: widget.social, updates: widget.updates, legal: widget.legal),
    );
  }
}

class _AccountApp extends StatefulWidget {
  const _AccountApp({super.key, required this.session, required this.toolbox, this.display, this.backgroundPhase, this.reminders, this.social, this.updates, this.legal});
  final CampusReminders? reminders;
  final SocialService? social;
  final AppUpdates? updates;
  final LegalNoticeMemory? legal;
  final ToolboxRuntime toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final double? backgroundPhase;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(gateway: widget.session.gateway, session: widget.session, toolbox: widget.toolbox, reminders: widget.reminders, social: widget.social, updates: widget.updates);
  late final _display = widget.display ?? DisplaySettings.memory();

  // 协议与政策的更新提示开着时，更新弹窗先等它关掉再弹，不叠两层。
  bool _legalOpen = false;

  @override
  void initState() {
    super.initState();
    widget.updates?.addListener(_promptUpdate);
    widget.legal?.addListener(_onLegal);
    // 换了账号代次时，上一个账号应用没来得及弹的提示由这里接着弹。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onLegal();
      _promptUpdate();
    });
  }

  void _onLegal() => unawaited(_promptLegal());

  // 协议与政策有实质变化后提示一次：同更新弹窗挂在根导航器上；点「知道了」才记下，关掉后接着弹被搁下的更新。
  Future<void> _promptLegal() async {
    final legal = widget.legal;
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (legal == null || context == null || !mounted) return;
    final revision = legal.takePending();
    if (revision == null) return;
    _legalOpen = true;
    final seen = await showLegalUpdateNotice(context);
    _legalOpen = false;
    if (seen) {
      try {
        await legal.markSeen(revision);
      } catch (error, stack) {
        campusLog('[Legal] action=mark_seen errorType=${error.runtimeType}\n$stack');
      }
    }
    _promptUpdate();
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
      builder: (context, child) => DisplayScope(settings: _display, child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: CampusTextScaler(MediaQuery.textScalerOf(context), _display.scale)),
        child: AnnotatedRegion<SystemUiOverlayStyle>(value: campusSystemOverlay(CampusPalette.of(context)), child: CampusGlassScope.wrap(mode: CampusGlassMode.values.byName(_display.glassMode), capped: campusGlassCapped.value, child: CampusMotion(child: CampusAtmosphere(phase: widget.backgroundPhase, wallpaper: _wallpaper(), child: CampusEntryFade(child: LiveClock(child: child!)))))),
      )),
    ));
  }
}
