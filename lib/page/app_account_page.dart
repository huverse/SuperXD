import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/page/app_account_join_page.dart';
import 'package:superxd/page/diagnostic_uploads_page.dart';
import 'package:superxd/page/sensitive_clipboard.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 应用账号页（人工决策见 domain/app_account.dart 的 11-15 16:40:33 那条）：与教务各管各的，没登录教务也能进（游乐场、私信、节日提示都推它）。
// 没登录：登录 / 注册两段，「忘记密码」用恢复码重设，「扫码登录」让已登录的手机批准；注册与重设成功后弹出恢复码让用户抄下。
// 登录着：用户名、改密码、换恢复码、让新设备登录、我上传的诊断包（配了诊断包上传才有），退出与注销单独一组放最底，都先确认。
class AppAccountPage extends StatefulWidget {
  const AppAccountPage({super.key, required this.appAccounts, this.diagnostics, this.scanJoin = scanJoinWithCamera});
  final AppAccounts appAccounts;
  final AccountDiagnostics? diagnostics;
  // 让新设备登录时扫码的入口（测试注入假扫码）。
  final JoinScanner scanJoin;

  @override
  State<AppAccountPage> createState() => _AppAccountPageState();
}

enum _Mode { login, register, recover }

class _AppAccountPageState extends State<AppAccountPage> {
  _Mode _mode = _Mode.login;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _recovery = TextEditingController();
  bool _obscure = true;
  String? _usernameError, _passwordError, _recoveryError;

  AppAccounts get _accounts => widget.appAccounts;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _recovery.dispose();
    super.dispose();
  }

  void _clearErrors() => setState(() => _usernameError = _passwordError = _recoveryError = null);

  // 本机先查格式（不合格不联网），再交给编排；注册与重设成功后弹出恢复码。
  Future<void> _submit() async {
    final username = _username.text, password = _password.text;
    final usernameError = validAppUsername(username) ? null : '3–20 位字母、数字或下划线';
    final passwordError = validAppPassword(password) ? null : '$appPasswordMin–$appPasswordMax 个字符';
    final recoveryError = _mode != _Mode.recover || normalizeRecoveryCode(_recovery.text) != null ? null : '恢复码不对';
    if (usernameError != null || passwordError != null || recoveryError != null) {
      setState(() {
        _usernameError = usernameError;
        _passwordError = passwordError;
        _recoveryError = recoveryError;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    final result = await switch (_mode) {
      _Mode.login => _accounts.login(username, password),
      _Mode.register => _accounts.register(username, password),
      _Mode.recover => _accounts.recover(username, _recovery.text, password),
    };
    if (!mounted) return;
    // 成功才清掉密码与恢复码、回到「登录」（退出后再进来是登录）；失败留着让用户改一处再交。
    if (result is! AppAccountError) {
      _password.clear();
      _recovery.clear();
      setState(() => _mode = _Mode.login);
    }
    await _show(result);
  }

  Future<void> _show(AppAccountResult result) async {
    switch (result) {
      case AppAccountRecoveryCode(:final code, :final notice):
        await showRecoveryCode(context, code);
        if (mounted) showCampusToast(context, notice);
      case AppAccountDone(:final notice?):
        showCampusToast(context, notice);
      case AppAccountError(:final message):
        await showCampusNotice(context, message);
      default:
        break;
    }
  }

  Future<void> _joinWithQr() async {
    final joined = await Navigator.of(context).push<bool>(CampusPageRoute(builder: (_) => AppAccountJoinPage(appAccounts: _accounts)));
    if (mounted && joined == true) showCampusToast(context, '已登录应用账号');
  }

  Future<void> _changePassword() async {
    final password = await showCampusDialog<String>(context: context, builder: (context) => const _NewPasswordDialog());
    if (!mounted || password == null) return;
    await _show(await showCampusWaiting(context, label: '正在修改密码', operation: () => _accounts.changePassword(password)));
  }

  Future<void> _renewRecoveryCode() async {
    final confirmed = await showCampusConfirm(context, title: '换新的恢复码？', message: '原来的恢复码会作废。', action: '换新的');
    if (!mounted || !confirmed) return;
    await _show(await showCampusWaiting(context, label: '正在换新的恢复码', operation: _accounts.renewRecoveryCode));
  }

  Future<void> _leave({required bool deleting}) async {
    final confirmed = await showCampusConfirm(
      context,
      title: deleting ? '注销应用账号？' : '退出应用账号？',
      // 长文案：注销的删除确认。
      message: deleting ? '服务器上的应用账号、所有设备上的登录，以及账号下的积分、私信好友与诊断包都会删除，这台手机上的私信记录也一并清掉，不能恢复。' : '这台设备不再登录应用账号，可以用用户名和密码再登录。',
      action: deleting ? '注销' : '退出',
      destructive: true,
    );
    if (!mounted || !confirmed) return;
    await _show(await showCampusWaiting(context, label: deleting ? '正在注销应用账号' : '正在退出应用账号', operation: deleting ? _accounts.deleteAccount : _accounts.signOut));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      title: const Text('应用账号'),
    ),
    body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListenableBuilder(
      listenable: _accounts,
      builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: _accounts.username == null ? _signedOut(context) : _signedIn(context)),
    ))))),
  );

  List<Widget> _signedOut(BuildContext context) {
    final busy = _accounts.busy;
    const fieldStyle = TextStyle(fontSize: 16);
    return [
      CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_mode == _Mode.recover)
          Text('用恢复码重设密码', style: Theme.of(context).textTheme.titleMedium)
        else
          CampusSegmented<_Mode>(
            values: const [_Mode.login, _Mode.register],
            selected: _mode,
            label: (mode) => mode == _Mode.login ? '登录' : '注册',
            onSelected: busy ? null : (mode) => setState(() {
              _mode = mode;
              _usernameError = _passwordError = _recoveryError = null;
            }),
          ),
        SizedBox(height: campusFieldGap(context) + 8),
        AutofillGroup(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _username, enabled: !busy, onChanged: (_) => _clearErrors(),
            autofillHints: [_mode == _Mode.register ? AutofillHints.newUsername : AutofillHints.username], textInputAction: TextInputAction.next,
            autocorrect: false, enableSuggestions: false, style: fieldStyle,
            decoration: InputDecoration(labelText: '用户名', errorText: _usernameError),
          ),
          if (_mode == _Mode.recover) ...[
            SizedBox(height: campusFieldGap(context)),
            TextField(
              controller: _recovery, enabled: !busy, onChanged: (_) => _clearErrors(), textInputAction: TextInputAction.next,
              autocorrect: false, enableSuggestions: false, textCapitalization: TextCapitalization.characters, style: fieldStyle,
              decoration: InputDecoration(labelText: '恢复码', errorText: _recoveryError),
            ),
          ],
          SizedBox(height: campusFieldGap(context)),
          TextField(
            controller: _password, obscureText: _obscure, enabled: !busy, onChanged: (_) => _clearErrors(),
            autofillHints: [_mode == _Mode.login ? AutofillHints.password : AutofillHints.newPassword], textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_submit()), style: fieldStyle,
            decoration: InputDecoration(
              labelText: _mode == _Mode.login ? '密码' : '新密码', errorText: _passwordError,
              suffixIcon: IconButton(tooltip: _obscure ? '显示密码' : '隐藏密码', onPressed: () => setState(() => _obscure = !_obscure), icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed)),
            ),
          ),
        ])),
        const SizedBox(height: 16),
        FilledButton(
          style: campusProminent,
          onPressed: busy ? null : _submit,
          child: CampusBusyContent(
            busy: busy,
            label: switch (_mode) { _Mode.login => '登录', _Mode.register => '注册', _Mode.recover => '重设并登录' },
            busyLabel: switch (_mode) { _Mode.login => '正在登录', _Mode.register => '正在注册', _Mode.recover => '正在重设' },
            icon: CampusIcon(_mode == _Mode.register ? CampusIcons.add : CampusIcons.login),
          ),
        ),
      ])),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        if (_mode == _Mode.recover)
          OutlinedButton.icon(onPressed: busy ? null : () => setState(() => _mode = _Mode.login), icon: const CampusIcon(CampusIcons.back), label: const Text('返回登录'))
        else
          OutlinedButton.icon(onPressed: busy ? null : () => setState(() => _mode = _Mode.recover), icon: const CampusIcon(CampusIcons.key), label: const Text('忘记密码')),
        OutlinedButton.icon(onPressed: busy ? null : _joinWithQr, icon: const CampusIcon(CampusIcons.qrCode), label: const Text('扫码登录')),
      ]),
    ];
  }

  List<Widget> _signedIn(BuildContext context) {
    final colors = CampusPalette.of(context);
    final enabled = !_accounts.busy;
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    final diagnostics = widget.diagnostics;
    return [
      CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
        CircleAvatar(radius: 28, backgroundColor: colors.surfaceSelected, child: CampusIcon(CampusIcons.mainAccount, color: colors.primary, size: 28)),
        const SizedBox(width: 16),
        Expanded(child: Text(_accounts.username!, style: Theme.of(context).textTheme.titleLarge)),
      ])),
      const SizedBox(height: 16),
      CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
        ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.lock), trailing: const CampusIcon(CampusIcons.next), title: const Text('修改密码'), enabled: enabled, onTap: _changePassword),
        ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.key), trailing: const CampusIcon(CampusIcons.next), title: const Text('换新的恢复码'), enabled: enabled, onTap: _renewRecoveryCode),
        ListTile(
          contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.scan), trailing: const CampusIcon(CampusIcons.next), title: const Text('让新设备登录'), enabled: enabled,
          onTap: () => approveAppAccountJoin(context, _accounts, scan: widget.scanJoin),
        ),
        if (diagnostics != null) ListTile(
          contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.send), trailing: const CampusIcon(CampusIcons.next), title: const Text('我上传的诊断包'), enabled: enabled,
          onTap: () => unawaited(Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => DiagnosticUploadsPage(diagnostics: diagnostics)))),
        ),
      ])),
      const SizedBox(height: 16),
      CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
        ListTile(contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.logout), title: const Text('退出应用账号'), enabled: enabled, onTap: () => _leave(deleting: false)),
        ListTile(
          contentPadding: rowPadding, leading: CampusIcon(CampusIcons.delete, color: colors.danger), title: Text('注销应用账号', style: TextStyle(color: colors.danger)), enabled: enabled,
          onTap: () => _leave(deleting: true),
        ),
      ])),
    ];
  }
}

// 恢复码只显示这一次：分组写出、可复制（标成敏感内容、一分钟后清掉，见 sensitive_clipboard.dart），点「我已保存」才关（按返回不关，免得没抄就没了）。
Future<void> showRecoveryCode(BuildContext context, String code) => showCampusDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => PopScope(canPop: false, child: CampusGlassDialog(
    title: const Text('保存恢复码'),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // 三组一行、固定两行（自动折行会在组中间断开，不好抄）；复制的是一行的写法。
      SelectableText(formatRecoveryCode(code).split('-').indexed.map((group) => group.$1 == 3 ? '\n${group.$2}' : group.$1 == 0 ? group.$2 : '-${group.$2}').join(), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      const BalancedText('忘了密码时凭它重设，只显示这一次。'),
    ]),
    actions: [
      TextButton(
        onPressed: () async {
          await copySensitive(formatRecoveryCode(code));
          if (context.mounted) showCampusToast(context, '已复制恢复码');
        },
        child: const Text('复制'),
      ),
      FilledButton(onPressed: () => Navigator.pop(context), child: const Text('我已保存')),
    ],
  )),
);

// 登录着改密码：输一次新密码（看得见的切换在框里），不合格原地说明。
class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog();

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _password = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (validAppPassword(_password.text)) return Navigator.pop(context, _password.text);
    setState(() => _error = '$appPasswordMin–$appPasswordMax 个字符');
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: const Text('修改密码'),
    content: Padding(padding: EdgeInsets.only(top: campusFieldGap(context) / 2), child: TextField(
      controller: _password, obscureText: _obscure, autofocus: true, onChanged: (_) => setState(() => _error = null),
      autofillHints: const [AutofillHints.newPassword], onSubmitted: (_) => _submit(), style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        labelText: '新密码', errorText: _error,
        suffixIcon: IconButton(tooltip: _obscure ? '显示密码' : '隐藏密码', onPressed: () => setState(() => _obscure = !_obscure), icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed)),
      ),
    )),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _submit, child: const Text('修改')),
    ],
  );
}
