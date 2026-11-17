import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/app_diagnostics.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/app_shortcuts.dart';
import 'package:superxd/application/app_moments.dart';
import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/device/picture_export.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/app_update_dialog.dart';
import 'package:superxd/page/developer_notes_page.dart';
import 'package:superxd/page/developer_page.dart';
import 'package:superxd/page/festival/festival_catalog.dart';
import 'package:superxd/page/festival/festival_reward.dart';
import 'package:superxd/page/festival/reward_attachment.dart';
import 'package:superxd/page/festival/festival_stage.dart';
import 'package:superxd/page/image_copy_pick.dart';
import 'package:superxd/page/legal_page.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/page/share_target_sheet.dart';
import 'package:superxd/page/sync_merge_page.dart';
import 'package:superxd/page/text_size_range.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/router.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_probe.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/status_bar_scroll.dart';
import 'package:superxd/theme/wallpaper_tone.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 应用外壳（组合根，从 main.dart 拆出来）：SuperXdApp 按账号代次重建账号应用，账号应用挂路由、打扰时机、协议与更新弹窗、快捷入口与通知的推入。
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

// 点了系统通知要去的页面（同步结果通知进同步记录），由账号应用等会话恢复好再推入；只有组合根写它。
final notificationRoute = ValueNotifier<String?>(null);

class SuperXdApp extends StatefulWidget {
  const SuperXdApp({super.key, required this.session, this.services = const AppServices(), this.backgroundPhase, this.launch, this.splashGone});
  final AppSession session;
  // 组合根造好的设备级服务（见 app_services.dart）。
  final AppServices services;
  // 测试/截图固定装饰相位，不关闭业务转场或图标动画。
  final double? backgroundPhase;
  // 这次冷启动点的快捷入口 id（见 app_shortcuts.dart）。
  final String? launch;
  // 开屏是否走完（打扰时机等它，见 application/app_moments.dart）；为空当作没有开屏。
  final ValueListenable<bool>? splashGone;

  @override
  State<SuperXdApp> createState() => _SuperXdAppState();
}

class _SuperXdAppState extends State<SuperXdApp> {
  late final _playground = widget.services.playground ?? PlaygroundStore.inSupportDirectory();
  late final _toolbox = widget.services.toolbox ?? ToolboxRuntime(
    shareVideo: switch (widget.services.social) {
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
    pinShortcut: widget.services.shortcuts == null || Platform.isIOS ? null : (toolId, shortcutId) => _shortcuts!.pin(toolId, shortcutId),
  );
  late final AppShortcuts? _shortcuts = switch (widget.services.shortcuts) {
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
    if (_shortcuts?.pending.value != null) widget.services.moments?.taskLaunch();
  }

  @override
  void dispose() {
    _shortcuts?.pending.removeListener(_onShortcutLaunch);
    _shortcuts?.dispose();
    if (widget.services.toolbox == null) {
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
      builder: (context, child) => _AccountApp(key: ValueKey(widget.session.generation), session: widget.session, services: widget.services, toolbox: _toolbox, playground: _playground, shortcuts: _shortcuts, splashGone: widget.splashGone, backgroundPhase: widget.backgroundPhase),
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
  const _AccountApp({super.key, required this.session, required this.services, required this.toolbox, required this.playground, this.shortcuts, this.splashGone, this.backgroundPhase});
  final AppSession session;
  final AppServices services;
  final ToolboxRuntime toolbox;
  final PlaygroundStore playground;
  final AppShortcuts? shortcuts;
  final ValueListenable<bool>? splashGone;
  final double? backgroundPhase;

  @override
  State<_AccountApp> createState() => _AccountAppState();
}

class _AccountAppState extends State<_AccountApp> {
  late final _router = buildRouter(session: widget.session, services: widget.services, toolbox: widget.toolbox, playground: widget.playground, splashGone: widget.splashGone, saveRewardPicture: saveRewardPicture, observers: [_MomentObserver(_onMoment)]);
  late final VoidCallback _unwatchRoutes;
  late final _display = widget.services.display ?? DisplaySettings.memory();

  // 协议与政策的更新提示开着时，更新弹窗先等它关掉再弹，不叠两层。
  bool _legalOpen = false;
  late final StreamSubscription<CampusGlassTier> _glassBroken;

  @override
  void initState() {
    super.initState();
    widget.services.updates?.addListener(_promptUpdate);
    widget.services.legal?.addListener(_onLegal);
    widget.shortcuts?.pending.addListener(_onShortcut);
    notificationRoute.addListener(_onShortcut);
    _router.routerDelegate.addListener(_onShortcut);
    _onShortcut();
    _unwatchRoutes = watchRoutes(_router);
    _glassBroken = campusGlassBroken.stream.listen((tier) => unawaited(_onGlassBroken(tier).catchError((Object error, StackTrace stack) => campusLog('[CampusGlass] action=switch_off errorType=${error.runtimeType}\n$stack'))));
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
  late final _momentSources = <Listenable?>[widget.services.moments, _router.routerDelegate, campusOverlayDepth, widget.splashGone, widget.services.legal];
  Timer? _momentTimer;
  bool _momentOpen = false;

  void _onMoment() {
    if (widget.services.moments == null) return;
    _momentTimer?.cancel();
    _momentTimer = Timer(_momentSettle, () => unawaited(_promptMoment()));
  }

  bool get _momentIdle {
    final legal = widget.services.legal, lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted && !_legalOpen && !_momentOpen && campusOverlayDepth.value == 0 && (widget.splashGone?.value ?? true) &&
        (legal == null || legal.agreedRevision != null && !legal.pending) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        _homes.contains(_router.routerDelegate.currentConfiguration.uri.path) && !(_router.routerDelegate.navigatorKey.currentState?.canPop() ?? true);
  }

  Future<void> _promptMoment() async {
    final moments = widget.services.moments;
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
        case SyncConflictMoment(:final held):
          await showHeldScheduleSync(context, autoSync: widget.services.autoSync!, gateway: widget.session.gateway, held: held);
        case NoteLetterMoment(:final note):
          await showDeveloperNoteLetter(context, notes: widget.services.notes!, note: note);
      }
    } finally {
      _momentOpen = false;
    }
  }

  // 节日：边播动画边抽签，抽中的放完动画接着揭晓；动画放完时结果还没回来的最多再等 _drawWait，等不到的抽中了下次回到前台再揭晓。
  // 有抽奖但没登录应用账号（人工决策见 domain/festival.dart）：动画放完提示一句，可以直接去账号页登录，登录后回来补抽；应用账号建立不满规定天数的提示从哪天起能抽。
  static const _drawWait = Duration(seconds: 3);

  Future<void> _celebrate(BuildContext context, FestivalOccasion occasion) async {
    final festivals = widget.services.festivals!;
    final signIn = festivals.needsSignIn(occasion);
    final drawing = festivals.draw(occasion).catchError((Object error, StackTrace stack) {
      campusLog('[Festival] action=draw errorType=${error.runtimeType}\n$stack');
      return null;
    });
    final scene = festivalCatalog.where((item) => item.occasion.id == occasion.id).firstOrNull;
    if (scene != null) await showFestivalCelebration(context, scene);
    if (signIn && context.mounted) {
      final appAccounts = widget.services.appAccounts;
      showCampusToast(context, '登录应用账号就能参加这次抽奖', action: appAccounts == null ? null : '去登录', onAction: appAccounts == null ? null : () => pushAppAccountPage(context, widget.services));
      return;
    }
    final result = await drawing.timeout(_drawWait, onTimeout: () => null);
    if (!context.mounted) return;
    switch (result) {
      case FestivalWon(:final prize):
        await _reveal(context, prize);
      case FestivalTooNew(:final eligibleAt):
        showCampusToast(context, '应用账号${formatCampusRelative(eligibleAt.toIso8601String())}起能参加抽奖');
      default:
        break;
    }
  }

  Future<void> _reveal(BuildContext context, FestivalPrize prize) {
    final festivals = widget.services.festivals!;
    unawaited(festivals.markRevealed(prize));
    return showFestivalReward(context, prize: prize, title: festivals.occasionName(prize.occasion), saveQrCode: saveRewardPicture);
  }

  void _onLegal() => unawaited(_promptLegal());

  // 快捷入口要去的页面（见 app_shortcuts.dart 的 openShortcut）：入口来了、路由变了都看一眼；在这一帧之后做，不在路由的通知里改路由。
  // 快捷入口与点通知要去的页面（notificationRoute）同一种走法：会话恢复好、先回首页再推入；同时有两个时先处理快捷入口。
  void _onShortcut() {
    final shortcuts = widget.shortcuts;
    if (shortcuts?.pending.value == null && notificationRoute.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final home = widget.session.loggedIn ? '/today' : '/login';
      if (shortcuts?.pending.value != null) {
        openShortcut(_router, shortcuts!.pending, home: home);
      } else {
        openShortcut(_router, notificationRoute, home: home);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // 协议与政策：没同意过的先征得同意，同意过的有实质变化后提示一次；同更新弹窗挂在根导航器上。
  // 点「同意」「知道了」才记下，关掉后接着弹被搁下的更新；选了退出应用就什么也不记。
  Future<void> _promptLegal() async {
    final legal = widget.services.legal;
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
    final updates = widget.services.updates;
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (updates == null || context == null || !mounted || _legalOpen) return;
    if (updates.takePrompt() == null) return;
    unawaited(showAppUpdateDialog(context, updates));
  }

  @override
  void dispose() {
    widget.services.updates?.removeListener(_promptUpdate);
    widget.services.legal?.removeListener(_onLegal);
    widget.shortcuts?.pending.removeListener(_onShortcut);
    notificationRoute.removeListener(_onShortcut);
    _router.routerDelegate.removeListener(_onShortcut);
    for (final source in _momentSources) {
      source?.removeListener(_onMoment);
    }
    _momentTimer?.cancel();
    unawaited(_glassBroken.cancel());
    _unwatchRoutes();
    _router.dispose();
    if (widget.services.display == null) _display.dispose();
    super.dispose();
  }

  // 玻璃画坏了（显示自检截到整块近乎纯黑，人工决策见 theme/campus_glass_tier.dart 的 11-16 那条）：这台手机改成关闭并提示，用户可在界面页再改回。
  Future<void> _onGlassBroken(CampusGlassTier tier) async {
    if (_display.glassMode == 'off') return;
    campusLog('[CampusGlass] action=switch_off from=${_display.glassMode} tier=${tier.name}');
    await _display.setGlassMode('off');
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (context != null && context.mounted) showCampusToast(context, '玻璃效果在这台手机上显示异常，已关闭');
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

  // 开发者的话的附件怎么画（人工决策见 domain/developer_note.dart 的附件）：红包交给节日模块的 RewardAttachment，信件页不认识红包。
  late final Map<String, NoteAttachmentBuilder> _noteAttachments = {
    if (widget.services.festivals case final festivals?)
      'reward': (context, attachment) => RewardAttachment(
        festivals: festivals,
        campaign: attachment.ref,
        saveQrCode: saveRewardPicture,
        accountChanges: widget.services.appAccounts,
        onSignIn: widget.services.appAccounts == null ? null : (context) => pushAppAccountPage(context, widget.services),
      ),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: Listenable.merge([_display, campusGlassCapped]), builder: (context, _) => MaterialApp.router(
      title: 'SuperXD', theme: campusTheme(palette: CampusPalette.byId(_display.paletteId), fontFamily: _display.fontFamily),
      darkTheme: campusTheme(palette: CampusPalette.byId(_display.paletteId, brightness: Brightness.dark), fontFamily: _display.fontFamily),
      themeMode: _display.themeMode, routerConfig: _router, scrollBehavior: const CampusScrollBehavior(),
      themeAnimationDuration: WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
      locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // 跟随系统时字号最多到这台手机的推荐上限（[人工决策] 见 local/display_settings.dart 的 textSizeMin），上限由 TextSizeComfort 按页面规则量。
      // 分享弹层在私信没就绪时直达能处理的那一页（见 page/share_target_sheet.dart 的 ShareGuide）：应用账号页（配了中转才有），
      // 消息页（在底栏壳里，没登录教务时进不去，不给）。
      builder: (context, child) => ShareGuide(
        openAccount: widget.services.appAccounts == null ? null : (context) => pushAppAccountPage(context, widget.services),
        openMessages: widget.session.loggedIn ? (context) => _router.go('/message') : null,
        child: NoteAttachmentScope(builders: _noteAttachments, child: DisplayScope(settings: _display, child: TextSizeComfort(builder: (context, comfortable) => CampusTextScale(
        textSize: _display.textSize,
        followLimit: comfortable,
        child: AnnotatedRegion<SystemUiOverlayStyle>(value: campusSystemOverlay(CampusPalette.of(context)), child: NativeAppearanceSync(child: CampusStatusBarScroll(child: CampusGlassScope.wrap(mode: CampusGlassMode.values.byName(_display.glassMode), capped: campusGlassCapped.value, child: CampusMotion(child: CampusAtmosphere(phase: widget.backgroundPhase, wallpaper: _wallpaper(), overlays: campusOverlayDepth, child: CampusEntryFade(child: LiveClock(child: switch ((widget.services.developer, widget.services.logs)) {
        // 开发者模式下浮在所有页面上的开发者工具按钮（见 page/developer_page.dart 的 DeveloperOverlay）；字号状态记录见 app_diagnostics.dart 的 TextSizeWatch。
        (final developer?, final logs?) => TextSizeWatch(developer: developer, logs: logs, display: _display, child: DeveloperOverlay(developer: developer, logs: logs, navigator: _router.routerDelegate.navigatorKey, location: () => _router.routerDelegate.currentConfiguration.uri.path, child: child!)),
        _ => child!,
      })))))))),
      ))))),
    ));
  }
}
