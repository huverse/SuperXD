import 'dart:io';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// [人工决策-2026-11-27 17:45:01] 生活的第二个子模块胖乖生活（com.qiekj.user 1.148.0，资料是用户 11-27 转交的另一个 AI 的移交包，仓库外）：
// 登录 → 扫码或按附近门店浏览 → 设备详情 → 有档位的选档、没有的直接下一步 → 下单 → 支付宝付款 → 胖乖下发开机，品类为洗衣机、洗鞋机、烘干机、吹风机（先付后用）；
// 饮水机是用户说的「现有的」apwork.cn 码那种，照官方 App 打开胖乖自己的网页（pangguai_web_page.dart），原生的先用后付（饮水机、淋浴）以后再说。
// 用户 11-27 四项选择：加手机定位（附近门店按位置列、下单带真实坐标，没选「不申请定位、用门店坐标」）；多账号切换（同住理，没选单账号）；
// 第一版不用券（下单不带优惠，付多少以胖乖订单为准，没选「照官方自动选券」）；付款先只接支付宝、给以后的其他方式留位置（PangguaiPayMethod，没选「支付宝加胖乖余额」）。
// 碰真钱，照 domain/feature_flags.dart 11-27 那条登记自己的开关 toolbox.life.pangguai、默认关，先点名给开发者测。
//
// 服务：持有账号的安全存储、本机的最近使用、客户端、支付宝与定位，没有业务库（订单与设备即查即用，不落盘）。
class PangguaiService implements ToolboxService {
  PangguaiService({required this.vault, required this.devices, PangguaiClient? client, LifeAlipay? alipay, PangguaiLocator? locator})
    : client = client ?? PangguaiClient(),
      alipay = alipay ?? TobiasLifeAlipay(),
      locator = locator ?? GeolocatorPangguaiLocator();
  final PangguaiVault vault;
  final PangguaiDeviceStore devices;
  final PangguaiClient client;
  final LifeAlipay alipay;
  final PangguaiLocator locator;

  // 子模块 id：路由（/toolbox/life/pangguai）、服务与同意记录共用，发出后不改。
  static const serviceId = 'life.pangguai';
  // 第一次登录前的同意说明的版本，说明有实质变化就加一档。
  static const consentVersion = 'pangguai-1';

  static Future<PangguaiService> open(ToolboxServiceContext context) async =>
      PangguaiService(vault: SecurePangguaiVault(), devices: PangguaiDeviceStore.file(File('${context.base.path}/pangguai_devices.json')));

  Future<PangguaiVaultState> state() => vault.load();

  // 发登录短信：先问胖乖要不要过易盾图形验证（要的话这一版做不了，请用户去官方 App 登录）。
  Future<void> sendCode(String phone) async {
    if (await client.needsCaptcha(phone)) throw const PangguaiException(PangguaiFailure.rejected, '胖乖生活这次要先过图形验证，这里还做不了，先在胖乖生活 App 里登录');
    await client.sendCode(phone);
  }

  // 登录（也用来加账号、重新登录）：成功后记下凭据并设为当前账号，同一手机号只记一份，最多 pangguaiAccountLimit 个。
  Future<void> signIn(String phone, String code) async {
    final token = await client.login(phone, code);
    final state = await vault.load();
    final accounts = [PangguaiCredential(phone: phone, token: token), ...state.accounts.where((account) => account.phone != phone)];
    await vault.save(PangguaiVaultState(accounts: accounts.take(pangguaiAccountLimit).toList(), active: phone));
  }

  Future<void> switchTo(String phone) async {
    final state = await vault.load();
    if (state.accounts.any((account) => account.phone == phone)) await vault.save(PangguaiVaultState(accounts: state.accounts, active: phone));
  }

  // 退出这个账号：删掉它的凭据与最近使用（胖乖那边的账号与订单不动），当前账号换成剩下的第一个。
  Future<void> signOut(String phone) async {
    final state = await vault.load();
    final accounts = [for (final account in state.accounts) if (account.phone != phone) account];
    await vault.save(PangguaiVaultState(accounts: accounts, active: state.active == phone ? accounts.firstOrNull?.phone : state.active));
    await devices.forget(phone);
  }

  // 带着这个账号的凭据做一次请求。凭据失效（胖乖回没登录）没法在后台重登（登录要短信验证码），原样抛给页面请用户重新登录。
  Future<T> run<T>(String phone, Future<T> Function(String token) action) async {
    final credential = (await vault.load()).accounts.where((account) => account.phone == phone).firstOrNull;
    if (credential == null) throw const PangguaiException(PangguaiFailure.notSignedIn, '请先登录');
    return action(credential.token);
  }

  // 打开设备页：详情、档位与体检（体检不健康时不许下单）。
  Future<PangguaiDeviceInfo> inspect(String phone, String goodsId) => run(phone, (token) async {
    final device = await client.device(token, goodsId);
    final skus = device.payment == 'before' ? await client.skus(token, goodsId) : const <PangguaiSku>[];
    final health = device.payment == 'before' && device.unusable == null ? await client.health(token, goodsId) : (healthy: true, fault: '');
    await devices.used(phone, PangguaiDeviceEntry(goodsId: device.goodsId, name: device.name, category: device.category, place: device.orgName));
    return (device: device, skus: skus, fault: health.healthy ? null : (health.fault.isEmpty ? '设备故障，换一台吧' : health.fault));
  });

  // 下单：胖乖按凭据记着「选中了哪台设备」，详情 → 档位 → 试算 → 下单四步要按顺序、同一个凭据连着发（少一步或隔久了只回「下单异常，请稍后再试」，资料实测），
  // 所以点「下单」时整串重发一遍，不沿用打开页面时取的；位置在这之前取好（取不到写空，见 PangguaiClient.create）。
  // 试算的实付和页面上给人看的价不一样时不下单，交回新价请用户再确认（不让人付没看过的钱）。
  Future<PangguaiPlacement> place(String phone, {required String goodsId, required PangguaiItem item, required int expected}) async {
    PangguaiPosition? position;
    try {
      position = await locator.locate(ask: true);
    } on PangguaiLocateException catch (error) {
      campusLog('[Pangguai] action=place_locate reason=${error.failure.name}');
    }
    return run(phone, (token) async {
      final device = await client.device(token, goodsId);
      await client.skus(token, goodsId);
      final cents = await client.preview(token, [item]);
      if (cents != expected) return PangguaiPriceChanged(cents);
      final order = await client.create(token, device, [item], position);
      campusLog('[Pangguai] action=placed category=${device.category} located=${position != null}');
      return PangguaiPlaced(order, device.orgId);
    });
  }

  // 这一单能用哪些付款方式：收银台给的、且这一版接了的（只有支付宝）。不知道门店编号（从订单列表进来的）时不问收银台，直接给支付宝。
  Future<List<PangguaiPayMethod>> payMethods(String phone, String orderNo, String? orgId) async {
    if (orgId == null || orgId.isEmpty) return PangguaiPayMethod.values;
    final channels = await run(phone, (token) => client.channels(token, orderNo, orgId));
    return [for (final method in PangguaiPayMethod.values) if (channels.any((channel) => channel.method == method.code && channel.usable)) method];
  }

  @override
  Future<void> close() async => client.close();

  // 清除数据：删掉安全存储里本工具的全部账号与凭据、本机的最近使用（胖乖那边的账号与订单都不动）。
  @override
  Future<void> clearData() async {
    await vault.deleteAll();
    await devices.deleteAll();
  }
}

typedef PangguaiDeviceInfo = ({PangguaiDevice device, List<PangguaiSku> skus, String? fault});

sealed class PangguaiPlacement {
  const PangguaiPlacement();
}

class PangguaiPlaced extends PangguaiPlacement {
  const PangguaiPlaced(this.order, this.orgId);
  final PangguaiOrderRef order;
  final String orgId;
}

class PangguaiPriceChanged extends PangguaiPlacement {
  const PangguaiPriceChanged(this.cents);
  final int cents;
}

// 付款方式：这一版只接支付宝（用户 11-27 选的），收银台给了别的方式也不显示；以后接胖乖余额这类就在这里加一项（code 是胖乖的支付方式编号），结账按它分支。
enum PangguaiPayMethod {
  alipay(PangguaiClient.alipayMethod, '支付宝');

  const PangguaiPayMethod(this.code, this.label);
  final int code;
  final String label;
}
