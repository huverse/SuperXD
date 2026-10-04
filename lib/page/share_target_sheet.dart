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
import 'package:superxd/theme/campus_transitions.dart';

// 分享给好友：底部弹层里多选好友，点发送后每一行原地显示发送中、已发送或失败（可单独重发），完成后按钮变为“完成”。
// 课表页、界面页、百宝箱结果页共用；百宝箱经组合根注入的回调调用这里。
Future<void> showShareSheet(BuildContext context, {required SocialService social, required ShareCard card}) async {
  if (social.status != SocialStatus.ready) {
    await showCampusNotice(context, social.status == SocialStatus.unavailable ? '当前版本未配置私信服务' : '请先在“消息 › 私信”开启私信并添加好友');
    return;
  }
  if (!social.friends.any((friend) => !friend.removed)) {
    await showCampusNotice(context, '还没有好友，先在“消息 › 私信”扫码添加');
    return;
  }
  await showCampusSheet<void>(context: context, builder: (context) => CampusSheetPanel(child: _ShareSheet(social: social, card: card)));
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.social, required this.card});
  final SocialService social;
  final ShareCard card;
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
        ]),
      ),
    );
  }
}
