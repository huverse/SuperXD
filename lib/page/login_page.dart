
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/account_dialogs.dart';

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
    final confirmed = await showCampusConfirm(context, title: '记住账号', action: '同意并开启',
      message: 'SuperXD本地版的记住账号功能将会把账号鉴权数据加密存储在本地，用于会话失效后自动登录。\n\n仅在此账号成功登录后保存，你可在“我的 › 账号”关闭记住账号，或退出登录清除凭据。\n\n本地加密不等于传输加密：当前教务系统使用HTTP。请只在你信任的设备和网络上启用。');
    if (mounted && confirmed) setState(() => _remember = true);
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
        campusLog('[LoginPage] action=cancel errorType=${error.runtimeType}\n$stack');
      });
    }
    super.dispose();
  }

  bool get _canLogin => _account.text.trim().isNotEmpty && _password.text.isNotEmpty && _agreed && !_busy;

  Future<void> _notice(String message) async {
    if (mounted) await showCampusNotice(context, message);
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
          builder: (context) => LoginCaptchaDialog(gateway: widget.gateway, captcha: result.data!.captcha!),
        );
        if (!mounted) return;
        if (error != null) await _notice(error);
      } else if (!result.ok) {
        await _notice(result.error?.message ?? '登录未完成');
      }
      // 成功仅由账号协调器发布新的generation，不由页面自行翻loggedIn。
    } catch (error, stack) {
      campusLog('[LoginPage] action=login errorType=${error.runtimeType}\n$stack');
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
                    style: campusProminent,
                    onPressed: _canLogin ? _login : null,
                    child: CampusBusyContent(busy: _busy, label: widget.switching ? '登录并切换' : '登录', busyLabel: widget.switching ? '正在登录并切换' : '正在登录', icon: const CampusIcon(CampusIcons.login)),
                  )),
                ])),
                if (!widget.switching) Padding(padding: const EdgeInsets.only(top: 16), child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => context.push('/toolbox'), icon: const CampusIcon(CampusIcons.toolbox), label: const Text('百宝箱'))),
                // [人工决策-2026-10-18 15:18:41] 勾选框读屏读整句「我已阅读并同意用户协议和隐私政策」（以前只念“复选框”），
                // 点「我已阅读并同意」几个字也能勾选（同常见 App 的同意行）；两个链接仍单独可点（用户从走查清单选定）。
                Padding(padding: const EdgeInsets.only(top: 24), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 48, height: 48, child: Checkbox(key: const ValueKey('agree-terms'), semanticLabel: '我已阅读并同意用户协议和隐私政策', value: _agreed, onChanged: _busy ? null : (value) => setState(() => _agreed = value == true))),
                  Expanded(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                    GestureDetector(excludeFromSemantics: true, onTap: _busy ? null : () => setState(() => _agreed = !_agreed), child: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text('我已阅读并同意', style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant)))),
                    TextButton(style: campusLink, onPressed: _busy ? null : () => context.push('/legal/service'), child: const Text('用户协议', style: TextStyle(fontSize: 14))),
                    const Text('和', style: TextStyle(fontSize: 14)),
                    TextButton(style: campusLink, onPressed: _busy ? null : () => context.push('/legal/privacy'), child: const Text('隐私政策', style: TextStyle(fontSize: 14))),
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
