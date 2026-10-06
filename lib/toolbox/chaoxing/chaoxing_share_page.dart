import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 出示代签码：二维码里只有一次性取件号与密钥，凭据密文放在自建中转，对方扫走即取即删。
Future<void> showChaoxingTicketPage(BuildContext context, {required ChaoxingController controller}) =>
    Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ChaoxingTicketPage(controller: controller)));

class ChaoxingTicketPage extends StatefulWidget {
  const ChaoxingTicketPage({super.key, required this.controller});
  final ChaoxingController controller;
  @override
  State<ChaoxingTicketPage> createState() => _ChaoxingTicketPageState();
}

class _ChaoxingTicketPageState extends State<ChaoxingTicketPage> {
  String? _ticket;
  String? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final ticket = await widget.controller.createCredentialTicket();
      if (!mounted) return;
      setState(() => _ticket = ticket);
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
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('出示代签码'),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
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
                                    ? const CampusLoading(label: '正在生成代签码', network: true)
                                    : Text(_error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: light.danger)),
                              )
                            : Semantics(
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
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(ticket == null ? ' ' : '10 分钟内有效，被扫走即失效', style: secondary),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _creating ? null : _create,
                      icon: const CampusIcon(CampusIcons.sync),
                      label: CampusBusyContent(busy: _creating, label: '重新生成', busyLabel: '正在生成'),
                    ),
                  ],
                ),
              ),
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
