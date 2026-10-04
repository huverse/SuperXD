import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 私信错误码 → 界面文案，页面只按错误码取文案。
String socialErrorText(String? code) => switch (code) {
  RelayCode.network => '连不上私信服务，请检查网络',
  RelayCode.timeout => '私信服务响应超时，请重试',
  RelayCode.rateLimited => '操作太频繁，请稍后再试',
  RelayCode.clockSkew => '手机时间不准，请校准后重试',
  RelayCode.inviteNotFound || SocialCode.inviteExpired => '二维码已失效，请对方刷新后再扫',
  RelayCode.inviteSelf => '这是你自己的二维码',
  RelayCode.inviteProofInvalid || SocialCode.notInvite => '不是有效的 SuperXD 好友二维码',
  RelayCode.friendLimit || SocialCode.localFriendLimit => '好友数量已达上限',
  RelayCode.notFriend || SocialCode.friendRemoved => '对方已解除好友',
  RelayCode.peerNotFound => '对方已关闭私信',
  RelayCode.mailboxFull => '对方待收消息太多，请稍后再发',
  RelayCode.envelopeTooLarge => '内容太大，无法发送',
  'INTERRUPTED' => '发送被中断',
  _ => '操作未完成，请重试',
};

// 列表行里的时间：校园时区今天只显示钟点，其余显示月-日；会话里用完整时间 formatCampusTimestamp。
String socialShortTime(String iso) {
  final instant = DateTime.parse(iso);
  final day = formatCampusDate(campusInstant(instant));
  return day == campusToday() ? formatCampusClock(instant) : day.substring(5);
}

// 单行文字输入（昵称、备注）：返回 null 表示取消。validate 返回错误文案或 null。
Future<String?> showSocialTextInput(BuildContext context, {required String title, required String initial, required String hint, required int maxLength, required String action, String? Function(String value)? validate}) =>
    showCampusDialog<String>(context: context, builder: (context) => _TextInputDialog(title: title, initial: initial, hint: hint, maxLength: maxLength, action: action, validate: validate));

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({required this.title, required this.initial, required this.hint, required this.maxLength, required this.action, this.validate});
  final String title;
  final String initial;
  final String hint;
  final int maxLength;
  final String action;
  final String? Function(String value)? validate;
  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = widget.validate?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: Text(widget.title),
    content: Padding(
      padding: EdgeInsets.only(top: campusFieldGap(context)),
      child: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(labelText: widget.hint, errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _submit, child: Text(widget.action)),
    ],
  );
}
