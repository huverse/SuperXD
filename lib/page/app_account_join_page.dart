import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 学号已有应用账号时的授权（人工决策见 application/app_accounts.dart 与 domain/app_account.dart）：新手机出示二维码、登录着的手机扫码批准，
// 或申请找回（等 3 天，账号的手机可以拒绝）。

String _moment(DateTime value) => formatCampusRelative(value.toUtc().toIso8601String());

// 学号已有应用账号：选扫码授权或申请找回；返回 'join'、'recover' 或空（取消）。找回在等着时不再给申请。
Future<String?> chooseAppAccountAuthorization(BuildContext context, AppAccountRecovery? recovery) async {
  final pending = recovery?.state == AppAccountRecoveryState.pending;
  final message = switch (recovery?.state) {
    AppAccountRecoveryState.pending => '已申请找回，${_moment(recovery!.grantAt)}起生效。也可以用已登录的手机扫码授权。',
    // 长文案：找回被拒绝后的说明与去路。
    AppAccountRecoveryState.denied => '找回申请被已登录的手机拒绝了。可以用那台手机扫码授权，或重新申请找回。',
    // 长文案：两台设备同时申请时为安全都不生效，要说明原因与去路。
    AppAccountRecoveryState.conflict => '同时有别的设备在申请找回，为了安全都没有生效。可以用已登录的手机扫码授权，或重新申请。',
    // 长文案：两条去路与找回的等待期都要写明。
    _ => '用已登录的手机扫码授权；手机丢了可以申请找回，3 天后生效，期间已登录的手机可以拒绝。',
  };
  const title = '这个学号已有应用账号';
  if (campusIos) {
    final actions = [const NativeAlertAction('取消', cancel: true), if (!pending) const NativeAlertAction('申请找回'), const NativeAlertAction('扫码授权', preferred: true)];
    final index = await showNativeAlert(title: title, message: message, actions: actions);
    return switch (index == null ? null : actions[index].title) { '扫码授权' => 'join', '申请找回' => 'recover', _ => null };
  }
  if (!context.mounted) return null;
  return showCampusDialog<String>(context: context, builder: (context) => CampusGlassDialog(
    title: const Text(title),
    content: SingleChildScrollView(child: BalancedText(message)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      if (!pending) TextButton(onPressed: () => Navigator.pop(context, 'recover'), child: const Text('申请找回')),
      FilledButton(onPressed: () => Navigator.pop(context, 'join'), child: const Text('扫码授权')),
    ],
  ));
}

// 扫授权二维码的入口可注入（同添加好友的 InviteScanner），测试用假扫码；返回扫到的原文。
typedef JoinScanner = Future<String?> Function(BuildContext context);

Future<String?> scanJoinWithCamera(BuildContext context) => Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => QrScanPage(
  hint: '扫新手机上的授权二维码',
  accept: (value) => AppAccountJoin.parse(value) == null ? '不是应用账号的授权二维码' : null,
)));

// 登录着的手机：扫新手机上的授权二维码，核对 6 位码后批准。
Future<void> approveAppAccountJoin(BuildContext context, AppAccounts appAccounts, {JoinScanner scan = scanJoinWithCamera}) async {
  final raw = await scan(context);
  final parsed = raw == null ? null : AppAccountJoin.parse(raw);
  if (parsed == null || !context.mounted) return;
  final confirmed = await showCampusConfirm(context, title: '授权新设备？', message: '新手机上的核对码是 ${parsed.code} 吗？授权后那台手机登录这个应用账号。', action: '授权');
  if (!confirmed || !context.mounted) return;
  final result = await showCampusWaiting(context, label: '正在授权', operation: () => appAccounts.approveJoin(raw!));
  if (!context.mounted) return;
  switch (result) {
    case AppAccountDone(:final notice?):
      showCampusToast(context, notice);
    case AppAccountError(:final message):
      await showCampusNotice(context, message);
    default:
      break;
  }
}

// 别的设备提交的找回申请：拒绝、同意或以后再说（打扰时机与账号页共用）。拒绝是默认的主操作（不是本人时最该点的）。
Future<void> decideAppAccountRecovery(BuildContext context, AppAccounts appAccounts, AppAccountPendingRecovery recovery) async {
  const title = '有设备在申请找回';
  // 长文案：找回申请的安全提醒，要写明生效时刻与不是本人时怎么做。
  final message = '一台设备用这个学号申请登录应用账号，${_moment(recovery.grantAt)}起生效。不是你本人请拒绝。';
  bool? approve;
  if (campusIos) {
    final index = await showNativeAlert(title: title, message: message, actions: const [NativeAlertAction('以后再说', cancel: true), NativeAlertAction('是我本人'), NativeAlertAction('拒绝', destructive: true, preferred: true)]);
    approve = switch (index) { 1 => true, 2 => false, _ => null };
  } else {
    approve = await showCampusDialog<bool>(context: context, builder: (context) => CampusGlassDialog(
      title: const Text(title),
      content: SingleChildScrollView(child: BalancedText(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('是我本人')),
        FilledButton(style: campusDestructive, onPressed: () => Navigator.pop(context, false), child: const Text('拒绝')),
      ],
    ));
  }
  if (approve == null || !context.mounted) return;
  final decided = approve;
  final result = await showCampusWaiting(context, label: '正在处理', operation: () => appAccounts.decideRecovery(recovery.id, approve: decided));
  if (!context.mounted) return;
  switch (result) {
    case AppAccountDone(:final notice?):
      showCampusToast(context, notice);
    case AppAccountError(:final message):
      await showCampusNotice(context, message);
    default:
      break;
  }
}

// 新手机出示授权二维码（5 分钟有效，可刷新）：每 3 秒问一次批准了没有，批准了返回 true。
// 出示时本页亮度调到最高、离开恢复，同添加好友页（人工决策在 friend_add_page.dart 的 initState）。
class AppAccountJoinPage extends StatefulWidget {
  const AppAccountJoinPage({super.key, required this.appAccounts});
  final AppAccounts appAccounts;

  @override
  State<AppAccountJoinPage> createState() => _AppAccountJoinPageState();
}

class _AppAccountJoinPageState extends State<AppAccountJoinPage> {
  static const _pollGap = Duration(seconds: 3);
  AppAccountJoin? _join;
  QrImage? _qrImage;
  String? _error;
  bool _creating = false;
  Timer? _ticker;
  Timer? _poll;

  int get _remaining => _join == null ? 0 : (_join!.expiresAt.difference(DateTime.now()).inMilliseconds / 1000).ceil();

  @override
  void initState() {
    super.initState();
    // 发起出示会通知应用账号的监听者（账号页那一行），等这一帧建完再发。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_create());
    });
    _brightness(() => ScreenBrightness.instance.setApplicationScreenBrightness(1));
  }

  void _brightness(Future<void> Function() change) => change().catchError((Object error, StackTrace stack) {
    campusLog('[AppAccountJoin] action=brightness errorType=${error.runtimeType}\n$stack');
  });

  @override
  void dispose() {
    _ticker?.cancel();
    _poll?.cancel();
    _brightness(ScreenBrightness.instance.resetApplicationScreenBrightness);
    super.dispose();
  }

  Future<void> _create() async {
    _poll?.cancel();
    setState(() {
      _creating = true;
      _error = null;
    });
    final result = await widget.appAccounts.startJoin();
    if (!mounted) return;
    setState(() {
      _creating = false;
      switch (result) {
        case AppAccountJoinStarted(:final join):
          _join = join;
          _qrImage = QrImage(QrCode.fromData(data: join.payload, errorCorrectLevel: QrErrorCorrectLevel.M));
        case AppAccountError(:final message):
          _error = message;
        default:
          break;
      }
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _schedule();
  }

  // 上一次问完再排下一次，不叠请求；过期了不再问。
  void _schedule() {
    final join = _join;
    if (join == null || _error != null) return;
    _poll = Timer(_pollGap, () async {
      if (!mounted || !identical(join, _join) || _remaining <= 0) return;
      final result = await widget.appAccounts.pollJoin(join);
      if (!mounted || !identical(join, _join)) return;
      switch (result) {
        case AppAccountDone():
          Navigator.pop(context, true);
        case AppAccountError(:final message):
          setState(() => _error = message);
        default:
          _schedule();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    // 二维码固定画在浅色配色上（同好友二维码）：深色模式下反色的二维码不少扫码器认不出。
    final light = CampusPalette.byId(colors.id);
    final join = _join;
    final expired = join != null && _remaining <= 0;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('扫码授权'),
      ),
      body: CampusScrollFade(child: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
        CampusSurface(padding: const EdgeInsets.all(20), child: Column(children: [
          AspectRatio(aspectRatio: 1, child: Container(
            decoration: BoxDecoration(color: light.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: colors.outlineSubtle)),
            padding: const EdgeInsets.all(12),
            child: join == null || _qrImage == null
                ? Center(child: _error == null ? const CampusLoading(label: '正在生成二维码', network: true, remote: '中转服务') : Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: light.danger)))
                : Stack(fit: StackFit.expand, children: [
                    Semantics(
                      label: '应用账号授权二维码',
                      image: true,
                      child: PrettyQrView(
                        qrImage: _qrImage!,
                        decoration: PrettyQrDecoration(shape: PrettyQrSmoothSymbol(color: light.onSurface, roundFactor: .5), quietZone: PrettyQrQuietZone.standard),
                      ),
                    ),
                    if (expired || _error != null) ColoredBox(
                      color: light.surface.withValues(alpha: .94),
                      child: Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error ?? '已失效', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: light.onSurface)))),
                    ),
                  ]),
          )),
          const SizedBox(height: 12),
          if (join != null) Text('核对码 ${join.code}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(join == null || _error != null ? ' ' : expired ? '二维码已失效' : '${_remaining ~/ 60}:${(_remaining % 60).toString().padLeft(2, '0')} 后失效', style: secondary),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: CampusBusyContent(busy: _creating, label: '刷新二维码', busyLabel: '正在生成', icon: const CampusIcon(CampusIcons.sync)),
          ),
        ])),
        const SizedBox(height: 16),
        BalancedText('在已登录的手机上：账号 › 应用账号 › 授权新设备', textAlign: TextAlign.center, style: secondary),
      ]))),
    );
  }
}
