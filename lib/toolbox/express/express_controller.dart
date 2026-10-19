import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';

// 快递页的状态：会话恢复、绑定手机号与待取件查询、身份码生成与到期刷新。
// 一次只跑一个请求（busy）；拿到「未登录」就清掉会话，由页面回到登录态。
class ExpressController extends ChangeNotifier {
  ExpressController(this._service);
  final ExpressService _service;

  ExpressClient? _client;
  PddSession? _session;
  List<PddBoundMobile>? _mobiles;
  StationPackagesResult? _packages;
  IdentityCodeResult? _identityCode;
  bool _busy = false;
  String? _error;

  PddSession? get session => _session;
  bool get loggedIn => _session != null;
  List<PddBoundMobile>? get mobiles => _mobiles;
  StationPackagesResult? get packages => _packages;
  IdentityCodeResult? get identityCode => _identityCode;
  bool get busy => _busy;
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

  Future<void> queryBoundMobiles() => _run(() async {
    _mobiles = await _client!.queryBoundMobiles();
  });

  Future<void> queryStationPackages({String stationCode = ''}) => _run(() async {
    _packages = await _client!.queryStationPackages(
      stationCode: stationCode,
      entrySource: stationCode.isEmpty ? PddConstants.entryOther : PddConstants.entryScan,
    );
  });

  Future<void> generateIdentityCode() => _run(() async {
    _identityCode = await _client!.generateIdentityCode();
  });

  // 身份码到期自动刷新：失败不清掉当前码，只记一笔，倒计时组件会在下次到期再试。
  Future<void> refreshIdentityCode() async {
    if (_client == null || _busy) return;
    try {
      _identityCode = await _client!.generateIdentityCode();
      _error = null;
      notifyListeners();
    } on ExpressFailure catch (failure) {
      await _onFailure(failure);
      notifyListeners();
    } catch (error, stack) {
      campusLog('[Express] action=refresh_code errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> logout() async {
    await _service.vault.deleteAll();
    _reset();
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_client == null || _busy) return;
    _busy = true;
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
      _busy = false;
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
    _mobiles = null;
    _packages = null;
    _identityCode = null;
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
