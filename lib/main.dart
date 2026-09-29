import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:superxd/app_session.dart';
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
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/third_party_licenses.dart';
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
  final display = await DisplaySettings.open();
  runApp(SuperXdApp(session: session, display: display));
  unawaited(initializeCampusGlass());
  try {
    await session.restore();
  } catch (error, stack) {
    campusLog('[AppSession] action=restore errorType=${error.runtimeType}\n$stack');
  }
}

class SuperXdApp extends StatefulWidget {
  const SuperXdApp({super.key, required this.session, this.display, this.backgroundPhase, this.toolbox});
  final ToolboxRuntime? toolbox;
  final AppSession session;
  final DisplaySettings? display;
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
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, display: widget.display, backgroundPhase: widget.backgroundPhase, toolbox: _toolbox),
    );
  }
}

class _AccountApp extends StatefulWidget {
  const _AccountApp({super.key, required this.session, required this.toolbox, this.display, this.backgroundPhase});
  final ToolboxRuntime toolbox;
  final AppSession session;
  final DisplaySettings? display;
  final double? backgroundPhase;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(gateway: widget.session.gateway, session: widget.session, toolbox: widget.toolbox);
  late final _display = widget.display ?? DisplaySettings.memory();

  @override
  void dispose() {
    _router.dispose();
    if (widget.display == null) _display.dispose();
    super.dispose();
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
        child: AnnotatedRegion<SystemUiOverlayStyle>(value: campusSystemOverlay(CampusPalette.of(context)), child: CampusMotion(child: CampusAtmosphere(phase: widget.backgroundPhase, child: CampusEntryFade(child: LiveClock(child: child!))))),
      )),
    ));
  }
}
