import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/device/notification_reminders.dart';
import 'package:superxd/gateway/account_gateway.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/credential_store.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/router.dart';
import 'package:superxd/page/live_clock.dart';
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
  runApp(SuperXdApp(session: session, display: display, glassCapped: glassCapped, reminders: reminders));
  unawaited(initializeCampusGlass());
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
  watchReminders(session, reminders);
}

// 课前提醒对账时机：启动恢复会话后、回到前台、切换账号或退出登录、本机课表相关写入后；1秒防抖合并连续写入。
// 对账只读本地数据，失败只记日志，不影响应用。
void watchReminders(AppSession session, CampusReminders reminders) {
  Timer? pending;
  void schedule() {
    pending?.cancel();
    pending = Timer(const Duration(seconds: 1), () {
      reminders.reconcile().then<void>((_) {}).catchError((Object error, StackTrace stack) {
        campusLog('[Reminder] action=reconcile errorType=${error.runtimeType}\n$stack');
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

class SuperXdApp extends StatefulWidget {
  const SuperXdApp({super.key, required this.session, this.display, this.backgroundPhase, this.toolbox, this.glassCapped = false, this.reminders});
  final CampusReminders? reminders;
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
  late final _toolbox = widget.toolbox ?? ToolboxRuntime();
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
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, display: widget.display, backgroundPhase: widget.backgroundPhase, toolbox: _toolbox, glassCapped: widget.glassCapped, reminders: widget.reminders),
    );
  }
}

class _AccountApp extends StatefulWidget {
  const _AccountApp({super.key, required this.session, required this.toolbox, required this.glassCapped, this.display, this.backgroundPhase, this.reminders});
  final CampusReminders? reminders;
  final ToolboxRuntime toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final double? backgroundPhase;
  final bool glassCapped;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(gateway: widget.session.gateway, session: widget.session, toolbox: widget.toolbox, reminders: widget.reminders);
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
    return CampusWallpaper(image: FileImage(file), tone: _tone!.$2, blurLevel: _display.wallpaperBlur, fadeLevel: _display.wallpaperFade);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: _display, builder: (context, _) => MaterialApp.router(
      title: 'SuperXD', theme: campusTheme(palette: CampusPalette.byId(_display.paletteId), fontFamily: _display.fontFamily),
      darkTheme: campusTheme(palette: CampusPalette.byId(_display.paletteId, brightness: Brightness.dark), fontFamily: _display.fontFamily),
      themeMode: _display.themeMode, routerConfig: _router,
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
