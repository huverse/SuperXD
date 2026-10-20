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
    await _controller!.queryStationPackages(stationCode: raw.trim());
  }

  Future<void> _menu() async {
    final choice = await showCampusMenu<String>(
      context,
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
      actions: [
        if (_controller?.loggedIn ?? false)
          IconButton(tooltip: '更多', onPressed: _menu, icon: const CampusIcon(CampusIcons.manage)),
      ],
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
                child: controller.loggedIn ? _buildMain(controller) : _buildLogin(),
              ),
            ),
          );
        },
      ),
    )),
  );

  Widget _buildLogin() {
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

  Widget _buildMain(ExpressController controller) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final mobiles = controller.mobiles;
    final packages = controller.packages;
    final identityCode = controller.identityCode;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CampusSurface(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('已登录拼多多', style: textTheme.titleMedium),
              if (controller.session!.userId.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('账号 ${controller.session!.userId}', style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: controller.busy ? null : controller.queryBoundMobiles,
                    icon: const CampusIcon(CampusIcons.phone),
                    label: const Text('绑定手机号'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.busy ? null : () => controller.queryStationPackages(),
                    icon: const CampusIcon(CampusIcons.parcel),
                    label: const Text('驿站快递'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: controller.busy ? null : _scanStation,
                    icon: const CampusIcon(CampusIcons.scan),
                    label: const Text('扫驿站码'),
                  ),
                  FilledButton.icon(
                    style: campusProminent,
                    onPressed: controller.busy ? null : controller.generateIdentityCode,
                    icon: const CampusIcon(CampusIcons.qrCode),
                    label: const Text('身份码'),
                  ),
                ],
              ),
              if (controller.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(controller.error!, style: textTheme.bodyMedium?.copyWith(color: palette.danger)),
                ),
            ],
          ),
        ),
        if (mobiles != null) ...[
          const SizedBox(height: 16),
          CampusSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('绑定的取件手机号', style: textTheme.titleSmall),
                const SizedBox(height: 8),
                if (mobiles.isEmpty)
                  Text('未绑定取件手机号', style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant))
                else
                  for (final mobile in mobiles)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(mobile.alias.isEmpty ? mobile.maskedMobile : '${mobile.maskedMobile}（${mobile.alias}）'),
                    ),
              ],
            ),
          ),
        ],
        if (packages != null) ...[
          const SizedBox(height: 16),
          CampusSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('驿站待取件 ${packages.count} 件', style: textTheme.titleSmall),
                if (packages.count == 0 && (packages.noPackageMobileInfo?.mobileList.isNotEmpty ?? false)) ...[
                  const SizedBox(height: 4),
                  Text('手机尾号：${packages.noPackageMobileInfo!.mobileList.join('、')}', style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
                ],
                if (packages.packages.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('共有 ${packages.packages.length} 件待取', style: textTheme.bodyMedium?.copyWith(color: palette.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ],
        if (identityCode != null) ...[
          const SizedBox(height: 16),
          CampusSurface(
            padding: const EdgeInsets.all(16),
            child: ExpressIdentityView(controller: controller),
          ),
        ],
      ],
    );
  }
}
