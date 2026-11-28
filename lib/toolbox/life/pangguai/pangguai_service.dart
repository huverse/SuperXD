import 'dart:async';
import 'dart:io';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_captcha.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// [人工决策-2026-11-27 23:34:29] 生活的第二个子模块胖乖生活（com.qiekj.user 1.148.0；资料是用户 11-27 转交的另一个 AI 的移交包 v2.3，仓库外，
// ~/Projects/SelfProjects/API/shenghuo/pangguai）：登录 → 扫码或按附近门店查看设备 → 打开设备 → 有档位的选档、没有的直接下一步 → 下单 → 支付宝付款 → 使用，
// 品类是洗衣机（含洗鞋、烘干）、吹风机与饮水机；饮水机是用户说的「现有的」（扫 apwork.cn 码的那种），原生的先用后付（饮水机、淋浴）以后再说。
// 用户 11-27 晚四项选择：按 v2.3 从头写（没选「以已关闭的 #370 为底改」）；饮水机走原生接口（选水种与水卡、锁机后在机器上按键出水、查状态与用水记录、
// 余额不够时跳支付宝小程序充值，没选「打开胖乖自己的网页」）；登录要人机验证时接易盾原生 SDK（没选「内嵌网页跑易盾」「先不做」）；
// 定位自己写系统定位（安卓 LocationManager、iOS CoreLocation，没选 geolocator 插件（安卓带谷歌闭源库）与「不定位」）。
// 其余照上一轮：多账号切换、第一版不用券与积分（试算不带优惠、饮水不用积分抵扣）、付款只接支付宝；碰真钱，照 domain/feature_flags.dart 的规矩登记开关 toolbox.life.pangguai、默认关，先点名给开发者测。
// 沿用快递、住理的立场接受公开仓库接胖乖私有接口的风险；v2.3 没实测过的接口（退款、绑卡、免密、蓝牙、原生先用后付）不接。
//
// 服务：持有账号的安全存储、本机的最近使用、客户端、支付宝、定位与人机验证，没有业务库（订单、余额与用水记录即查即用，不落盘）。
class PangguaiService implements ToolboxService {
  PangguaiService({required this.vault, required this.devices, PangguaiClient? client, LifeAlipay? alipay, PangguaiLocator? locator, PangguaiCaptcha? captcha})
    : client = client ?? PangguaiClient(),
      alipay = alipay ?? TobiasLifeAlipay(),
      locator = locator ?? ChannelPangguaiLocator(),
      captcha = captcha ?? ChannelPangguaiCaptcha();
  final PangguaiVault vault;
  final PangguaiDeviceStore devices;
  final PangguaiClient client;
  final LifeAlipay alipay;
  final PangguaiLocator locator;
  final PangguaiCaptcha captcha;

  // 子模块 id：路由（/toolbox/life/pangguai）、服务、同意记录与开关共用，发出后不改。
  static const serviceId = 'life.pangguai';
  // 第一次发验证码前的同意说明的版本，说明有实质变化就加一档。
  // pangguai-2（11-28）：写明打开设备时先读一次位置、下单时才发给胖乖。
  static const consentVersion = 'pangguai-2';

  static Future<PangguaiService> open(ToolboxServiceContext context) async =>
      PangguaiService(vault: SecurePangguaiVault(), devices: PangguaiDeviceStore.file(File('${context.base.path}/pangguai_devices.json')));

  Future<PangguaiVaultState> state() => vault.load();

  // 胖乖要人机验证时先过易盾（用户关掉了抛 cancelled），过了把结果交给胖乖核对。发验证码与登录前都问一次（同官方 App）。
  Future<void> _human(String phone, {required bool dark}) async {
    if (!await client.needsCaptcha(phone)) return;
    final validate = await captcha.verify(dark: dark);
    if (validate == null) throw const PangguaiException(PangguaiFailure.cancelled, '没有完成人机验证');
    await client.checkCaptcha(phone, validate);
  }

  Future<void> sendCode(String phone, {required bool dark}) async {
    await _human(phone, dark: dark);
    await client.sendCode(phone);
  }

  // 登录（也用来加账号、重新登录）：成功后才记下凭据并设为当前账号，同一手机号只记一份，最多 pangguaiAccountLimit 个。
  Future<PangguaiAccount> signIn(String phone, String code, {required bool dark}) async {
    await _human(phone, dark: dark);
    final token = await client.login(phone, code);
    final account = await client.account(token);
    final state = await vault.load();
    final accounts = [PangguaiCredential(phone: phone, token: token, name: account.name), ...state.accounts.where((known) => known.phone != phone)];
    await vault.save(PangguaiVaultState(accounts: accounts.take(pangguaiAccountLimit).toList(), active: phone));
    return account;
  }

  Future<void> switchTo(String phone) async {
    final state = await vault.load();
    if (state.accounts.any((account) => account.phone == phone)) await vault.save(PangguaiVaultState(accounts: state.accounts, active: phone));
  }

  // 退出这个账号：本机删掉它的凭据（胖乖那边的账号与订单不动），当前账号换成剩下的第一个。
  Future<void> signOut(String phone) async {
    final state = await vault.load();
    final accounts = [for (final account in state.accounts) if (account.phone != phone) account];
    await vault.save(PangguaiVaultState(accounts: accounts, active: state.active == phone ? accounts.firstOrNull?.phone : state.active));
  }

  // 带着这个账号的凭据做一次请求。凭据失效（业务码 2）原样抛 notSignedIn：胖乖登录要短信验证码，没法在后台重登，页面请用户重新登录。
  Future<T> run<T>(String phone, Future<T> Function(String token) action) async {
    final credential = (await vault.load()).accounts.where((account) => account.phone == phone).firstOrNull;
    if (credential == null) throw const PangguaiException(PangguaiFailure.notSignedIn, '请先登录');
    return action(credential.token);
  }

  // 进行中的订单（首页用）：订单第一页里使用中的，加上 payWindow 内新建、还没付的（胖乖不给没付的单关单时刻，太久的不再提）。
  static const payWindow = Duration(minutes: 10);

  Future<List<PangguaiOrder>> ongoing(String phone, {DateTime? now}) => run(phone, (token) async {
    final moment = (now ?? DateTime.now()).toUtc();
    return [
      for (final order in (await client.orders(token)).orders)
        if (order.running || (order.payable && order.createdAt != null && moment.difference(order.createdAt!) < payWindow)) order,
    ];
  });

  // 打开一台先付后用的设备：详情与档位（暂不可用的档位也带上，页面标出来，不藏），记进最近使用。
  Future<({PangguaiDevice device, List<PangguaiSku> skus})> inspect(String phone, String goodsId) => run(phone, (token) async {
    final result = await _deviceAndSkus(token, goodsId);
    await _remember(phone, PangguaiDeviceEntry(water: false, id: goodsId, name: result.device.name, place: result.device.orgName, category: result.device.category));
    return result;
  });

  // 详情与档位一起取（请求策略见 life_http_brake.dart）：设备不能用时不要档位，它的结果与错误都不管，原因照详情写。
  Future<({PangguaiDevice device, List<PangguaiSku> skus})> _deviceAndSkus(String token, String goodsId) async {
    // 档位的错误一发出就接住：详情先失败、或设备不能用而用不上它时，它的错误不成为没人处理的异步错误。
    final pending = client.skus(token, goodsId).then<Object>((skus) => skus, onError: (Object error, StackTrace stack) => AsyncError(error, stack));
    final device = await client.device(token, goodsId);
    if (device.unusable != null) return (device: device, skus: const <PangguaiSku>[]);
    final skus = await pending;
    if (skus is AsyncError) Error.throwWithStackTrace(skus.error, skus.stackTrace);
    return (device: device, skus: skus as List<PangguaiSku>);
  }

  // 选好档位后试算实付（页面上显示的价）。
  Future<int> quote(String phone, PangguaiDevice device, PangguaiSku sku, int? minutes) => run(phone, (token) => client.preview(token, pangguaiItems(device, sku, minutes)));

  // [人工决策-2026-11-28 21:26:48] 打开设备页就先读一次位置（用户看了诊断包 NNK5V9VD 后选「打开设备页就先读」，没选「选好档位时才读」与「保持下单时才读」）：
  // 点「下单」后最慢的是现取定位（那份包里 1.9 秒，室内可能更久）。只在已经允许过位置时读、不弹授权；读到的照旧在定位端口里留 5 分钟，下单时才发给胖乖。
  // 隐私政策升修订 17、同意说明加一档，写明打开设备时读一次。
  Future<PangguaiPosition>? _warming;

  Future<void> warmLocation() async {
    final warming = _warming = locator.current(ask: false);
    try {
      await warming;
    } on PangguaiLocationException catch (error) {
      // 没给过权限、定位关着或这一会儿取不到：下单时照常再问。
      campusLog('[Pangguai] action=warm_location problem=${error.problem.name}');
    } finally {
      if (identical(_warming, warming)) _warming = null;
    }
  }

  // 下单：先取一次位置（打开设备页时先读的那一次还没回来就等它，不另起一次；取不到抛 PangguaiLocationException，一个请求都不发；
  // 可能要等系统授权框，所以不和下面的请求一起发），
  // 再一起重取详情与档位（同一个凭据，不沿用打开页面时取的），都到了再依次试算、下单（同移交包实测成功的顺序：试算在详情与档位之后、下单紧跟试算）；
  // 试算的实付和页面上的价（expected）不一样时不下单、抛 PangguaiPriceChanged；零元的单不在这里下（可能直接启动）。回订单号。
  // quotedItems 是页面按刚才的详情与档位算出的 items（试算过的那份）：试算与重取详情、档位一起发（11-28 夜用户要再快一些，少等一个来回）；
  // 详情回来后按新的算出的 items 和它不一样（档位或时长变了），就按新的再试算一次，下单用的永远是按刚取的详情算的那份。下单请求照旧等这三个都核对过才发。
  Future<String> place(String phone, {required String goodsId, required String skuId, int? minutes, required int expected, String? quotedItems}) async {
    PangguaiPosition? warmed;
    if (_warming case final warming?) {
      try {
        warmed = await warming;
      } on PangguaiLocationException {
        // 先读的那一次没取到（多半是没给过权限）：下面照常问，这次可以弹授权。
      }
    }
    final position = warmed ?? await locator.current(ask: true);
    return run(phone, (token) async {
      // 先发的试算一发出就接住错误（详情先失败、或 items 变了用不上它时，不成为没人处理的异步错误）。
      final early = quotedItems == null ? null : client.preview(token, quotedItems).then<Object>((price) => price, onError: (Object error, StackTrace stack) => AsyncError(error, stack));
      final (:device, :skus) = await _deviceAndSkus(token, goodsId);
      if (device.unusable case final reason?) throw PangguaiException(PangguaiFailure.rejected, reason);
      final sku = skus.where((each) => each.id == skuId && each.available).firstOrNull;
      if (sku == null) throw const PangguaiException(PangguaiFailure.rejected, '这个档位现在选不了，换一个');
      final items = pangguaiItems(device, sku, minutes);
      final quoted = early != null && items == quotedItems ? await early : null;
      if (quoted is AsyncError) Error.throwWithStackTrace(quoted.error, quoted.stackTrace);
      final price = quoted as int? ?? await client.preview(token, items);
      if (price != expected) throw PangguaiPriceChanged(price);
      if (price <= 0) throw const PangguaiException(PangguaiFailure.rejected, '这一单请在胖乖生活 App 里下');
      final orderId = await client.create(token, items, (category: device.category, imei: device.imei, latitude: position.latitude.toStringAsFixed(6), longitude: position.longitude.toStringAsFixed(6)));
      campusLog('[Pangguai] action=order_created category=${device.category}');
      return orderId;
    });
  }

  // 付款前：核对订单（还没付、金额和页面上的一样），收银台有能用的支付宝渠道，再拿支付串。
  // fresh 是订单页刚读到的那份（刚下好的单打开就付，页面刚查过），给了就不再重查；没给（过一会儿自己点付款）就重查。
  Future<String> prepay(String phone, String orderId, {required int expected, PangguaiOrder? fresh}) => run(phone, (token) async {
    final order = fresh ?? await client.order(token, orderId);
    if (!order.payable) throw PangguaiException(PangguaiFailure.rejected, order.cancelled ? '这一单已取消，重新下单吧' : '这一单已经付过了');
    if (order.price != expected) throw PangguaiPriceChanged(order.price);
    if (!await client.alipayUsable(token, order)) throw const PangguaiException(PangguaiFailure.rejected, '这一单不能用支付宝付，请在胖乖生活 App 里付');
    return client.prepay(token, order.number);
  });

  // 放弃付款：只取消还没付的单。
  Future<void> cancel(String phone, String orderId) => run(phone, (token) async {
    final order = await client.order(token, orderId);
    if (!order.payable) throw PangguaiException(PangguaiFailure.rejected, order.cancelled ? '这一单已经取消了' : '付过的单不能在这里取消');
    await client.cancel(token, orderId);
  });

  // 打开一台饮水机（扫码给的合作方会话就在回复里），记进最近使用。
  Future<PangguaiWater> water(String phone, String hash) => run(phone, (token) async {
    final water = await client.water(token, hash);
    await _remember(phone, PangguaiDeviceEntry(water: true, id: hash, name: water.name, place: water.place));
    return water;
  });

  // 锁机：重新扫一次拿新的会话，核对设备在线、水种能出、所选水卡够余额门槛（胖乖照样会核对，这里只是先拦明显不行的），再锁。
  // 回这次取水（查状态要用的会话、水种与取水编号）。
  Future<({PangguaiWater water, PangguaiWaterChoice choice, String? workingId})> unlock(String phone, String hash, {required String choiceId, required String areaId}) => run(phone, (token) async {
    final water = await client.water(token, hash);
    if (water.unusable case final reason?) throw PangguaiException(PangguaiFailure.rejected, reason);
    final choice = water.choices.where((each) => each.id == choiceId && each.available).firstOrNull;
    if (choice == null) throw const PangguaiException(PangguaiFailure.rejected, '这种水现在出不了，换一种');
    final card = water.cards.where((each) => each.areaId == areaId).firstOrNull;
    if (card == null) throw const PangguaiException(PangguaiFailure.rejected, '水卡变了，重新选一张');
    if (card.balance < water.minimum) throw const PangguaiException(PangguaiFailure.rejected, '水卡余额不够，先充值', code: 'balance');
    final workingId = await client.unlock(token, water, choice, card);
    campusLog('[Pangguai] action=water_locked working=${workingId != null}');
    return (water: water, choice: choice, workingId: workingId);
  });

  Future<void> _remember(String phone, PangguaiDeviceEntry entry) async {
    try {
      await devices.used(phone, entry);
    } catch (error, stack) {
      campusLog('[Pangguai] action=devices_write errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  Future<void> close() async => client.close();

  // 清除数据：删掉安全存储里本工具的全部账号与凭据、本机的最近使用（胖乖那边的账号、订单与水卡都不动）。
  @override
  Future<void> clearData() async {
    await vault.deleteAll();
    await devices.deleteAll();
  }
}
