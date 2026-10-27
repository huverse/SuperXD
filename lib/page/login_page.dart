import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_updates.dart';
import 'package:superxd/domain/painting.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/page/about_page.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/page/account_dialogs.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.gateway, required this.session, this.switching = false, this.updates, this.developer, this.logs, this.paintings});
  final AccountAccess gateway;
  final AppSession session;
  final bool switching;
  // 关于页要的应用更新、开发者模式与本机日志（设备级），没登录也能检查更新、开开发者模式。
  final AppUpdates? updates;
  final DeveloperSettings? developer;
  final DiagnosticLog? logs;
  final PaintingGallery? paintings;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  late final _generation = widget.gateway.generation;
  bool _agreed = false;
  bool _remember = false;
  bool _obscure = true;
  String? _accountError;
  String? _passwordError;
  // 没勾同意就点了登录：同意行短暂衬色提示一下（不加位移动画，同签到码输错的处理）。
  bool _nudged = false;
  Timer? _nudge;

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
    _nudge?.cancel();
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

  // [人工决策-2026-10-19 17:55:48] 登录按钮常亮（用户选定，同淘宝、支付宝）：没填的项在输入框下原地写明，没勾同意时提示并给同意行衬色，
  // 不再用置灰的按钮让人猜为什么点不了；学号、密码用浮动标签，接系统自动填充，键盘「下一项」「完成」直接登录。
  void _attempt() {
    if (_busy) return;
    final account = _account.text.trim().isEmpty, password = _password.text.isEmpty;
    if (account || password) {
      setState(() {
        _accountError = account ? '请输入学号' : null;
        _passwordError = password ? '请输入密码' : null;
      });
      return;
    }
    if (!_agreed) {
      HapticFeedback.mediumImpact();
      showCampusToast(context, '请先阅读并同意用户协议和隐私政策');
      _nudge?.cancel();
      setState(() => _nudged = true);
      _nudge = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _nudged = false);
      });
      return;
    }
    unawaited(_login());
  }

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
      // 登录成功时让系统的自动填充（密码管理器）有机会记下这对账号密码；其余情况不保存。
      if (result.ok && result.needsInput == null) TextInput.finishAutofillContext();
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

  // 同意行：「我已阅读并同意」一段、「用户协议 和 隐私政策」一组，一行放不下时整组换到第二行，不把链接拆开、不留单独一个链接；
  // 行距按文字排（每项上下各 4、链接的触区也是这么高），不再按链接 48 的触区撑开（以前换行后两行相隔一个按钮高、第二行还缩进一截）。
  // 首行与左边的勾选框居中对齐。
  Widget _agreement(BuildContext context) {
    const style = TextStyle(fontSize: 14);
    final line = campusTextPainter(context, '我', style: style);
    final top = math.max(0.0, (48 - line.height - 8) / 2);
    line.dispose();
    final link = campusLink.copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)), minimumSize: const WidgetStatePropertyAll(Size.zero), tapTargetSize: MaterialTapTargetSize.shrinkWrap);
    return Padding(padding: EdgeInsets.only(top: top), child: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      // 整句已在勾选框的读屏名里，这两段文字不再单独朗读；两个链接照常是按钮。
      ExcludeSemantics(child: GestureDetector(onTap: _busy ? null : () => setState(() => _agreed = !_agreed), child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('我已阅读并同意', style: style.copyWith(color: CampusPalette.of(context).onSurfaceVariant))))),
      Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        TextButton(style: link, onPressed: _busy ? null : () => context.push('/legal/service'), child: const Text('用户协议', style: style)),
        const ExcludeSemantics(child: Text('和', style: style)),
        TextButton(style: link, onPressed: _busy ? null : () => context.push('/legal/privacy'), child: const Text('隐私政策', style: style)),
      ]),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    return CampusBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: widget.switching ? AppBar(leading: IconButton(tooltip: '返回', onPressed: () => context.pop(), icon: const CampusIcon(CampusIcons.back)), title: const Text('切换账号'), backgroundColor: Colors.transparent) : null,
        body: CampusScrollFade(child: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: (constraints.maxHeight - 32).clamp(0, double.infinity)),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const SizedBox(height: 32),
                CampusSurface(padding: const EdgeInsets.all(20), child: Column(children: [
                  Text('SuperXD', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 32),
                  AutofillGroup(onDisposeAction: AutofillContextAction.cancel, child: Column(children: [
                    TextField(
                      controller: _account, enabled: !_busy, onChanged: (_) => setState(() => _accountError = null),
                      autofillHints: const [AutofillHints.username], textInputAction: TextInputAction.next, autocorrect: false, enableSuggestions: false,
                      style: const TextStyle(fontSize: 16), decoration: InputDecoration(labelText: '学号', errorText: _accountError),
                    ),
                    SizedBox(height: campusFieldGap(context)),
                    TextField(
                      controller: _password, obscureText: _obscure, enabled: !_busy, onChanged: (_) => setState(() => _passwordError = null),
                      autofillHints: const [AutofillHints.password], textInputAction: TextInputAction.done, onSubmitted: (_) => _attempt(),
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        labelText: '密码', errorText: _passwordError,
                        suffixIcon: IconButton(tooltip: _obscure ? '显示密码' : '隐藏密码', onPressed: () => setState(() => _obscure = !_obscure), icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed)),
                      ),
                    ),
                  ])),
                  // 文字紧跟勾选框（同下面的同意行），不按列表行默认的 16 再空一截。
                  CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, horizontalTitleGap: 0,
                    title: const Text('记住账号', style: TextStyle(fontSize: 14)), value: _remember,
                    onChanged: _busy ? null : (value) => _chooseRemember(value == true)),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: FilledButton(
                    style: campusProminent,
                    onPressed: _busy ? null : _attempt,
                    child: CampusBusyContent(busy: _busy, label: widget.switching ? '登录并切换' : '登录', busyLabel: widget.switching ? '正在登录并切换' : '正在登录', icon: const CampusIcon(CampusIcons.login)),
                  )),
                ])),
                // [人工决策-2026-10-21 23:48:00] 登录页加「关于」入口（用户要求未登录也能进开发者模式）：进的是同一个关于页，
                // 连点版本号开启、开着时有开发者选项，只有一种开启方式；未登录时也能检查更新、看协议。切换账号页不显示，同百宝箱。
                if (!widget.switching) Padding(padding: const EdgeInsets.only(top: 16), child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: _busy ? null : () => context.push('/toolbox'), icon: const CampusIcon(CampusIcons.toolbox), label: const Text('百宝箱')),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => Navigator.push(context, CampusPageRoute<void>(builder: (_) => AboutPage(updates: widget.updates, developer: widget.developer, logs: widget.logs, paintings: widget.paintings))),
                    icon: const CampusIcon(CampusIcons.info),
                    label: const Text('关于'),
                  ),
                ])),
                // [人工决策-2026-10-18 15:18:41] 勾选框读屏读整句「我已阅读并同意用户协议和隐私政策」（以前只念“复选框”），
                // 点「我已阅读并同意」几个字也能勾选（同常见 App 的同意行）；两个链接仍单独可点（用户从走查清单选定）。
                Padding(padding: const EdgeInsets.only(top: 24), child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                  decoration: BoxDecoration(color: _nudged ? CampusPalette.of(context).surfaceSelected : CampusPalette.of(context).surfaceSelected.withValues(alpha: 0), borderRadius: BorderRadius.circular(12)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 48, height: 48, child: Checkbox(key: const ValueKey('agree-terms'), semanticLabel: '我已阅读并同意用户协议和隐私政策', value: _agreed, onChanged: _busy ? null : (value) => setState(() => _agreed = value == true))),
                  Expanded(child: _agreement(context)),
                ]))),
              ]),
            ),
          )),
        )),
      ),
    );
  }
}
