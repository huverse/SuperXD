import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/friend_schedule_page.dart';
import 'package:superxd/page/share_card_view.dart';
import 'package:superxd/page/social_dialogs.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 打开好友分享的视频：由组合根接到百宝箱的短视频页（页面层不依赖百宝箱）。
typedef VideoOpener = void Function(BuildContext context, VideoShare video);

// 与一位好友的私信会话：只有功能性卡片，没有文字聊天。底部操作栏发送课表、界面配置；视频从百宝箱结果页分享。
class ConversationPage extends StatefulWidget {
  const ConversationPage({super.key, required this.social, required this.friendId, this.gateway, this.openVideo});
  final SocialService social;
  final String friendId;
  // 读取本机课表用于分享与对比；为空时不提供分享课表（未登录或测试）。
  final CampusGateway? gateway;
  final VideoOpener? openVideo;
  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  List<SocialMessage>? _messages;
  int _loadVersion = 0;
  bool _preparing = false;

  SocialService get _social => widget.social;
  SocialFriend? get _friend => _social.friends.where((friend) => friend.deviceId == widget.friendId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _social.addListener(_reload);
    // 新消息由服务的前台长轮询送达并通知，这里只跟着重读本机，不另外拉取。
    _reload();
  }

  @override
  void dispose() {
    _social.removeListener(_reload);
    super.dispose();
  }

  // 服务有变化（发送状态、新消息）时重读本会话；会话最多 200 条，读本机很快。看到的新消息即算已读。
  Future<void> _reload() async {
    final version = ++_loadVersion;
    try {
      final messages = await _social.conversation(widget.friendId);
      if (!mounted || version != _loadVersion) return;
      setState(() => _messages = messages);
      if ((_friend?.unread ?? 0) > 0) await _social.markRead(widget.friendId);
    } catch (error, stack) {
      campusLog('[Conversation] action=load errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _send(ShareCard card) async {
    try {
      await _social.send(widget.friendId, card);
    } catch (error, stack) {
      campusLog('[Conversation] action=send errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, socialErrorText(error is SocialException ? error.code : null));
    }
  }

  // 分享课表：本机有多个已同步学期时先选学期；只发本机已有的课表与作息，不联网同步。
  Future<void> _shareSchedule(BuildContext anchor) async {
    final gateway = widget.gateway!;
    setState(() => _preparing = true);
    try {
      final listed = await gateway.listTerms();
      final terms = listed.data ?? const <TermRef>[];
      if (!mounted) return;
      if (terms.isEmpty) {
        await showCampusNotice(context, '本机还没有课表，请先在今天页同步');
        return;
      }
      final term = terms.length == 1 || !anchor.mounted
          ? terms.first
          : await showCampusMenu<TermRef>(anchor, items: [for (final term in terms) CampusMenuItem(value: term, label: term.label.isEmpty ? term.key : term.label, icon: CampusIcons.todaySelected)]);
      if (term == null || !mounted) return;
      final schedule = await gateway.readSchedule(ScheduleScope.term(term));
      final bells = await gateway.readBells(term);
      if (!mounted) return;
      final view = schedule.data;
      if (!schedule.ok || view == null || view.revisionId == null) {
        await showCampusNotice(context, '这个学期本机还没有课表');
        return;
      }
      await _send(ScheduleShare(term: term, termStartDate: view.termStartDate, courses: view.courses, bells: bells.data?.periods ?? const []));
    } catch (error, stack) {
      campusLog('[Conversation] action=share_schedule errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '读取本机课表失败');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  // 套用界面配置：立即生效，提示条带“撤销”回到套用前。
  Future<void> _apply(AppearanceShare share) async {
    final settings = DisplayScope.of(context);
    final previous = settings.appearance;
    try {
      final skipped = await settings.applyAppearance(share);
      if (!mounted) return;
      showCampusToast(context, skipped.isEmpty ? '已套用' : '已套用，当前版本不支持：${skipped.join('、')}', action: '撤销', onAction: () {
        settings.applyAppearance(previous).catchError((Object error, StackTrace stack) {
          campusLog('[Conversation] action=undo_appearance errorType=${error.runtimeType}\n$stack');
          return const <String>[];
        });
      });
    } catch (error, stack) {
      campusLog('[Conversation] action=apply_appearance errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '套用未完成，请重试');
    }
  }

  void _open(SocialMessage message) {
    final card = message.card;
    switch (card) {
      case ScheduleShare():
        Navigator.of(context).push(CampusPageRoute<void>(builder: (_) => FriendSchedulePage(
          friendName: message.outgoing ? '我' : _friend?.displayName ?? '好友',
          share: card,
          sharedAt: message.createTime,
          gateway: widget.gateway,
          outgoing: message.outgoing,
        )));
      case VideoShare():
        if (widget.openVideo == null) {
          showCampusNotice(context, '当前环境无法打开视频');
        } else {
          widget.openVideo!(context, card);
        }
      case AppearanceShare():
        _apply(card);
      case UnknownShare() || null:
        break;
    }
  }

  Future<void> _messageMenu(BuildContext anchor, SocialMessage message) async {
    final action = await showCampusMenu<String>(anchor, items: [
      if (message.state == MessageState.failed) const CampusMenuItem(value: 'retry', label: '重新发送', icon: CampusIcons.sync),
      const CampusMenuItem(value: 'delete', label: '删除（仅本机）', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    try {
      switch (action) {
        case 'retry':
          await _social.retry(message.id);
        case 'delete':
          final confirmed = await showCampusConfirm(context, title: '删除这张卡片？', message: '只删本机的记录，对方那边不受影响。', action: '删除', destructive: true);
          if (confirmed && mounted) await _social.deleteMessage(message.id);
      }
    } catch (error, stack) {
      campusLog('[Conversation] action=message_menu errorType=${error.runtimeType}\n$stack');
      if (mounted) showCampusToast(context, '操作未完成，请重试');
    }
  }

  Future<void> _more(BuildContext anchor) async {
    final friend = _friend;
    if (friend == null) return;
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'remark', label: '修改备注', icon: CampusIcons.edit),
      CampusMenuItem(value: 'remove', label: '删除好友', icon: CampusIcons.removeFriend),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'remark':
        final remark = await showSocialTextInput(context, title: '修改备注', initial: friend.remark ?? '', hint: '备注（留空显示对方昵称）', maxLength: 20, action: '保存');
        if (remark != null) await _social.setRemark(friend.deviceId, remark);
      case 'remove':
        final confirmed = await showCampusConfirm(context, title: '删除好友？', message: '删除后双方不能再互发，本机与${friend.displayName}的会话一并删除。', action: '删除', destructive: true);
        if (!confirmed || !mounted) return;
        try {
          await showCampusWaiting(context, label: '正在删除', operation: () => _social.removeFriend(friend.deviceId));
          if (mounted) Navigator.pop(context);
        } catch (error, stack) {
          campusLog('[Conversation] action=remove_friend errorType=${error.runtimeType}\n$stack');
          if (mounted) await showCampusNotice(context, socialErrorText(error is SocialException ? error.code : null));
        }
    }
  }

  Widget _status(SocialMessage message, CampusPalette colors) {
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    return switch (message.state) {
      MessageState.sending => Row(mainAxisSize: MainAxisSize.min, children: [const SizedBox(width: 16, height: 16, child: CampusLoader(size: 16)), const SizedBox(width: 6), Text('发送中', style: secondary)]),
      MessageState.failed => Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        Text(socialErrorText(message.error), style: TextStyle(fontSize: 14, color: colors.danger)),
        if (_friend?.removed == false) TextButton.icon(onPressed: () => _social.retry(message.id), icon: const CampusIcon(CampusIcons.sync), label: const Text('重新发送')),
      ]),
      _ => const SizedBox.shrink(),
    };
  }

  // 时间分隔：与上一条相隔超过 5 分钟（或是第一条）才在上方居中显示一次时间，同常见 IM，不在每张卡片下重复。
  static bool _timeGap(SocialMessage message, SocialMessage? older) =>
      older == null || DateTime.parse(message.createTime).difference(DateTime.parse(older.createTime)) > const Duration(minutes: 5);

  Widget _item(SocialMessage message, SocialMessage? older, CampusPalette colors, double maxWidth) {
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    final time = _timeGap(message, older) ? Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Center(child: Text(formatCampusTimestamp(message.createTime), style: secondary))) : null;
    if (message.system != null) {
      return Column(children: [
        ?time,
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Center(child: Text('已成为好友', style: secondary))),
      ]);
    }
    final alignment = message.outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: alignment, children: [
        if (time != null) SizedBox(width: double.infinity, child: time),
        // [人工决策-2026-10-09 20:32:45] 卡片右上加可见的⋯（重新发送、删除），删除标警示色并确认；长按仍可打开同一菜单。
        // 以前只能长按，入口看不见；用户选定在卡片角上加⋯（同课程管理卡片、iOS 与鸿蒙列表的更多按钮）。
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Builder(builder: (anchor) => GestureDetector(
            onLongPress: () => _messageMenu(anchor, message),
            child: Stack(children: [
              CampusSurface(
                radius: 20,
                child: ShareCardView(
                  card: message.card!,
                  outgoing: message.outgoing,
                  onOpenSchedule: () => _open(message),
                  onApplyAppearance: () => _open(message),
                  onOpenVideo: () => _open(message),
                ),
              ),
              // 48 触区贴卡片右上角，图标与标题行同高；卡片标题行左对齐且很短，不会被盖住。
              PositionedDirectional(top: 2, end: 2, child: Builder(builder: (menuAnchor) => IconButton(
                tooltip: '卡片操作',
                onPressed: () => _messageMenu(menuAnchor, message),
                icon: CampusIcon(CampusIcons.manage, size: 20, color: colors.onSurfaceVariant),
              ))),
            ]),
          )),
        ),
        if (message.outgoing && message.state != MessageState.sent) Padding(padding: const EdgeInsets.only(top: 6, left: 4, right: 4), child: _status(message, colors)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    return ListenableBuilder(listenable: _social, builder: (context, _) {
      final friend = _friend;
      final messages = _messages;
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
          title: Text(friend?.displayName ?? '好友'),
          actions: [
            if (friend != null) Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Builder(builder: (anchor) => CampusGlassCircleButton(label: '更多操作', size: 44, onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
            ),
          ],
        ),
        body: Column(children: [
          Expanded(child: messages == null
              ? const Center(child: CampusLoading(label: '读取会话'))
              : LayoutBuilder(builder: (context, constraints) => ListView.builder(
                  // 最新的在最下面，打开即停在底部。
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: messages.length,
                  // 列表倒序：index + 1 是更早的一条。
                  itemBuilder: (context, index) => KeyedSubtree(key: ValueKey(messages[index].id), child: _item(messages[index], index + 1 < messages.length ? messages[index + 1] : null, colors, constraints.maxWidth * .82)),
                ))),
          // 底部操作栏：实色、顶部分割线（同会话页输入栏规格），不模糊，铺满宽度。
          Container(
            width: double.infinity,
            decoration: BoxDecoration(color: colors.surface, border: Border(top: BorderSide(color: colors.outlineSubtle))),
            child: SafeArea(top: false, child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: friend == null || friend.removed
                  ? SizedBox(height: 48, child: Center(child: Text('对方已解除好友，无法发送', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant))))
                  // 两个操作等宽并排。
                  : Row(children: [
                      if (widget.gateway != null) ...[
                        Expanded(child: Builder(builder: (anchor) => FilledButton.icon(
                          onPressed: _preparing ? null : () => _shareSchedule(anchor),
                          icon: const CampusIcon(CampusIcons.todaySelected),
                          label: CampusBusyContent(busy: _preparing, label: '分享课表', busyLabel: '读取课表'),
                        ))),
                        const SizedBox(width: 12),
                      ],
                      Expanded(child: FilledButton.icon(onPressed: () => _send(DisplayScope.of(context).appearance), icon: const CampusIcon(CampusIcons.palette), label: const Text('分享界面'))),
                    ]),
            )),
          ),
        ]),
      );
    });
  }
}
