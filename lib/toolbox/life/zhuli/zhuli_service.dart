import 'dart:async';
import 'dart:io';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// [人工决策-2026-11-22 18:46:09] 生活的第一个子模块住理生活（洗浴、充值、买券、余额与券、订单；资料 ~/Projects/SelfProjects/API/shenghuo/zhuli，
// 11-22 用户两轮选项）：灰度开关 toolbox.life.zhuli 默认关、先点名给开发者（11-23 全量、11-27 删掉开关，见 domain/feature_flags.dart）；沿用快递的立场接受公开仓库接住理私有接口的风险；
// 不用资料里靠测试手机号触发的 mp.whxinna.com 调试转发，staff_id 只填自己，资料列出的越权点一个都不碰。
// 用户选了：充值与买券接支付宝 SDK（tobias，微信支付按应用签名认 AppID 做不了）；常用设备与最近使用分两份（最近 6 台、收藏最多 20 台，都只存本机）；
// 自定义充值 0.01–500 元、最多两位小数（服务端只拒负数）；余额与券只显示服务端的真实结果（服务端按券的 use_order 自己扣，客户端没法选券）；
// 增项要进行中通知、蓝牙开阀、设备报修、桌面快捷入口、券使用记录、多账号切换，不做强制结束与消费投诉。
// [人工决策-2026-11-22 20:12:55] 登录：手机号加 6 位数字密码（官方要图形验证码时当场输），密码在登录成功后才记进系统安全存储，
// 会话过期时在后台用它重登并重放一次（洗澡中途会话过期也能关水）；用户选的「短信验证码登录」官方没有（资料里的 get_login_code 是图形验证码），
// 改选「短信找回密码」，没选支付宝快捷登录（没有密码可存，会话过期不能在后台重登）。
// [人工决策-2026-11-23 22:09:09] 用户取消增项里的进行中通知与设备报修、不再开发，住理生活到第四轮为止；同时全量（灰度配置放到 100%，见 domain/feature_flags.dart）。
//
// 服务：持有账号的安全存储、本机的设备列表与客户端，没有业务库（余额、券与订单即查即用，不落盘）。每个账号一份会话，只在内存。
class ZhuliService implements ToolboxService {
  ZhuliService({required this.vault, required this.devices, ZhuliClient? client, LifeAlipay? payer}) : client = client ?? ZhuliClient(), payer = payer ?? TobiasLifeAlipay();
  final ZhuliVault vault;
  final ZhuliDeviceStore devices;
  // 支付宝付款（充值与买券；测试注入假的）。
  final LifeAlipay payer;
  final ZhuliClient client;
  final _sessions = <String, ZhuliSession>{};
  final _logins = <String, Future<ZhuliSession>>{};

  // 子模块 id：路由（/toolbox/life/zhuli）、服务与同意记录共用，发出后不改。
  static const serviceId = 'life.zhuli';
  // 第一次登录前的同意说明的版本，说明有实质变化就加一档。
  // [人工决策-2026-11-24 13:24:06] zhuli-2：用户要求面向用户的文字一起重写得简洁（见 lib/page/legal_page.dart 同一时刻那条），
  // 补写在这里登录与官方 App 会互相要求重新登录（11-24 修复后两边都会自动重登），升一档。
  static const consentVersion = 'zhuli-2';

  static Future<ZhuliService> open(ToolboxServiceContext context) async => ZhuliService(vault: SecureZhuliVault(), devices: ZhuliDeviceStore.file(File('${context.base.path}/zhuli_devices.json')));

  Future<ZhuliVaultState> state() => vault.load();

  // 登录（也用来加账号、重新登录）：成功后才记下密码并设为当前账号，同一手机号只记一份，最多 zhuliAccountLimit 个。
  Future<ZhuliSession> signIn(String phone, String password, {String captcha = ''}) async {
    final state = await vault.load();
    final session = await client.login(phone, password, deviceToken: state.device, captcha: captcha);
    final accounts = [ZhuliCredential(phone: phone, password: password), ...state.accounts.where((account) => account.phone != phone)];
    await vault.save(ZhuliVaultState(accounts: accounts.take(zhuliAccountLimit).toList(), active: phone, device: state.device));
    _sessions[phone] = session;
    return session;
  }

  Future<void> switchTo(String phone) async {
    final state = await vault.load();
    if (state.accounts.any((account) => account.phone == phone)) await vault.save(ZhuliVaultState(accounts: state.accounts, active: phone, device: state.device));
  }

  // 退出这个账号：删掉它的密码与会话（住理那边的账号与数据不动），当前账号换成剩下的第一个。
  Future<void> signOut(String phone) async {
    final state = await vault.load();
    final accounts = [for (final account in state.accounts) if (account.phone != phone) account];
    await vault.save(ZhuliVaultState(accounts: accounts, active: state.active == phone ? accounts.firstOrNull?.phone : state.active, device: state.device));
    _sessions.remove(phone);
  }

  // 带着这个账号的会话做一次请求：还没有会话先用记着的密码登录；会话过期（login_timeout，或别处登录换掉了签名密钥回 api_sign_error）自动重登一次再重放这一次
  // （跨模块不变量 9 允许的「会话自动恢复后的一次重放」）。重登时住理要图形验证码、或密码不对了，抛给页面请用户重新登录。
  Future<T> run<T>(String phone, Future<T> Function(ZhuliSession session) action) async {
    final session = _sessions[phone] ?? await _relogin(phone);
    try {
      return await action(session);
    } on ZhuliException catch (error) {
      if (error.failure != ZhuliFailure.sessionExpired) rethrow;
      if (identical(_sessions[phone], session)) _sessions.remove(phone);
      campusLog('[Zhuli] action=relogin reason=${error.code}');
      return action(_sessions[phone] ?? await _relogin(phone));
    }
  }

  // 同一个账号同时只重登一次，几处一起等。
  Future<ZhuliSession> _relogin(String phone) => _logins.putIfAbsent(phone, () async {
    try {
      final state = await vault.load();
      final credential = state.accounts.where((account) => account.phone == phone).firstOrNull;
      if (credential == null) throw const ZhuliException(ZhuliFailure.notSignedIn, '请先登录');
      try {
        return _sessions[phone] = await client.login(phone, credential.password, deviceToken: state.device);
      } on ZhuliException catch (error) {
        // 密码在别处改过、账号被停用这类：请用户重新登录（住理的原话照写）。
        if (error.failure == ZhuliFailure.rejected) throw ZhuliException(ZhuliFailure.notSignedIn, error.message);
        rethrow;
      }
    } finally {
      unawaited(_logins.remove(phone));
    }
  });

  // 未使用的券加起来还剩多少（首页「券余额」）：一页 20 张，最多翻 5 页。
  Future<({int balance, int count})> couponBalance(ZhuliSession session) async {
    var balance = 0, count = 0;
    for (var page = 0; page < 5; page++) {
      final result = await client.coupons(session, ZhuliCouponTab.unused, page: page);
      balance += result.coupons.fold(0, (sum, coupon) => sum + coupon.balance);
      count += result.coupons.length;
      if (result.coupons.length < ZhuliClient.couponPage || count >= result.total) break;
    }
    return (balance: balance, count: count);
  }

  @override
  Future<void> close() async => client.close();

  // 清除数据：删掉安全存储里本工具的全部账号与密码、本机的设备列表（住理那边的账号、余额与订单都不动），内存里的会话一并丢掉。
  @override
  Future<void> clearData() async {
    _sessions.clear();
    await vault.deleteAll();
    await devices.deleteAll();
  }
}
