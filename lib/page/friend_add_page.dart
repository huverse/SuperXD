import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/qr_scan_page.dart';
import 'package:superxd/page/social_dialogs.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 好友二维码：内容是 Base45（全是字母数字模式字符），按字母数字模式编码并取装得下的最小版本；
// qr 库的 fromData 固定用字节模式，同样内容要大好几个版本。纠错取 M，屏幕反光时也能扫。
QrImage inviteQrImage(String text) {
  for (var version = 1; version <= 40; version++) {
    try {
      return QrImage(QrCode(version, QrErrorCorrectLevel.M)..addAlphaNumeric(text));
    } on InputTooLongException {
      continue;
    }
  }
  throw ArgumentError.value(text.length, 'text', '二维码内容过长');
}

// 扫码页的入口函数可注入，测试用假扫码。
typedef InviteScanner = Future<InviteCode?> Function(BuildContext context);

Future<InviteCode?> scanInviteWithCamera(BuildContext context) async {
  final raw = await Navigator.of(context).push<String>(
    CampusPageRoute(
      builder: (_) => QrScanPage(
        hint: '将好友的二维码放入框内',
        accept: (value) => InviteCode.decode(value) == null ? '不是 SuperXD 好友二维码' : null,
      ),
    ),
  );
  return raw == null ? null : InviteCode.decode(raw);
}

// 添加好友：出示自己的二维码（5 分钟有效，可刷新），或扫对方的二维码。
// 出示期间每 3 秒拉一次信箱，对方一扫就原地提示“已添加”；离开页面即作废二维码。返回新加好友的设备号。
class FriendAddPage extends StatefulWidget {
  const FriendAddPage({super.key, required this.social, this.scan = scanInviteWithCamera});
  final SocialService social;
  final InviteScanner scan;
  @override
  State<FriendAddPage> createState() => _FriendAddPageState();
}

class _FriendAddPageState extends State<FriendAddPage> {
  InviteCode? _code;
  QrImage? _qrImage;
  String? _error;
  bool _creating = false;
  bool _redeeming = false;
  Timer? _ticker;
  // 进入页面时已有的好友；必须在 initState 里取，懒初始化会在新好友到达后才取值而漏报。
  late Set<String> _known;
  final _added = <String>[];

  SocialService get _social => widget.social;
  int get _remaining => _code == null ? 0 : ((_code!.expiresAt - _social.serverNow) / 1000).ceil();

  @override
  void initState() {
    super.initState();
    _known = {for (final friend in _social.friends) friend.deviceId};
    _social.addListener(_detectNew);
    _create();
  }

  @override
  void dispose() {
    _social.removeListener(_detectNew);
    _ticker?.cancel();
    final code = _code;
    if (code != null && _remaining > 0) unawaited(_social.revokeInvite(code.inviteId));
    super.dispose();
  }

  Future<void> _create() async {
    final previous = _code;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final code = await _social.createInvite();
      if (!mounted) {
        unawaited(_social.revokeInvite(code.inviteId));
        return;
      }
      final image = inviteQrImage(code.encode());
      setState(() {
        _code = code;
        _qrImage = image;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } on SocialException catch (error) {
      if (mounted) setState(() => _error = socialErrorText(error.code));
    } catch (error, stack) {
      campusLog('[FriendAdd] action=create errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = socialErrorText(null));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
    if (previous != null) unawaited(_social.revokeInvite(previous.inviteId));
  }

  // 出示期间对方扫码：信箱里的问候被核验后好友列表多出新人，原地提示。
  void _detectNew() {
    final fresh = [for (final friend in _social.friends) if (!_known.contains(friend.deviceId)) friend];
    if (fresh.isEmpty || !mounted) return;
    _known = {for (final friend in _social.friends) friend.deviceId};
    setState(() => _added.addAll(fresh.map((friend) => friend.displayName)));
    showCampusToast(context, '已添加 ${fresh.map((friend) => friend.displayName).join('、')}');
  }

  Future<void> _scan() async {
    final code = await widget.scan(context);
    if (code == null || !mounted) return;
    setState(() => _redeeming = true);
    try {
      final friend = await _social.redeem(code);
      if (mounted) Navigator.pop(context, friend.deviceId);
    } on SocialException catch (error) {
      if (mounted) await showCampusNotice(context, socialErrorText(error.code));
    } catch (error, stack) {
      campusLog('[FriendAdd] action=redeem errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, socialErrorText(null));
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    // 二维码固定画在浅色配色的卡片底与正文色上：深色模式下反色的二维码不少扫码器认不出。
    final light = CampusPalette.byId(colors.id);
    final code = _code;
    final expired = code != null && _remaining <= 0;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('添加好友'),
      ),
      body: CampusScrollFade(child: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
        CampusSurface(padding: const EdgeInsets.all(20), child: Column(children: [
          Text(_social.profile?.nickname ?? '', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          AspectRatio(aspectRatio: 1, child: Container(
            decoration: BoxDecoration(color: light.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: colors.outlineSubtle)),
            padding: const EdgeInsets.all(12),
            child: code == null
                ? Center(child: _error == null ? const CampusLoading(label: '正在生成二维码', network: true, remote: '中转服务') : Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: light.danger)))
                : Stack(fit: StackFit.expand, children: [
                    Semantics(
                      label: '我的好友二维码',
                      image: true,
                      child: PrettyQrView(
                        qrImage: _qrImage!,
                        decoration: PrettyQrDecoration(shape: PrettyQrSmoothSymbol(color: light.onSurface, roundFactor: .5), quietZone: PrettyQrQuietZone.standard),
                      ),
                    ),
                    if (expired) ColoredBox(
                      color: light.surface.withValues(alpha: .94),
                      child: Center(child: Text('已失效', style: TextStyle(fontSize: 16, color: light.onSurface))),
                    ),
                  ]),
          )),
          const SizedBox(height: 12),
          Text(code == null ? ' ' : expired ? '二维码已失效' : '${_remaining ~/ 60}:${(_remaining % 60).toString().padLeft(2, '0')} 后失效', style: secondary),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: CampusBusyContent(busy: _creating, label: '刷新二维码', busyLabel: '正在生成', icon: const CampusIcon(CampusIcons.sync)),
          ),
          if (_added.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text('已添加：${_added.join('、')}', textAlign: TextAlign.center, style: secondary)),
        ])),
        const SizedBox(height: 16),
        Text('同学用 SuperXD 扫这个二维码，即互为好友', textAlign: TextAlign.center, style: secondary),
        const SizedBox(height: 20),
        FilledButton(
          style: campusProminent,
          onPressed: _redeeming ? null : _scan,
          child: CampusBusyContent(busy: _redeeming, label: '扫一扫', busyLabel: '正在添加', icon: const CampusIcon(CampusIcons.scan)),
        ),
      ]))),
    );
  }
}
