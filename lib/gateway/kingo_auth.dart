import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

// 登录暂态只属于本次认证，不读取或清理正在使用的账号数据库。
class KingoAuth {
  KingoAuth({required this.client, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final KingoClient client;
  final DateTime Function() _now;
  String? _account;
  String? _password;
  SavedSession? _session;
  KingoLoginResult? _authenticated;
  int _epoch = 0;
  bool _busy = false;

  SavedSession? get session => _session;

  void cancel() {
    _epoch++;
    _account = null;
    _password = null;
    _session = null;
    _authenticated = null;
    _busy = false;
    client.cancelRequests();
    client.jar.clear();
    client.pageSession = '';
  }

  Future<GatewayResult<LoginView>> login(String account, String password) {
    cancel();
    _account = account;
    _password = password;
    return _attempt(() => client.login(account, password));
  }

  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) {
    if (_busy) return Future.value(_fail('LOGIN_BUSY', '登录处理中，请稍候'));
    final account = _account;
    final password = _password;
    if (account == null || password == null) return Future.value(_fail('LOGIN_FAILED', '请重新登录'));
    return _attempt(() => client.login(account, password, captcha: code));
  }

  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() {
    if (_busy) return Future.value(_fail('LOGIN_BUSY', '登录处理中，请稍候'));
    if (_account == null || _password == null || client.pageSession.isEmpty) {
      return Future.value(_fail('LOGIN_FAILED', '请重新登录'));
    }
    return _run(() async => GatewayResult(ok: true, source: 'edu', fetchedAt: _stamp(), data: _captcha(await client.fetchCaptcha())));
  }

  Future<GatewayResult<LoginView>> _attempt(Future<KingoLoginResult> Function() request) {
    final epoch = _epoch;
    return _run(() async {
      final result = await request();
      if (epoch != _epoch) return _fail('ACCOUNT_CHANGED', '登录操作已取消或被替换');
      if (result.needsCaptcha && result.captcha != null) {
        return GatewayResult(ok: true, needsInput: 'captcha', source: 'edu', fetchedAt: _stamp(), data: LoginView(captcha: _captcha(result.captcha!)));
      }
      _account = null;
      _password = null;
      if (!result.ok) return _fail(result.failure?.code ?? 'LOGIN_FAILED', result.failure?.message ?? '登录失败');
      final loginId = result.loginId?.trim() ?? '';
      if (loginId.isEmpty || result.userCode.trim().isEmpty) {
        return _fail('UPSTREAM_FORMAT', '教务未返回有效账号身份，未切换账号');
      }
      _authenticated = result;
      _session = SavedSession(
        loginId: loginId,
        displayName: '',
        className: '',
        cookieJson: jsonEncode({'cookies': client.jar, 'pageSession': client.pageSession, 'userCode': result.userCode}),
        savedAt: _stamp(),
      );
      return GatewayResult(ok: true, source: 'edu', fetchedAt: _session!.savedAt, data: LoginView(session: SessionView(loginId: loginId, name: '', className: '')));
    });
  }

  // 固定账号网关和账号切换门面共用同一份会话、学期落库规则。
  Future<void> persistSession(AppDatabase database) async {
    final saved = _session;
    final result = _authenticated;
    if (saved == null || result == null) throw StateError('尚未完成认证');
    await database.writeSession(saved);
    final terms = result.terms.map((term) => TermRef(xn: term.xn, xq: term.xq, label: term.label)).toList();
    if (terms.isEmpty && result.currentXn.isNotEmpty) {
      terms.add(TermRef(xn: result.currentXn, xq: result.currentXq));
    }
    if (terms.isNotEmpty) await database.saveTerms(terms, currentXn: result.currentXn, currentXq: result.currentXq);
  }

  Future<GatewayResult<T>> _run<T>(Future<GatewayResult<T>> Function() request) async {
    final epoch = _epoch;
    _busy = true;
    GatewayResult<T> result;
    try {
      result = await request();
    } on KingoCallException catch (error, stack) {
      _log(error, stack, error.failure.code);
      result = _fail(error.failure.code, error.failure.message);
    } on TimeoutException catch (error, stack) {
      _log(error, stack, 'NETWORK_TIMEOUT');
      result = _fail('NETWORK_TIMEOUT', '教务连接超时');
    } on FormatException catch (error, stack) {
      _log(error, stack, 'UPSTREAM_FORMAT');
      result = _fail('UPSTREAM_FORMAT', '教务返回的数据格式异常');
    } on SocketException catch (error, stack) {
      _log(error, stack, 'NETWORK_FAILED');
      result = _fail('NETWORK_FAILED', '教务连接失败');
    } on http.ClientException catch (error, stack) {
      _log(error, stack, 'NETWORK_FAILED');
      result = _fail('NETWORK_FAILED', '教务连接失败');
    } catch (error, stack) {
      _log(error, stack, 'LOGIN_FAILED');
      result = _fail('LOGIN_FAILED', '登录未完成，请重试');
    }
    if (epoch != _epoch) return _fail('ACCOUNT_CHANGED', '登录操作已取消或被替换');
    _busy = false;
    if (!result.ok) cancel();
    return result;
  }

  CaptchaView _captcha(CaptchaViewData data) => CaptchaView(prompt: data.prompt, hint: data.hint, contentType: data.contentType, imageBase64: data.imageBase64);

  void _log(Object error, StackTrace stack, String code) => stderr.writeln('[KingoAuth] code=$code errorType=${error.runtimeType}\n$stack');

  String _stamp() => _now().toUtc().toIso8601String();

  GatewayResult<T> _fail<T>(String code, String message) => GatewayResult(ok: false, source: 'edu', fetchedAt: _stamp(), error: GatewayError(code: code, message: message));
}
