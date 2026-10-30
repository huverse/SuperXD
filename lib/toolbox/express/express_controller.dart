import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';

// 正在跑的是哪个查询：发起它的按钮原地转圈，其余按钮暂不可点；refresh 是下拉刷新，由下拉指示转圈、不占任何按钮。
enum ExpressAction { mobiles, packages, scan, identity, track, refresh }

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
  StationScan? _station;
  String _trackingKey = '';
  bool _disposed = false;
  // 每件寄到的手机尾号（运单号与快递公司为键，见 _fillOwners），存在本机、同一件只查一次；退出或失效时清空。
  final _owners = <String, String>{};
  // 拼多多要求先过安全验证时的令牌，页面取走后打开官方验证页（见 takeVerifyToken）。
  String? _verifyToken;

  PddSession? get session => _session;
  bool get loggedIn => _session != null;
  StationPackagesResult? get packages => _packages;
  IdentityCodeResult? get identityCode => _identityCode;
  // 最近一次扫到的驿站码：身份码同官方带上它；普通「驿站快递」查询后清空，身份码回到不限站点。
  String get stationCode => _station?.code ?? '';
  // 最近一次查物流的那件（运单号）：查询进行中时它那一行的「物流」按钮原地转圈。
  String get trackingKey => _trackingKey;
  ExpressAction? get running => _running;
  bool get busy => _running != null;
  // 身份码到期后的自动刷新进行中（不占 busy，查询按钮照常可点）。
  bool get refreshing => _refreshing;
  String? get error => _error;
  // 这件寄到的手机尾号，没查到是空串（页面归到「尾号未知」）。
  String ownerOf(StationPackage parcel) => _owners[_ownerKey(parcel)] ?? '';

  Future<void> initialize() async {
    final session = await _service.vault.load();
    if (session != null) {
      _bind(session);
      _owners.addAll(await _service.vault.ownerTails());
      // 还没读过昵称与取件号的会话（加这两项之前登录的）补读一次，不挡页面打开。
      if (session.nickname == null) unawaited(_fillAccount(session));
    }
    notifyListeners();
  }

  // 账号卡的昵称与常用取件号：刚登录、或会话还没读过时，并发读昵称与已绑号列表，读到就随会话存回安全存储（拼多多没给的记空串，不再反复读）；
  // 失败只记日志，下次打开再读。读的时候退出登录或换了账号就不存：退出与失效都先清内存里的会话再删存储，这里核对过才写，不会在删除之后又把会话写回去。
  Future<void> _fillAccount(PddSession session) async {
    final client = _service.clientFactory(session);
    try {
      final nickname = client.queryNickname();
      final mobiles = client.queryBoundMobiles();
      await Future.wait([nickname, mobiles]);
      final current = _session;
      if (current == null || current.accessToken != session.accessToken || current.cookie != session.cookie) return;
      final pickup = _pickupOf(await mobiles);
      final filled = current.withAccount(nickname: await nickname, pickupMobile: pickup.mobile, pickupMore: pickup.more);
      _session = filled;
      await _service.vault.save(filled);
      if (!_disposed) notifyListeners();
    } on ExpressFailure catch (failure, stack) {
      campusLog('[Express] action=account_info errorType=${failure.code.name}\n$stack');
    } catch (error, stack) {
      campusLog('[Express] action=account_info errorType=${error.runtimeType}\n$stack');
    } finally {
      client.close();
    }
  }

  // 账号卡写的取件号：拼多多标为常用的那个，没有就第一个；还绑了别的号时补「等」。
  ({String mobile, bool more}) _pickupOf(List<PddBoundMobile> mobiles) {
    if (mobiles.isEmpty) return (mobile: '', more: false);
    final main = mobiles.firstWhere((mobile) => mobile.commonlyUsed, orElse: () => mobiles.first);
    return (mobile: main.maskedMobile, more: mobiles.length > 1);
  }

  // 读到了已绑号列表（打开取件手机号管理、绑定或解绑后重读）就顺手更新账号卡的取件号，变了才存。
  Future<void> _savePickup(List<PddBoundMobile> mobiles) async {
    final current = _session;
    if (current == null) return;
    final pickup = _pickupOf(mobiles);
    if (current.pickupMobile == pickup.mobile && current.pickupMore == pickup.more) return;
    final next = current.withAccount(pickupMobile: pickup.mobile, pickupMore: pickup.more);
    _session = next;
    await _service.vault.save(next);
    if (!_disposed) notifyListeners();
  }

  // 登录成功：存会话并建客户端，再读账号卡的昵称与取件号。
  Future<void> onLoggedIn(PddSession session) async {
    await _service.vault.save(session);
    _bind(session);
    _error = null;
    notifyListeners();
    unawaited(_fillAccount(session));
  }

  void _bind(PddSession session) {
    _client?.close();
    _client = _service.clientFactory(session);
    _session = session;
  }

  // [人工决策-2026-10-21 12:53:40] 1.0.0-alpha.6 的绑定漏了官方紧随其后的「关联驿站包裹」，那时绑的号在绑定前就到站的件查不到。
  // 用户选「自动补一次」：本账号第一次查驿站时先补关联一次、记在本机，之后不再做（重新登录后会再补一次）；补关联失败不挡查询，下次再补。
  Future<void> queryStationPackages({StationScan? station}) => _queryPackages(station, station == null ? ExpressAction.packages : ExpressAction.scan);

  // 下拉刷新：重做上一次的驿站查询（扫过驿站码的重查同一站点，没查过的等于点「驿站快递」），见 express_page.dart 的 _buildMain。
  Future<void> refreshPackages() => _queryPackages(_station, ExpressAction.refresh);

  Future<void> _queryPackages(StationScan? station, ExpressAction running) => _run(running, () async {
    if (!await _service.vault.stationLinked()) await _linkStationPackages();
    final result = await _client!.queryStationPackages(
      stationCode: station?.code ?? '',
      dynamicQr: station?.dynamicQr ?? false,
      entrySource: station == null ? PddConstants.entryOther : PddConstants.entryScan,
    );
    final before = {..._owners};
    await _fillOwners(result);
    // 普通查询是全部待取件：不在里面的件（取走了）的尾号删掉，存的条数不超过待取件数；扫码查只是一个站，只增不删。
    if (station == null) _owners.removeWhere((key, _) => !result.groups.any((group) => group.packages.any((parcel) => _ownerKey(parcel) == key)));
    if (!mapEquals(before, _owners)) await _service.vault.saveOwnerTails(_owners);
    _packages = result;
    _station = station;
  });

  String _ownerKey(StationPackage parcel) => '${parcel.shippingId}|${parcel.trackingNumber}';

  // [人工决策-2026-10-22 23:46:24] 每件寄到的手机尾号：驿站查询不给（10-22 真机），只有物流接口的 package_info 写着，所以按件补查一次物流（只读），
  // 尾号都到了再一起交给页面，条目不跳。真机上短时间反复查物流触发了拼多多风控（54001），用户选「尾号存本机、同一件只查一次」：
  // 查到就存进安全存储，以后重开也不重查，只有新到的件发一次请求；5 件一批并发。
  // 查不到的归「尾号未知」、下次查驿站再试，不挡这次查询；碰到 54001 这一轮停止补查、不弹验证页（只有用户点按钮时才弹）；登录失效照常上抛回登录页。
  // [人工决策-2026-10-25 15:17:41] 用户反馈在拼多多里自己添加的快递在这里写「尾号未知」：补查一律走了按运单号查的通用物流接口，官方物流页对驿站里的件
  // 是按 order_sn 查驿站物流（见 ExpressClient.queryShippingTrack），改成同官方（按官方代码推断，真机待核对）；以前查成功但没给尾号的也存成了空串、再也不查。
  // 用户选「每次查驿站都重查尾号未知的件」（未选「空的不存本机、下次打开再查」「空的也存、只清一次旧记录」）：没给尾号的不存，下次查驿站再查。
  // [人工决策-2026-10-26 17:23:51] 用户真机装上这一版后，自己添加的那件仍是「尾号未知」，拼多多官方 App 里这件也看不到手机号（官方添加快递须知写着仅供隐私面单用户），
  // 即拼多多本来就不给这类件的尾号。用户仍选每次查驿站都重查（未选「查成功没给尾号的记住、不再查」「每天最多重查一次」），分组照旧写「尾号未知」。
  // [人工决策-2026-10-30 18:03:16] 补查也同官方带 anti-content（见 express_models.dart）：每件现取一个，生成器排队逐个出，请求照旧一批 5 件。
  Future<void> _fillOwners(StationPackagesResult result) async {
    final pending = [
      for (final group in result.groups)
        for (final parcel in group.packages)
          if (parcel.trackingNumber.isNotEmpty && (_owners[_ownerKey(parcel)] ?? '').isEmpty) parcel,
    ];
    var blocked = false;
    for (var start = 0; start < pending.length && !blocked; start += 5) {
      await Future.wait(pending.skip(start).take(5).map((parcel) async {
        try {
          final tail = (await _client!.queryShippingTrack(parcel.trackQuery, antiContent: await _anti())).ownerTail;
          if (tail.isEmpty) {
            _owners.remove(_ownerKey(parcel));
          } else {
            _owners[_ownerKey(parcel)] = tail;
          }
        } catch (error, stack) {
          if (error is ExpressFailure && error.isNotLoggedIn) rethrow;
          if (error is ExpressFailure && error.code == ExpressFailureCode.verifyRequired) blocked = true;
          campusLog('[Express] action=package_owner errorType=${error is ExpressFailure ? error.code.name : error.runtimeType}\n$stack');
        }
      }));
    }
  }

  // 用户点的操作碰到拼多多要求安全验证时的令牌，页面取走一次（打开官方验证页由用户本人完成）。
  String? takeVerifyToken() {
    final token = _verifyToken;
    _verifyToken = null;
    return token;
  }

  // 用户在官方验证页完成了验证：之后的请求同官方带上这个令牌。
  void acceptVerify(String token) => _client?.verifyToken = token;

  // 查一件包裹的实时物流，同取件手机号管理先读后开：那一行的「物流」按钮原地转圈，读好再由页面弹出；失败记 error 交页面提示条。
  Future<ShippingTrack?> loadTrack(ExpressTrackQuery query) async {
    ShippingTrack? track;
    _trackingKey = query.trackingNumber;
    await _run(ExpressAction.track, () async => track = await _client!.queryShippingTrack(query, antiContent: await _anti()));
    return track;
  }

  // 同官方：从驿站进来（扫过驿站码）时生成身份码带上这个站的 station_code。
  Future<void> generateIdentityCode() => _run(ExpressAction.identity, () async {
    _identityCode = await _client!.generateIdentityCode(stationCode: stationCode);
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

  // 短信登录（[人工决策] 见 express_models.dart 的登录常量）：还没有会话，用空会话建客户端，失败照常抛给登录表单原地说明；
  // 发码与登录前都现取 anti_content，成功后同网页登录走 onLoggedIn。
  Future<bool> sendLoginSms(String mobile, {required int requestTimes, bool voice = false}) =>
      _signIn((client) async => client.sendLoginSms(mobile, antiContent: await _anti(), requestTimes: requestTimes, voice: voice));
  Future<void> loginWithSms(String mobile, String code) async =>
      onLoggedIn(await _signIn((client) async => client.loginWithSms(mobile: mobile, code: code, antiContent: await _anti())));
  Future<void> verifiedLogin(String verifyToken) async => onLoggedIn(await _signIn((client) => client.verifiedLogin(verifyToken)));

  Future<T> _signIn<T>(Future<T> Function(ExpressClient client) op) async {
    final client = _service.clientFactory(const PddSession());
    try {
      return await op(client);
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
      _identityCode = await _client!.generateIdentityCode(stationCode: stationCode);
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
    await _savePickup(await mobiles);
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
  Future<void> completeBind(String sessionId, {String alias = ''}) => _binding(() async {
    await _client!.newBindMobile(sessionId, antiContent: await _anti(), alias: alias);
    await _relinkStationPackages();
  });
  Future<void> unbind(PddBoundMobile mobile) => _binding(() async => _client!.unbindMobile(mobileId: mobile.mobileId, mobileIdScene: mobile.mobileIdScene, antiContent: await _anti()));
  Future<void> updateAlias(PddBoundMobile mobile, String alias) =>
      _binding(() async => _client!.updateMobileAlias(mobileId: mobile.mobileId, mobileIdScene: mobile.mobileIdScene, alias: alias, antiContent: await _anti()));

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

  // 绑定类与查物流请求前现取 anti_content；生成器没就绪就报错让用户重试。
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

  // 先清内存里的会话再删存储（同 _onFailure）：读昵称与取件号的后台请求据此知道会话没了，见 _fillAccount。
  Future<void> logout() async {
    _reset();
    await _service.vault.deleteAll();
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
      _reset();
      await _service.vault.deleteAll();
    }
    if (failure.code == ExpressFailureCode.verifyRequired && failure.verifyToken.isNotEmpty) _verifyToken = failure.verifyToken;
    _error = failure.message;
  }

  void _reset() {
    _client?.close();
    _client = null;
    _session = null;
    _packages = null;
    _identityCode = null;
    _station = null;
    _owners.clear();
    _verifyToken = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}
