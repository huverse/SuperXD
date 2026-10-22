import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_cookies.dart';
import 'package:superxd/toolbox/express/express_identity_view.dart';
import 'package:superxd/toolbox/express/express_login_webview.dart';
import 'package:superxd/toolbox/express/express_mobile_sheet.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_track_sheet.dart';
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
        message: '将打开拼多多官方页面登录你本人的账号，登录态只保存在本机安全存储，仅用于查询你的快递与生成取件身份码。\n\n'
            '拼多多同一账号不支持多设备同时在线：在这里登录后，你其他设备上的拼多多会被挤下线。建议用小号登录，再用「绑定手机号」把大号的手机号绑进来，就能用小号的身份码取大号的快递。\n\n'
            '身份码是取件凭证、短时有效，请勿分享或截图外传。请遵守拼多多的服务条款，仅用于本人已授权的账号。',
        action: '同意并登录',
      );
      if (!agreed || !mounted) return;
      await widget.runtime.store.grantConsent(ExpressService.serviceId, expressConsentVersion);
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      CampusPageRoute(
        builder: (_) => ExpressLoginWebView(
          verify: controller.verifySession,
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
    if (!confirmed) return;
    await controller.logout();
    // 退出时把 WebView 残留的会话 Cookie 也清掉，下次登录从干净状态开始（登录态等同凭据，退出即删）。
    await clearExpressWebCookies();
  }

  // [人工决策-2026-10-21 12:53:40] 用户选「先读后开」：按钮原地转圈读好预检查与列表再弹出弹层，弹层一出来就是最终高度，
  // 不再先放整页加载动画撑满、读完缩回（真机上的突闪）；没读到用提示条说明，登录失效时控制器已回到登录页。
  Future<void> _manageMobiles() async {
    final controller = _controller!;
    final loaded = await controller.loadMobiles();
    if (!mounted) return;
    if (loaded == null) {
      if (controller.loggedIn && controller.error != null) showCampusToast(context, controller.error!);
      return;
    }
    await showExpressMobileSheet(context, controller: controller, initial: loaded);
  }

  // 包裹的实时物流同样先读后开：那一行的「物流」按钮原地转圈，读好再弹物流详情。
  Future<void> _showTrack(ExpressTrackQuery query) async {
    final controller = _controller!;
    final track = await controller.loadTrack(query);
    if (!mounted) return;
    if (track == null) {
      if (controller.loggedIn && controller.error != null) showCampusToast(context, controller.error!);
      return;
    }
    await showExpressTrackSheet(context, track);
  }

  // anti_content 的隐藏 WebView：只建一次、常驻且一直被绘制（页面稳定位置、不随列表或控制器重建），
  // 这样 window.__sxdGen 能常驻、现取 anti_content 不用每次重载（被盖住重置时还有重载兜底，见 express_anti_content.dart）。
  // 1px、IgnorePointer，不显示拼多多页面也不吃点按；测试里假实现无 controller 则不挂。
  Widget? _antiHost;
  Widget _antiHostWidget() {
    final webController = _service.antiContent?.webViewController;
    if (webController == null) return const SizedBox.shrink();
    return _antiHost ??= IgnorePointer(child: SizedBox(width: 1, height: 1, child: WebViewWidget(controller: webController)));
  }

  // [人工决策-2026-10-19 23:35:59] 功能范围为核心四项（登录、绑定手机号、驿站待取件、身份码）加驿站扫码进入；
  // 订单驿站柜、取件码搜索不做（无真实样本且偏离身份码聚焦）。
  // [人工决策-2026-10-20 15:36:10] 用户确认把「绑定手机号」从只查列表扩成真正的取件手机号管理（列表 + 短信验证绑新号 + 快速绑本账号已有号 + 解绑）：
  // 绑定短信走 francis 端点（属绑定不属登录、按反编译不需 anti_content），仍不做需 anti_content 的短信登录高级接口（sigerus）。
  // 绑定/解绑是账号状态变更，逐步由用户点击确认（见 express_mobile_sheet.dart），不后台自动做。移交包未真机验证过绑定/解绑，实际风控与解绑参数待真机核实。
  // [人工决策-2026-10-21 17:49:44] 扫驿站二维码进入：真实驿站码是带 station_code 参数的链接（10-21 拿到样本），
  // 用户确认改为从链接、JSON 或裸码里取 station_code（parseStationScan），取不到就在扫码页提示，不再把原文发给服务端（原「原文非空即原样传」作废）。
  Future<void> _scanStation() async {
    final scan = widget.runtime.scanQrCode;
    if (scan == null) {
      await showCampusNotice(context, '当前版本不能扫码');
      return;
    }
    final raw = await scan(context, '把驿站的二维码放入框内', (value) => parseStationScan(value) == null ? '不是驿站的二维码' : null);
    if (raw == null || !mounted) return;
    await _act(() => _controller!.queryStationPackages(station: parseStationScan(raw)), reveal: _stationCard);
  }

  // [人工决策-2026-10-21 17:49:44] 只能微信扫码取件的账号（only_wx_scan）：用户选「提示但保留身份码」，并加「去微信取件」——
  // 第三方 App 让微信打开指定网页要接微信开放平台 SDK，做不到；改为扫过驿站码时把这个站的微信取件链接生成纯二维码存进相册，
  // 提示在微信「扫一扫」里从相册选它，再用公开的 weixin:// 拉起微信；没扫过驿站码就提示扫驿站墙上的码。
  // [人工决策-2026-10-21 18:55:20] 用户看真机后定文案：微信是用来「查询待取件、查询取件」的，标题写「这个账号目前只能用微信查询待取件」，
  // 弹窗写「查询取件」；删去「拼多多暂停了它在 App 里取件」说明行与身份码上方的「驿站可能不认」提醒（身份码照常可生成）。
  Future<void> _toWeChat() async {
    final stationCode = _controller!.stationCode;
    final saved = stationCode.isNotEmpty && await _saveStationQr(stationCode);
    if (!mounted) return;
    final go = await showCampusConfirm(
      context,
      title: saved ? '驿站码已存到相册' : '去微信取件',
      // 按步骤分行写：整句在窄弹窗里会把「扫一扫」拆到两行。
      message: saved ? '打开微信，点右上角＋\n→「扫一扫」→ 相册\n选这张驿站码查询取件。' : '打开微信，点右上角＋\n→「扫一扫」\n扫驿站的二维码查询取件。',
      action: '打开微信',
    );
    if (!go || !mounted) return;
    final opened = await _service.launchExternal(Uri.parse(PddConstants.weChatScheme)).catchError((Object error, StackTrace stack) {
      campusLog('[Express] action=open_wechat errorType=${error.runtimeType}\n$stack');
      return false;
    });
    if (!opened && mounted) showCampusToast(context, '没有找到微信');
  }

  // 驿站的微信取件链接画成纯黑白二维码（四周留白），经百宝箱的一次性导出存进公共目录（相册里可见，同名不重复存）；临时文件用完即删。
  Future<bool> _saveStationQr(String stationCode) async {
    final temp = File(path.join((await _service.temporaryDirectory()).path, 'express-station-${DateTime.now().microsecondsSinceEpoch}.png'));
    try {
      final image = QrImage(QrCode.fromData(data: weChatStationUrl(stationCode), errorCorrectLevel: QrErrorCorrectLevel.M));
      final bytes = await image.toImageAsBytes(
        size: 1024,
        decoration: const PrettyQrDecoration(
          shape: PrettyQrSmoothSymbol(color: Colors.black, roundFactor: 0),
          background: Colors.white,
          quietZone: PrettyQrQuietZone.standard,
        ),
      );
      if (bytes == null) return false;
      await temp.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      final filename = '驿站码-${stationCode.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}.png';
      return await _service.filePublisher().publishExternal(source: temp.path, filename: filename, mimeType: 'image/png') != null;
    } catch (error, stack) {
      campusLog('[Express] action=save_station_qr errorType=${error.runtimeType}\n$stack');
      return false;
    } finally {
      unawaited(temp.delete().then((_) {}, onError: (Object error, StackTrace stack) {
        if (error is! PathNotFoundException) campusLog('[Express] action=station_qr_clean errorType=${error.runtimeType}\n$stack');
      }));
    }
  }

  // 查询失败用提示条说明（同学习通、成绩页），不在卡片里留一行不会消失的红字；登录失效时控制器已回到登录态，原因写在登录页上。
  // 成功了把这次的结果卡滚进可视区（见 _reveal）。
  Future<void> _act(Future<void> Function() action, {required GlobalKey reveal}) async {
    await action();
    final controller = _controller!;
    if (!mounted || !controller.loggedIn) return;
    if (controller.error != null) {
      showCampusToast(context, controller.error!);
    } else {
      _reveal(reveal);
    }
  }

  final _stationCard = GlobalKey();
  final _identityCard = GlobalKey();

  // [人工决策-2026-10-21 20:04:39] 点了按钮出来的结果卡滚进可视区（用户选定，未选「身份码移到最上面」「一次只显示一张」）：
  // 先查驿站（有快递时驿站卡很长）再点身份码，身份码画在驿站卡下面、落在屏幕外，要自己下滑才看到。卡片顺序不变，只滚最少的距离：
  // 整张放得下就让它整张露出，比屏幕高就让卡顶露出、至少占半屏，已经满足就不动；只在点按钮后做，身份码到期自动换码不滚。
  void _reveal(GlobalKey key) => WidgetsBinding.instance.addPostFrameCallback((_) {
    final card = key.currentContext;
    if (!mounted || card == null) return;
    final scrollable = Scrollable.of(card);
    final position = scrollable.position;
    final box = card.findRenderObject()! as RenderBox;
    final viewport = position.viewportDimension;
    // 卡顶对齐可视区顶时的滚动位置；顶边留出内容渐隐的高度，不让卡顶压在渐隐里。
    final top = position.pixels + box.localToGlobal(Offset.zero, ancestor: scrollable.context.findRenderObject()).dy;
    const margin = 24.0;
    final height = box.size.height;
    final shown = height + 2 * margin <= viewport ? height + margin : viewport / 2;
    final goal = position.pixels.clamp(top - viewport + shown, top - margin).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((goal - position.pixels).abs() < 1) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      position.jumpTo(goal);
    } else {
      position.animateTo(goal, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  });

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
          // 内容作非定位子项（Stack 按它定尺寸、填满），隐藏 WebView 作 1px 定位子项（不影响尺寸、常驻绘制）。
          // 靠上对齐：已登录的 SingleChildScrollView 按内容收缩高度，居中会把不满一屏的内容整块挤到屏幕中间。
          return Stack(
            children: [
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: controller.loggedIn ? _buildMain(controller) : _buildLogin(controller),
                  ),
                ),
              ),
              Positioned(left: 0, top: 0, width: 1, height: 1, child: _antiHostWidget()),
            ],
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
        const SizedBox(height: 24),
        // 多端登录提醒：拼多多不支持多端同时在线，这里登录会把其他设备挤下线；引导用小号登录、绑大号。只读说明，不用主色。
        CampusSurface(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(right: 12), child: CampusIcon(CampusIcons.info, size: 20, color: palette.onSurfaceVariant)),
              Expanded(
                child: Text(
                  '拼多多不支持多端同时登录，这里登录会让你其他设备上的拼多多下线。建议用小号登录，再用「绑定手机号」绑定大号的手机号。',
                  style: TextStyle(fontSize: 14, height: 1.5, color: palette.onSurfaceVariant),
                ),
              ),
            ],
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
  // [人工决策-2026-10-20 15:36:10] 「绑定手机号」改为打开取件手机号管理弹层（增删绑定），不再在卡下方画列表结果卡；其余三项仍是原地查询。
  // [人工决策-2026-10-22 20:51:17] 用户反馈只写「拼多多账号」认不出是哪个账号：账号卡标题改写本账号手机号（拼多多只给打码的号），
  // 下面一行写「拼多多账号」；读不到手机号时照旧，标题「拼多多账号」、下面写账号号。手机号登录时读一次、随会话存进安全存储（用户选定，
  // 未选「每次打开读一次、不存」），之前登录的会话打开快递页时补读一次（见 ExpressController.initialize）。
  Widget _buildMain(ExpressController controller) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final packages = controller.packages;
    // 没有待取件时写查过的手机尾号：同官方只写前两个，还有更多时补「等」（服务端也只给前几个）。
    final noPackage = packages?.noPackageMobileInfo;
    final tails = noPackage == null || noPackage.mobileList.isEmpty
        ? ''
        : '${noPackage.mobileList.take(2).join('、')}${noPackage.largerThanTwo || noPackage.mobileList.length > 2 ? '等' : ''}';
    final identityCode = controller.identityCode;
    final locked = controller.busy || controller.refreshing;
    final session = controller.session!;
    final mobile = session.mobile ?? '';
    Widget action(ExpressAction kind, IconData icon, String label, String busyLabel, VoidCallback onPressed, {bool prominent = false}) {
      final content = CampusBusyContent(busy: controller.running == kind, label: label, busyLabel: busyLabel, icon: CampusIcon(icon));
      return prominent
          ? FilledButton(style: campusProminent, onPressed: locked ? null : onPressed, child: content)
          : OutlinedButton(onPressed: locked ? null : onPressed, child: content);
    }
    // 每件包裹行尾的「物流」：查询进行中只有发起的那一行原地转圈；没有运单号的不能查。
    Widget trackButton(ExpressTrackQuery query) => OutlinedButton(
      onPressed: locked || query.trackingNumber.isEmpty ? null : () => _showTrack(query),
      child: CampusBusyContent(
        busy: controller.running == ExpressAction.track && controller.trackingKey == query.trackingNumber,
        label: '物流',
        busyLabel: '物流',
        icon: const CampusIcon(CampusIcons.logistics),
      ),
    );
    Widget result(GlobalKey key, String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: CampusSurface(
        key: key,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          ...children,
        ]),
      ),
    );
    // 整页一次排完（只有几张卡）：按需建的 ListView 不建屏幕外远处的卡，结果卡就没法定位滚进可视区（见 _reveal）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CampusSurface(
            child: Row(
              children: [
                const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox.square(dimension: 44, child: Center(child: CampusIcon(CampusIcons.account)))),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mobile.isEmpty ? '拼多多账号' : mobile, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                      const SizedBox(height: 4),
                      Text(mobile.isNotEmpty ? '拼多多账号' : session.userId.isEmpty ? '已登录' : '账号 ${session.userId}', style: secondary),
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
              // 绑定手机号是增删管理：原地转圈读好再打开弹层，增删在弹层里做。
              action(ExpressAction.mobiles, CampusIcons.phone, '绑定手机号', '读取中', _manageMobiles),
              action(ExpressAction.packages, CampusIcons.parcel, '驿站快递', '正在查询', () => _act(controller.queryStationPackages, reveal: _stationCard)),
              action(ExpressAction.scan, CampusIcons.scan, '扫驿站码', '正在查询', _scanStation),
              action(ExpressAction.identity, CampusIcons.qrCode, '身份码', '生成中', () => _act(controller.generateIdentityCode, reveal: _identityCard), prominent: true),
            ],
          ),
          if (packages != null)
            result(_stationCard, '驿站待取件', [
              if (packages.stationName.isNotEmpty) Text('当前站点：${packages.stationName}', style: secondary),
              // 只能微信扫码取件的账号不写「没有待取件」（那会让人以为只是没快递），写明只能用微信查询并给「去微信取件」。
              if (packages.onlyWxScan) ...[
                Text('这个账号目前只能用微信查询待取件', style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface)),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: locked ? null : _toWeChat, icon: const CampusIcon(CampusIcons.open), label: const Text('去微信取件')),
              ] else ...[
                Text(packages.total == 0 ? '没有待取件' : '${packages.total} 件待取', style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface)),
                if (packages.total == 0 && tails.isNotEmpty) Text('手机尾号 $tails', style: secondary),
              ],
              // 按驿站分组列出，取件码最醒目（到驿站报的就是它），下面一行快递公司、运单号与收件人备注。
              for (final group in packages.groups) ...[
                const SizedBox(height: 12),
                Text(group.stationName.isEmpty ? '驿站' : group.stationName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                if (group.address.isNotEmpty) Text(group.address, style: secondary),
                for (final parcel in group.packages)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(parcel.pickCode.isEmpty ? '取件码未知' : '取件码 ${parcel.pickCode}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: palette.onSurface)),
                              DotSeparatedText([parcel.shippingName, parcel.trackingNumber, parcel.mobileAlias].where((part) => part.isNotEmpty).join(' · '), style: secondary),
                            ],
                          ),
                        ),
                        trackButton(parcel.trackQuery),
                      ],
                    ),
                  ),
                if (group.deliveryCount > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${group.deliveryCount} 个快递已安排送货上门', style: secondary)),
              ],
              // 近一周已取出（官方放在取快递页底部一行，点开列取件地址、取件时间、快递公司与运单号）：直接列在卡片里，每件可查物流。
              if (packages.recentPackages.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('近一周已取出 ${packages.recentPackages.length} 件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                for (final parcel in packages.recentPackages)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DotSeparatedText([parcel.shippingName, parcel.trackingNumber].where((part) => part.isNotEmpty).join(' · '), style: TextStyle(fontSize: 15, color: palette.onSurface)),
                              if (parcel.operateTime.isNotEmpty) Text('取件时间 ${parcel.operateTime}', style: secondary),
                              if (parcel.address.isNotEmpty) Text(parcel.address, style: secondary),
                            ],
                          ),
                        ),
                        trackButton(parcel.trackQuery),
                      ],
                    ),
                  ),
              ],
            ]),
          if (identityCode != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: CampusSurface(key: _identityCard, child: ExpressIdentityView(controller: controller)),
            ),
        ],
      ),
    );
  }
}
