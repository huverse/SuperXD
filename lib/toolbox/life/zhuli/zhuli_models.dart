import 'dart:convert';

// 住理生活的数据类型。回复全是外部输入：decode* 逐项核对类型，不对抛 ZhuliException(invalidResponse)。
// 金额一律按「分」的整数存（服务端给的是 18.4、"13.3900" 这类数或字符串，按十进制文本换算、四舍五入到分，不经浮点运算）。

enum ZhuliFailure {
  // 没连上、断开、TLS 失败。
  network,
  timeout,
  // 回复不是认得的格式（改版时最先坏在这里）。
  invalidResponse,
  // 会话过期（login_timeout）：服务层自动重登一次再重放。
  sessionExpired,
  // 住理要图形验证码（本次登录需要进行验证）：只能请用户在登录页输。
  captchaRequired,
  // 本机没有这个账号的密码（退出了或清除了数据）。
  notSignedIn,
  // 住理明确拒绝（密码错误、余额不足这类），message 是给用户看的话。
  rejected,
  // 蓝牙设备在附近找不到或连不上（多半是同房间换下来、已不在用的老设备），洗浴页据此给出「换到同房间的另一台」。
  unreachable,
}

class ZhuliException implements Exception {
  const ZhuliException(this.failure, this.message);
  final ZhuliFailure failure;
  final String message;
  @override
  String toString() => 'ZhuliException($failure)';
}

const _invalid = ZhuliException(ZhuliFailure.invalidResponse, '住理生活的返回看不懂，稍后再试');

Never _bad(String field) => throw _invalid;

String _text(Map<String, Object?> json, String field, {bool optional = false}) => switch (json[field]) {
  final String value => value,
  final num value => '$value',
  null when optional => '',
  _ => _bad(field),
};

int _int(Map<String, Object?> json, String field, {int? fallback}) => switch (json[field]) {
  final int value => value,
  final double value when value == value.truncateToDouble() => value.toInt(),
  final String value when int.tryParse(value) != null => int.parse(value),
  null when fallback != null => fallback,
  _ => _bad(field),
};

int _cents(Map<String, Object?> json, String field, {bool optional = false}) => zhuliCents(json[field]) ?? (optional && json[field] == null ? 0 : _bad(field));

Map<String, Object?> zhuliObject(Object? value) => value is Map ? value.cast<String, Object?>() : _bad('object');

List<Map<String, Object?>> zhuliRows(Object? value, {String? field}) {
  final list = field == null ? value : zhuliObject(value)[field];
  if (list == null && field != null) return const [];
  if (list is! List) _bad(field ?? 'list');
  return [for (final row in list) zhuliObject(row)];
}

// 金额换成分：数或十进制文本（"13.3900"、176.35、-0.14），四舍五入到分；不是金额返回空。
int? zhuliCents(Object? raw) {
  final text = switch (raw) {
    final num value => value.toString(),
    final String value => value.trim(),
    _ => null,
  };
  final match = text == null ? null : RegExp(r'^(-?)(\d{1,12})(?:\.(\d+))?$').firstMatch(text);
  if (match == null) return null;
  final fraction = (match[3] ?? '').padRight(3, '0');
  final cents = int.parse(match[2]!) * 100 + int.parse(fraction.substring(0, 2)) + (int.parse(fraction[2]) >= 5 ? 1 : 0);
  return match[1] == '-' ? -cents : cents;
}

// 分写成元，两位小数（1840 → 18.40）。
String zhuliYuan(int cents) => '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';

// 本机记着的一个住理账号：手机号与登录密码（只在系统安全存储，见 zhuli_vault.dart）。
class ZhuliCredential {
  const ZhuliCredential({required this.phone, required this.password});
  final String phone;
  final String password;
}

// 一次登录拿到的业务会话（只在内存，约 20–40 分钟过期，过期由服务层用记着的密码重登）。
class ZhuliSession {
  const ZhuliSession({required this.base, required this.key, required this.userId, required this.identity, required this.pid, required this.appid, required this.project});
  // 业务接口的地址（登录给的 server_addr，只认 https 的 whxinna.com 主机）。
  final Uri base;
  // 签名密钥 session_secret（有它时盖过 appsecret）。
  final String key;
  final String userId;
  final String identity;
  final Object pid;
  final Object appid;
  // 学校（项目）名。
  final String project;

  Map<String, Object> get common => {'user_id': userId, 'identitycode': identity, 'pid': pid, 'appid': appid};
}

ZhuliSession decodeZhuliLogin(Object? data) {
  final json = zhuliObject(data);
  final server = zhuliObject(json['server_info']);
  final user = zhuliObject(json['user_info']);
  final base = Uri.tryParse(_text(server, 'server_addr'));
  // 业务地址来自回复：只认 https 的 whxinna.com 主机，免得把签名与身份参数发去别处。
  if (base == null || base.scheme != 'https' || !(base.host == 'whxinna.com' || base.host.endsWith('.whxinna.com')) || base.hasPort || base.userInfo.isNotEmpty) _bad('server_addr');
  final key = _text(server, 'session_secret', optional: true);
  Object id(String field) => switch (server[field]) {
    final num value => value,
    final String value when value.isNotEmpty => value,
    _ => _bad(field),
  };
  final pid = id('server_appid'), appid = id('server_id');
  return ZhuliSession(
    base: base.replace(path: base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path),
    key: key.isNotEmpty ? key : _text(server, 'appsecret'),
    userId: _text(user, 'id'),
    identity: _text(user, 'identity_code'),
    pid: pid,
    appid: appid,
    project: _text(server, 'projectname', optional: true),
  );
}

// 账户：余额以 get_user_detail_by_id 为准（登录回复里的余额不可信，资料实测 0.0000 对真实 18.39）。
// 计费规则也在这里（ChargeRules，设备级的 device_chargerule/get 这个项目返回空）。
class ZhuliProfile {
  const ZhuliProfile({required this.balance, required this.frozen, required this.couponCount, this.rules = const []});
  final int balance;
  final int frozen;
  final int couponCount;
  final List<ZhuliChargeRule> rules;

  // 一台设备的计费规则：按设备类型与设备分组对上（11-22 实测这个项目洗浴有默认分组 0 与 1001 两条）；没有为空，开不了。
  ZhuliChargeRule? ruleFor(ZhuliDevice device) => rules.where((rule) => rule.deviceType == device.type && rule.groupId == device.groupId).firstOrNull;
}

ZhuliProfile decodeZhuliProfile(Object? data) {
  final json = zhuliObject(data);
  return ZhuliProfile(
    balance: _cents(json, 'balance'),
    frozen: _cents(json, 'frozen_balance', optional: true),
    couponCount: _int(json, 'cash_coupon_count', fallback: 0),
    rules: [for (final row in zhuliRows(json, field: 'ChargeRules')) _rule(row)],
  );
}

// 计费规则里开水前要给人看的几项：预扣多少、单价（按量计费时每个计费单位约 1 升）。
class ZhuliChargeRule {
  const ZhuliChargeRule({required this.deviceType, required this.groupId, required this.prepaid, required this.price, required this.metering});
  final int deviceType;
  final int groupId;
  // 开水时先扣（charge_money），关水后按用量多退少补。
  final int prepaid;
  // 第一档单价（分）；没有档为空。
  final int? price;
  // 按量（metering）还是按时长。
  final bool metering;
}

ZhuliChargeRule _rule(Map<String, Object?> json) {
  final units = zhuliRows(json, field: 'charge_units');
  return ZhuliChargeRule(
    deviceType: _int(json, 'device_type'),
    groupId: _int(json, 'device_group_id', fallback: 0),
    prepaid: _cents(json, 'charge_money', optional: true),
    price: units.isEmpty ? null : _cents(units.first, 'price'),
    metering: _text(json, 'charge_option', optional: true) != 'timing',
  );
}

// 项目配置里用到的几项（get_config；整份很大，只取要的）。
class ZhuliConfig {
  const ZhuliConfig({
    required this.consumeOrderDays,
    this.bath = true,
    this.minimumBalance = 0,
    this.continueBelowMinimum = false,
    this.forceSupplyTime = false,
    this.rechargeShown = true,
    this.rechargeClosed,
    this.alipay = true,
  });
  // 消费订单能查最近几天（consume_order_display_cut_enable 开着时），为空表示不限。
  final int? consumeOrderDays;
  // 洗浴开着（bath_enable，关了整个洗浴入口不显示）。
  final bool bath;
  // 余额低于它不让开（minimum_consume_balance，0 不拦；券不算在内，同原 App）。
  final int minimumBalance;
  // 低于门槛时还能选「继续使用」（continue_use_on_min_consume_balance_enabled）。
  final bool continueBelowMinimum;
  // 不在供水时段时不让开（force_supply_time 为 1；否则只提醒）。
  final bool forceSupplyTime;
  // 充值入口显示（recharge_display_enable）；关着充值时（recharge_enable 为 0）给人看的原因（recharge_unenable_desc），开着为空。
  final bool rechargeShown;
  final String? rechargeClosed;
  // 支付宝付款开着（alipay_enable；本应用只接支付宝）。
  final bool alipay;
}

ZhuliConfig decodeZhuliConfig(Object? data) {
  final json = zhuliObject(data);
  final days = _int(json, 'consume_order_display_cut_days', fallback: 0);
  return ZhuliConfig(
    consumeOrderDays: _int(json, 'consume_order_display_cut_enable', fallback: 0) == 1 && days > 0 ? days : null,
    bath: _int(json, 'bath_enable', fallback: 1) == 1,
    minimumBalance: _cents(json, 'minimum_consume_balance', optional: true),
    continueBelowMinimum: _int(json, 'continue_use_on_min_consume_balance_enabled', fallback: 0) == 1,
    forceSupplyTime: _int(json, 'force_supply_time', fallback: 0) == 1,
    rechargeShown: _int(json, 'recharge_display_enable', fallback: 1) == 1,
    rechargeClosed: _int(json, 'recharge_enable', fallback: 1) == 1 ? null : switch (_text(json, 'recharge_unenable_desc', optional: true)) {
      '' => '暂时不能充值',
      final reason => reason,
    },
    alipay: _int(json, 'alipay_enable', fallback: 0) == 1,
  );
}

// ---------- 充值与买券 ----------

// 充值的一档额度（list_recharge_quota）与充这一档送的券（11-22 这个学校 20/50/100/200 都不送）。
class ZhuliQuota {
  const ZhuliQuota({required this.value, required this.giftCount, required this.giftMoney});
  final int value;
  final int giftCount;
  final int giftMoney;
}

List<ZhuliQuota> decodeZhuliQuotas(Object? data) => [
  for (final row in zhuliRows(data))
    ZhuliQuota(value: _cents(row, 'quota'), giftCount: _int(row, 'cash_coupon_count', fallback: 0), giftMoney: _cents(row, 'cash_coupon_money', optional: true)),
];

// 能买的券（get_cash_coupon_app，回数组）：售价与面额只给人看，下单不带金额（住理按商品定价）。
class ZhuliGoods {
  const ZhuliGoods({
    required this.id,
    required this.name,
    required this.price,
    required this.money,
    required this.useLimit,
    required this.couponFirst,
    required this.stock,
    required this.limit,
    required this.bought,
    required this.expireAt,
    required this.validDays,
  });
  final String id;
  final String name;
  final int price;
  final int money;
  final List<String> useLimit;
  final bool couponFirst;
  // 剩余张数（total_count）。
  final int stock;
  // 限购张数（0 不限）与已买的张数（没付的不算）。
  final int limit;
  final int bought;
  final String expireAt;
  // 买后几天有效（validated_days，0 是按到期时刻）。
  final int validDays;

  // 买不了的原因（同原 App：限购买满、售罄），能买为空。
  String? get unavailable => limit != 0 && bought >= limit ? '限购 $limit 张，已买满' : stock <= 0 ? '已售罄' : null;
}

List<ZhuliGoods> decodeZhuliGoods(Object? data) => [
  for (final row in zhuliRows(data))
    ZhuliGoods(
      id: _text(row, 'id'),
      name: _text(row, 'name', optional: true),
      price: _cents(row, 'price'),
      money: _cents(row, 'money', optional: true),
      useLimit: [for (final part in _text(row, 'use_limit', optional: true).split(',')) if (part.trim().isNotEmpty) part.trim()],
      couponFirst: _int(row, 'use_order', fallback: 0) == 0,
      stock: _int(row, 'total_count', fallback: 0),
      limit: _int(row, 'limit_count', fallback: 0),
      bought: _int(row, 'gained_count', fallback: 0),
      expireAt: _text(row, 'expire_at', optional: true),
      validDays: _int(row, 'validated_days', fallback: 0),
    ),
];

// 下好的付款单（充值 createorder 与买券 buy_cash_coupon）：订单号与交给支付宝的支付串（5 分钟内有效）。
// 只认支付宝 APP 支付串（method=alipay.trade.app.pay）；微信、农行安心付与扫码串本应用不接。支付串不进日志。
class ZhuliPayOrder {
  const ZhuliPayOrder({required this.orderId, required this.orderContent});
  final String orderId;
  final String orderContent;
}

ZhuliPayOrder decodeZhuliPayOrder(Object? data) {
  final json = zhuliObject(data);
  final content = _text(json, 'order_content');
  if (!content.contains('alipay.trade.app.pay')) throw const ZhuliException(ZhuliFailure.rejected, '住理给的不是支付宝付款单，换住理生活 App 付');
  return ZhuliPayOrder(orderId: _text(json, 'order_id'), orderContent: content);
}

// 买的券到账没有（list_staff_cash_coupon_app 按订单号查，回调写进来之前 rows 为空）。
bool decodeZhuliCouponPaid(Object? data) => zhuliRows(data, field: 'rows').any((row) => row['trade_status'] == 'TRADE_SUCCESS');

// 我的优惠券的三栏（list_staff_cash_coupon_app 的入参组合；回复里 status 与 is_blance 恒为空，只能靠入参过滤）。
enum ZhuliCouponTab {
  unused('未使用', {'is_blance': 1, 'status': 1}),
  spent('已用完', {'is_blance': 2, 'status': 1}),
  expired('已失效', {'status': 2});

  const ZhuliCouponTab(this.label, this.filter);
  final String label;
  final Map<String, int> filter;
}

// 一张券（储值式代金券：带余额，可多次抵扣，抵扣由服务端在消费时自动完成，客户端不能选券）。
class ZhuliCoupon {
  const ZhuliCoupon({required this.id, required this.name, required this.balance, required this.total, required this.useLimit, required this.couponFirst, required this.startAt, required this.expireAt});
  final String id;
  final String name;
  final int balance;
  final int total;
  // 适用范围（all、bath…）。
  final List<String> useLimit;
  // 抵扣顺序：true 优先用券，false 优先用余额。
  final bool couponFirst;
  final String startAt;
  final String expireAt;

  // 失效时刻在 2099 年及以后表示长期有效。
  bool get permanent => expireAt.compareTo('2099') >= 0;
}

ZhuliCoupon _coupon(Map<String, Object?> json) => ZhuliCoupon(
  id: _text(json, 'id'),
  name: _text(json, 'cash_coupon_name', optional: true),
  balance: _cents(json, 'balance'),
  total: _cents(json, 'total_money', optional: true),
  useLimit: [for (final part in _text(json, 'use_limit', optional: true).split(',')) if (part.trim().isNotEmpty) part.trim()],
  couponFirst: _int(json, 'use_order', fallback: 0) == 0,
  startAt: _text(json, 'start_at', optional: true),
  expireAt: _text(json, 'expire_at', optional: true),
);

// 一页券与总张数。
typedef ZhuliCouponPage = ({List<ZhuliCoupon> coupons, int total});

ZhuliCouponPage decodeZhuliCoupons(Object? data) {
  final json = zhuliObject(data);
  return (coupons: [for (final row in zhuliRows(json, field: 'rows')) _coupon(row)], total: _int(json, 'total_count', fallback: 0));
}

// 券的一笔抵扣：value 是负数（扣了多少），couponBalance 是扣完剩多少。
class ZhuliCouponRecord {
  const ZhuliCouponRecord({required this.value, required this.couponBalance, required this.createAt, required this.consumeType, required this.orderId});
  final int value;
  final int couponBalance;
  final String createAt;
  final String consumeType;
  final String orderId;
}

List<ZhuliCouponRecord> decodeZhuliCouponRecords(Object? data) => [
  for (final row in zhuliRows(data, field: 'rows'))
    ZhuliCouponRecord(value: _cents(row, 'value'), couponBalance: _cents(row, 'coupon_balance'), createAt: _text(row, 'create_at'), consumeType: _text(row, 'consume_type', optional: true), orderId: _text(row, 'consume_record_id', optional: true)),
];

// 充值订单（列表一行，详情多几项）。状态见 zhuliRechargeStatus。
class ZhuliRechargeOrder {
  const ZhuliRechargeOrder({required this.outTradeNo, required this.value, required this.status, required this.createAt, this.tradeNo = '', this.payTime = '', this.rechargeType, this.balance});
  final String outTradeNo;
  final int value;
  final int status;
  final String createAt;
  final String tradeNo;
  // 没付时住理写 2011-01-01 00:00:00。
  final String payTime;
  // 2 支付宝、3 微信、6 农行、10 云闪付。
  final int? rechargeType;
  // 到账后的余额（分）。
  final int? balance;

  bool get paid => status == 0;
}

List<ZhuliRechargeOrder> decodeZhuliRechargeOrders(Object? data) => [
  for (final row in zhuliRows(data, field: 'rows')) ZhuliRechargeOrder(outTradeNo: _text(row, 'out_trade_no'), value: _cents(row, 'recharge_value'), status: _int(row, 'status'), createAt: _text(row, 'create_at')),
];

ZhuliRechargeOrder decodeZhuliRechargeOrder(Object? data) {
  final row = zhuliObject(data);
  return ZhuliRechargeOrder(
    outTradeNo: _text(row, 'out_trade_no'),
    value: _cents(row, 'recharge_value'),
    status: _int(row, 'status'),
    createAt: _text(row, 'create_at', optional: true),
    tradeNo: _text(row, 'trade_no', optional: true),
    payTime: _text(row, 'pay_time', optional: true),
    rechargeType: row['recharge_type'] == null ? null : _int(row, 'recharge_type'),
    balance: row['balance'] == null ? null : _cents(row, 'balance'),
  );
}

// 消费订单列表的一行（list_record_by_staffid 是精简投影，设备号、用量要查详情）。
class ZhuliConsumeRecord {
  const ZhuliConsumeRecord({required this.orderId, required this.consumeType, required this.status, required this.createAt, required this.money, required this.deviceName});
  final String orderId;
  final String consumeType;
  final String status;
  final String createAt;
  final int money;
  final String deviceName;
}

List<ZhuliConsumeRecord> decodeZhuliConsumeRecords(Object? data) => [
  for (final row in zhuliRows(data))
    ZhuliConsumeRecord(orderId: _text(row, 'order_id'), consumeType: _text(row, 'consume_type', optional: true), status: _text(row, 'status'), createAt: _text(row, 'create_at'), money: _cents(row, 'consume_money', optional: true), deviceName: _text(row, 'device_name', optional: true)),
];

// 消费订单详情（get_bill_detail_by_id，use_type=consume；也是开阀后轮询的接口）。
class ZhuliBill {
  const ZhuliBill({
    required this.orderId,
    required this.consumeType,
    required this.status,
    required this.createAt,
    required this.money,
    required this.prepaid,
    required this.refund,
    required this.liters,
    required this.seconds,
    required this.deviceName,
    required this.place,
    required this.payChannel,
    required this.fromCoupon,
    required this.fromBalance,
    required this.fromPay,
  });
  final String orderId;
  final String consumeType;
  final String status;
  final String createAt;
  // 实扣。
  final int money;
  // 下单预扣（charge_money），结束按用量多退少补。
  final int prepaid;
  final int refund;
  // 第一个端口的水量（升），不是钱、按原样留小数。
  final double liters;
  // 有效用水时长（秒）。
  final int seconds;
  final String deviceName;
  // 楼栋/楼层/房间。
  final String place;
  final int? payChannel;
  final int fromCoupon;
  final int fromBalance;
  final int fromPay;
}

ZhuliBill decodeZhuliBill(Object? data) {
  final row = zhuliObject(data);
  final liters = row['water_volume_1'];
  final building = _text(row, 'building_name', optional: true), floor = _text(row, 'floor_name', optional: true), room = _text(row, 'room_name', optional: true);
  return ZhuliBill(
    orderId: _text(row, 'order_id'),
    consumeType: _text(row, 'consume_type', optional: true),
    status: _text(row, 'status'),
    createAt: _text(row, 'create_at', optional: true),
    money: _cents(row, 'consume_money', optional: true),
    prepaid: _cents(row, 'charge_money', optional: true),
    refund: _cents(row, 'refund_money', optional: true),
    liters: liters is num ? liters.toDouble() : 0,
    seconds: _int(row, 'consume_timing', fallback: 0),
    deviceName: _text(row, 'device_name', optional: true),
    place: [building, if (floor.isNotEmpty) '$floor层', room].where((part) => part.isNotEmpty).join(' '),
    payChannel: row['pay_channel'] == null ? null : _int(row, 'pay_channel'),
    fromCoupon: _cents(row, 'deduct_from_coupon', optional: true),
    fromBalance: _cents(row, 'deduct_from_balance', optional: true),
    fromPay: _cents(row, 'deduct_from_pay', optional: true),
  );
}

// ---------- 洗浴 ----------

// 供水时段的一段：一天里的分钟数（北京时间；住理写成 2025-03-08T06:00:00，只看钟点）。
typedef ZhuliSupply = ({int start, int end});

// 一台设备（device/get_by_id 与房间设备列表；列表那份少几项，缺的按没有处理）。
class ZhuliDevice {
  const ZhuliDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.netType,
    required this.modules,
    required this.status,
    required this.idle,
    required this.groupId,
    required this.primaryNet,
    required this.forceBluetooth,
    required this.supply,
    required this.building,
    required this.floor,
    required this.room,
    required this.bleName,
    required this.bleMac,
  });
  final int id;
  final String name;
  // 0 水控机（洗浴），其余见资料 3.1.1；这一版只开洗浴。
  final int type;
  final int netType;
  // 设备支持的通道（net_module 拆开：4 蓝牙、6 移动 4G、7 NBIOT…）。
  final List<int> modules;
  // 0 正常，其余（维护、故障）不能用。
  final int status;
  // consume_status 为 1：空闲。
  final bool idle;
  final int groupId;
  // primary_consume_net_type：非 0 时优先用它。
  final int? primaryNet;
  // change_network 非空：原 App 改走蓝牙。
  final bool forceBluetooth;
  final List<ZhuliSupply> supply;
  final String building;
  final String floor;
  final String room;
  // 蓝牙广播名（XN-设备号）与地址（AA:BB:CC:DD:EE:FF；安卓扫描时名字没带上就按地址认）。
  final String bleName;
  final String bleMac;

  bool get bath => type == 0;

  // 楼栋/楼层/房间：1号楼 2层 201。
  String get place => [building, if (floor.isNotEmpty) '$floor层', room].where((part) => part.isNotEmpty).join(' ');

  // 开水走哪一路，同原 App 的 En()（network_selection 为 0 时）：指定了优先通道用它；change_network 改走蓝牙；
  // 有蓝牙时用第一个不是蓝牙的通道（「4,6」走 6 云端），只有蓝牙就走蓝牙；有 NBIOT 时走 1；都没有用 net_type。
  int get channel {
    if (primaryNet case final net? when net != 0) return net;
    if (forceBluetooth) return 4;
    if (modules.contains(4)) return modules.firstWhere((module) => module != 4, orElse: () => 4);
    if (modules.contains(7)) return 1;
    return netType;
  }

  bool get bluetooth => channel == 4;
}

// 供水时段（JSON 串里的数组）：外部输入，认不出的段跳过。
List<ZhuliSupply> _supply(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return const [];
  final Object? list;
  try {
    list = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (list is! List) return const [];
  int? minutes(Object? text) => switch (text is String ? RegExp(r'T(\d{2}):(\d{2})').firstMatch(text) : null) {
    final match? => int.parse(match[1]!) * 60 + int.parse(match[2]!),
    null => null,
  };
  return [
    for (final item in list)
      if (item is Map)
        if ((minutes(item['start_time']), minutes(item['end_time'])) case (final start?, final end?)) (start: start, end: end),
  ];
}

ZhuliDevice decodeZhuliDevice(Object? data) {
  final json = zhuliObject(data);
  final netType = _int(json, 'net_type', fallback: 0);
  final modules = [for (final part in _text(json, 'net_module', optional: true).split(',')) ?int.tryParse(part.trim())];
  return ZhuliDevice(
    id: _int(json, 'device_id'),
    name: _text(json, 'device_name', optional: true),
    type: _int(json, 'device_type'),
    netType: netType,
    modules: modules.isEmpty ? [netType] : modules,
    status: _int(json, 'status', fallback: 0),
    idle: _int(json, 'consume_status', fallback: 1) == 1,
    groupId: _int(json, 'group_id', fallback: 0),
    primaryNet: json['primary_consume_net_type'] == null ? null : _int(json, 'primary_consume_net_type'),
    forceBluetooth: switch (json['change_network']) {
      null => false,
      final String value => value.trim().isNotEmpty,
      _ => true,
    },
    supply: _supply(json['water_supply_time']),
    building: _text(json, 'building_name', optional: true),
    floor: _text(json, 'floor_name', optional: true),
    room: _text(json, 'room_name', optional: true),
    bleName: _text(json, 'ble_name', optional: true),
    bleMac: _text(json, 'ble_mac', optional: true),
  );
}

List<ZhuliDevice> decodeZhuliDevices(Object? data) => [for (final row in zhuliRows(data is Map ? zhuliObject(data)['rows'] : data)) decodeZhuliDevice(row)];

// 选设备的三级（楼栋、楼层、房间）共用：id 与名字，楼栋与房间多一个设备台数。
class ZhuliPlace {
  const ZhuliPlace({required this.id, required this.name, this.devices});
  final String id;
  final String name;
  // 设备总数：房间是 total_room_device_count，楼栋是 total_count（11-22 真机：楼栋没有前者，读成了 0）；normal_count 不准（资料 4.1.2）。没有为空。
  final int? devices;
}

int? _devices(Object? raw) {
  if (raw is! Map) return null;
  final count = zhuliObject(raw);
  if (count['total_room_device_count'] != null) return _int(count, 'total_room_device_count');
  if (count['total_count'] != null) return _int(count, 'total_count');
  return null;
}

List<ZhuliPlace> decodeZhuliPlaces(Object? data) => [
  for (final row in zhuliRows(data)) ZhuliPlace(id: _text(row, 'id'), name: _text(row, 'name', optional: true), devices: _devices(row['device_count'])),
];

// 开水下单（create_order）的回复：订单号、预扣后的余额与蓝牙开始帧（走蓝牙时有）。
class ZhuliOrderStart {
  const ZhuliOrderStart({required this.orderId, required this.status, this.balance, this.startFrame});
  final String orderId;
  final String status;
  final int? balance;
  final String? startFrame;
}

ZhuliOrderStart decodeZhuliOrderStart(Object? data) {
  final json = zhuliObject(data);
  final frame = _text(json, 'app_bytes', optional: true);
  return ZhuliOrderStart(
    orderId: _text(json, 'order_id'),
    status: _text(json, 'status', optional: true),
    balance: json['balance'] == null ? null : _cents(json, 'balance'),
    startFrame: frame.isEmpty ? null : frame,
  );
}

// 蓝牙握手的结果（heart_shark_response）：isn 是这次连接后续命令的校验串，rateCommand 有时要先写给设备，occupied 是设备正被占用（result 3）。
class ZhuliHandshake {
  const ZhuliHandshake({required this.isn, required this.rateCommand, required this.occupied});
  final String isn;
  final String? rateCommand;
  final bool occupied;
}

ZhuliHandshake decodeZhuliHandshake(Object? data) {
  final json = zhuliObject(data);
  final rate = _text(json, 'ratecmd', optional: true);
  return ZhuliHandshake(isn: _text(json, 'isn'), rateCommand: rate.isEmpty ? null : rate, occupied: _int(json, 'result', fallback: 0) == 3);
}

// 最近一笔消费（get_staff_last_record）：重开时接回进行中的单、蓝牙握手说设备被占用时看是不是自己的。
class ZhuliLastRecord {
  const ZhuliLastRecord({required this.orderId, required this.status, required this.deviceId, required this.deviceType, required this.createAt});
  final String orderId;
  final String status;
  final int deviceId;
  final int deviceType;
  final String createAt;

  bool get running => status == 'created' || status == 'consuming';
}

// 从没消费过时 data 为空。
ZhuliLastRecord? decodeZhuliLastRecord(Object? data) {
  if (data == null) return null;
  final json = zhuliObject(data);
  if (json['order_id'] == null) return null;
  return ZhuliLastRecord(orderId: _text(json, 'order_id'), status: _text(json, 'status', optional: true), deviceId: _int(json, 'device_id', fallback: 0), deviceType: _int(json, 'device_type', fallback: 0), createAt: _text(json, 'create_at', optional: true));
}

// 充值订单状态（资料第 3.4 节）。
String zhuliRechargeStatus(int status) => switch (status) {
  0 => '已到账',
  1 => '排队中',
  2 => '已冲账',
  7 => '等待支付',
  11 => '已退款',
  12 => '支付超时',
  100 => '已关闭',
  _ => '处理中',
};

// 消费订单状态（资料第 3.3 节；cancled 是住理的原拼写）。
String zhuliConsumeStatus(String status) => switch (status) {
  'created' => '已创建',
  'consuming' => '使用中',
  'finished' => '已结束',
  'cancled' => '已取消',
  'refund' => '已退款',
  'waiting_pay' => '待支付',
  'prepare_pay' => '支付中',
  'waiting_start' => '等待启动',
  'barrel_clean' => '清洗中',
  _ => status,
};

// 消费类型与券的适用范围。
String zhuliConsumeType(String type) => switch (type) {
  'all' => '通用',
  'bath' => '洗浴',
  'laundry' => '洗衣',
  'drinking' => '饮水',
  'blower' => '吹风',
  'dryer' => '烘干',
  'shoe' => '洗鞋',
  'retail' => '零售',
  'dispenser' => '投放',
  'talking' => '通话',
  _ => type,
};

// 支付方式（账单的 pay_channel 与充值的 recharge_type，资料第 7.3 节：0 是优惠券）。
String zhuliPayChannel(int? channel) => switch (channel) {
  0 => '优惠券',
  1 => '余额',
  2 => '支付宝',
  3 => '微信',
  6 => '农业银行',
  10 => '云闪付',
  12 => '支付宝免密',
  _ => '其他',
};
