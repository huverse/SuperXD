import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

// 出示代签码：二维码里只有一次性取件号与密钥，凭据密文放在自建中转，对方扫走即取即删。
// 可以勾选附带几张人脸照片（只是学习通云盘里的 objectId），对方替你签人脸签到时用；默认不附带。
Future<void> showChaoxingTicketPage(BuildContext context, {required ChaoxingController controller}) =>
    Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ChaoxingTicketPage(controller: controller)));

class ChaoxingTicketPage extends StatefulWidget {
  const ChaoxingTicketPage({super.key, required this.controller, this.now = DateTime.now});
  final ChaoxingController controller;
  // 倒计时用的时钟，测试注入可拨动的时钟。
  final DateTime Function() now;
  @override
  State<ChaoxingTicketPage> createState() => _ChaoxingTicketPageState();
}

class _ChaoxingTicketPageState extends State<ChaoxingTicketPage> {
  // 当前出示的码；换码或离开页面时凭它的口令作废，旧码不再能被取走（轮换即作废，见服务端 revoke 的人工决策）。
  ({String ticket, String pickupId, String? revokeToken})? _issued;
  String? get _ticket => _issued?.ticket;
  String? _error;
  bool _creating = false;
  List<ChaoxingFaceImage> _faces = const [];
  final _attached = <String>{};
  // 当前这张码在本地算的到期时刻（同加好友二维码：倒计时 m:ss，到点盖上「已失效」）。
  DateTime? _expiresAt;
  Timer? _ticker;

  int get _remaining => _expiresAt == null ? 0 : (_expiresAt!.difference(widget.now()).inMilliseconds / 1000).ceil();

  @override
  void initState() {
    super.initState();
    _loadFaces();
    _create();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _revoke(_issued);
    super.dispose();
  }

  // 作废只是收尾：没作废成功（断网等）也不挡界面，码 10 分钟后照样过期。
  void _revoke(({String ticket, String pickupId, String? revokeToken})? issued) {
    if (issued == null) return;
    widget.controller.delegate.revokeTicket(pickupId: issued.pickupId, revokeToken: issued.revokeToken).catchError((Object error, StackTrace stack) {
      campusLog('[Chaoxing] action=ticket_revoke errorType=${error is ChaoxingFailure ? error.code.name : error.runtimeType}\n$stack');
    });
  }

  Future<void> _loadFaces() async {
    final record = widget.controller.current;
    if (record == null) return;
    try {
      final faces = await widget.controller.faces.faceImages(record);
      if (mounted) setState(() => _faces = faces);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=ticket_faces errorType=${failure.runtimeType}\n$stack');
    }
  }

  // 改了附带的照片就重新生成一张码（旧码里的包已经封好，改不了）。
  void _toggleFace(String objectId) {
    setState(() => _attached.contains(objectId) ? _attached.remove(objectId) : _attached.add(objectId));
    _create();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final issuedAt = widget.now();
      final issued = await widget.controller.delegate.createTicket(faceObjectIds: _attached.toList());
      if (!mounted) {
        _revoke(issued);
        return;
      }
      final previous = _issued;
      setState(() {
        _issued = issued;
        _expiresAt = issuedAt.add(chaoxingTicketLifetime);
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        // 到点后不再每秒重画。
        if (_remaining <= 0) _ticker?.cancel();
      });
      _revoke(previous);
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=ticket errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '代签码没生成出来，请稍后重试');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    // 二维码固定画在浅色配色的底上：深色模式下反色的二维码不少扫码器认不出。
    final light = CampusPalette.byId(colors.id);
    final ticket = _ticket;
    final expired = ticket != null && _remaining <= 0;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('出示代签码'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            children: [
              CampusSurface(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(widget.controller.current?.name ?? '我的学习通账号', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        decoration: BoxDecoration(
                          color: light.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: colors.outlineSubtle),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: ticket == null
                            ? Center(
                                child: _error == null
                                    ? const CampusLoading(label: '正在生成代签码', network: true, remote: '中转服务')
                                    : Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: light.danger)),
                              )
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  Semantics(
                                    label: '我的代签二维码',
                                    image: true,
                                    child: PrettyQrView.data(
                                      data: ticket,
                                      decoration: PrettyQrDecoration(
                                        shape: PrettyQrSmoothSymbol(color: light.onSurface, roundFactor: .5),
                                        quietZone: PrettyQrQuietZone.standard,
                                      ),
                                    ),
                                  ),
                                  // 过期的码盖住，别让人拿着失效的码给对方扫。
                                  if (expired)
                                    ColoredBox(
                                      color: light.surface.withValues(alpha: .94),
                                      child: Center(child: Text('已失效', style: TextStyle(fontSize: 16, color: light.onSurface))),
                                    ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (ticket == null)
                      Text(' ', style: secondary)
                    else if (expired)
                      Text('代签码已失效，请重新生成', style: secondary)
                    else
                      DotSeparatedText('${_remaining ~/ 60}:${(_remaining % 60).toString().padLeft(2, '0')} 后失效 · 被扫走或离开本页也会失效', style: secondary),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _creating ? null : _create,
                      child: CampusBusyContent(busy: _creating, label: '重新生成', busyLabel: '正在生成', icon: const CampusIcon(CampusIcons.sync)),
                    ),
                  ],
                ),
              ),
              if (_faces.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('附带人脸照片（对方替你签人脸签到时用）', style: secondary),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (index, face) in _faces.indexed)
                      CampusGlassChip(
                        label: '第 ${index + 1} 张',
                        selected: _attached.contains(face.objectId),
                        onSelected: _creating ? null : (_) => _toggleFace(face.objectId),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('让对方在“学习通签到”里选“扫别人的代签码”，扫到后本机就会保存你的账号替他签到', textAlign: TextAlign.center, style: secondary),
              const SizedBox(height: 8),
              Text('二维码被谁扫到就等于把账号交给了他，只当面给自己信得过的人看', textAlign: TextAlign.center, style: secondary),
            ],
          ),
        ),
      ),
    );
  }
}
