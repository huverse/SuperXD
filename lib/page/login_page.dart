import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.gateway, required this.session, this.switching = false});
  final AccountAccess gateway;
  final AppSession session;
  final bool switching;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  late final _generation = widget.gateway.generation;
  bool _agreed = false;
  bool _remember = false;

  Future<void> _chooseRemember(bool value) async {
    if (!value) { setState(() => _remember = false); return; }
    final confirmed = await showCampusDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('记住账号'),
      scrollable: true,
      content: const Text('SuperXD本地版的记住账号功能将会把账号鉴权数据加密存储在本地，用于会话失效后自动登录。\n\n仅在此账号成功登录后保存，你可在“我的”关闭记住账号，或退出登录清除凭据。\n\n本地加密不等于传输加密：当前教务系统使用HTTP。请只在你信任的设备和网络上启用。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('同意并开启'))],
    ));
    if (mounted && confirmed == true) setState(() => _remember = true);
  }
  bool _busy = false;
  bool _attemptStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.switching) return;
      final message = widget.session.takeNotice();
      if (message != null) await _notice(message);
    });
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    if (_attemptStarted && _generation == widget.gateway.generation) {
      widget.gateway.cancelLogin().catchError((Object error, StackTrace stack) {
        debugPrint('[LoginPage] action=cancel errorType=${error.runtimeType}\n$stack');
      });
    }
    super.dispose();
  }

  bool get _canLogin => _account.text.trim().isNotEmpty && _password.text.isNotEmpty && _agreed && !_busy;

  Future<void> _notice(String message) async {
    if (!mounted) return;
    await showCampusDialog<void>(context: context, builder: (context) => AlertDialog(
      content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
    ));
  }

  Future<void> _login() async {
    if (!_canLogin) return;
    setState(() => _busy = true);
    _attemptStarted = true;
    try {
      final result = await widget.gateway.loginRemembered(_account.text.trim(), _password.text, remember: _remember);
      if (!mounted) return;
      _password.clear();
      setState(() => _busy = false);
      if (result.needsInput == 'captcha' && result.data?.captcha != null) {
        final error = await showCampusDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _CaptchaDialog(gateway: widget.gateway, captcha: result.data!.captcha!),
        );
        if (!mounted) return;
        if (error != null) await _notice(error);
      } else if (!result.ok && result.error?.code != 'LOGIN_CANCELLED') {
        await _notice(result.error?.message ?? '登录未完成');
      }
      // 成功仅由账号协调器发布新的generation，不由页面自行翻loggedIn。
    } catch (error, stack) {
      debugPrint('[LoginPage] action=login errorType=${error.runtimeType}\n$stack');
      if (mounted) {
        _password.clear();
        await _notice('登录未完成，请重试；原账号数据未删除。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CampusBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: widget.switching ? AppBar(leading: IconButton(tooltip: '返回', onPressed: () => context.pop(), icon: const CampusIcon(CampusIcons.back)), title: const Text('切换账号'), backgroundColor: Colors.transparent) : null,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: (constraints.maxHeight - 32).clamp(0, double.infinity)),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const SizedBox(height: 32),
                CampusSurface(padding: const EdgeInsets.all(20), child: Column(children: [
                  Text('SuperXD', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _account, enabled: !_busy, onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 16), decoration: const InputDecoration(hintText: '账号'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password, obscureText: true, enabled: !_busy, onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 16), decoration: const InputDecoration(hintText: '密码'),
                  ),
                  CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('记住账号', style: TextStyle(fontSize: 14)), value: _remember,
                    onChanged: _busy ? null : (value) => _chooseRemember(value == true)),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: FilledButton(
                    onPressed: _canLogin ? _login : null,
                    child: CampusBusyContent(busy: _busy, label: widget.switching ? '登录并切换' : '登录', busyLabel: widget.switching ? '正在登录并切换' : '正在登录'),
                  )),
                ])),
                if (!widget.switching) Padding(padding: const EdgeInsets.only(top: 16), child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => context.push('/toolbox'), icon: const CampusIcon(CampusIcons.toolbox), label: const Text('百宝箱'))),
                Padding(padding: const EdgeInsets.only(top: 24), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 48, height: 48, child: Checkbox(key: const ValueKey('agree-terms'), value: _agreed, onChanged: _busy ? null : (value) => setState(() => _agreed = value == true))),
                  Expanded(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('我已阅读并同意', style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant)),
                    TextButton(onPressed: _busy ? null : () => context.push('/legal/service'), child: const Text('服务协议', style: TextStyle(fontSize: 14))),
                    const Text('和', style: TextStyle(fontSize: 14)),
                    TextButton(onPressed: _busy ? null : () => context.push('/legal/privacy'), child: const Text('隐私政策', style: TextStyle(fontSize: 14))),
                  ])),
                ])),
              ]),
            ),
          )),
        ),
      ),
    );
  }
}

class _CaptchaDialog extends StatefulWidget {
  const _CaptchaDialog({required this.gateway, required this.captcha});
  final AccountAccess gateway;
  final CaptchaView captcha;

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
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
      debugPrint('[CaptchaDialog] action=refresh errorType=${error.runtimeType}\n$stack');
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
      } else if (!result.ok) {
        Navigator.pop(context, result.error?.message ?? '登录未完成');
      }
    } catch (error, stack) {
      debugPrint('[CaptchaDialog] action=submit errorType=${error.runtimeType}\n$stack');
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
          debugPrint('[CaptchaDialog] action=cancel errorType=${error.runtimeType}\n$stack');
        });
      }
    },
    child: AlertDialog(
      backgroundColor: CampusPalette.of(context).surface,
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
