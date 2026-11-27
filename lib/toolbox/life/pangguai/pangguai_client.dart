import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/toolbox/life/pangguai/pangguai_http.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';

// 手机的位置（GCJ-02，下单与附近门店用）。
typedef PangguaiPosition = ({double latitude, double longitude});

// 下单的一行（items 的一项）：洗衣机一次 amount 与 num 都是 1；吹风机、烘干机按时长档，amount 与 num 都写分钟数（soldType 1 是单价乘数量，资料实测吹风 5 分钟这样算出 1 元）。
// soldType 一定要带，缺了胖乖回 -1 且没有原因。
class PangguaiItem {
  const PangguaiItem({required this.goodsId, required this.skuId, this.amount = 1});
  final String goodsId;
  final String skuId;
  final int amount;

  Map<String, String> toJson() => {'goodsId': goodsId, 'skuId': skuId, 'amount': '$amount', 'soldType': '1', 'num': '$amount'};
}

// 胖乖接口（资料 01 第 12.1 节）。除登录的三个外都带登录凭据 token；一律经 PangguaiHttp 排队发。
class PangguaiClient {
  PangguaiClient({http.Client? client, Duration spacing = const Duration(milliseconds: 600), DateTime Function()? clock}) : _http = PangguaiHttp(client: client, spacing: spacing, clock: clock);
  final PangguaiHttp _http;

  // 支付宝 APP 支付（胖乖的支付方式编号）；收银台给的别的方式这一版不接（见 pangguai_service.dart 的人工决策）。
  static const alipayMethod = 13;

  // 登录前要不要过易盾图形验证（要的话这一版只能去官方 App 登录）。
  Future<bool> needsCaptcha(String phone) async => await _http.post('/common/isNeedCaptcha', {'phone': phone}) == true;

  Future<void> sendCode(String phone) => _http.post('/common/sms/sendCode', {'phone': phone, 'template': 'reg'});

  // 手机号加 4 位短信验证码登录（没注册过的号胖乖会直接注册）。
  Future<String> login(String phone, String code) async => decodePangguaiToken(await _http.post('/user/reg', {'channel': 'android_app', 'phone': phone, 'verify': code}));

  Future<PangguaiUser> user(String token) async => decodePangguaiUser(await _http.post('/user/info', const {}, token: token));

  Future<PangguaiScan> scan(String token, PangguaiGoodsCode code) async => decodePangguaiScan(await _http.post('/goods/scan/v2', {code.key: code.value}, token: token));

  Future<PangguaiDevice> device(String token, String goodsId) async => decodePangguaiDevice(await _http.post('/goods/normal/details', {'goodsId': goodsId}, token: token));

  Future<List<PangguaiSku>> skus(String token, String goodsId) async => decodePangguaiSkus(await _http.post('/goods/normal/skus', {'goodsId': goodsId}, token: token));

  Future<({bool healthy, String fault})> health(String token, String goodsId) async => decodePangguaiHealth(await _http.post('/trade/check_device_status', {'goodsId': goodsId}, token: token));

  // 试算：第一版不用优惠（promotions 为空，用户 11-27 选的），isAutoSelectPromotion 只认 1 或 0（传 true 回参数不正确）。
  Future<int> preview(String token, List<PangguaiItem> items) async => decodePangguaiPreview(
    await _http.post('/trade/preview/v4', {'promotions': '[]', 'items': jsonEncode([for (final item in items) item.toJson()]), 'isAutoSelectPromotion': '0'}, token: token),
  );

  // 下单：设备号、品类与位置放在请求头（不是表单）。position 为空时位置写空串。
  Future<PangguaiOrderRef> create(String token, PangguaiDevice device, List<PangguaiItem> items, PangguaiPosition? position) async => decodePangguaiOrderRef(
    await _http.post(
      '/trade/create',
      {'promotions': '[]', 'items': jsonEncode([for (final item in items) item.toJson()])},
      token: token,
      headers: {
        'imei': device.imei,
        'categoryCode': device.category,
        'lat': position == null ? '' : position.latitude.toStringAsFixed(6),
        'lng': position == null ? '' : position.longitude.toStringAsFixed(6),
      },
    ),
  );

  // 收银台给这一单的付款方式；shopId 要数字的 orgId（传 24 位的 shopId 胖乖报数字格式错）。
  Future<List<PangguaiPayChannel>> channels(String token, String orderNo, String orgId) async =>
      decodePangguaiChannels(await _http.post('/payChannelRoute/againPay', {'orderNo': orderNo, 'confirmSelectedStatus': 'true', 'shopId': orgId}, token: token));

  // 预支付：拿支付宝 APP 支付串。
  Future<String> alipayOrder(String token, String orderNo) async =>
      decodePangguaiAlipayOrder(await _http.post('/pay/unify/prePay', {'orderNo': orderNo, 'payType': '$alipayMethod', 'againFlag': '1'}, token: token));

  Future<PangguaiOrder> order(String token, String orderId) async => decodePangguaiOrder(await _http.post('/order/detail', {'orderId': orderId}, token: token));

  Future<List<PangguaiOrder>> orders(String token, {int page = 1, int pageSize = 10}) async => decodePangguaiOrders(await _http.post('/order/list', {'page': '$page', 'pageSize': '$pageSize'}, token: token));

  // 取消没付的单：胖乖对待付款的单回成功但状态不变，所以接着把它从订单列表里删掉（同官方 App 的「删除订单」），设备也随之放开。
  Future<void> cancel(String token, String orderId) async {
    await _http.post('/order/cancel', {'orderId': orderId}, token: token);
    await _http.post('/order/hidden', {'orderId': orderId}, token: token);
  }

  // 付款后 3 分钟内设备没动可以重新启动。
  Future<void> restart(String token, String orderNo) => _http.post('/trade/order/start', {'orderNo': orderNo}, token: token);

  Future<List<PangguaiShop>> nearbyShops(String token, PangguaiPosition position, {int page = 1}) async => decodePangguaiShops(
    await _http.post('/shop/nearby/list', {'longitude': position.longitude.toStringAsFixed(6), 'latitude': position.latitude.toStringAsFixed(6), 'reserve': '1', 'page': '$page', 'pageSize': '20'}, token: token),
  );

  Future<List<({String id, String name})>> machineTypes(String token, String shopId, PangguaiPosition? position) async => decodePangguaiMachineTypes(
    await _http.post(
      '/appointNew/newNearByList',
      {'shopId': shopId, 'longitude': position?.longitude.toStringAsFixed(6) ?? '', 'latitude': position?.latitude.toStringAsFixed(6) ?? '', 'positionId': '0'},
      token: token,
    ),
  );

  // 门店里某个机型的设备：orgId 一定要传 0（传真实的门店编号胖乖回「设备类型不存在」，资料实测）。
  Future<List<({String goodsId, String name})>> machines(String token, String shopId, String typeId, {int page = 1}) async => decodePangguaiMachines(
    await _http.post('/appointNew/near/newMachines', {'goodsPage': '$page', 'pageSize': '$machinePage', 'shopId': shopId, 'machineTypeId': typeId, 'orgId': '0'}, token: token),
  );

  static const machinePage = 20;

  void close() => _http.close();
}
