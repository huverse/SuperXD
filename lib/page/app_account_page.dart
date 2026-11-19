import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:superxd/application/account_diagnostics.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/festivals.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/page/app_account_join_page.dart';
import 'package:superxd/page/developer_notes_page.dart';
import 'package:superxd/page/diagnostic_uploads_page.dart';
import 'package:superxd/page/festival/festival_reward.dart';
import 'package:superxd/page/sensitive_clipboard.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 应用账号页（人工决策见 domain/app_account.dart 的 11-15 16:40:33 那条）：与教务各管各的，没登录教务也能进（游乐场、私信、节日提示都推它）。
// 没登录：登录 / 注册两段，「忘记密码」用恢复码重设，「扫码登录」让已登录的手机批准；注册与重设成功后弹出恢复码让用户抄下。
// 登录着：用户名、改密码、换恢复码、让新设备登录、我上传的诊断包（配了诊断包上传才有），退出与注销各自单独一组放最底，都先确认。
// [人工决策-2026-11-16 22:24:59] 最上面是联网偏好（联网化 / 本地化，规则见 domain/network_policy.dart；用户 17:05:21 选定与娱乐与积分的开关合成一个放在这页）：
// 本地化时不显示登录与账号管理（登录保留、只是不联网），只写一句暂停；最底下单独一组红字「删除游乐场与积分的数据」（从原来的游乐场与积分设置页挪来）。
// [人工决策-2026-11-17 21:24:25] 设计审查后用户选定（位置与规则不变）：叫法改成「联网 / 仅本机」（取代上一条的「联网化 / 本地化」，「本地化」常被读成翻译成本地语言），
// 分段上面加组标题「联网偏好」（同界面页的小节标题，和下面的「登录 | 注册」分得开）；退出与注销各自单独一组、居中红字（同教务账号页的退出登录、iOS 的退出与删除账户），
// 删除数据那一组同样居中红字，改叫「删除游乐场与积分」（11-17 主会话改：设计包缩成的「删除游乐场数据」漏了积分；原来的长名字在窄屏大字号下折成两行）。
// [人工决策-2026-11-19 13:09:34] 「我的」页的开发者的话与节日红包并进这页（用户选「合成一行应用账号」，见 page/section_pages.dart 的 MinePage）：
// 最上面一组「开发者的话」（有信才有，没读的带小圆点）与「我的红包」（有奖品才有，点开同原来「我的」页那一行），没登录、仅本机也看得到。
class AppAccountPage extends StatefulWidget {
  const AppAccountPage({super.key, required this.appAccounts, this.diagnostics, this.network, this.leisure, this.notes, this.festivals, this.saveRewardPicture, this.scanJoin = scanJoinWithCamera});
  final AppAccounts appAccounts;
  // 开发者的话与节日奖品（设备级，没配中转或没有内容时不显示那一行）。
  final DeveloperNotes? notes;
  final Festivals? festivals;
  final Future<bool> Function(Uint8List png)? saveRewardPicture;
  final AccountDiagnostics? diagnostics;
  // 联网偏好（测试里可以没有，当联网）与游乐场与积分的删除数据（没有就不显示那一组）。
  final NetworkPreference? network;
  final Leisure? leisure;
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
      listenable: Listenable.merge([_accounts, ?widget.network, ?widget.notes, ?widget.festivals]),
      builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
        ..._inbox(context),
        if (widget.network case final network?) ..._preference(context, network),
        if (widget.network?.online == false)
          ..._paused(context)
        else if (_accounts.username == null)
          ..._signedOut(context)
        else
          ..._signedIn(context),
        if (widget.leisure case final leisure?) ..._deleteData(context, leisure),
      ]),
    ))))),
  );

  // 开发者的话与我的红包（人工决策见类上 11-19 那条）：两行都没有时整组不画。
  List<Widget> _inbox(BuildContext context) {
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    final notes = widget.notes, festivals = widget.festivals;
    final prize = festivals?.prizes.lastOrNull;
    final rows = [
      if (notes != null && notes.notes.isNotEmpty)
        ListTile(
          contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.letter), title: const Text('开发者的话'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (notes.unread) ...[Semantics(label: '有新的', child: UnreadDot(color: CampusPalette.of(context).dangerFill)), const SizedBox(width: CampusGap.medium)],
            const CampusIcon(CampusIcons.next),
          ]),
          onTap: () => Navigator.of(context).push(CampusPageRoute<void>(builder: (_) => DeveloperNotesPage(notes: notes))),
        ),
      if ((festivals, prize) case (final festivals?, final prize?))
        // 还没揭晓的（动画放完时结果还没回来）在这里打开也照样拆红包。
        ListTile(
          contentPadding: rowPadding, leading: const CampusIcon(CampusIcons.gift), title: const Text('我的红包'), trailing: const CampusIcon(CampusIcons.next),
          onTap: () {
            if (!prize.revealed) festivals.markRevealed(prize);
            showFestivalReward(context, prize: prize, title: festivals.occasionName(prize.occasion), envelope: !prize.revealed, saveQrCode: widget.saveRewardPicture);
          },
        ),
    ];
    if (rows.isEmpty) return const [];
    return [CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: rows)), const Padding(padding: EdgeInsets.only(top: 16))];
  }

  // 联网偏好：改为仅本机先确认写明关掉哪些、本机都留着；改回联网不用确认。组标题是读屏的小节标题。
  List<Widget> _preference(BuildContext context, NetworkPreference network) => [
    CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(header: true, child: Text('联网偏好', style: Theme.of(context).textTheme.titleLarge)),
      const SizedBox(height: CampusGap.medium),
      CampusSegmented<NetworkMode>(
        values: NetworkMode.values,
        selected: network.mode,
        label: (mode) => mode == NetworkMode.online ? '联网' : '仅本机',
        onSelected: (mode) => unawaited(_switchMode(network, mode)),
      ),
    ])),
    const Padding(padding: EdgeInsets.only(top: 16)),
  ];

  Future<void> _switchMode(NetworkPreference network, NetworkMode mode) async {
    if (mode == network.mode) return;
    if (mode == NetworkMode.local) {
      // 长文案：切到仅本机要写清哪些服务停下、本机的账号与记录都留着。
      const message = '应用账号、经服务器的私信、挑战积分与解锁、节日抽奖和健康回报都不再联网；本机的账号与记录都留着，随时可以改回来。';
      final confirmed = await showCampusConfirm(context, title: '改为仅本机？', message: message, action: '改为仅本机');
      if (!mounted || !confirmed) return;
    }
    await network.setMode(mode);
    if (mounted) showCampusToast(context, mode == NetworkMode.local ? '已改为仅本机' : '已改为联网');
  }

  // 仅本机时：登录着的写用户名与暂停，没登录什么也不写。
  List<Widget> _paused(BuildContext context) {
    final username = _accounts.username;
    if (username == null) return const [];
    final colors = CampusPalette.of(context);
    return [
      CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
        CircleAvatar(radius: 28, backgroundColor: colors.surfaceSelected, child: CampusIcon(CampusIcons.mainAccount, color: colors.onSurfaceVariant, size: 28)),
        const Padding(padding: EdgeInsets.only(left: 16)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(username, style: Theme.of(context).textTheme.titleLarge),
          Text('仅本机时暂停使用', style: Theme.of(context).textTheme.bodyMedium),
        ])),
      ])),
    ];
  }

  // 游乐场与积分的删除数据（原来在游乐场与积分设置页，人工决策见 domain/leisure.dart）：先确认写明删哪些；联网且登录着应用账号时连服务器上的一起删，没删成本机也不动。
  List<Widget> _deleteData(BuildContext context, Leisure leisure) => [
    const Padding(padding: EdgeInsets.only(top: 16)),
    _DangerRow(icon: CampusIcons.delete, label: '删除游乐场与积分', enabled: !_accounts.busy, onTap: () => unawaited(_delete(leisure))),
  ];

  Future<void> _delete(Leisure leisure) async {
    final username = _accounts.username;
    // 长文案：删除确认要写清删哪些数据、删了不能恢复。
    final message = leisure.signedIn ? '本机的游戏成绩与笔记，以及应用账号 $username 在服务器上的积分、挑战成绩与解锁记录都会删除，不能恢复。'
        // 长文案：仅本机或没登录应用账号时要说明服务器上的积分不在这次删除里。
        : '本机的游戏成绩与笔记会删除，不能恢复；服务器上的积分要改为联网并登录应用账号后才能删。';
    final confirmed = await showCampusConfirm(context, title: '删除游乐场与积分？', message: message, action: '删除', destructive: true);
    if (!mounted || !confirmed) return;
    String? failure;
    await showCampusWaiting(context, label: '正在删除', operation: () async {
      try {
        await leisure.deleteData();
      } on ChallengeException catch (error) {
        failure = error.message;
      }
    });
    if (!mounted) return;
    if (failure case final message?) return showCampusNotice(context, message);
    showCampusToast(context, '已删除');
  }

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
      // 退出与注销各自单独一组、居中红字（人工决策见文件头 11-17 那条）。
      const SizedBox(height: 16),
      _DangerRow(icon: CampusIcons.logout, label: '退出应用账号', enabled: enabled, onTap: () => _leave(deleting: false)),
      const SizedBox(height: 16),
      _DangerRow(icon: CampusIcons.delete, label: '注销应用账号', enabled: enabled, onTap: () => _leave(deleting: true)),
    ];
  }
}

// 页面最底下单独一组的破坏性操作（同教务账号页的「退出登录」）：整行可点、图标与红字居中，放不下一行时均衡折行。
class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.icon, required this.label, required this.enabled, required this.onTap});
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final danger = CampusPalette.of(context).danger;
    return CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20), enabled: enabled, onTap: onTap,
      title: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        CampusIcon(icon, color: danger), const SizedBox(width: CampusGap.small),
        Flexible(child: BalancedText(label, style: TextStyle(color: danger))),
      ]),
    ));
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
