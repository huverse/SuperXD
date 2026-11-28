import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_http.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';

// 胖乖生活的接口（路径与参数照移交包 v2.3 的集成契约与 Demo；没在 v2.3 里实测过的接口不接）。
// 下单、锁机这类不能重发的请求没等到回复时改报 unsure（可能已经办成），由页面请人先核对，不自动重发。
class PangguaiClient {
  PangguaiClient({PangguaiHttp? http}) : _http = http ?? PangguaiHttp();
  final PangguaiHttp _http;

  // 列表的页大小：订单、附近门店一页 10 条，门店里的设备一页 20 台（v2.3 的有界分页）。
  static const orderPage = 10;
  static const shopPage = 10;
  static const machinePage = 20;

  // 登录三步（v2.3 契约第 1 节）：要不要人机验证 → 必要时把易盾的结果交给胖乖核对 → 发短信 → 手机号加验证码登录（没注册过的号胖乖直接注册）。
  Future<bool> needsCaptcha(String phone) async => await _http.post('/common/isNeedCaptcha', {'phone': phone}) == true;

  Future<void> checkCaptcha(String phone, String validate) => _http.post('/captcha/checkCaptcha', {'suitScene': '3', 'userPhone': phone, 'validate': validate});

  Future<void> sendCode(String phone) => _http.post('/common/sms/sendCode', {'phone': phone, 'template': 'reg'});

  Future<String> login(String phone, String code) async => decodePangguaiToken(await _http.post('/user/reg', {'channel': 'android_app', 'phone': phone, 'verify': code}));

  Future<PangguaiAccount> account(String token) async => decodePangguaiAccount(await _http.post('/user/info', const {}, token: token));

  // 扫胖乖的设备码：NQT、IMEI 或 SN 交给胖乖，回设备号 goodsId。
  Future<String> scan(String token, PangguaiCode code) async {
    final id = pangguaiObject(await _http.post('/goods/scan/v2', {code.key: code.value}, token: token))['id'];
    if (id is! num && (id is! String || id.isEmpty)) throw const PangguaiException(PangguaiFailure.rejected, '没认出这台设备');
    return '$id';
  }

  Future<PangguaiDevice> device(String token, String goodsId) async => decodePangguaiDevice(await _http.post('/goods/normal/details', {'goodsId': goodsId}, token: token));

  Future<List<PangguaiSku>> skus(String token, String goodsId) async => decodePangguaiSkus(await _http.post('/goods/normal/skus', {'goodsId': goodsId}, token: token));

  // 试算：不用优惠（promotions 为空、isAutoSelectPromotion 传 0，第一版不用券与积分），回服务端算的实付。
  Future<int> preview(String token, String items) async => decodePangguaiPrice(await _http.post('/trade/preview/v4', {'items': items, 'promotions': '[]', 'isAutoSelectPromotion': '0'}, token: token));

  // 下单：items 与上一次试算一字不差，设备号、品类与位置在请求头。回订单号 orderId。
  Future<String> create(String token, String items, PangguaiRisk risk) async {
    try {
      return decodePangguaiCreated(await _http.post('/trade/create', {'items': items, 'promotions': '[]'}, token: token, risk: risk));
    } on PangguaiException catch (error) {
      if (error.failure != PangguaiFailure.network && error.failure != PangguaiFailure.timeout) rethrow;
      throw const PangguaiException(PangguaiFailure.unsure, '没等到下单结果，先到「订单」里看看有没有这一单，别重复下单');
    }
  }

  Future<PangguaiOrder> order(String token, String orderId) async {
    final order = decodePangguaiOrder(await _http.post('/order/detail', {'orderId': orderId}, token: token));
    if (order.id != orderId) throw const PangguaiException(PangguaiFailure.invalidResponse, '胖乖生活的返回看不懂，稍后再试');
    return order;
  }

  // 订单列表（新的在前，页从 1 起）。
  Future<({List<PangguaiOrder> orders, int total})> orders(String token, {int page = 1}) async => decodePangguaiOrders(await _http.post('/order/list', {'page': '$page', 'pageSize': '$orderPage'}, token: token));

  // 这一单能不能用支付宝 App 付（shopId 要数字门店号）。
  Future<bool> alipayUsable(String token, PangguaiOrder order) async =>
      decodePangguaiAlipayUsable(await _http.post('/payChannelRoute/againPay', {'orderNo': order.number, 'shopId': order.orgId, 'confirmSelectedStatus': 'true'}, token: token));

  Future<String> prepay(String token, String orderNo) async => decodePangguaiPrepay(await _http.post('/pay/unify/prePay', {'orderNo': orderNo, 'payType': '13', 'againFlag': '1'}, token: token));

  // 放弃付款：取消后订单变成 1（已取消；移交包当成「状态不变」，11-28 查明不是），接着隐藏（同官方的删除订单；不是退款，也不是解除占用）。
  Future<void> cancel(String token, String orderId) async {
    await _http.post('/order/cancel', {'orderId': orderId}, token: token);
    await _http.post('/order/hidden', {'orderId': orderId}, token: token);
  }

  // 附近门店（按距离，页从 1 起）、门店里有哪几类设备、某一类的设备（orgId 一定传 0，v2.3 观察到的契约）。坐标按 GCJ-02 写到小数点后 6 位。
  Future<List<PangguaiShop>> shops(String token, PangguaiPosition position, {int page = 1}) async => decodePangguaiShops(await _http.post('/shop/nearby/list', {
    'longitude': position.longitude.toStringAsFixed(6),
    'latitude': position.latitude.toStringAsFixed(6),
    'reserve': '1',
    'page': '$page',
    'pageSize': '$shopPage',
  }, token: token));

  Future<List<PangguaiMachineType>> machineTypes(String token, String shopId, PangguaiPosition position) async => decodePangguaiMachineTypes(await _http.post('/appointNew/newNearByList', {
    'shopId': shopId,
    'longitude': position.longitude.toStringAsFixed(6),
    'latitude': position.latitude.toStringAsFixed(6),
    'positionId': '0',
  }, token: token));

  Future<List<PangguaiMachine>> machines(String token, String shopId, String typeId, {int page = 1}) async => decodePangguaiMachines(
    await _http.post('/appointNew/near/newMachines', {'goodsPage': '$page', 'pageSize': '$machinePage', 'shopId': shopId, 'machineTypeId': typeId, 'orgId': '0'}, token: token),
  );

  // 饮水机（apwork.cn 码，v2.3 契约第 5 节）：multipart，reqMap 展开成 reqMap[xxx]；scanType 4 是安卓 App。
  Future<PangguaiWater> water(String token, String hash) async =>
      decodePangguaiWater(hash, await _http.post('/distributor/scan', {'reqMap[imei]': hash, 'distributorType': '2', 'scanType': '4'}, token: token, multipart: true));

  // 锁机：之后人在机器上按闪灯的按钮出水、再按停止，App 没有远程停止。useIntegral 1 是不用积分抵扣（第一版不用积分）。回这次取水的编号。
  Future<String?> unlock(String token, PangguaiWater water, PangguaiWaterChoice choice, PangguaiWaterCard card) async {
    final fields = {
      'imei': water.hash,
      'accountId': water.accountId,
      'token': water.session,
      'washerId': water.washerId,
      'passagewaySettingId': choice.id,
      'passagewaySort': choice.sort,
      'chargeAreaId': card.areaId,
      'useIntegral': '1',
    };
    try {
      return decodePangguaiUnlock(await _http.post('/distributor/unlock', {for (final MapEntry(:key, :value) in fields.entries) 'reqMap[$key]': value, 'distributorType': '2', 'scanType': '4'}, token: token, multipart: true));
    } on PangguaiException catch (error) {
      if (error.failure != PangguaiFailure.network && error.failure != PangguaiFailure.timeout) rethrow;
      throw const PangguaiException(PangguaiFailure.unsure, '没等到锁机结果，先看饮水机上有没有灯在闪，别重复点');
    }
  }

  Future<int> waterStatus(String token, PangguaiWater water, PangguaiWaterChoice choice, String workingId) async => decodePangguaiWaterStatus(await _http.post('/distributor/deviceStatus', {
    'reqMap[token]': water.session,
    'reqMap[macAddress]': water.mac,
    'reqMap[passagewaySort]': choice.sort,
    'reqMap[waterWorkingId]': workingId,
    'distributorType': '2',
    'scanType': '4',
  }, token: token, multipart: true));

  Future<List<PangguaiWaterRecord>> waterRecords(String token) async =>
      decodePangguaiWaterRecords(await _http.post('/distributorOrder/list', {'page': '1', 'pageSize': '10', 'distributorType': '2', 'scanType': '4'}, token: token, multipart: true));

  // 水卡充值档位：用这次扫码给的合作方会话问 apwork（这个商户没给充值地址时为空）。
  Future<List<PangguaiRechargeTier>> rechargeTiers(PangguaiWater water) async {
    final merchantId = water.merchantId, merchantAreaId = water.merchantAreaId;
    if (merchantId == null || merchantAreaId == null) return const [];
    return decodePangguaiRechargeTiers(await _http.partner('/ewash/api/scanLd/getLdRechargeGift.json', {'token': water.session, 'merchantId': merchantId, 'merchantAreaId': merchantAreaId}));
  }

  void close() => _http.close();
}
