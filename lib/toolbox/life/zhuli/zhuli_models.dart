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
class ZhuliProfile {
  const ZhuliProfile({required this.balance, required this.frozen, required this.couponCount});
  final int balance;
  final int frozen;
  final int couponCount;
}

ZhuliProfile decodeZhuliProfile(Object? data) {
  final json = zhuliObject(data);
  return ZhuliProfile(balance: _cents(json, 'balance'), frozen: _cents(json, 'frozen_balance', optional: true), couponCount: _int(json, 'cash_coupon_count', fallback: 0));
}

// 项目配置里用到的几项（get_config；整份很大，只取要的）。
class ZhuliConfig {
  const ZhuliConfig({required this.consumeOrderDays});
  // 消费订单能查最近几天（consume_order_display_cut_enable 开着时），为空表示不限。
  final int? consumeOrderDays;
}

ZhuliConfig decodeZhuliConfig(Object? data) {
  final json = zhuliObject(data);
  final days = _int(json, 'consume_order_display_cut_days', fallback: 0);
  return ZhuliConfig(consumeOrderDays: _int(json, 'consume_order_display_cut_enable', fallback: 0) == 1 && days > 0 ? days : null);
}

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
