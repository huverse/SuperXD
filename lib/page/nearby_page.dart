import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/nearby_radio.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/page/conversation_page.dart';
import 'package:superxd/page/friend_add_page.dart';
import 'package:superxd/page/social_dialogs.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/nearby_service.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_animated_list.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 面对面私信页（人工决策见 social/nearby_service.dart）：两人都打开这一页时经蓝牙互相发现、点好友就发，离开这一页就停。
// 打开即开蓝牙（安卓按系统版本要附近设备或位置权限），上方原地写蓝牙的状态与下一步；好友行写在不在附近。
// card 不为空时是从分享弹层来的：点一位在附近的好友就把这张卡发给他，每行原地显示发送中、已发送或失败。
class NearbyPage extends StatefulWidget {
  const NearbyPage({super.key, required this.nearby, this.card, this.gateway, this.openVideo, this.scan = scanNearbyInviteWithCamera});
  final NearbyService nearby;
  final ShareCard? card;
  final CampusGateway? gateway;
  final VideoOpener? openVideo;
  final InviteScanner scan;
  @override
  State<NearbyPage> createState() => _NearbyPageState();
}

class _NearbyPageState extends State<NearbyPage> {
  final _nickname = TextEditingController();
  bool _enabling = false;
  String? _nicknameError;
  // 分享模式下每位好友这次的结果：null 发送中，空串已发送，其余为错误码。
  final _results = <String, String?>{};
  final _messageIds = <String, String>{};

  NearbyService get _nearby => widget.nearby;

  @override
  void initState() {
    super.initState();
    _nearby.acquire();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await _nearby.open();
      // 打开后蓝牙要等设好昵称才开：acquire 在 open 之前调过，这里再对一次。
      _nearby.acquire();
      _nearby.release();
      final count = await _nearby.pendingMerge();
      if (count != null && mounted) await _askMerge(count);
    } catch (error, stack) {
      campusLog('[NearbyPage] action=open errorType=${error.runtimeType}\n$stack');
    }
  }

  // 登录应用账号后问一次（人工决策见 social/nearby_service.dart）：只能二选一，不能点外面关掉。
  Future<void> _askMerge(int count) async {
    final merge = await showCampusConfirm(
      context,
      title: '把 $count 位面对面好友并进这个账号？',
      message: '并进后只在登录这个账号时看得到，仍只经蓝牙收发。',
      action: '并进',
      cancel: '不并',
      barrierDismissible: false,
    );
    if (!mounted) return;
    await _nearby.chooseMerge(merge: merge);
  }

  @override
  void dispose() {
    _nearby.release();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    final nickname = _nickname.text.trim();
    if (!validNickname(nickname)) {
      setState(() => _nicknameError = '昵称为 1–$nicknameMaxLength 个字');
      return;
    }
    setState(() {
      _enabling = true;
      _nicknameError = null;
    });
    try {
      await _nearby.enable(nickname);
    } catch (error, stack) {
      campusLog('[NearbyPage] action=enable errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _nicknameError = socialErrorText(null));
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  Future<void> _add() async {
    final friendId = await Navigator.of(context).push<String>(CampusPageRoute(builder: (_) => FriendAddPage(social: _nearby, scan: widget.scan, nearby: true)));
    if (friendId != null && mounted && widget.card == null) await _openConversation(friendId);
  }

  Future<void> _openConversation(String friendId) => Navigator.of(context).push(CampusPageRoute<void>(
    builder: (_) => ConversationPage(social: _nearby, friendId: friendId, gateway: widget.gateway, openVideo: widget.openVideo),
  ));

  Future<void> _sendCard(String friendId) async {
    setState(() => _results[friendId] = null);
    String outcome;
    try {
      final previous = _messageIds[friendId];
      final message = previous == null ? await _nearby.send(friendId, widget.card!) : await _nearby.retry(previous);
      _messageIds[friendId] = message.id;
      outcome = message.state == MessageState.sent ? '' : message.error ?? '';
    } catch (error, stack) {
      campusLog('[NearbyPage] action=send errorType=${error.runtimeType}\n$stack');
      outcome = error is SocialException ? error.code : 'UNKNOWN';
    }
    if (mounted) setState(() => _results[friendId] = outcome);
  }

  Future<void> _more(BuildContext anchor) async {
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'rename', label: '修改昵称', icon: CampusIcons.edit),
      CampusMenuItem(value: 'clear', label: '删除面对面数据', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final nickname = await showSocialTextInput(context, title: '修改昵称', initial: _nearby.profile?.nickname ?? '', hint: '昵称（对之后添加的好友生效）', maxLength: nicknameMaxLength, action: '保存', validate: (value) => validNickname(value) ? null : '昵称为 1–$nicknameMaxLength 个字');
        if (nickname != null) await _nearby.rename(nickname);
      case 'clear':
        // 长文案：删除面对面数据的确认，写明对方那边删不到。
        final confirmed = await showCampusConfirm(context, title: '删除面对面数据？', message: '将删除这台手机的面对面身份、全部面对面好友与会话，无法恢复；好友手机上的记录不受影响。', action: '删除', destructive: true);
        if (confirmed && mounted) await showCampusWaiting(context, label: '正在删除', operation: _nearby.clearAll);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _nearby, builder: (context, _) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: Text(widget.card == null ? '面对面' : '面对面发送'),
      actions: [
        if (_nearby.status == NearbyStatus.ready && widget.card == null) Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Builder(builder: (anchor) => CampusGlassCircleButton(label: '面对面设置', size: 44, onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
        ),
      ],
    ),
    body: switch (_nearby.status) {
      NearbyStatus.loading => const Center(child: CampusLoading(label: '读取面对面')),
      NearbyStatus.setup => _setup(context),
      NearbyStatus.ready => _ready(context),
    },
  ));

  Widget _setup(BuildContext context) {
    final colors = CampusPalette.of(context);
    return CampusScrollFade(child: SafeArea(child: ListView(padding: const EdgeInsets.all(CampusGap.large), children: [
      CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('面对面私信', style: Theme.of(context).textTheme.titleLarge),
        SizedBox(height: campusFieldGap(context)),
        TextField(
          controller: _nickname,
          enabled: !_enabling,
          maxLength: nicknameMaxLength,
          style: const TextStyle(fontSize: CampusFontSize.body),
          decoration: InputDecoration(labelText: '昵称', errorText: _nicknameError),
          onSubmitted: (_) => _enable(),
        ),
        const SizedBox(height: CampusGap.tight),
        Text('两人都打开这一页，经蓝牙直接互发，不经服务器、不用登录。', style: TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant)),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton(style: campusLink, onPressed: () => context.push('/legal/privacy'), child: const Text('隐私政策', style: TextStyle(fontSize: CampusFontSize.secondary)))),
        const SizedBox(height: CampusGap.small),
        FilledButton(
          style: campusProminent,
          onPressed: _enabling ? null : _enable,
          child: CampusBusyContent(busy: _enabling, label: '同意并开始', busyLabel: '正在准备', icon: const CampusIcon(CampusIcons.check)),
        ),
      ])),
    ])));
  }

  Widget _ready(BuildContext context) {
    final colors = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final friends = _nearby.friends;
    final card = widget.card;
    final secondary = TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant);
    return CampusScrollFade(bottom: inset, child: CustomScrollView(slivers: [
      SliverPadding(padding: EdgeInsets.fromLTRB(CampusGap.large, CampusGap.large, CampusGap.large, friends.isEmpty ? CampusGap.large + inset : 0), sliver: SliverList.list(children: [
        _RadioStatus(nearby: _nearby),
        const SizedBox(height: CampusGap.medium),
        if (card != null) ...[
          Text('点一位在附近的好友发送：${shareCardSummary(card)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: secondary),
          const SizedBox(height: CampusGap.medium),
        ],
        Row(children: [
          Expanded(child: Text('我：${_nearby.profile?.nickname ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary)),
          FilledButton.icon(style: card == null ? campusProminent : null, onPressed: _add, icon: const CampusIcon(CampusIcons.addFriend), label: const Text('添加好友')),
        ]),
        const SizedBox(height: CampusGap.medium),
        if (friends.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 48), child: Center(child: Text('还没有面对面好友，点「添加好友」当面扫码', textAlign: TextAlign.center, style: TextStyle(fontSize: CampusFontSize.body, color: colors.onSurface)))),
      ])),
      if (friends.isNotEmpty)
        SliverPadding(padding: EdgeInsets.fromLTRB(CampusGap.large, 0, CampusGap.large, CampusGap.large + inset), sliver: CampusSliverCard(sliver: CampusAnimatedSliverList<SocialFriend>(
          items: friends,
          keyOf: (friend) => ValueKey(friend.deviceId),
          itemBuilder: (context, friend, index, count) => CampusCardRow(first: index == 0, last: index == count - 1, child: _NearbyFriendRow(
            friend: friend,
            present: _nearby.present.containsKey(friend.deviceId),
            sharing: card != null,
            result: _results.containsKey(friend.deviceId) ? (done: true, code: _results[friend.deviceId]) : null,
            onTap: card == null ? () => _openConversation(friend.deviceId) : _results[friend.deviceId] == '' || (_results.containsKey(friend.deviceId) && _results[friend.deviceId] == null) ? null : () => _sendCard(friend.deviceId),
          )),
        ))),
    ]));
  }
}

// 蓝牙的状态与下一步：好了只写一行在找；没好写原因，给能做的那一步（授权、去设置、重试）。
class _RadioStatus extends StatelessWidget {
  const _RadioStatus({required this.nearby});
  final NearbyService nearby;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant);
    final (text, action, onPressed) = switch (nearby.radioState) {
      NearbyRadioState.off || NearbyRadioState.starting => ('正在打开蓝牙', null, null),
      NearbyRadioState.ready => (nearby.present.isEmpty ? '正在找附近打开面对面的好友' : '附近有 ${nearby.present.length} 位好友', null, null),
      NearbyRadioState.bluetoothOff => ('蓝牙关着，打开后重试', '重试', nearby.retryRadio),
      NearbyRadioState.denied => ('没有蓝牙权限', '去设置', nearby.openRadioSettings),
      NearbyRadioState.locationOff => ('这台手机要打开定位开关才能用蓝牙找人', '重试', nearby.retryRadio),
      NearbyRadioState.unsupported => ('这台手机的蓝牙不支持面对面', null, null),
      NearbyRadioState.failed => ('蓝牙没能打开', '重试', nearby.retryRadio),
    };
    final ready = nearby.radioState == NearbyRadioState.ready || nearby.radioState == NearbyRadioState.starting || nearby.radioState == NearbyRadioState.off;
    return Semantics(
      liveRegion: true,
      child: Row(children: [
        CampusIcon(CampusIcons.nearby, size: 20, color: ready ? colors.onSurfaceVariant : colors.danger),
        const SizedBox(width: CampusGap.small),
        Expanded(child: BalancedText(text, style: ready ? secondary : TextStyle(fontSize: CampusFontSize.secondary, color: colors.danger))),
        if (action != null && onPressed != null) TextButton.icon(onPressed: () => unawaited(onPressed()), icon: const CampusIcon(CampusIcons.sync), label: Text(action)),
      ]),
    );
  }
}

class _NearbyFriendRow extends StatelessWidget {
  const _NearbyFriendRow({required this.friend, required this.present, required this.sharing, required this.result, required this.onTap});
  final SocialFriend friend;
  final bool present;
  final bool sharing;
  // 分享模式这次的结果：code 为空发送中，空串已发送，其余错误码。
  final ({bool done, String? code})? result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant);
    final where = present ? '在附近' : '不在附近';
    final subtitle = switch (result) {
      (done: true, code: final String code) when code.isNotEmpty => Text(socialErrorText(code), maxLines: 2, style: TextStyle(fontSize: CampusFontSize.secondary, color: colors.danger)),
      _ => Text(sharing || friend.lastPreview.isEmpty ? where : '$where · ${friend.lastPreview}', maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary),
    };
    final trailing = switch (result) {
      (done: true, code: null) => const SizedBox(width: 24, height: 24, child: CampusLoader(size: 24)),
      (done: true, code: '') => Row(mainAxisSize: MainAxisSize.min, children: [
        CampusIcon(CampusIcons.success, color: colors.onSurfaceVariant),
        const SizedBox(width: CampusGap.tight),
        Text('已发送', style: secondary),
      ]),
      (done: true, code: _) => CampusIcon(CampusIcons.sync, color: colors.primary),
      _ when sharing => CampusIcon(CampusIcons.send, color: present ? colors.primary : colors.onSurfaceVariant),
      _ when friend.unread > 0 => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 20),
        decoration: BoxDecoration(color: colors.dangerFill, borderRadius: BorderRadius.circular(10)),
        child: Text(friend.unread > 99 ? '99+' : '${friend.unread}', textAlign: TextAlign.center, style: const TextStyle(fontSize: CampusFontSize.secondary, color: Colors.white, height: 1.4)),
      ),
      _ => null,
    };
    return Semantics(
      label: '${friend.displayName}，$where${friend.unread > 0 ? '，${friend.unread} 条未读' : ''}',
      excludeSemantics: true,
      button: onTap != null,
      child: ListTile(
        key: ValueKey(friend.deviceId),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        onTap: onTap,
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: colors.surfaceSelected,
          child: Text(friend.displayName.characters.first, style: TextStyle(fontSize: CampusFontSize.body, color: colors.primary, fontWeight: FontWeight.w600)),
        ),
        title: Text(friend.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: CampusFontSize.body, color: colors.onSurface, fontWeight: friend.unread > 0 ? FontWeight.w600 : FontWeight.w400)),
        subtitle: Padding(padding: const EdgeInsets.only(top: CampusGap.hairline), child: subtitle),
        trailing: trailing,
      ),
    );
  }
}
