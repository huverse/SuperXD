import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/domain/campus_log.dart';

Future<void> showLegacyImport(BuildContext context, AppSession session, {bool automatic = false}) async {
  final accounts = session.gateway;
  final generation = accounts.generation;
  final identity = accounts.activeIdentity;
  if (identity == null || accounts.activeSession == null) return;
  bool active() => context.mounted && accounts.generation == generation;
  try {
    final state = await accounts.legacyImportState();
    if (!context.mounted || !active() || (automatic && state.deferred)) return;
    if (!state.available) {
      if (!automatic) await showCampusNotice(context, '没有可导入的未归属旧数据。');
      return;
    }
    // [人工决策-2026-09-24 20:40:27] 旧库没有可信账号归属；本人确认后仅导入一次，不导入旧会话，不自动认领。
    final confirmed = await showCampusConfirm(
      context,
      barrierDismissible: false,
      title: state.resumable ? '继续导入旧数据？' : '确认旧数据归属',
      message: '当前账号：${identity.loginId}\n\n旧版本未记录每条缓存的账号归属，可能包含以前使用过的其他账号数据。只有确认全部旧数据属于此账号时才导入。\n\n课表、成绩、开学日、作息和历史版本会迁入这个账号，已有当前课表不被覆盖；合并后每学期最多保留100个历史版本，超限旧版本会清理；旧登录态不迁入，原文件保留。\n\n不能确认时请选择“暂不导入”，不影响正常使用。',
      cancel: '暂不导入',
      action: '确认属于我并导入',
    );
    if (!active()) return;
    if (!confirmed) {
      await accounts.deferLegacyImport();
      return;
    }
    // 操作与状态存储在应用层；完成后会话代次变化，原确认页面随路由一起销毁。
    if (!context.mounted) return;
    await showCampusWaiting(context, label: '正在导入已确认归属的数据', operation: session.importLegacy);
  } catch (error, stack) {
    campusLog('[AccountImport] errorType=${error.runtimeType}\n$stack');
    if (context.mounted && active()) await showCampusNotice(context, '旧数据导入未完成，原文件保留，请重试。');
  }
}

class LegacyImportGate extends StatefulWidget {
  const LegacyImportGate({super.key, required this.session, required this.child});
  final AppSession session;
  final Widget child;

  @override
  State<LegacyImportGate> createState() => _LegacyImportGateState();
}

class _LegacyImportGateState extends State<LegacyImportGate> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_noticeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _showNotice();
      if (mounted) await showLegacyImport(context, widget.session, automatic: true);
    });
  }

  void _noticeChanged() {
    if (widget.session.pendingNotice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _showNotice(); });
  }

  Future<void> _showNotice() async {
    final message = widget.session.takeNotice();
    if (message != null && mounted) await showCampusNotice(context, message);
  }

  @override
  void dispose() {
    widget.session.removeListener(_noticeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// 开启记住账号时要密码：学号就是当前账号，只输密码；返回空表示取消。
Future<String?> askRememberPassword(BuildContext context) => showCampusDialog<String>(context: context, builder: (context) => const _RememberPasswordDialog());

class _RememberPasswordDialog extends StatefulWidget {
  const _RememberPasswordDialog();

  @override
  State<_RememberPasswordDialog> createState() => _RememberPasswordDialogState();
}

class _RememberPasswordDialogState extends State<_RememberPasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isNotEmpty) Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: const Text('开启记住账号'),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('输入当前账号的教务密码，核对通过后保存在本机安全存储，以后自动登录。', style: TextStyle(fontSize: 14)),
      SizedBox(height: campusFieldGap(context)),
      TextField(
        controller: _password,
        obscureText: true,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(labelText: '教务密码'),
      ),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _password.text.isEmpty ? null : _submit, child: const Text('开启')),
    ],
  );
}

// 教务登录的验证码弹窗：登录页与账号页开启记住账号共用。通过后自己关（返回空）；出错带原因关，取消时撤掉这次登录尝试。
class LoginCaptchaDialog extends StatefulWidget {
  const LoginCaptchaDialog({super.key, required this.gateway, required this.captcha});
  final AccountAccess gateway;
  final CaptchaView captcha;

  @override
  State<LoginCaptchaDialog> createState() => _LoginCaptchaDialogState();
}

class _LoginCaptchaDialogState extends State<LoginCaptchaDialog> {
  late CaptchaView _captcha = widget.captcha;
  final _code = TextEditingController();
  bool _busy = false;
  bool _refreshing = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() { _busy = true; _refreshing = true; });
    try {
      final result = await widget.gateway.refreshLoginCaptcha();
      if (!mounted) return;
      if (!result.ok || result.data == null) {
        Navigator.pop(context, result.error?.message ?? '验证码刷新失败');
        return;
      }
      setState(() {
        _captcha = result.data!;
        _code.clear();
      });
    } catch (error, stack) {
      campusLog('[CaptchaDialog] action=refresh errorType=${error.runtimeType}\n$stack');
      if (mounted) Navigator.pop(context, '验证码刷新失败，请重新登录');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || _code.text.trim().isEmpty) return;
    setState(() { _busy = true; _refreshing = false; });
    try {
      final result = await widget.gateway.submitLoginCaptcha(_code.text.trim());
      if (!mounted) return;
      if (result.needsInput == 'captcha' && result.data?.captcha != null) {
        setState(() {
          _captcha = result.data!.captcha!;
          _code.clear();
        });
      } else {
        // 登录成功时账号代次变化会连弹窗一起换掉；只核对密码（开启记住账号）不换代次，要自己关。
        Navigator.pop(context, result.ok ? null : result.error?.message ?? '登录未完成');
      }
    } catch (error, stack) {
      campusLog('[CaptchaDialog] action=submit errorType=${error.runtimeType}\n$stack');
      if (mounted) Navigator.pop(context, '验证码提交未完成，请重新登录');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) {
        widget.gateway.cancelLogin().catchError((Object error, StackTrace stack) {
          campusLog('[CaptchaDialog] action=cancel errorType=${error.runtimeType}\n$stack');
        });
      }
    },
    child: CampusGlassDialog(
      solid: true,
      title: const Text('验证码'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(onTap: _busy ? null : _refresh, child: Image.memory(base64Decode(_captcha.imageBase64), height: 64, gaplessPlayback: true)),
        TextButton(onPressed: _busy ? null : _refresh, child: CampusBusyContent(busy: _busy && _refreshing, label: '刷新验证码', busyLabel: '刷新中', icon: const CampusIcon(CampusIcons.sync))),
        const SizedBox(height: 8),
        Text(_captcha.hint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        TextField(controller: _code, enabled: !_busy, onChanged: (_) => setState(() {}), style: const TextStyle(fontSize: 16), decoration: const InputDecoration(hintText: '验证码')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _busy || _code.text.trim().isEmpty ? null : _submit, child: CampusBusyContent(busy: _busy && !_refreshing, label: '确定', busyLabel: '验证中')),
      ],
    ),
  );
}
