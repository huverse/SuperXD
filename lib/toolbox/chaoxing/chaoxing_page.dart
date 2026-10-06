import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_group_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_history_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_share_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_sheet.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 扫别人的代签码：扫到就导入，导入前把「本机会保存对方的账号与凭据」说清楚。
// 抽成独立函数便于测试直接驱动这条流程（菜单在测试环境里的定位不可靠）。
Future<void> importChaoxingTicket(
  BuildContext context, {
  required ChaoxingController controller,
  ToolboxQrScan? scan,
}) async {
  if (scan == null) {
    await showCampusNotice(context, '当前版本不能扫码，请让对方出示代签码后再试');
    return;
  }
  final raw = await scan(
    context,
    '把对方的代签二维码放入框内',
    (value) => decodeChaoxingPackTicket(value) == null ? '这不是学习通代签二维码' : null,
  );
  if (raw == null || !context.mounted) return;
  final agreed = await showCampusConfirm(
    context,
    title: '导入代签账号',
    message: '导入后本机会保存对方的手机号、登录凭据与设备码，用来替他签到；对方改了密码要重新导入。你可以在账号菜单里随时删掉。',
    action: '导入',
  );
  if (!agreed || !context.mounted) return;
  try {
    final record = await controller.importCredentialTicket(raw);
    if (context.mounted) showCampusToast(context, '已导入 ${record.name}');
  } on ChaoxingFailure catch (failure) {
    if (context.mounted) await showCampusNotice(context, failure.message);
  } catch (failure, stack) {
    campusLog('[Chaoxing] action=import errorType=${failure.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '导入没完成，请稍后重试');
  }
}

// 首次登录前的第三方说明；条款版本变了要重新征得同意。
const chaoxingConsentService = 'chaoxing';
const chaoxingConsentVersion = 'chaoxing-sign-1';

class ChaoxingPage extends StatefulWidget {
  const ChaoxingPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<ChaoxingPage> createState() => _ChaoxingPageState();
}

class _ChaoxingPageState extends State<ChaoxingPage> {
  // 账号闭环要等运行时打开本机库之后才能建，所以先为空。
  ChaoxingController? _controller;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.runtime.initialize();
      final accounts = widget.runtime.chaoxing;
      if (accounts == null) throw const ToolboxException('学习通签到暂不可用');
      final controller = ChaoxingController(accounts: accounts, hub: widget.runtime.chaoxingHub);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.initialize();
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=start errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _startError = '学习通签到暂时打不开，请稍后重试');
    }
  }

  Future<bool> _grantConsent() async {
    final store = widget.runtime.store;
    if (await store.consent(chaoxingConsentService, chaoxingConsentVersion)) return true;
    if (!mounted) return false;
    final agreed = await showCampusConfirm(
      context,
      title: '登录学习通',
      message: 'SuperXD 会把你的学习通账号与密码保存在本机安全存储，用于登录超星学习通（chaoxing.com）并提交签到；'
          '签到时的位置、照片与账号信息会发送给学习通。选签到位置时可以用高德地图（会打开高德 SDK 加载地图），'
          '应用不申请定位权限。本功能与教务账号无关，也不会读取教务密码。',
      action: '同意并登录',
    );
    if (!agreed || !mounted) return false;
    await store.grantConsent(chaoxingConsentService, chaoxingConsentVersion);
    return true;
  }

  Future<void> _signIn(String phoneNumber, String password) async {
    final controller = _controller;
    if (controller == null) return;
    if (!await _grantConsent()) return;
    await controller.signIn(phoneNumber, password);
    if (!mounted) return;
    if (controller.error == null) showCampusToast(context, '已登录');
  }

  Future<void> _sign(ChaoxingActivity activity) async {
    final controller = _controller;
    if (controller == null) return;
    final result = await showChaoxingSignSheet(
      context,
      controller: controller,
      activity: activity,
      scanQrCode: widget.runtime.scanQrCode,
    );
    if (!mounted || result == null) return;
    showCampusToast(context, result.late ? '签到成功，不过已经迟到' : '签到成功');
    await controller.refresh();
  }

  Future<void> _accountMenu(BuildContext anchor) async {
    final controller = _controller;
    final record = controller?.current;
    if (controller == null || record == null) return;
    // 代签要靠自建中转转交凭据包，没配中转时不显示这两项。
    final canDelegate = widget.runtime.chaoxingHub?.available ?? false;
    final action = await showCampusMenu<String>(
      anchor,
      items: [
        if (controller.accountList.length > 1)
          const CampusMenuItem(value: 'switch', label: '切换账号', icon: CampusIcons.switchAccount),
        const CampusMenuItem(value: 'signIn', label: '登录其他账号', icon: CampusIcons.add),
        if (canDelegate)
          const CampusMenuItem(value: 'ticket', label: '出示我的代签码', icon: CampusIcons.qrCode),
        if (canDelegate)
          const CampusMenuItem(value: 'import', label: '扫别人的代签码', icon: CampusIcons.scan),
        CampusMenuItem(value: 'remove', label: '删除该账号', icon: CampusIcons.delete, destructive: true),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'switch':
        await _pickAccount(controller);
      case 'signIn':
        await _addAccount();
      case 'ticket':
        await showChaoxingTicketPage(context, controller: controller);
      case 'import':
        await _importTicket(controller);
      case 'remove':
        await _removeAccount(controller, record);
    }
  }

  Future<void> _importTicket(ChaoxingController controller) =>
      importChaoxingTicket(context, controller: controller, scan: widget.runtime.scanQrCode);

  Future<void> _pickAccount(ChaoxingController controller) async {
    await showCampusSheet<void>(
      context: context,
      builder: (context) => CampusSheetPanel(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(child: Text('切换账号', style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const CampusIcon(CampusIcons.close),
                    ),
                  ],
                ),
              ),
              for (final item in controller.accountList)
                ListTile(
                  title: Text(item.name, style: const TextStyle(fontSize: 16)),
                  subtitle: Text(
                    '${item.schoolName.isEmpty ? '学习通' : item.schoolName} · ${item.phoneNumber}${item.isOtherUser ? ' · 他人账号' : ''}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: item.phoneNumber == controller.current?.phoneNumber ? const CampusIcon(CampusIcons.check) : null,
                  onTap: () {
                    Navigator.pop(context);
                    controller.select(item).catchError((Object error, StackTrace stack) {
                      campusLog('[Chaoxing] action=select errorType=${error.runtimeType}\n$stack');
                    });
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addAccount() async {
    final credentials = await showCampusSheet<({String phoneNumber, String password})>(
      context: context,
      builder: (context) => const ChaoxingLoginForm(compact: true),
    );
    if (!mounted || credentials == null) return;
    await _signIn(credentials.phoneNumber, credentials.password);
  }

  Future<void> _removeAccount(ChaoxingController controller, ChaoxingAccountRecord record) async {
    final agreed = await showCampusConfirm(
      context,
      title: '删除${record.name}？',
      message: '会删除本机保存的账号、密码与签到记录，不影响学习通上的数据。',
      action: '删除',
      destructive: true,
    );
    if (!agreed || !mounted) return;
    await controller.removeAccount(record);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('学习通签到'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              Navigator.pop(context);
            }
          },
          icon: const CampusIcon(CampusIcons.back),
        ),
      ),
      body: switch ((controller, _startError)) {
        (final ChaoxingController value, _) => ListenableBuilder(
          listenable: value,
          builder: (context, _) => switch (value.status) {
            ChaoxingStatus.loading => const CampusLoading(label: '正在读取账号…'),
            ChaoxingStatus.signedOut => ChaoxingLoginForm(onSubmit: _signIn, busy: value.busy),
            ChaoxingStatus.ready => _readyBody(context, value),
          },
        ),
        (null, final String message) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, style: const TextStyle(fontSize: 16)),
          ),
        ),
        _ => const CampusLoading(label: '正在准备…'),
      },
    );
  }

  Widget _readyBody(BuildContext context, ChaoxingController controller) {
    final palette = CampusPalette.of(context);
    return CampusScrollFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          CampusSurface(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.current?.name ?? '学习通账号',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if ((controller.current?.schoolName ?? '').isNotEmpty) controller.current!.schoolName,
                          controller.current?.phoneNumber ?? '',
                        ].join(' · '),
                        style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                // 菜单按 anchor 控件的矩形定位，必须把按钮自己的 context 传进去；
                // 传整页的 context 会让菜单算成「从整页弹出」，落到屏幕左下角。
                Builder(
                  builder: (menuAnchor) => IconButton(
                    tooltip: '账号操作',
                    onPressed: () => _accountMenu(menuAnchor),
                    icon: const CampusIcon(CampusIcons.manage),
                  ),
                ),
              ],
            ),
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 12),
            Text(controller.error!, style: TextStyle(fontSize: 14, color: palette.danger)),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  '进行中的签到',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface),
                ),
              ),
              IconButton(
                tooltip: '从群聊里找签到',
                onPressed: controller.busy
                    ? null
                    : () => showChaoxingGroupPage(
                        context,
                        controller: controller,
                        scanQrCode: widget.runtime.scanQrCode,
                      ),
                icon: const CampusIcon(CampusIcons.messages),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: controller.busy
                    ? null
                    : () {
                        controller.refresh().catchError((Object error, StackTrace stack) {
                          campusLog('[Chaoxing] action=refresh errorType=${error.runtimeType}\n$stack');
                        });
                      },
                icon: controller.busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const CampusIcon(CampusIcons.sync),
              ),
            ],
          ),
          if (controller.activities.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('现在没有可签到的活动', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            )
          else
            for (final activity in controller.activities)
              _ActivityCard(
                activity: activity,
                busy: controller.signingActiveId == activity.activeId,
                onSign: () => _sign(activity),
              ),
          if (controller.pastActivities.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                onPressed: () => showChaoxingHistoryPage(context, controller: controller),
                icon: const CampusIcon(CampusIcons.history),
                label: Text('往期签到（${controller.pastActivities.length}）'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity, required this.busy, required this.onSign});
  final ChaoxingActivity activity;
  final bool busy;
  final VoidCallback onSign;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final endTime = activity.endTime;
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(activity.subtitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                const SizedBox(height: 4),
                Text(activity.displayTitle, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(
                  endTime != null && activity.ended
                      ? '已结束 ${formatCampusTimestamp(endTime.toIso8601String())}'
                      : '开始 ${formatCampusTimestamp(activity.startTime.toIso8601String())}',
                  style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: busy ? null : onSign,
            child: CampusBusyContent(busy: busy, label: '去签到', busyLabel: '签到中'),
          ),
        ],
      ),
    );
  }
}

// 登录表单：整页登录与「登录其他账号」弹层共用；compact 时随弹层返回填好的账号密码。
class ChaoxingLoginForm extends StatefulWidget {
  const ChaoxingLoginForm({super.key, this.onSubmit, this.compact = false, this.busy = false});
  final Future<void> Function(String phoneNumber, String password)? onSubmit;
  final bool compact;
  final bool busy;
  @override
  State<ChaoxingLoginForm> createState() => _ChaoxingLoginFormState();
}

class _ChaoxingLoginFormState extends State<ChaoxingLoginForm> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final phoneNumber = _phone.text.trim();
    final password = _password.text;
    if (phoneNumber.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写手机号与密码');
      return;
    }
    final onSubmit = widget.onSubmit;
    if (onSubmit == null) {
      Navigator.pop(context, (phoneNumber: phoneNumber, password: password));
      return;
    }
    setState(() => _error = null);
    onSubmit(phoneNumber, password).catchError((Object error, StackTrace stack) {
      campusLog('[Chaoxing] action=sign_in errorType=${error.runtimeType}\n$stack');
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final fields = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: '学习通手机号'),
        ),
        SizedBox(height: campusFieldGap(context)),
        TextField(
          controller: _password,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '密码',
            helperText: '8-16 位，与学习通登录一致',
            suffixIcon: IconButton(
              tooltip: _obscure ? '显示密码' : '隐藏密码',
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: CampusIcon(_obscure ? CampusIcons.eye : CampusIcons.eyeClosed),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(fontSize: 14, color: palette.danger)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          style: campusProminent,
          onPressed: widget.busy ? null : _submit,
          child: CampusBusyContent(
            busy: widget.busy,
            label: '登录',
            busyLabel: '登录中',
            icon: const CampusIcon(CampusIcons.login),
          ),
        ),
      ],
    );
    if (widget.compact) {
      return CampusSheetPanel(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('登录学习通账号', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              fields,
            ],
          ),
        ),
      );
    }
    return CampusScrollFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Text(
            '用学习通账号登录后，就能在这里查看并完成课堂签到。账号只保存在本机安全存储，与教务账号无关。',
            style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          fields,
        ],
      ),
    );
  }
}
