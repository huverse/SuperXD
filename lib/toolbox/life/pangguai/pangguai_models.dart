import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/toolbox/life/life_money.dart';

// 胖乖生活的数据类型。回复全是外部输入：decode* 逐项核对类型，不对抛 PangguaiException(invalidResponse)。
// 金额一律按「分」的整数（lifeCents 按十进制文本换算，不经浮点运算）。

enum PangguaiFailure {
  // 没连上、断开、TLS 失败。
  network,
  timeout,
  // 回复不是认得的格式（改版时最先坏在这里）。
  invalidResponse,
  // 登录失效（业务码 2）或本机没有这个账号的凭据：胖乖登录要短信验证码，没法在后台重登，请用户重新登录。
  notSignedIn,
  // 胖乖的防火墙拦了（HTTP 403、405、429）：这段时间里不再发任何请求（见 PangguaiHttp）。
  blocked,
  // 胖乖明确拒绝（验证码不对、设备忙这类），message 是给人看的话。
  rejected,
  // 下单、锁机这类不能重发的请求没等到回复：可能已经办成了，请人先看订单或设备，不自动重发。
  unsure,
  // 用户关掉了人机验证。
  cancelled,
}

class PangguaiException implements Exception {
  const PangguaiException(this.failure, this.message, {this.code = ''});
  final PangguaiFailure failure;
  final String message;
  // 胖乖的业务码（2、-1…）或合作方的 success 值，没有时为空。
  final String code;
  @override
  String toString() => 'PangguaiException($failure, $code)';
}

// 手机位置（已换成 GCJ-02，胖乖按国内地图的口径认）；取法见 pangguai_location.dart。
typedef PangguaiPosition = ({double latitude, double longitude});

// 下单前重算的实付和页面上显示的不一样：不下单，交回新价请人再确认。
class PangguaiPriceChanged implements Exception {
  const PangguaiPriceChanged(this.price);
  final int price;
}

const _invalid = PangguaiException(PangguaiFailure.invalidResponse, '胖乖生活的返回看不懂，稍后再试');

Never _bad(String field) => throw _invalid;

Map<String, Object?> pangguaiObject(Object? value) => value is Map ? value.cast<String, Object?>() : _bad('object');

List<Map<String, Object?>> pangguaiRows(Object? value) => value is List ? [for (final row in value) pangguaiObject(row)] : _bad('list');

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

int _cents(Map<String, Object?> json, String field, {bool optional = false}) => lifeCents(json[field]) ?? (optional && json[field] == null ? 0 : _bad(field));

// 胖乖与它的合作方回的时间都是不带时区的北京时间字符串（2026-11-27 21:42:40），是对方协议的写法、不是本应用的业务时区：
// 在这里换成 UTC 绝对时刻再交给界面按校园时区显示。认不出（空、null）返回空。
const pangguaiTimeZone = 'Asia/Shanghai';

DateTime? pangguaiMoment(Object? raw) {
  final match = raw is String ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(raw.trim()) : null;
  if (match == null) return null;
  ensureCampusClock();
  final parts = [for (var index = 1; index <= 6; index++) int.parse(match[index]!)];
  return tz.TZDateTime(tz.getLocation(pangguaiTimeZone), parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).toUtc();
}

// 登录回复：凭据 token；要先在官方 App 绑定手机的号（forcedBind）这里登不了。
String decodePangguaiToken(Object? data) {
  final json = pangguaiObject(data);
  if (json['forcedBind'] == true) throw const PangguaiException(PangguaiFailure.rejected, '这个号要先在胖乖生活 App 里绑定手机', code: 'forcedBind');
  final token = _text(json, 'token');
  if (token.isEmpty || token.length > 512) _bad('token');
  return token;
}

// 账户（/user/info）：昵称与胖乖钱包余额（这一版不用余额付款，只显示）。
class PangguaiAccount {
  const PangguaiAccount({required this.id, required this.name, required this.balance});
  final String id;
  final String name;
  final int balance;
}

PangguaiAccount decodePangguaiAccount(Object? data) {
  final json = pangguaiObject(data);
  return PangguaiAccount(id: _text(json, 'id'), name: _text(json, 'userName', optional: true), balance: _cents(json, 'balance', optional: true));
}

// 品类（categoryCode），v2.3 契约第 2 节。
const pangguaiCategoryNames = {'00': '洗衣机', '01': '洗鞋机', '02': '烘干机', '03': '吹风机', '04': '饮水机', '05': '充电', '08': '淋浴', '11': '空调'};
// 这里能下单的：先付后用的洗衣机、洗鞋机（按次）与烘干机、吹风机（按分钟）。先用后付的饮水机、淋浴以后再说（人工决策见 pangguai_service.dart 文件头）。
const _orderable = {'00', '01', '02', '03'};

// 设备详情（/goods/normal/details）。orgId 是数字门店号（付款渠道的 shopId 用它），详情里的 shopId 是另一套字符串标识，不混用。
class PangguaiDevice {
  const PangguaiDevice({
    required this.goodsId,
    required this.name,
    required this.category,
    required this.imei,
    required this.orgId,
    required this.orgName,
    required this.payment,
    this.errorCode,
    this.errorMessage,
  });
  final String goodsId;
  final String name;
  final String category;
  final String imei;
  final String orgId;
  final String orgName;
  // before 先付后用，after 先用后付；真正走哪种流程看它，不只看品类。
  final String payment;
  // 设备状态码（可能是数字 4204），没有为空；没有也只说明查的那一刻能用。
  final String? errorCode;
  final String? errorMessage;

  String get kind => pangguaiCategoryNames[category] ?? '设备';
  // 烘干机、吹风机按分钟买（选时长），洗衣机、洗鞋机按次买（选程序）。
  bool get timed => category == '02' || category == '03';

  // 不能在这里下单的原因，能下单为空。
  String? get unusable {
    if (errorCode != null) return errorMessage?.isNotEmpty == true ? errorMessage : '设备暂时不能用（$errorCode）';
    if (payment != 'before') return '这台是先用后付的设备，请在胖乖生活 App 里用';
    if (!_orderable.contains(category)) return '这类设备请在胖乖生活 App 里用';
    return null;
  }
}

PangguaiDevice decodePangguaiDevice(Object? data) {
  final json = pangguaiObject(data);
  final error = json['deviceErrorCode'];
  return PangguaiDevice(
    goodsId: _text(json, 'goodsId'),
    name: _text(json, 'name'),
    category: _text(json, 'categoryCode'),
    imei: _text(json, 'imei', optional: true),
    orgId: _text(json, 'orgId'),
    orgName: _text(json, 'orgName', optional: true),
    payment: _text(json, 'payment', optional: true),
    errorCode: error == null || error == '' ? null : '$error',
    errorMessage: json['deviceErrorMsg'] is String ? (json['deviceErrorMsg']! as String).trim() : null,
  );
}

// 吹风机、烘干机的一个时长档（extAttr.perPrice 里的一项）：status 为假的不能选。
class PangguaiTier {
  const PangguaiTier({required this.minutes, required this.price, required this.enabled});
  final int minutes;
  final int price;
  final bool enabled;
}

// 一个档位（/goods/normal/skus）：洗衣机是程序（unit 是约几分钟，不是计价单位），吹风机是位置（左边 1 号）、下面再分时长档。
class PangguaiSku {
  const PangguaiSku({required this.id, required this.name, required this.feature, required this.price, required this.minutes, required this.tiers, required this.available});
  final String id;
  final String name;
  final String feature;
  // 标价（有折扣时是折扣价）；实付以下单前的试算为准。
  final int price;
  final int? minutes;
  final List<PangguaiTier> tiers;
  final bool available;
}

List<PangguaiSku> decodePangguaiSkus(Object? data) => [for (final row in pangguaiRows(data)) _sku(row)];

PangguaiSku _sku(Map<String, Object?> json) {
  Map<String, Object?> extension = const {};
  if (json['extAttr'] case final String raw when raw.trim().isNotEmpty) {
    try {
      extension = pangguaiObject(jsonDecode(raw));
    } on FormatException {
      _bad('extAttr');
    }
  }
  final tiers = [
    for (final row in extension['perPrice'] is List ? pangguaiRows(extension['perPrice']) : const <Map<String, Object?>>[])
      PangguaiTier(minutes: _int(row, 'time'), price: _cents(row, 'price'), enabled: row['status'] != false),
  ]..sort((first, second) => first.minutes.compareTo(second.minutes));
  final scannable = json['scanAvailable'] ?? extension['scanAvailable'];
  return PangguaiSku(
    id: _text(json, 'skuId'),
    name: _text(json, 'name'),
    feature: _text(json, 'feature', optional: true),
    price: lifeCents(json['discountPrice']) ?? _cents(json, 'price'),
    minutes: int.tryParse(_text(json, 'unit', optional: true)),
    tiers: tiers,
    available: _int(json, 'stockState', fallback: 1) == 1 && scannable != false && scannable != 'false',
  );
}

// 下单的 items（v2.3 契约 3.1）：洗衣机、洗鞋机一次 amount 与 num 都是 1；吹风机、烘干机都写所选的分钟数；soldType 一定带 1（缺了胖乖回 -1 没原因）。
String pangguaiItems(PangguaiDevice device, PangguaiSku sku, int? minutes) {
  final String quantity;
  if (device.timed) {
    if (minutes == null || !sku.tiers.any((tier) => tier.minutes == minutes && tier.enabled)) throw const PangguaiException(PangguaiFailure.rejected, '选一个能用的时长');
    quantity = '$minutes';
  } else {
    quantity = '1';
  }
  return jsonEncode([
    {'goodsId': device.goodsId, 'skuId': sku.id, 'amount': quantity, 'soldType': '1', 'num': quantity},
  ]);
}

// 试算（/trade/preview/v4）的实付：唯一的应付来源，客户端不按单价自己乘。
int decodePangguaiPrice(Object? data) => _cents(pangguaiObject(data), 'realPrice');

// 下单回执（/trade/create）：{tradeType, tradeNo, orderId}，后面按 orderId 查详情、按详情里的 orderNo 付款。
String decodePangguaiCreated(Object? data) {
  final orderId = _text(pangguaiObject(data), 'orderId');
  if (orderId.isEmpty) _bad('orderId');
  return orderId;
}

// 订单（/order/detail 与 /order/list 的一项；列表里没有付款时刻与预计结束时刻）。
// 状态：0 待付款，1 已取消（自己取消的与没付被胖乖关掉的），2 使用中，3 已完成。
// 1 原先当成「拿过付款参数的待付款」，11-28 真机查明不是：对 1 的单调取消，胖乖回 3122「只有未支付订单才能取消」（诊断包 BMVART4N），
// 移交包里一个月前没付的旧单至今都是 1，移交包取消成功后查到的也是 1。
class PangguaiOrder {
  const PangguaiOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.price,
    required this.machine,
    required this.program,
    required this.shop,
    required this.orgId,
    this.createdAt,
    this.paidAt,
    this.endsAt,
  });
  final String id;
  // 付款渠道与预支付认的订单号。
  final String number;
  final int status;
  final int price;
  final String machine;
  final String program;
  final String shop;
  // 数字门店号（付款渠道的 shopId）。
  final String orgId;
  final DateTime? createdAt;
  final DateTime? paidAt;
  // 预计结束时刻（completeTime，运行中可能更新，完成后清空）：只是线索，到点不等于已完成，以状态为准。
  final DateTime? endsAt;

  bool get payable => paidAt == null && status == 0;
  bool get cancelled => status == 1;
  bool get running => status == 2;
  bool get done => status == 3;
  String get statusLabel => payable ? '待付款' : cancelled ? '已取消' : running ? '使用中' : done ? '已完成' : '状态 $status';
}

// 使用中的剩余时间写法：「还剩 2:31」，一小时以上「还剩 1:05:00」，到点写「快好了」（向上取整到秒，订单变成已完成之前一直这样写）。
String pangguaiLeft(Duration left) {
  final seconds = (left.inMilliseconds / 1000).ceil();
  if (seconds <= 0) return '快好了';
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = seconds ~/ 3600, minutes = seconds % 3600 ~/ 60;
  return hours > 0 ? '还剩 $hours:${two(minutes)}:${two(seconds % 60)}' : '还剩 $minutes:${two(seconds % 60)}';
}

PangguaiOrder decodePangguaiOrder(Object? data) {
  final json = pangguaiObject(data);
  return PangguaiOrder(
    id: _text(json, 'id'),
    number: _text(json, 'orderNo'),
    status: _int(json, 'orderStatus'),
    price: _cents(json, 'payPrice'),
    machine: _text(json, 'machineName', optional: true),
    program: _text(json, 'machineFunctionName', optional: true),
    shop: _text(json, 'shopName', optional: true),
    orgId: _text(json, 'shopAutoId', optional: true),
    createdAt: pangguaiMoment(json['createTime']),
    paidAt: pangguaiMoment(json['payTime']),
    endsAt: pangguaiMoment(json['completeTime']),
  );
}

({List<PangguaiOrder> orders, int total}) decodePangguaiOrders(Object? data) {
  final json = pangguaiObject(data);
  return (orders: [for (final row in pangguaiRows(json['items'] ?? const [])) decodePangguaiOrder(row)], total: _int(json, 'total', fallback: 0));
}

// 下单后的付款渠道（/payChannelRoute/againPay）里有没有能用的支付宝 App 渠道（method 13）；余额（2）与免密不自动切过去。
bool decodePangguaiAlipayUsable(Object? data) => pangguaiRows(data).any((row) => row['method'] == 13 && row['useStatus'] == true);

// 预支付（/pay/unify/prePay）给的支付串：只认支付宝 APP 支付（收款方是胖乖），别的不交给 SDK；支付串不进日志。
String decodePangguaiPrepay(Object? data) {
  final param = _text(pangguaiObject(data), 'prepayParam', optional: true);
  if (param.isEmpty || param.length > 8192 || !param.contains('alipay.trade.app.pay')) {
    throw const PangguaiException(PangguaiFailure.rejected, '这一单没拿到支付宝付款单，请在胖乖生活 App 里付', code: 'prepay');
  }
  return param;
}

// 附近门店（/shop/nearby/list 的一项）：id 是 30 位字符串门店标识，orgId 是数字门店号；distance 是米。
class PangguaiShop {
  const PangguaiShop({required this.id, required this.orgId, required this.name, required this.address, required this.distance, required this.total, required this.free});
  final String id;
  final String orgId;
  final String name;
  final String address;
  final int distance;
  final int total;
  final int free;
}

List<PangguaiShop> decodePangguaiShops(Object? data) => [
  for (final row in pangguaiRows(pangguaiObject(data)['items'] ?? const []))
    PangguaiShop(
      id: _text(row, 'id'),
      orgId: _text(row, 'orgId', optional: true),
      name: _text(row, 'name'),
      address: _text(row, 'address', optional: true),
      distance: _int(row, 'distance', fallback: -1),
      total: _int(row, 'machineCount', fallback: 0),
      free: _int(row, 'freeMachine', fallback: 0),
    ),
];

// 门店里有哪几类设备（/appointNew/newNearByList）：machineTypeId 就是品类码（00 洗衣…）。
typedef PangguaiMachineType = ({String id, String name});

List<PangguaiMachineType> decodePangguaiMachineTypes(Object? data) => [for (final row in pangguaiRows(data)) (id: _text(row, 'machineTypeId'), name: _text(row, 'machineTypeName'))];

// 门店里的一台设备（/appointNew/near/newMachines 的一项）：状态 10 空闲、20 使用中（remaining 是还剩多久，如「21分钟」），其余当暂不可用。
class PangguaiMachine {
  const PangguaiMachine({required this.goodsId, required this.name, required this.status, required this.remaining});
  final String goodsId;
  final String name;
  final int status;
  final String remaining;

  bool get idle => status == 10;
  String get statusLabel => switch (status) {
    10 => '空闲',
    20 => remaining.isEmpty ? '使用中' : '使用中 · 还剩 $remaining',
    _ => '暂不可用',
  };
}

List<PangguaiMachine> decodePangguaiMachines(Object? data) => [
  for (final row in pangguaiRows(pangguaiObject(data)['items'] ?? const []))
    PangguaiMachine(goodsId: _text(row, 'goodsId'), name: _text(row, 'goodsName'), status: _int(row, 'deviceWorkStatus', fallback: 0), remaining: _text(row, 'endUseTimeValue', optional: true).trim()),
];

// 饮水机的一种水（开水、热水、常温水）：rate 是每升的价，status 1 才能出。passgetwaySort 是对方的拼写。
class PangguaiWaterChoice {
  const PangguaiWaterChoice({required this.id, required this.sort, required this.name, required this.rate, required this.available});
  final String id;
  final String sort;
  final String name;
  final int rate;
  final bool available;
}

// 扣费的水卡区域（accountShare 的一项，不共享时就是 accountInfo 自己）。
class PangguaiWaterCard {
  const PangguaiWaterCard({required this.areaId, required this.name, required this.balance});
  final String areaId;
  final String name;
  final int balance;
}

// 扫饮水机码（/distributor/scan）：两个凭据别混：请求顶层的 token 是胖乖的登录凭据，session 是这次扫码给的合作方会话（锁机、查状态、充值都用它）。
// 充值的商户与区域标识从 redirectUrl 里取（十六进制的那套），和 accountInfo 里数字的 merchantId、areaId 不是一回事。
class PangguaiWater {
  const PangguaiWater({
    required this.hash,
    required this.name,
    required this.session,
    required this.accountId,
    required this.washerId,
    required this.mac,
    required this.place,
    required this.online,
    required this.workStatus,
    required this.minimum,
    required this.choices,
    required this.cards,
    this.merchantId,
    this.merchantAreaId,
  });
  final String hash;
  final String name;
  final String session;
  final String accountId;
  final String washerId;
  final String mac;
  final String place;
  final bool online;
  // 1 空闲、2 有人在用、3 故障。
  final int workStatus;
  // 水卡至少要有这么多才能取水（waterInit.balanceLimit）。
  final int minimum;
  final List<PangguaiWaterChoice> choices;
  final List<PangguaiWaterCard> cards;
  final String? merchantId;
  final String? merchantAreaId;

  String? get unusable => !online ? '水机离线了，请联系商家' : workStatus == 3 ? '水机故障，请联系商家' : null;
}

PangguaiWater decodePangguaiWater(String hash, Object? data) {
  final json = pangguaiObject(data);
  if (json['respCode'] != '0000') throw const PangguaiException(PangguaiFailure.rejected, '水卡或这台饮水机用不了，请在胖乖生活 App 里看看绑卡', code: 'respCode');
  final account = pangguaiObject(json['accountInfo']);
  final info = pangguaiObject(json['deviceInfo']);
  final init = pangguaiObject(json['waterInit']);
  final shared = account['isShare'] == 1 && json['accountShare'] is List;
  final areaName = _text(info, 'areaName', optional: true);
  final redirect = Uri.tryParse(_text(json, 'redirectUrl', optional: true));
  final query = redirect != null && redirect.scheme == 'https' && redirect.host == 'apwork.cn' ? redirect.queryParameters : const <String, String>{};
  final session = _text(json, 'token');
  if (session.isEmpty) _bad('token');
  return PangguaiWater(
    hash: hash,
    name: _text(json, 'deviceName', optional: true),
    session: session,
    accountId: _text(account, 'accountId'),
    washerId: _text(info, 'washerId'),
    mac: _text(info, 'macAddress'),
    place: [_text(info, 'buildName', optional: true), if (_text(info, 'floors', optional: true) case final floor when floor.isNotEmpty) '$floor楼'].where((part) => part.isNotEmpty).join(' '),
    online: info['deviceStatus'] == 0,
    workStatus: _int(json, 'deviceWorkStatus', fallback: 1),
    minimum: _cents(init, 'balanceLimit', optional: true),
    choices: [
      for (final row in pangguaiRows(json['waterPassageways'] ?? const []))
        PangguaiWaterChoice(id: _text(row, 'passagewaySettingId'), sort: _text(row, 'passgetwaySort'), name: _text(row, 'passagewayName'), rate: _cents(row, 'waterCharge', optional: true), available: row['status'] == 1),
    ],
    cards: [
      for (final row in shared ? pangguaiRows(json['accountShare']) : [account])
        PangguaiWaterCard(areaId: _text(row, 'areaId'), name: _text(row, 'areaName', optional: true).isEmpty ? areaName : _text(row, 'areaName'), balance: _cents(row, 'totalBalance')),
    ],
    merchantId: query['merchantId'],
    merchantAreaId: query['washerAreaId'],
  );
}

// 锁机（/distributor/unlock）：lock 为真才算锁上，data 是这次取水的编号（查状态用；没给就只能看用水记录）。
String? decodePangguaiUnlock(Object? data) {
  final json = pangguaiObject(data);
  if (json['lock'] != true) throw const PangguaiException(PangguaiFailure.rejected, '没锁上饮水机，稍后再试', code: 'lock');
  return json['data'] is String && (json['data']! as String).isNotEmpty ? json['data']! as String : null;
}

// 取水状态（/distributor/deviceStatus）：0 等按键，2 出水中，3、5 这次结束了（结束不等于扣了费，费用看用水记录）。
int decodePangguaiWaterStatus(Object? data) => _int(pangguaiObject(data), 'deviceWorkStatus');

// 用水记录（/distributorOrder/list 的一项）：订单和锁机之间没有关联字段，靠设备与时刻对上；记录可能晚一会儿才出现。
class PangguaiWaterRecord {
  const PangguaiWaterRecord({required this.number, required this.device, required this.price, this.at});
  final String number;
  final String device;
  final int price;
  final DateTime? at;
}

List<PangguaiWaterRecord> decodePangguaiWaterRecords(Object? data) => [
  for (final row in pangguaiRows(pangguaiObject(data)['items'] ?? const []))
    PangguaiWaterRecord(number: _text(row, 'orderNo'), device: _text(row, 'goodsName', optional: true), price: _cents(row, 'realPrice', optional: true), at: pangguaiMoment(row['thirdCreateTime'])),
];

// 水卡充值档位（apwork 的 getLdRechargeGift.json）：充多少、送多少，选档按 id（不按下标）。
typedef PangguaiRechargeTier = ({String id, int amount, int gift});

List<PangguaiRechargeTier> decodePangguaiRechargeTiers(Map<String, Object?> json) => [
  for (final row in pangguaiRows(json['giftAmountList'] ?? const [])) (id: _text(row, 'giftAmountSubId'), amount: _cents(row, 'rechargeAmount'), gift: _cents(row, 'giftAmount', optional: true)),
];

// 水卡充值是跳支付宝小程序（同官方网页）：内层查询串每个值先编码，整串再编码一次；里面有合作方会话，不进日志。
Uri pangguaiRechargeUri({required String session, required String merchantId, required String merchantAreaId, required String tierId, required String phone}) {
  final inner = Uri(queryParameters: {'token': session, 'mId': merchantId, 'aId': merchantAreaId, 'amountSubId': tierId, 'phone': phone}).query;
  return Uri.parse('alipays://platformapi/startapp?appId=2021003142624414&page=pages/index/index?${Uri.encodeComponent(inner)}');
}
