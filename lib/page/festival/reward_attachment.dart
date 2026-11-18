import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:superxd/application/festivals.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/page/festival/festival_reward.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 开发者的话里附的红包（[人工决策-2026-11-16 21:17:51]，服务端规则见 server/src/modules/reward/reward_odds.ts 的 11-16 那条）：
// 由组合根登记成 reward 类附件（信件页不认识红包）。先问这个活动能不能领：没资格的不显示；能领给「领取红包」，点了原地转圈、领到就揭晓；
// 领过的给「查看红包」（本机有奖品直接揭晓，没有就再问一次服务器，同一个人结果不变）；账号天数不够、没抽中、已结束只写一行状态。
class RewardAttachment extends StatefulWidget {
  const RewardAttachment({super.key, required this.festivals, required this.campaign, this.onSignIn, this.accountChanges, this.saveQrCode});
  final Festivals festivals;
  // 应用账号变了（在这页上去登录了再回来）再问一次；组合根给 AppAccounts。
  final Listenable? accountChanges;
  final String campaign;
  // 没登录应用账号时的「登录领取」；为空就不显示。
  final void Function(BuildContext context)? onSignIn;
  final Future<bool> Function(Uint8List png)? saveQrCode;

  @override
  State<RewardAttachment> createState() => _RewardAttachmentState();
}

class _RewardAttachmentState extends State<RewardAttachment> {
  RewardStatus? _status;
  FestivalDraw? _result;
  bool _asking = false, _claiming = false;
  bool? _askedSignedIn;

  @override
  void initState() {
    super.initState();
    widget.festivals.addListener(_changed);
    widget.accountChanges?.addListener(_changed);
    _ask();
  }

  // 换了活动或服务（同一位置画另一封信的附件）：旧的状态作废、重新问。
  @override
  void didUpdateWidget(RewardAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.festivals != widget.festivals || oldWidget.accountChanges != widget.accountChanges) {
      oldWidget.festivals.removeListener(_changed);
      oldWidget.accountChanges?.removeListener(_changed);
      widget.festivals.addListener(_changed);
      widget.accountChanges?.addListener(_changed);
    }
    if (oldWidget.festivals != widget.festivals || oldWidget.campaign != widget.campaign) {
      _status = null;
      _result = null;
      _asking = false;
      _ask();
    }
  }

  @override
  void dispose() {
    widget.festivals.removeListener(_changed);
    widget.accountChanges?.removeListener(_changed);
    super.dispose();
  }

  // 登录状态变了（在这页上登录了应用账号）再问一次。
  void _changed() {
    if (widget.festivals.signedIn != _askedSignedIn) _ask();
    if (mounted) setState(() {});
  }

  Future<void> _ask() async {
    final festivals = widget.festivals;
    _askedSignedIn = festivals.signedIn;
    if (!festivals.signedIn || festivals.prizeOf(widget.campaign) != null || _asking) return;
    setState(() => _asking = true);
    final status = await festivals.status(widget.campaign);
    if (!mounted) return;
    setState(() {
      _asking = false;
      _status = status;
    });
  }

  Future<void> _claim() async {
    final endsAt = _status?.endsAt;
    if (endsAt == null || _claiming) return;
    setState(() => _claiming = true);
    final result = await widget.festivals.claim(widget.campaign, endsAt: endsAt);
    if (!mounted) return;
    setState(() {
      _claiming = false;
      _result = result;
    });
    switch (result) {
      case null:
        showCampusToast(context, '连不上服务器，稍后再试');
      case FestivalWon():
        await _reveal();
      default:
        break;
    }
  }

  Future<void> _reveal() async {
    final prize = widget.festivals.prizeOf(widget.campaign);
    if (prize == null) return;
    unawaited(widget.festivals.markRevealed(prize));
    await showFestivalReward(context, prize: prize, title: widget.festivals.occasionName(prize.occasion), saveQrCode: widget.saveQrCode);
  }

  Widget _line(String text) => Text(text, style: Theme.of(context).textTheme.bodyMedium);

  Widget _button(String label, VoidCallback? onPressed) => Align(
    alignment: Alignment.centerLeft,
    child: FilledButton.icon(
      onPressed: _claiming ? null : onPressed,
      icon: const CampusIcon(CampusIcons.gift),
      label: CampusBusyContent(busy: _claiming, label: label, busyLabel: '领取中'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final festivals = widget.festivals;
    if (festivals.prizeOf(widget.campaign) != null) return _button('查看红包', () => unawaited(_reveal()));
    if (!festivals.signedIn) {
      final signIn = widget.onSignIn;
      return signIn == null ? const SizedBox.shrink() : _button('登录应用账号领取', () => signIn(context));
    }
    return switch ((_result, _status)) {
      (FestivalMissed(), _) => _line('没有抽中'),
      (FestivalIneligible(), _) || (_, RewardStatus(state: RewardState.ineligible)) => const SizedBox.shrink(),
      (FestivalClosed(), _) || (_, RewardStatus(state: RewardState.closed)) => _line('红包已结束'),
      (FestivalSoldOut(), _) || (_, RewardStatus(state: RewardState.soldOut)) => _line('这一批领完了，下一批再来'),
      (FestivalTooNew(:final eligibleAt), _) || (_, RewardStatus(state: RewardState.tooNew, eligibleAt: final DateTime eligibleAt)) => _line('应用账号${formatCampusRelative(eligibleAt.toIso8601String())}起能领'),
      (_, RewardStatus(state: RewardState.drawn)) => _button('查看结果', () => unawaited(_claim())),
      (_, RewardStatus(state: RewardState.open)) => _button('领取红包', () => unawaited(_claim())),
      _ => const SizedBox.shrink(),
    };
  }
}
