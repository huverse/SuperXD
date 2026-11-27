import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/toolbox/life/life_money.dart';

// 胖乖生活的数据类型。回复全是外部输入：decode* 逐项核对类型，不对抛 PangguaiException(invalidResponse)。
// 金额一律按「分」的整数（胖乖给的是 "5.00"、"0.66" 这类十进制文本，按文本换算，见 life_money.dart）。

enum PangguaiFailure {
  // 没连上、断开、TLS 失败。
  network,
  timeout,
  // 回复不是认得的格式（改版时最先坏在这里）。
  invalidResponse,
  // 胖乖说没登录（code 2）：登录凭据失效了，只能请用户重新收短信登录（没有密码可以在后台重登）。
  notSignedIn,
  // 胖乖前面的阿里云防火墙拦下了请求（HTTP 405）：这段时间里本机一律不再发请求，见 PangguaiHttp。
  blocked,
  // 有没付的订单（code 2128）：先去付或取消。
  unpaid,
  // 胖乖明确拒绝（设备离线、参数不对这类），message 是给用户看的话。
  rejected,
}

class PangguaiException implements Exception {
  const PangguaiException(this.failure, this.message, {this.code});
  final PangguaiFailure failure;
  final String message;
  // 胖乖回的业务码（code），HTTP 层的失败为空。
  final int? code;
  @override
  String toString() => 'PangguaiException($failure)';
}

const _invalid = PangguaiException(PangguaiFailure.invalidResponse, '胖乖生活的返回看不懂，稍后再试');

Never _bad(String field) => throw _invalid;

Map<String, Object?> pangguaiObject(Object? value) => value is Map ? value.cast<String, Object?>() : _bad('object');

List<Map<String, Object?>> pangguaiRows(Object? value) => value is List ? [for (final row in value) pangguaiObject(row)] : _bad('list');

// 分页的列表：有的接口回 {items: [...]}，有的直接回数组。
List<Map<String, Object?>> _items(Object? data) => data is List ? pangguaiRows(data) : pangguaiRows(pangguaiObject(data)['items'] ?? const []);

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

int? _cents(Map<String, Object?> json, String field) => json[field] == null ? null : lifeCents(json[field]) ?? _bad(field);

bool _flag(Object? value) => value == true || value == 1 || value == '1' || value == 'true';

// 胖乖的时间是不带时区的北京时间字符串（2026-11-27 15:40:36），是对方协议的写法、不是本应用的业务时区：
// 进来的在这里换成 UTC 绝对时刻，界面再按校园时区显示（同住理生活的 zhuliTimeZone）。
const pangguaiTimeZone = 'Asia/Shanghai';

// 胖乖的时间字符串换成 UTC 时刻；空或认不出返回空。
DateTime? pangguaiMoment(Object? raw) {
  final match = raw is String ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(raw.trim()) : null;
  if (match == null) return null;
  ensureCampusClock();
  final parts = [for (var index = 1; index <= 6; index++) int.parse(match[index]!)];
  return tz.TZDateTime(tz.getLocation(pangguaiTimeZone), parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).toUtc();
}

// 本机记着的一个胖乖账号：手机号与登录凭据（token，只在系统安全存储，见 pangguai_vault.dart）。
class PangguaiCredential {
  const PangguaiCredential({required this.phone, required this.token});
  final String phone;
  final String token;
}

// 账号信息（/user/info）：昵称给账号卡；余额这一版不用（付款只走支付宝，见 pangguai_service.dart 的人工决策）。
class PangguaiUser {
  const PangguaiUser({required this.id, required this.name});
  final String id;
  final String name;
}

PangguaiUser decodePangguaiUser(Object? data) {
  final json = pangguaiObject(data);
  return PangguaiUser(id: _text(json, 'id'), name: _text(json, 'userName', optional: true));
}

// 登录（/user/reg）拿到的凭据：不透明的长串，胖乖不给过期时间，失效时接口回 code 2。
String decodePangguaiToken(Object? data) {
  final token = _text(pangguaiObject(data), 'token', optional: true);
  if (token.isEmpty || token.length > 512 || token.contains(RegExp(r'\s'))) _bad('token');
  return token;
}

// 设备品类（categoryCode）：洗衣机、洗鞋机、烘干机、吹风机是先付后用（选档 → 下单 → 付款 → 胖乖下发开机），饮水机与淋浴是先用后付。
const pangguaiCategories = {'00': '洗衣机', '01': '洗鞋机', '02': '烘干机', '03': '吹风机', '04': '饮水机', '05': '充电桩', '08': '淋浴', '11': '空调'};

// 时长按功能位 × 时长档两级选的品类（烘干机、吹风机）。
bool pangguaiTimed(String category) => category == '02' || category == '03';

// 扫码（/goods/scan/v2）认出的设备。
class PangguaiScan {
  const PangguaiScan({required this.goodsId, required this.category});
  final String goodsId;
  final String category;
}

PangguaiScan decodePangguaiScan(Object? data) {
  final json = pangguaiObject(data);
  final goodsId = _text(json, 'id');
  if (!RegExp(r'^\d{1,20}$').hasMatch(goodsId)) _bad('id');
  return PangguaiScan(goodsId: goodsId, category: _text(json, 'categoryCode', optional: true));
}

// 设备详情（/goods/normal/details）。下单要的 imei 与品类一律从这里取，不写死。
class PangguaiDevice {
  const PangguaiDevice({
    required this.goodsId,
    required this.name,
    required this.category,
    required this.payment,
    required this.imei,
    required this.orgId,
    required this.orgName,
    required this.errorCode,
    required this.errorMessage,
  });
  final String goodsId;
  final String name;
  final String category;
  // before 先付后用，after 先用后付。
  final String payment;
  final String imei;
  // 门店的数字编号（付款渠道接口要它；设备接口的 24 位 shopId 是另一套）。
  final String orgId;
  final String orgName;
  // 设备状态码，空是正常；胖乖给了说明就用说明。
  final String? errorCode;
  final String errorMessage;

  String get categoryName => pangguaiCategories[category] ?? '设备';

  // 这台设备现在能不能下单：不能时是给人看的原因（状态码对照资料 4.5）。
  String? get unusable => switch (errorCode) {
    null => null,
    _ when errorMessage.isNotEmpty => errorMessage,
    '2' => '设备在用，换一台吧',
    '7' => '设备被预约了',
    '-100' => '设备连接超时，换一台吧',
    '4000' => '设备还没绑定商家',
    '4107' => '设备故障',
    '4111' => '设备已停用',
    '4204' => '设备离线了',
    '5023' => '现在不在营业时间',
    final code => '设备暂时不能用（$code）',
  };
}

PangguaiDevice decodePangguaiDevice(Object? data) {
  final json = pangguaiObject(data);
  final error = json['deviceErrorCode'];
  return PangguaiDevice(
    goodsId: _text(json, 'goodsId'),
    name: _text(json, 'name', optional: true),
    category: _text(json, 'categoryCode'),
    payment: _text(json, 'payment', optional: true),
    imei: _text(json, 'imei', optional: true),
    orgId: _text(json, 'orgId', optional: true),
    orgName: _text(json, 'orgName', optional: true),
    errorCode: error == null || error == '' ? null : '$error',
    errorMessage: _text(json, 'deviceErrorMsg', optional: true),
  );
}

// 吹风机、烘干机的一档时长（档位 extAttr.perPrice 里的一项）。
class PangguaiTier {
  const PangguaiTier({required this.minutes, required this.cents, required this.available});
  final int minutes;
  final int cents;
  final bool available;
}

// 一个档位（/goods/normal/skus）：洗衣机是程序（超净洗、单脱…），吹风机、烘干机是功能位（左边 1 号…）下面再分时长档。
class PangguaiSku {
  const PangguaiSku({required this.skuId, required this.name, required this.feature, required this.minutes, required this.cents, required this.tiers});
  final String skuId;
  final String name;
  final String feature;
  // 程序大约多少分钟（洗衣机）；按时长档计价的为空。
  final int? minutes;
  // 标价：有折扣价用折扣价，否则原价（会员价不一定轮得到，不拿来显示）；下单前以胖乖试算的实付为准。
  final int cents;
  final List<PangguaiTier> tiers;
}

List<PangguaiSku> decodePangguaiSkus(Object? data) => [
  for (final json in pangguaiRows(data))
    PangguaiSku(
      skuId: _text(json, 'skuId'),
      name: _text(json, 'name', optional: true),
      feature: _text(json, 'feature', optional: true),
      minutes: int.tryParse(_text(json, 'unit', optional: true)),
      cents: switch (_cents(json, 'discountPrice')) {
        final discount? when discount > 0 => discount,
        _ => _cents(json, 'price') ?? _bad('price'),
      },
      tiers: _tiers(json['extAttr']),
    ),
];

// extAttr 是 JSON 字符串：{"perPrice":[{"time":"5","price":"1","status":false}, …]}；status 缺省算能选。按时长排。
List<PangguaiTier> _tiers(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return _bad('extAttr');
  }
  final rows = json is Map ? json['perPrice'] : null;
  if (rows == null) return const [];
  return [
    for (final row in pangguaiRows(rows))
      PangguaiTier(minutes: _int(row, 'time'), cents: _cents(row, 'price') ?? _bad('price'), available: row['status'] != false),
  ]..sort((a, b) => a.minutes.compareTo(b.minutes));
}

// 设备体检（/trade/check_device_status）：不健康时给原因、不许下单。
({bool healthy, String fault}) decodePangguaiHealth(Object? data) {
  final json = pangguaiObject(data);
  return (healthy: json['health'] != false, fault: _text(json, 'faultDesc', optional: true));
}

// 试算（/trade/preview/v4）：胖乖算出的实付。
int decodePangguaiPreview(Object? data) => _cents(pangguaiObject(data), 'realPrice') ?? _bad('realPrice');

// 下单（/trade/create）拿到的订单。
class PangguaiOrderRef {
  const PangguaiOrderRef({required this.orderId, required this.orderNo});
  final String orderId;
  final String orderNo;
}

PangguaiOrderRef decodePangguaiOrderRef(Object? data) {
  final json = pangguaiObject(data);
  final orderId = _text(json, 'orderId');
  final orderNo = _text(json, 'tradeNo', optional: true);
  if (!RegExp(r'^\d{6,40}$').hasMatch(orderId)) _bad('orderId');
  return PangguaiOrderRef(orderId: orderId, orderNo: orderNo.isEmpty ? orderId : orderNo);
}

// 付款方式（收银台 /payChannelRoute/againPay 给的一项）：method 是胖乖的支付方式编号。
class PangguaiPayChannel {
  const PangguaiPayChannel({required this.method, required this.name, required this.usable});
  final int method;
  final String name;
  final bool usable;
}

List<PangguaiPayChannel> decodePangguaiChannels(Object? data) => [
  for (final json in pangguaiRows(data)) PangguaiPayChannel(method: _int(json, 'method'), name: _text(json, 'methodName', optional: true), usable: json['useStatus'] != false),
];

// 预支付（/pay/unify/prePay）给的支付宝 APP 支付串：只认 alipay.trade.app.pay 的串（别的渠道的串交给支付宝也付不了）。
String decodePangguaiAlipayOrder(Object? data) {
  final order = _text(pangguaiObject(data), 'prepayParam', optional: true);
  if (order.isEmpty || order.length > 8192 || !order.contains('method=alipay.trade.app.pay') || !order.contains('app_id=')) _bad('prepayParam');
  return order;
}

// 订单状态：1 待付款（创建 5 分钟内能付，过了胖乖不改状态、官方 App 自己按创建时刻判失效）、2 使用中、3 已完成。
const pangguaiUnpaid = 1, pangguaiInUse = 2, pangguaiFinished = 3;

// 待付款的订单创建多久之内还能付（同官方 App：超过就当失效、只能删）。
const pangguaiPayWindow = Duration(minutes: 5);

// 订单（/order/detail 与 /order/list 的一项）。
class PangguaiOrder {
  const PangguaiOrder({
    required this.orderId,
    required this.orderNo,
    required this.status,
    required this.createdAt,
    required this.paidAt,
    required this.endsAt,
    required this.showStart,
    required this.cents,
    required this.minutes,
    required this.function,
    required this.device,
  });
  final String orderId;
  final String orderNo;
  final int status;
  final DateTime? createdAt;
  final DateTime? paidAt;
  // 使用中时是预计结束的时刻（付款时刻加时长，胖乖付款成功就写上，用完清空）；有它就是胖乖已经下发了开机。
  final DateTime? endsAt;
  // 胖乖让不让显示「重新启动」。
  final bool showStart;
  // 实付（还没付时是标价）。
  final int cents;
  final int? minutes;
  // 程序或功能名（超净洗、左边 1 号）。
  final String function;
  // 设备名（列表才有）。
  final String device;

  // 待付款且还在 5 分钟里。
  bool payable(DateTime now) => status == pangguaiUnpaid && createdAt != null && now.difference(createdAt!) < pangguaiPayWindow;
  // 付款后 3 分钟内可以重新启动（胖乖超过 180 秒会拒绝）。
  bool restartable(DateTime now) => status == pangguaiInUse && showStart && paidAt != null && now.difference(paidAt!) < const Duration(minutes: 3);
}

PangguaiOrder decodePangguaiOrder(Object? data) {
  final json = pangguaiObject(data);
  final orderNo = _text(json, 'orderNo');
  String first(List<String> fields) => [for (final field in fields) _text(json, field, optional: true)].firstWhere((value) => value.isNotEmpty, orElse: () => '');
  return PangguaiOrder(
    orderId: json['id'] == null ? orderNo : _text(json, 'id'),
    orderNo: orderNo,
    status: _int(json, 'orderStatus'),
    createdAt: pangguaiMoment(json['createTime']),
    paidAt: pangguaiMoment(json['payTime']),
    endsAt: pangguaiMoment(json['completeTime']),
    showStart: _flag(json['showStart']),
    cents: _cents(json, 'payPrice') ?? _cents(json, 'markPrice') ?? 0,
    minutes: json['markMinutes'] == null ? null : _int(json, 'markMinutes'),
    function: first(const ['machineFunctionName', 'skuName']),
    device: first(const ['goodsName', 'machineName']),
  );
}

List<PangguaiOrder> decodePangguaiOrders(Object? data) => [for (final row in _items(data)) decodePangguaiOrder(row)];

// 附近的门店（/shop/nearby/list）。shopId 是 24 位左右的字符串编号（设备接口用），orgId 是数字编号。
class PangguaiShop {
  const PangguaiShop({required this.shopId, required this.orgId, required this.name, required this.address, required this.meters, required this.machines});
  final String shopId;
  final String orgId;
  final String name;
  final String address;
  final int? meters;
  final int? machines;
}

List<PangguaiShop> decodePangguaiShops(Object? data) => [
  for (final json in _items(data))
    PangguaiShop(
      shopId: _text(json, 'id'),
      orgId: _text(json, 'orgId', optional: true),
      name: _text(json, 'name', optional: true),
      address: _text(json, 'address', optional: true),
      meters: double.tryParse(_text(json, 'distance', optional: true))?.round(),
      machines: json['machineCount'] == null ? null : _int(json, 'machineCount'),
    ),
];

// 门店里有哪些机型（/appointNew/newNearByList），id 就是品类码。
List<({String id, String name})> decodePangguaiMachineTypes(Object? data) => [
  for (final json in pangguaiRows(data)) (id: _text(json, 'machineTypeId'), name: _text(json, 'machineTypeName', optional: true)),
];

// 门店里某个机型的设备（/appointNew/near/newMachines）。
List<({String goodsId, String name})> decodePangguaiMachines(Object? data) => [
  for (final json in _items(data)) (goodsId: _text(json, 'goodsId'), name: _text(json, 'goodsName', optional: true)),
];

// 扫到的码：NQT、IMEI、SN 三种查询参数交给 /goods/scan/v2（顺序同官方 App），apwork.cn 的饮水机码是合作方的网页设备（? 后面整段是设备号）。
sealed class PangguaiCode {
  const PangguaiCode();
}

class PangguaiGoodsCode extends PangguaiCode {
  const PangguaiGoodsCode(this.key, this.value);
  // NQT、IMEI 或 SN。
  final String key;
  final String value;
}

class PangguaiWaterCode extends PangguaiCode {
  const PangguaiWaterCode(this.imei);
  final String imei;
}

PangguaiCode? pangguaiParseCode(String raw) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || text.length > 1024) return null;
  if ((uri.scheme == 'http' || uri.scheme == 'https') && (uri.host == 'apwork.cn' || uri.host.endsWith('.apwork.cn'))) {
    final imei = uri.query;
    return RegExp(r'^[0-9A-Za-z]{8,64}$').hasMatch(imei) ? PangguaiWaterCode(imei) : null;
  }
  for (final key in const ['NQT', 'IMEI', 'SN']) {
    final value = uri.queryParameters[key];
    if (value != null && RegExp(r'^[0-9A-Za-z-]{4,64}$').hasMatch(value)) return PangguaiGoodsCode(key, value);
  }
  return null;
}
