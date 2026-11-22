import 'dart:io';

import 'package:timezone/timezone.dart' as tz;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_http.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';

// 住理服务端的时间都是不带时区的北京时间字符串（2026-11-21 16:51:04），是对方协议的写法、不是本应用的业务时区：
// 进来的在这里换成 UTC 绝对时刻再交给界面按校园时区显示，发出去的查询时间窗也在这里换算。
const zhuliTimeZone = 'Asia/Shanghai';

tz.Location get _zone {
  ensureCampusClock();
  return tz.getLocation(zhuliTimeZone);
}

// 住理的时间字符串换成 UTC 的 ISO 字符串；认不出（空、0001 年这类占位）返回空。
String? zhuliMoment(String text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(text.trim());
  if (match == null || int.parse(match[1]!) < 2012) return null;
  final parts = [for (var index = 1; index <= 6; index++) int.parse(match[index]!)];
  return tz.TZDateTime(_zone, parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).toUtc().toIso8601String();
}

// 绝对时刻写成住理要的北京时间字符串。
String zhuliClock(DateTime instant) {
  final local = tz.TZDateTime.from(instant, _zone);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

// 住理接口（资料附录 A）。平台端的几个（登录、图形验证码、找回密码）不要会话；其余都带一次登录拿到的 ZhuliSession。
class ZhuliClient {
  ZhuliClient({ZhuliHttp? http}) : http = http ?? ZhuliHttp();
  final ZhuliHttp http;

  static final _platform = Uri.parse(zhuliPlatformBase);

  // 一页消费订单最多 20 条（11-22 实测：时间窗怎么放都只回最近 20 条），翻页把上一页最后一条的时刻当新的截止。
  static const consumePage = 20;
  static const rechargePage = 20;
  static const couponPage = 20;

  // 手机号加 6 位数字密码登录；住理要图形验证码时抛 captchaRequired，带上 captcha 再登一次。
  // deviceToken 是这台手机上本工具自己生成的随机串（见 zhuli_vault.dart），机型不报，只报系统类型。
  Future<ZhuliSession> login(String phone, String password, {required String deviceToken, String captcha = ''}) async => decodeZhuliLogin(
    await http.get(_platform, '/webapi/users/login', {
      'appVersion': zhuliAppVersion,
      'systemType': Platform.isIOS ? 'ios' : 'android',
      'deviceModel': 'SuperXD',
      'deviceToken': deviceToken,
      'pwd': password,
      'phone': phone,
      'code': captcha,
      'user_extends': {'isAlipayAppExist': false},
    }, key: zhuliPlatformKey),
  );

  // 图形验证码（SVG 文本）。
  Future<String> captcha(String phone) async => switch (zhuliObject(await http.get(_platform, '/webapi/users/get_login_code', {'phone': phone}, key: zhuliPlatformKey))['codeImg']) {
    final String svg when svg.contains('<svg') => svg,
    _ => throw const ZhuliException(ZhuliFailure.invalidResponse, '验证码没取到，再点一次'),
  };

  // 找回密码：先发短信验证码，再用验证码设新密码（6 位数字，同原 App 的「短信验证」）。
  Future<void> sendResetCode(String phone) => http.get(_platform, '/webapi/users/sendresetpwdSMS', {'phone': phone}, key: zhuliPlatformKey);

  Future<void> resetPassword(String phone, {required String code, required String password}) => http.get(_platform, '/webapi/users/resetpwd', {
    'newpwd': password,
    'phone': phone,
    'code': code,
    'system_type': Platform.isIOS ? 'ios' : 'android',
    'sign_type': 'RSA',
  }, key: zhuliPlatformKey);

  Future<Object?> _call(ZhuliSession session, String path, [Map<String, Object?> params = const {}]) => http.get(session.base, path, params, key: session.key, common: session.common);

  Future<ZhuliProfile> profile(ZhuliSession session) async => decodeZhuliProfile(await _call(session, '/webapi/v1/staff/get_user_detail_by_id', {'id': session.userId}));

  Future<ZhuliConfig> config(ZhuliSession session) async => decodeZhuliConfig(await _call(session, '/webapi/v1/app_setting/get_config'));

  // 我的券：page 从 0 起（这个接口的分页从 0 起，别的从 1 起）。
  Future<ZhuliCouponPage> coupons(ZhuliSession session, ZhuliCouponTab tab, {int page = 0}) async => decodeZhuliCoupons(
    await _call(session, '/webapi/v1/cash_coupon/list_staff_cash_coupon_app', {'user_id': session.userId, 'staff_id': '', 'page_index': page, 'page_size': couponPage, ...tab.filter}),
  );

  // 一张券某个月的抵扣记录：month 写成 2026-11；page_index 0 是整月全部（实测忽略 page_size）。
  Future<List<ZhuliCouponRecord>> couponRecords(ZhuliSession session, String couponId, String month) async =>
      decodeZhuliCouponRecords(await _call(session, '/webapi/v1/cash_coupon/list_staff_cash_coupon_record', {'id': couponId, 'page_index': 0, 'page_size': couponPage, 'date': month}));

  // 充值订单：page 从 1 起（传 0 回 result=false），没有总数，回来的不满一页就是到底了；status、type 服务端不看，照原 App 带上。
  Future<List<ZhuliRechargeOrder>> rechargeOrders(ZhuliSession session, {required int page}) async =>
      decodeZhuliRechargeOrders(await _call(session, '/webapi/v1/recharge/list_order_app', {'page_index': page, 'page_size': rechargePage, 'status': 4, 'type': -1, 'staff_id': ''}));

  Future<ZhuliRechargeOrder> rechargeOrder(ZhuliSession session, String outTradeNo) async =>
      decodeZhuliRechargeOrder(await _call(session, '/webapi/v1/recharge/get_order_by_out_trade_no', {'out_trade_no': outTradeNo, 'staff_id': ''}));

  // 消费订单：起止时刻必填，回来是数组、最多 20 条（见 consumePage）。
  Future<List<ZhuliConsumeRecord>> consumeRecords(ZhuliSession session, {required DateTime start, required DateTime end}) async =>
      decodeZhuliConsumeRecords(await _call(session, '/webapi/v1/consume/list_record_by_staffid', {'staff_id': session.userId, 'start': zhuliClock(start), 'end': zhuliClock(end)}));

  Future<ZhuliBill> bill(ZhuliSession session, String orderId) async => decodeZhuliBill(await _call(session, '/webapi/v1/staff/get_bill_detail_by_id', {'bill_id': orderId, 'use_type': 'consume'}));

  void close() => http.close();
}
