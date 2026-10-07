import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/application/campus_widgets.dart';
import 'package:superxd/device/home_widget_publisher.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/domain/course_widget.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/router.dart';
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
import 'package:superxd/toolbox/chaoxing/chaoxing_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

void main() async {
  // 日志出口注入debugPrint，Android上才进入logcat，见campus_log.dart。
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
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
  final glassCapped = await CampusGlassGuard.capped();
  final reminders = CampusReminders(gateway: session.gateway, port: NotificationReminders());
  final widgetPort = HomeWidgetPublisher();
  final widgets = CampusWidgets(gateway: session.gateway, port: widgetPort);
  final social = SocialService(
    store: await SocialStore.open(path.join(await getDatabasesPath(), 'social.db')),
    vault: SecureIdentityVault(),
    transport: relayTransport(),
    polling: true,
  );
  runApp(SuperXdApp(session: session, display: display, glassCapped: glassCapped, reminders: reminders, social: social));
  unawaited(initializeCampusGlass());
  // 私信是设备级的，与教务会话无关；初始化失败只影响私信（状态 failed），不影响应用。
  unawaited(social.initialize());
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
  watchLocalSchedule(session, reminders: reminders, widgets: widgets);
  watchWidgetTheme(display, widgetPort);
}

// 中转服务地址来自构建参数 SUPERXD_RELAY；未配置或格式不对时私信不可用，不猜默认地址。
RelayTransport? relayTransport() {
  if (relayBaseUrl.isEmpty) return null;
  final uri = Uri.tryParse(relayBaseUrl);
  if (uri == null || !uri.isScheme('http') && !uri.isScheme('https') || uri.host.isEmpty || relayBaseUrl.endsWith('/')) {
    campusLog('[Social] action=config errorType=INVALID_RELAY_URL');
    return null;
  }
  return HttpRelayTransport(relayBaseUrl);
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
  const SuperXdApp({super.key, required this.session, this.display, this.backgroundPhase, this.toolbox, this.glassCapped = false, this.reminders, this.social});
  final CampusReminders? reminders;
  // 设备级私信服务，切换账号不重建；为空时私信入口显示未配置。
  final SocialService? social;
  final ToolboxRuntime? toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final bool glassCapped;
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
    // 学习通签到的服务由它自己的模块打开与关闭（库、安全存储、设备通道、代签中转客户端），
    // 框架只给目录；代签凭据包与私信共用同一个自建中转，地址同样只从构建参数来。
    serviceOpeners: {
      ChaoxingService.serviceId: (base) => ChaoxingService.open(base, relayUrl: relayBaseUrl.isEmpty ? null : Uri.tryParse(relayBaseUrl)),
    },
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
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, display: widget.display, backgroundPhase: widget.backgroundPhase, toolbox: _toolbox, glassCapped: widget.glassCapped, reminders: widget.reminders, social: widget.social),
    );
  }
}

class _AccountApp extends StatefulWidget {
  const _AccountApp({super.key, required this.session, required this.toolbox, required this.glassCapped, this.display, this.backgroundPhase, this.reminders, this.social});
  final CampusReminders? reminders;
  final SocialService? social;
  final ToolboxRuntime toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final double? backgroundPhase;
  final bool glassCapped;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(gateway: widget.session.gateway, session: widget.session, toolbox: widget.toolbox, reminders: widget.reminders, social: widget.social);
  late final _display = widget.display ?? DisplaySettings.memory();

  @override
  void dispose() {
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
    return ListenableBuilder(listenable: _display, builder: (context, _) => MaterialApp.router(
      title: 'SuperXD', theme: campusTheme(palette: CampusPalette.byId(_display.paletteId), fontFamily: _display.fontFamily),
      darkTheme: campusTheme(palette: CampusPalette.byId(_display.paletteId, brightness: Brightness.dark), fontFamily: _display.fontFamily),
      themeMode: _display.themeMode, routerConfig: _router, scrollBehavior: const CampusScrollBehavior(),
      themeAnimationDuration: WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
      locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => DisplayScope(settings: _display, child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: CampusTextScaler(MediaQuery.textScalerOf(context), _display.scale)),
        child: AnnotatedRegion<SystemUiOverlayStyle>(value: campusSystemOverlay(CampusPalette.of(context)), child: CampusGlassScope.wrap(mode: CampusGlassMode.values.byName(_display.glassMode), capped: widget.glassCapped, child: CampusMotion(child: CampusAtmosphere(phase: widget.backgroundPhase, wallpaper: _wallpaper(), child: CampusEntryFade(child: LiveClock(child: child!)))))),
      )),
    ));
  }
}
