import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/conversation_page.dart';
import 'package:superxd/page/friend_add_page.dart';
import 'package:superxd/page/section_pages.dart';
import 'package:superxd/page/social_dialogs.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 消息页：通知（暂未接入）与私信。私信是功能性的：只有好友之间的分享卡片，没有文字聊天。
class MessagePage extends StatefulWidget {
  const MessagePage({super.key, this.social, this.gateway, this.openVideo, this.scan = scanInviteWithCamera});
  // 为空表示本次运行未接入私信（测试或未配置中转服务）。
  final SocialService? social;
  final CampusGateway? gateway;
  final VideoOpener? openVideo;
  final InviteScanner scan;
  @override
  State<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends State<MessagePage> {
  // 通知尚未接入，默认停在私信。
  int _index = 1;
  bool _visible = false;

  SocialService get _social => widget.social!;

  // 分支重新可见时拉一次信箱并核对好友列表（被对方解除的标出来）；平时的新消息由服务的前台长轮询送达。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    // 刷新会同步通知监听者，不能在构建期间发起，放到这一帧之后。
    if (visible && !_visible && widget.social != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh(reconcile: true);
      });
    }
    _visible = visible;
  }

  Future<void> _refresh({bool reconcile = false, bool report = false}) async {
    await _social.refresh(reconcile: reconcile);
    if (report && mounted && _social.refreshError != null) showCampusToast(context, socialErrorText(_social.refreshError));
  }

  // 从会话、添加好友返回时刷新一次：期间可能有新消息或新好友。
  Future<void> _open(String friendId) async {
    await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
      builder: (_) => ConversationPage(social: _social, friendId: friendId, gateway: widget.gateway, openVideo: widget.openVideo),
    ));
    if (mounted) await _refresh();
  }

  Future<void> _add() async {
    final friendId = await Navigator.of(context, rootNavigator: true).push<String>(MaterialPageRoute(builder: (_) => FriendAddPage(social: _social, scan: widget.scan)));
    if (!mounted) return;
    if (friendId != null) {
      await _open(friendId);
    } else {
      await _refresh();
    }
  }

  Future<void> _more(BuildContext anchor) async {
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'rename', label: '修改昵称', icon: CampusIcons.edit),
      CampusMenuItem(value: 'disable', label: '关闭私信', icon: CampusIcons.logout),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final nickname = await showSocialTextInput(context, title: '修改昵称', initial: _social.profile?.nickname ?? '', hint: '昵称（对之后添加的好友生效）', maxLength: nicknameMaxLength, action: '保存', validate: _nicknameError);
        if (nickname != null) await _social.rename(nickname);
      case 'disable':
        final confirmed = await showCampusConfirm(context, title: '关闭私信？', message: '将删除本设备的私信身份、全部好友与会话，服务器上的好友关系和待收消息一并删除，无法恢复。', action: '关闭并删除', destructive: true);
        if (!confirmed || !mounted) return;
        try {
          await showCampusWaiting(context, label: '正在关闭私信', operation: _social.disable);
        } catch (error, stack) {
          campusLog('[MessagePage] action=disable errorType=${error.runtimeType}\n$stack');
          if (mounted) await showCampusNotice(context, socialErrorText(error is SocialException ? error.code : null));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final social = widget.social;
    return Column(children: [
      const SectionTitleBar(title: '消息'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: ListenableBuilder(
        listenable: social ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) => CampusSegmented<int>(
          values: const [0, 1], selected: _index, onSelected: (index) => setState(() => _index = index),
          label: (index) => index == 0 ? '通知' : (social?.unread ?? 0) > 0 ? '私信 ${social!.unread > 99 ? '99+' : social.unread}' : '私信',
        ),
      )),
      Expanded(child: _index == 0
          ? Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              child: Center(child: Text('还没有通知', style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface))),
            )
          : social == null
          ? const _CenteredText('当前版本未配置私信服务')
          : ListenableBuilder(listenable: social, builder: (context, _) => switch (social.status) {
              SocialStatus.loading => const Center(child: CampusLoading(label: '读取私信')),
              SocialStatus.unavailable => const _CenteredText('当前版本未配置私信服务'),
              SocialStatus.failed => const _CenteredText('私信暂时不可用，请重启应用后再试'),
              SocialStatus.disabled => _SocialSetup(social: social),
              SocialStatus.ready => _FriendList(social: social, onOpen: _open, onAdd: _add, onMore: _more, onRefresh: () => _refresh(reconcile: true, report: true)),
            })),
    ]);
  }
}

String? _nicknameError(String value) => validNickname(value) ? null : '昵称为 1–$nicknameMaxLength 个字';

class _CenteredText extends StatelessWidget {
  const _CenteredText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(32, 0, 32, MediaQuery.paddingOf(context).bottom),
    child: Center(child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface))),
  );
}

// 开启私信：设置昵称并说明数据处理方式（开启即生成本设备的私信身份并在中转服务注册）。
class _SocialSetup extends StatefulWidget {
  const _SocialSetup({required this.social});
  final SocialService social;
  @override
  State<_SocialSetup> createState() => _SocialSetupState();
}

class _SocialSetupState extends State<_SocialSetup> {
  final _nickname = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    final nickname = _nickname.text.trim();
    final invalid = _nicknameError(nickname);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.social.enable(nickname);
    } on SocialException catch (error) {
      if (mounted) setState(() => _error = socialErrorText(error.code));
    } catch (error, stack) {
      campusLog('[MessagePage] action=enable errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = socialErrorText(null));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return CampusScrollFade(bottom: inset, child: ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset), children: [
      CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('开启私信', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('和同学扫码互加好友，分享课表、界面配置和短视频。', style: TextStyle(fontSize: 16, color: colors.onSurface)),
        SizedBox(height: campusFieldGap(context)),
        TextField(
          controller: _nickname,
          enabled: !_busy,
          maxLength: nicknameMaxLength,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(labelText: '昵称', errorText: _error),
          onSubmitted: (_) => _enable(),
        ),
        const SizedBox(height: 4),
        Text('分享内容在本机加密，中转服务器只转交密文；对方未取走的 30 天后删除。好友与私信属于这台设备，切换教务账号不受影响。', style: secondary),
        Align(alignment: AlignmentDirectional.centerStart, child: TextButton(style: campusLink, onPressed: () => context.push('/legal/privacy'), child: const Text('隐私政策', style: TextStyle(fontSize: 14)))),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: campusProminent,
          onPressed: _busy ? null : _enable,
          icon: const CampusIcon(CampusIcons.check),
          label: CampusBusyContent(busy: _busy, label: '同意并开启', busyLabel: '正在开启'),
        ),
      ])),
    ]));
  }
}

class _FriendList extends StatelessWidget {
  const _FriendList({required this.social, required this.onOpen, required this.onAdd, required this.onMore, required this.onRefresh});
  final SocialService social;
  final void Function(String friendId) onOpen;
  final VoidCallback onAdd;
  final void Function(BuildContext anchor) onMore;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final friends = social.friends;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CampusScrollFade(bottom: inset, child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + inset),
        children: [
          Row(children: [
            Expanded(child: Text('我：${social.profile?.nickname ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant))),
            FilledButton.icon(style: campusProminent, onPressed: onAdd, icon: const CampusIcon(CampusIcons.addFriend), label: const Text('添加好友')),
            const SizedBox(width: 4),
            Builder(builder: (anchor) => IconButton(tooltip: '私信设置', onPressed: () => onMore(anchor), icon: const CampusIcon(CampusIcons.manage))),
          ]),
          const SizedBox(height: 12),
          if (friends.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 48), child: Center(child: Text('还没有好友，点“添加好友”面对面扫码', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: colors.onSurface))))
          else
            // 多行卡片去掉横向内边距，行自带 20 边距：按下变暗时整行铺满卡片宽度（同“我的”页）。
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
              for (final friend in friends) _FriendRow(friend: friend, onTap: () => onOpen(friend.deviceId)),
            ])),
        ],
      )),
    );
  }
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({required this.friend, required this.onTap});
  final SocialFriend friend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final unread = friend.unread;
    return Semantics(
      label: unread > 0 ? '${friend.displayName}，$unread 条未读' : null,
      child: ListTile(
        key: ValueKey(friend.deviceId),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        onTap: onTap,
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: colors.surfaceSelected,
          child: Text(friend.displayName.characters.first, style: TextStyle(fontSize: 16, color: colors.primary, fontWeight: FontWeight.w600)),
        ),
        title: Text(friend.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: colors.onSurface, fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400)),
        subtitle: Text(friend.removed ? '对方已解除好友' : friend.lastPreview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(socialShortTime(friend.lastActivity), style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
          if (unread > 0) Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            constraints: const BoxConstraints(minWidth: 20),
            decoration: BoxDecoration(color: colors.dangerFill, borderRadius: BorderRadius.circular(10)),
            child: Text(unread > 99 ? '99+' : '$unread', textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4)),
          ),
        ]),
      ),
    );
  }
}
