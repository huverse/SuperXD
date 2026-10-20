import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_identity_view.dart';
import 'package:superxd/toolbox/express/express_login_webview.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 首次使用拼多多这个来源要单独征得同意；说明版本变了就加一档，旧同意失效、再次征询。
const expressConsentVersion = 'pdd-1';

class ExpressPage extends StatefulWidget {
  const ExpressPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;

  @override
  State<ExpressPage> createState() => _ExpressPageState();
}

class _ExpressPageState extends State<ExpressPage> {
  ExpressController? _controller;
  late ExpressService _service;
  late Future<void> _ready = _initialize();

  Future<void> _initialize() async {
    try {
      await widget.runtime.initialize();
      _service = await widget.runtime.service<ExpressService>(ExpressService.serviceId);
      final controller = ExpressController(_service);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller = controller;
    } catch (error, stack) {
      campusLog('[Express] action=initialize errorType=${error.runtimeType}\n$stack');
      rethrow;
    }
  }

  // 登录前先取同意（拼多多是新来源），同意后打开官方 H5 登录页；登录态只从原生 Cookie 读、只存本机安全存储。
  Future<void> _login() async {
    final controller = _controller!;
    if (!await widget.runtime.store.consent(ExpressService.serviceId, expressConsentVersion)) {
      if (!mounted) return;
      final agreed = await showCampusConfirm(
        context,
        title: '使用拼多多快递',
        message: '将打开拼多多官方页面登录你本人的账号，登录态只保存在本机安全存储，仅用于查询你的快递与生成取件身份码。\n\n身份码是取件凭证、短时有效，请勿分享或截图外传。请遵守拼多多的服务条款，仅用于本人已授权的账号。',
        action: '同意并登录',
      );
      if (!agreed || !mounted) return;
      await widget.runtime.store.grantConsent(ExpressService.serviceId, expressConsentVersion);
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      CampusPageRoute(
        builder: (_) => ExpressLoginWebView(
          onLogin: (session) {
            controller.onLoggedIn(session);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final controller = _controller!;
    final confirmed = await showCampusConfirm(context, title: '退出登录', message: '退出后再次查询需要重新登录拼多多。', action: '退出', destructive: true);
    if (confirmed) await controller.logout();
  }

  // [人工决策-2026-10-19 23:35:59] 功能范围为核心四项（登录、绑定手机号、驿站待取件、身份码）加驿站扫码进入；
  // 订单驿站柜、取件码搜索、短信登录高级接口不做（无真实样本且偏离身份码聚焦）。
  // 扫驿站二维码进入：带着驿站码查这家驿站的待取件。真实驿站码格式未取到样本，原文非空即原样作为 station_code 传。
  Future<void> _scanStation() async {
    final scan = widget.runtime.scanQrCode;
    if (scan == null) {
      await showCampusNotice(context, '当前版本不能扫码');
      return;
    }
    final raw = await scan(context, '把驿站的二维码放入框内', (value) => value.trim().isEmpty ? '没有识别到驿站码' : null);
    if (raw == null || !mounted) return;
    await _act(() => _controller!.queryStationPackages(stationCode: raw.trim()));
  }

  // 查询失败用提示条说明（同学习通、成绩页），不在卡片里留一行不会消失的红字；登录失效时控制器已回到登录态，原因写在登录页上。
  Future<void> _act(Future<void> Function() action) async {
    await action();
    final controller = _controller!;
    if (mounted && controller.loggedIn && controller.error != null) showCampusToast(context, controller.error!);
  }

  Future<void> _accountMenu(BuildContext anchor) async {
    final choice = await showCampusMenu<String>(
      anchor,
      items: const [CampusMenuItem(value: 'logout', label: '退出登录', icon: CampusIcons.logout, destructive: true)],
    );
    if (choice == 'logout' && mounted) await _logout();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('快递'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => context.canPop() ? context.pop() : Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    // 内容滚到透明顶栏下时自身渐隐，同百宝箱其他页（theme 的 CampusScrollFade）。
    body: CampusScrollFade(child: SafeArea(
      child: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return CampusLoadError(message: '准备失败', onRetry: () => setState(() {
              _ready = _initialize();
            }));
          }
          final controller = _controller;
          if (controller == null) return const Center(child: CampusLoading(label: '正在准备'));
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: controller.loggedIn ? _buildMain(controller) : _buildLogin(controller),
              ),
            ),
          );
        },
      ),
    )),
  );

  Widget _buildLogin(ExpressController controller) {
    final palette = CampusPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 32),
        Center(child: CampusIcon(CampusIcons.parcel, size: 56, color: palette.onSurfaceVariant)),
        const SizedBox(height: 16),
        Center(child: Text('查询快递与取件身份码', style: Theme.of(context).textTheme.titleMedium)),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '用拼多多官方账号登录后，可查询驿站待取件、生成取件身份码。登录在拼多多官方页面完成，不接触你的密码。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
          ),
        ),
        // 登录失效被退回这里时写明原因（以前原因只写在已登录视图里，退回后看不到）。
        if (controller.error != null) ...[
          const SizedBox(height: 16),
          Center(child: Text(controller.error!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.danger))),
        ],
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            style: campusProminent,
            onPressed: _login,
            icon: const CampusIcon(CampusIcons.login),
            label: const Text('登录拼多多'),
          ),
        ),
      ],
    );
  }

  // [人工决策-2026-10-20 14:38:25] 首页同学习通：账号卡（人形头像、拼多多账号、⋯ 里退出登录），四个操作在卡下方单独一组，
  // 点哪个哪个原地转圈（不再出 Material 进度条、全组变灰）；结果卡标题与全应用同字号（用户选定的百宝箱统一性整改）。
  Widget _buildMain(ExpressController controller) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final mobiles = controller.mobiles;
    final packages = controller.packages;
    final identityCode = controller.identityCode;
    final locked = controller.busy || controller.refreshing;
    final userId = controller.session!.userId;
    Widget action(ExpressAction kind, IconData icon, String label, String busyLabel, VoidCallback onPressed, {bool prominent = false}) {
      final content = CampusBusyContent(busy: controller.running == kind, label: label, busyLabel: busyLabel, icon: CampusIcon(icon));
      return prominent
          ? FilledButton(style: campusProminent, onPressed: locked ? null : onPressed, child: content)
          : OutlinedButton(onPressed: locked ? null : onPressed, child: content);
    }
    Widget result(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: CampusSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          ...children,
        ]),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CampusSurface(
          child: Row(
            children: [
              const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox.square(dimension: 44, child: Center(child: CampusIcon(CampusIcons.account)))),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('拼多多账号', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                    const SizedBox(height: 4),
                    Text(userId.isEmpty ? '已登录' : '账号 $userId', style: secondary),
                  ],
                ),
              ),
              // 菜单按按钮自己的 context 定位（同学习通账号卡）。
              Builder(builder: (menuAnchor) => IconButton(tooltip: '账号操作', onPressed: () => _accountMenu(menuAnchor), icon: const CampusIcon(CampusIcons.manage))),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            action(ExpressAction.mobiles, CampusIcons.phone, '绑定手机号', '正在查询', () => _act(controller.queryBoundMobiles)),
            action(ExpressAction.packages, CampusIcons.parcel, '驿站快递', '正在查询', () => _act(controller.queryStationPackages)),
            action(ExpressAction.scan, CampusIcons.scan, '扫驿站码', '正在查询', _scanStation),
            action(ExpressAction.identity, CampusIcons.qrCode, '身份码', '生成中', () => _act(controller.generateIdentityCode), prominent: true),
          ],
        ),
        if (mobiles != null)
          result('绑定的取件手机号', [
            if (mobiles.isEmpty)
              Text('未绑定取件手机号', style: secondary)
            else
              for (final mobile in mobiles)
                Text(mobile.alias.isEmpty ? mobile.maskedMobile : '${mobile.maskedMobile}（${mobile.alias}）', style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface)),
          ]),
        if (packages != null)
          result('驿站待取件', [
            Text(packages.count == 0 ? '没有待取件' : '${packages.count} 件待取', style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface)),
            if (packages.count == 0 && (packages.noPackageMobileInfo?.mobileList.isNotEmpty ?? false))
              Text('手机尾号 ${packages.noPackageMobileInfo!.mobileList.join('、')}', style: secondary),
          ]),
        if (identityCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: CampusSurface(child: ExpressIdentityView(controller: controller)),
          ),
      ],
    );
  }
}
