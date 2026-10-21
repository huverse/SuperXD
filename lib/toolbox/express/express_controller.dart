import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';

// 正在跑的是哪个查询：发起它的按钮原地转圈，其余按钮暂不可点。
enum ExpressAction { mobiles, packages, scan, identity, track }

// 取件手机号管理要的两项只读数据：绑定预检查与已绑定列表。
typedef ExpressMobiles = ({PddBindPreCheck pre, List<PddBoundMobile> mobiles});

// 快递页的状态：会话恢复、绑定手机号与待取件查询、身份码生成与到期刷新。
// 一次只跑一个请求（busy）；拿到「未登录」就清掉会话，由页面回到登录态并写明原因。
class ExpressController extends ChangeNotifier {
  ExpressController(this._service);
  final ExpressService _service;

  ExpressClient? _client;
  PddSession? _session;
  StationPackagesResult? _packages;
  IdentityCodeResult? _identityCode;
  ExpressAction? _running;
  bool _refreshing = false;
  String? _error;
  String _stationCode = '';
  String _trackingKey = '';

  PddSession? get session => _session;
  bool get loggedIn => _session != null;
  StationPackagesResult? get packages => _packages;
  IdentityCodeResult? get identityCode => _identityCode;
  // 最近一次扫到的驿站码：身份码同官方带上它；普通「驿站快递」查询后清空，身份码回到不限站点。
  String get stationCode => _stationCode;
  // 最近一次查物流的那件（运单号）：查询进行中时它那一行的「物流」按钮原地转圈。
  String get trackingKey => _trackingKey;
  ExpressAction? get running => _running;
  bool get busy => _running != null;
  // 身份码到期后的自动刷新进行中（不占 busy，查询按钮照常可点）。
  bool get refreshing => _refreshing;
  String? get error => _error;

  Future<void> initialize() async {
    final session = await _service.vault.load();
    if (session != null) _bind(session);
    notifyListeners();
  }

  // 登录成功：存会话并建客户端。
  Future<void> onLoggedIn(PddSession session) async {
    await _service.vault.save(session);
    _bind(session);
    _error = null;
    notifyListeners();
  }

  void _bind(PddSession session) {
    _client?.close();
    _client = _service.clientFactory(session);
    _session = session;
  }

  // [人工决策-2026-10-21 12:53:40] 1.0.0-alpha.6 的绑定漏了官方紧随其后的「关联驿站包裹」，那时绑的号在绑定前就到站的件查不到。
  // 用户选「自动补一次」：本账号第一次查驿站时先补关联一次、记在本机，之后不再做（重新登录后会再补一次）；补关联失败不挡查询，下次再补。
  Future<void> queryStationPackages({StationScan? station}) => _run(station == null ? ExpressAction.packages : ExpressAction.scan, () async {
    if (!await _service.vault.stationLinked()) await _linkStationPackages();
    final result = await _client!.queryStationPackages(
      stationCode: station?.code ?? '',
      dynamicQr: station?.dynamicQr ?? false,
      entrySource: station == null ? PddConstants.entryOther : PddConstants.entryScan,
    );
    _packages = result;
    _stationCode = station?.code ?? '';
  });

  // 查一件包裹的实时物流，同取件手机号管理先读后开：那一行的「物流」按钮原地转圈，读好再由页面弹出；失败记 error 交页面提示条。
  Future<ShippingTrack?> loadTrack(ExpressTrackQuery query) async {
    ShippingTrack? track;
    _trackingKey = query.trackingNumber;
    await _run(ExpressAction.track, () async => track = await _client!.queryShippingTrack(query));
    return track;
  }

  // 同官方：从驿站进来（扫过驿站码）时生成身份码带上这个站的 station_code。
  Future<void> generateIdentityCode() => _run(ExpressAction.identity, () async {
    _identityCode = await _client!.generateIdentityCode(stationCode: _stationCode);
  });

  // 登录页拿到凭据后先用只读接口确认会话真的能用：明确未登录才返回 false（登录页不关、等用户走完验证），网络等其他失败不拦。
  Future<bool> verifySession(PddSession session) async {
    final client = _service.clientFactory(session);
    try {
      await client.preCheckBindMobile();
      return true;
    } on ExpressFailure catch (failure) {
      return !failure.isNotLoggedIn;
    } catch (error, stack) {
      campusLog('[Express] action=verify_session errorType=${error.runtimeType}\n$stack');
      return true;
    } finally {
      client.close();
    }
  }

  // 身份码到期自动刷新：失败不清掉当前码，只记一笔，倒计时组件会在下次到期再试。
  Future<void> refreshIdentityCode() async {
    if (_client == null || busy || _refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
      _identityCode = await _client!.generateIdentityCode(stationCode: _stationCode);
      _error = null;
    } on ExpressFailure catch (failure) {
      await _onFailure(failure);
    } catch (error, stack) {
      campusLog('[Express] action=refresh_code errorType=${error.runtimeType}\n$stack');
      _error = '出错了，请稍后重试';
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  // 打开取件手机号管理前先读好两项（并发），发起按钮原地转圈；失败照常记 error、交页面用提示条说明。
  Future<ExpressMobiles?> loadMobiles() async {
    ExpressMobiles? loaded;
    await _run(ExpressAction.mobiles, () async => loaded = await _readMobiles());
    return loaded;
  }

  Future<ExpressMobiles> _readMobiles() async {
    final pre = _client!.preCheckBindMobile();
    final mobiles = _client!.queryBoundMobiles();
    await Future.wait([pre, mobiles]);
    return (pre: await pre, mobiles: await mobiles);
  }

  // 绑定取件手机号（在管理弹层里逐步做，不占页面 busy）：拿到未登录照样清会话回登录页，其余失败交弹层原地说明。
  // 除只读的预检查/列表外，每次请求前现取一个 anti_content 过风控（隐藏 WebView 跑官方反爬 JS，不缓存）。
  Future<ExpressMobiles> reloadMobiles() => _binding(_readMobiles);
  Future<void> fastBind(PddBindPreCheck pre) => _binding(() async {
    await _client!.fastBindMobile(mobileId: pre.mobileId, mobileIdScene: pre.mobileIdScene, antiContent: await _anti());
    await _relinkStationPackages();
  });
  Future<String> sendBindSms(String mobile) => _binding(() async => _client!.sendBindSmsCode(mobile, antiContent: await _anti()));
  Future<String> verifyBindSms(String mobileId, String code) => _binding(() async => _client!.verifyBindSmsCode(mobileId: mobileId, code: code, antiContent: await _anti()));
  Future<void> completeBind(String sessionId) => _binding(() async {
    await _client!.newBindMobile(sessionId, antiContent: await _anti());
    await _relinkStationPackages();
  });
  Future<void> unbind(PddBoundMobile mobile) => _binding(() async => _client!.unbindMobile(mobileId: mobile.mobileId, mobileIdScene: mobile.mobileIdScene, antiContent: await _anti()));

  // 新绑了号，已关联的标记作废，再按官方在绑定成功后紧接着关联一次；这次没成，下次查驿站时补。
  Future<void> _relinkStationPackages() async {
    await _service.vault.saveStationLinked(false);
    await _linkStationPackages();
  }

  // 关联驿站包裹是绑定与查询之外的补充一步：官方不提示它的失败，这里也只记日志、不打断绑定或查询；登录失效照常上抛回登录页。
  Future<void> _linkStationPackages() async {
    try {
      await _client!.linkStationPackages(antiContent: await _anti());
      await _service.vault.saveStationLinked(true);
    } on ExpressFailure catch (failure, stack) {
      if (failure.isNotLoggedIn) rethrow;
      campusLog('[Express] action=link_station errorType=${failure.code.name}\n$stack');
    } catch (error, stack) {
      campusLog('[Express] action=link_station errorType=${error.runtimeType}\n$stack');
    }
  }

  // 绑定类请求前现取 anti_content；生成器没就绪就报错让用户重试。
  Future<String> _anti() async {
    final provider = _service.antiContent;
    if (provider == null) throw const ExpressFailure(ExpressFailureCode.server, '风控组件未就绪，请重试');
    return provider.generate();
  }

  Future<T> _binding<T>(Future<T> Function() op) async {
    if (_client == null) throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
    try {
      return await op();
    } on ExpressFailure catch (failure) {
      if (failure.isNotLoggedIn) {
        await _onFailure(failure);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    await _service.vault.deleteAll();
    _reset();
    notifyListeners();
  }

  Future<void> _run(ExpressAction running, Future<void> Function() action) async {
    if (_client == null || busy || _refreshing) return;
    _running = running;
    _error = null;
    notifyListeners();
    try {
      await action();
    } on ExpressFailure catch (failure) {
      await _onFailure(failure);
    } catch (error, stack) {
      campusLog('[Express] action=request errorType=${error.runtimeType}\n$stack');
      _error = '出错了，请稍后重试';
    } finally {
      _running = null;
      notifyListeners();
    }
  }

  // 拿到「未登录」就回到登录态：清掉过期会话（存储也删，免得下次打开又拿到它），其余只在页面展示原因。
  Future<void> _onFailure(ExpressFailure failure) async {
    if (failure.isNotLoggedIn) {
      await _service.vault.deleteAll();
      _reset();
    }
    _error = failure.message;
  }

  void _reset() {
    _client?.close();
    _client = null;
    _session = null;
    _packages = null;
    _identityCode = null;
    _stationCode = '';
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
