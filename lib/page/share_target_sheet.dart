import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/page/social_dialogs.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 私信没就绪时的直达（组合根套在账号应用外面）：去应用账号页（登录、改为联网）与去消息页（开启私信、加好友、接管、重试）。
// 设计语言 8.1「空状态原地给下一步的按钮，不让人去别的页面找」；去不了的（没配中转、没登录教务时消息页进不去）为空，只提示。
// openNearby：面对面发送这张卡（推入面对面页，人工决策见 social/nearby_service.dart），不受私信状态影响；没有面对面时为空。
class ShareGuide extends InheritedWidget {
  const ShareGuide({super.key, required this.openAccount, required this.openMessages, this.openNearby, required super.child});
  final void Function(BuildContext context)? openAccount;
  final void Function(BuildContext context)? openMessages;
  final void Function(BuildContext context, ShareCard card)? openNearby;

  static ShareGuide? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ShareGuide>();

  @override
  bool updateShouldNotify(ShareGuide oldWidget) => false;
}

// 分享给好友：底部弹层里多选好友，点发送后每一行原地显示发送中、已发送或失败（可单独重发），完成后按钮变为“完成”。
// 课表页、百宝箱结果页共用；百宝箱经组合根注入的回调调用这里。
// 私信没就绪或还没有好友时弹确认框，按钮直达能处理的那一页（11-17 设计审查：以前只写「请先在“我的 › 账号”登录…」让人自己去找）；
// 有面对面时弹层照样打开：最上面一行面对面发送，下面写私信为什么用不了与去处理的按钮。
Future<void> showShareSheet(BuildContext context, {required SocialService social, required ShareCard card}) async {
  final guide = ShareGuide.maybeOf(context);
  final (title, message, action, open) = switch (social.status) {
    SocialStatus.ready when !social.friends.any((friend) => !friend.removed) => ('还没有好友', '在消息页扫码加好友后就能分享。', '去添加', guide?.openMessages),
    SocialStatus.ready => (null, null, null, null),
    SocialStatus.unavailable => ('当前版本未配置私信服务', null, null, null),
    SocialStatus.signedOut => ('先登录应用账号', '私信跟着应用账号，登录后在消息页开启就能分享。', '去登录', guide?.openAccount),
    SocialStatus.offline => ('现在是仅本机', '仅本机时不经服务器分享，改为联网后就能分享。', '去改为联网', guide?.openAccount),
    SocialStatus.elsewhere => ('私信在另一台手机上', '可以在消息页改到这台手机上使用。', '去消息', guide?.openMessages),
    SocialStatus.disabled => ('还没开启私信', '在消息页开启私信、加好友后就能分享。', '去开启', guide?.openMessages),
    SocialStatus.loading || SocialStatus.failed => ('私信暂时连不上', '可以在消息页重试。', '去消息', guide?.openMessages),
  };
  final nearby = switch (guide?.openNearby) {
    final open? => () => open(context, card),
    null => null,
  };
  if (title != null && nearby == null) {
    if (message == null || action == null || open == null) return showCampusNotice(context, message ?? title, title: message == null ? null : title);
    if (await showCampusConfirm(context, title: title, message: message, action: action) && context.mounted) open(context);
    return;
  }
  final notice = title == null ? null : (title: title, message: message, action: action, open: open == null ? null : () => open(context));
  await showCampusSheet<void>(context: context, builder: (context) => CampusSheetPanel(child: _ShareSheet(social: social, card: card, nearby: nearby, notice: notice)));
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.social, required this.card, this.nearby, this.notice});
  final SocialService social;
  final ShareCard card;
  final VoidCallback? nearby;
  // 私信用不了时的说明（有面对面才走到弹层里）。
  final ({String title, String? message, String? action, VoidCallback? open})? notice;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  // 好友列表在打开时取一次快照：发送会更新会话排序，弹层里的行不跟着跳。
  late final List<SocialFriend> _friends = widget.social.friends.where((friend) => !friend.removed).toList()..sort((first, second) => first.displayName.compareTo(second.displayName));
  final _selected = <String>{};
  // 每个好友本次的发送结果：null 发送中，空串已发送，其余为错误码。
  final _results = <String, String?>{};
  final _messageIds = <String, String>{};
  bool _sending = false;
  bool get _started => _results.isNotEmpty;

  Future<void> _send(Iterable<String> friendIds) async {
    setState(() {
      _sending = true;
      for (final id in friendIds) {
        _results[id] = null;
      }
    });
    // 逐个发送，不并发：发送有限流，且每一行能按顺序看到进度。
    for (final id in friendIds) {
      String? outcome;
      try {
        final previous = _messageIds[id];
        final message = previous == null ? await widget.social.send(id, widget.card) : await widget.social.retry(previous);
        _messageIds[id] = message.id;
        outcome = message.state == MessageState.sent ? '' : message.error ?? '';
      } catch (error, stack) {
        campusLog('[ShareSheet] action=send errorType=${error.runtimeType}\n$stack');
        outcome = error is SocialException ? error.code : 'UNKNOWN';
      }
      if (!mounted) return;
      setState(() => _results[id] = outcome);
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final failed = [for (final entry in _results.entries) if (entry.value != null && entry.value!.isNotEmpty) entry.key];
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 12, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('分享给好友', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 12, bottom: 8),
            child: Text(shareCardSummary(widget.card), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
          ),
          if (widget.nearby case final nearby? when !_started) Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CampusIcon(CampusIcons.nearby),
              title: const Text('面对面发送'),
              subtitle: Text('两人都打开面对面，经蓝牙发送', style: TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant)),
              trailing: const CampusIcon(CampusIcons.next),
              onTap: () {
                Navigator.pop(context);
                nearby();
              },
            ),
          ),
          if (widget.notice case final notice?) ...[
            Padding(padding: const EdgeInsets.only(right: 12, top: 8), child: Text(notice.title, style: Theme.of(context).textTheme.titleMedium)),
            if (notice.message != null) Padding(padding: const EdgeInsets.only(right: 12, top: 4), child: Text(notice.message!, style: TextStyle(fontSize: CampusFontSize.secondary, color: colors.onSurfaceVariant))),
            if (notice.action != null && notice.open != null) Padding(padding: const EdgeInsets.only(right: 12, top: 12), child: FilledButton(onPressed: () {
              Navigator.pop(context);
              notice.open!();
            }, child: Text(notice.action!))),
          ] else ...[
          Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(right: 12), children: [
            for (final friend in _friends)
              if (!_started)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(friend.displayName),
                  value: _selected.contains(friend.deviceId),
                  onChanged: (value) => setState(() => value == true ? _selected.add(friend.deviceId) : _selected.remove(friend.deviceId)),
                )
              else if (_results.containsKey(friend.deviceId))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(friend.displayName),
                  subtitle: switch (_results[friend.deviceId]) {
                    null => null,
                    '' => null,
                    final code => Text(socialErrorText(code), style: TextStyle(fontSize: 14, color: colors.danger)),
                  },
                  trailing: switch (_results[friend.deviceId]) {
                    null => const SizedBox(width: 24, height: 24, child: CampusLoader(size: 24)),
                    '' => Row(mainAxisSize: MainAxisSize.min, children: [
                      CampusIcon(CampusIcons.success, color: colors.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text('已发送', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                    ]),
                    _ => CampusIcon(CampusIcons.warning, color: colors.danger),
                  },
                ),
          ])),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: !_started
                ? FilledButton.icon(
                    style: campusProminent,
                    onPressed: _selected.isEmpty ? null : () => _send(_friends.map((friend) => friend.deviceId).where(_selected.contains).toList()),
                    icon: const CampusIcon(CampusIcons.send),
                    label: Text(_selected.isEmpty ? '发送' : '发送给 ${_selected.length} 位好友'),
                  )
                : _sending
                    ? const FilledButton(onPressed: null, child: CampusBusyContent(busy: true, label: '发送', busyLabel: '正在发送'))
                    : failed.isNotEmpty
                        ? FilledButton.icon(style: campusProminent, onPressed: () => _send(failed), icon: const CampusIcon(CampusIcons.sync), label: Text('重发失败的 ${failed.length} 条'))
                        : FilledButton.icon(style: campusProminent, onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.check), label: const Text('完成')),
          ),
          ],
        ]),
      ),
    );
  }
}
