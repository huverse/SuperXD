import 'dart:async';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_ble.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';

// 开水前的检查结果（资料 4.2 的清单，顺序同原 App）：blocked 不为空不能开；confirm 不为空要用户再点一次（供水时段外、余额低于门槛但允许继续）；
// running 是自己在这台设备上正在用水的单（接回去，不再下单）。
// device 已按学校设定定好默认走哪一路（via）；channels 是能选的几路（两用设备是云端的通道与蓝牙 4，其余只有一路）。
class ZhuliBathPlan {
  const ZhuliBathPlan({required this.device, required this.channels, required this.profile, required this.coupons, this.rule, this.blocked, this.confirm, this.running});
  final ZhuliDevice device;
  final List<int> channels;
  final ZhuliProfile profile;
  // 未使用的券加起来还剩多少（开水前给人看，预扣先扣券还是余额看券的设定）。
  final ({int balance, int count}) coupons;
  final ZhuliChargeRule? rule;
  final String? blocked;
  final String? confirm;
  final ZhuliLastRecord? running;
}

// [人工决策-2026-11-22 22:35:03] 同房间新旧设备同名（用户选「排序加一键换设备」，没选收起老设备、只改提示、本机记住扫不到的）：
// 换下来的老蓝牙设备还挂在住理的列表里、和新的两用设备同名，住理的数据分不出哪台是死的（11-22 真机：232 的老设备不在广播，power_status 对蓝牙设备没意义）。
// 不按猜测藏设备：同房间能走云端的排前面（列表与换设备都按这个），蓝牙设备找不到或连不上时洗浴页列出同房间的其他设备一键换过去。
List<ZhuliDevice> zhuliCloudFirst(List<ZhuliDevice> devices) => [...devices.where((device) => !device.bluetooth), ...devices.where((device) => device.bluetooth)];

// 现在（北京时间的钟点）在不在供水时段里；没给时段当全天供水。
bool zhuliInSupply(List<ZhuliSupply> supply, DateTime now) {
  if (supply.isEmpty) return true;
  final clock = zhuliClock(now);
  final minutes = int.parse(clock.substring(11, 13)) * 60 + int.parse(clock.substring(14, 16));
  return supply.any((window) => window.start <= window.end ? minutes >= window.start && minutes <= window.end : minutes >= window.start || minutes <= window.end);
}

// 洗浴：开水与关水（资料第 4 节）。走哪一路看传进来的设备（ZhuliDevice.channel，洗浴页按学校设定或用户选的定下来）：
// 云端（4G 等）由服务端下发开关，开水后 3 秒查一次订单看水开没开、用了多少；
// 蓝牙（11-22 实测这个学校抽样的 50 台里 46 台只有蓝牙）由手机连上设备，按原 App 的 bleCommon 在服务端与设备之间搬运命令帧：
// 握手（拿 isn）→ 有设费率帧先写 → 补传设备里的历史单 → 下单拿开始帧 → 写给设备 → 回帧交服务端；关水同样先握手再写结束帧、回帧交服务端结算。
// 只在开水与关水时连蓝牙，做完就断开（设备空闲 25 秒左右会断，原 App 关水时也要重连再握手）。每一步请求各自经 run（会话过期重登后只重放那一步）。
class ZhuliBath {
  ZhuliBath({required this.service, required this.phone, ZhuliBleLink Function()? link, DateTime Function()? clock}) : _link = link ?? PluginZhuliBleLink.new, _clock = clock ?? DateTime.now;
  final ZhuliService service;
  final String phone;
  final ZhuliBleLink Function() _link;
  final DateTime Function() _clock;

  ZhuliClient get _client => service.client;

  Future<T> _run<T>(Future<T> Function(ZhuliSession session) action) => service.run(phone, action);

  // 开水前查一遍：设备、账户与计费规则、券余额、项目配置、待支付的单、最近一单（一起发）。
  Future<ZhuliBathPlan> prepare(int deviceId) => _run((session) async {
    final values = await Future.wait<Object?>([_client.device(session, deviceId), _client.profile(session), service.couponBalance(session), _client.config(session), _client.pendingOrders(session), _client.lastRecord(session)]);
    final found = values[0]! as ZhuliDevice, profile = values[1]! as ZhuliProfile, coupons = values[2]! as ({int balance, int count});
    final config = values[3]! as ZhuliConfig, pending = values[4]! as int, last = values[5] as ZhuliLastRecord?;
    final device = found.using(found.channelWith(config.networkSelection));
    final channels = found.dual && !found.forceBluetooth ? [found.cloudChannel(config.networkSelection), 4] : [device.channel];
    final rule = profile.ruleFor(device);
    ZhuliBathPlan plan({String? blocked, String? confirm, ZhuliLastRecord? running}) => ZhuliBathPlan(device: device, channels: channels, profile: profile, coupons: coupons, rule: rule, blocked: blocked, confirm: confirm, running: running);
    if (last != null && last.running && last.deviceId == device.id) return plan(running: last);
    if (!config.bath) return plan(blocked: '这个学校没开洗浴');
    if (!device.bath) return plan(blocked: '这台不是洗浴设备，暂不支持');
    if (last != null && last.running) return plan(blocked: '你还有一单在用水，先在首页结束那一单');
    if (device.status != 0) return plan(blocked: '设备正在维护，换一台试试');
    if (!device.idle) return plan(blocked: '设备正在被使用，换一台试试');
    if (rule == null) return plan(blocked: '这台设备没设定计费规则，请联系管理员');
    if (pending > 0) return plan(blocked: '你有 $pending 笔待支付的订单，先在住理生活 App 里付清');
    if (config.minimumBalance > 0 && profile.balance < config.minimumBalance) {
      if (!config.continueBelowMinimum) return plan(blocked: '余额不足 ¥${zhuliYuan(config.minimumBalance)}，先充值');
      return plan(confirm: '余额可能不够这次用水，仍要开吗？');
    }
    if (!zhuliInSupply(device.supply, _clock())) {
      if (config.forceSupplyTime) return plan(blocked: '现在不在供水时段');
      return plan(confirm: '现在不在供水时段，可能没有热水，仍要开吗？');
    }
    return plan();
  });

  // 开水，返回下的单（预扣后的余额在 balance）。
  Future<ZhuliOrderStart> start(ZhuliDevice device) async {
    campusLog('[Zhuli] action=bath_start channel=${device.channel}');
    if (!device.bluetooth) return _run((session) => _client.startCloud(session, device));
    return _withLink(device, (link, handshake) async {
      if (handshake.occupied) {
        // 设备被占用：是自己这台上没结束的单就接回去，别人的就换一台（同原 App）。
        final last = await _run(_client.lastRecord);
        if (last != null && last.running && last.deviceId == device.id) return ZhuliOrderStart(orderId: last.orderId, status: last.status);
        throw const ZhuliException(ZhuliFailure.rejected, '设备正在被使用，换一台试试');
      }
      final order = await _run((session) => _client.startBluetooth(session, device, handshake.isn));
      final frame = order.startFrame;
      if (frame == null) throw const ZhuliException(ZhuliFailure.invalidResponse, '住理生活的返回看不懂，稍后再试');
      final String reply;
      try {
        reply = await link.exchange(frame, zhuliStartReply);
      } on ZhuliException catch (error) {
        // 单已经下了、设备没回：水没开，这一单由住理收尾（结果在订单里看）。
        campusLog('[Zhuli] action=bath_start_frame reason=${error.failure.name}');
        throw ZhuliException(ZhuliFailure.rejected, '${error.message}（水没开，这一单的结果在订单里看）');
      }
      await _run((session) => _client.bleStarted(session, deviceId: device.id, orderId: order.orderId, reply: reply));
      return order;
    });
  }

  // 关水，返回结算后的订单（等到 finished，最多约 15 秒；还没结算完返回当时的样子）。
  Future<ZhuliBill> end(ZhuliDevice device, String orderId) async {
    campusLog('[Zhuli] action=bath_end channel=${device.channel}');
    if (!device.bluetooth) {
      await _run((session) => _client.endCloud(session, orderId: orderId, deviceId: device.id));
      return _settled(orderId);
    }
    await _withLink(device, (link, handshake) async {
      // 握手时补传了历史单：在设备上已经关了水的，这一单已结算，不用再写结束帧。
      if ((await _run((session) => _client.bill(session, orderId))).status == 'finished') return;
      final frame = await _run((session) => _client.bleEndFrame(session, device.id, handshake.isn));
      final reply = await link.exchange(frame, zhuliEndReply);
      await _run((session) => _client.bleEnded(session, device.id, reply));
    });
    return _settled(orderId);
  }

  Future<ZhuliBill> bill(String orderId) => _run((session) => _client.bill(session, orderId));

  // 同房间的其他设备（蓝牙设备找不到时给人换一台）：设备详情里没有房间的编号，按楼栋、楼层、房间的名字一级级找（只在失败时查一次）；找不到为空。
  Future<List<ZhuliDevice>> roomMates(ZhuliDevice device) => _run((session) async {
    ZhuliPlace? named(List<ZhuliPlace> places, String name) => places.where((place) => place.name == name).firstOrNull;
    final building = named(await _client.buildings(session), device.building);
    if (building == null) return const <ZhuliDevice>[];
    final floor = named(await _client.floors(session, building.id), device.floor);
    if (floor == null) return const <ZhuliDevice>[];
    final room = named(await _client.rooms(session, floor.id), device.room);
    if (room == null) return const <ZhuliDevice>[];
    final devices = await _client.roomDevices(session, buildingId: building.id, floorId: floor.id, roomId: room.id, page: 1);
    return zhuliCloudFirst([for (final mate in devices) if (mate.id != device.id && mate.bath) mate]);
  });

  Future<ZhuliBill> _settled(String orderId) async {
    var bill = await this.bill(orderId);
    for (var attempt = 0; attempt < 10 && bill.status != 'finished' && bill.status != 'refund'; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      bill = await this.bill(orderId);
    }
    return bill;
  }

  // 连上设备并握手，做完 work 断开；连着时设备发来的结束回执都交服务端结算。
  Future<T> _withLink<T>(ZhuliDevice device, Future<T> Function(ZhuliBleLink link, ZhuliHandshake handshake) work) async {
    final link = _link();
    await link.connect(bleName: device.bleName, bleMac: device.bleMac);
    final receipts = link.receipts.listen((reply) => unawaited(_run((session) => _client.bleEnded(session, device.id, reply)).catchError((Object error, StackTrace stack) {
      campusLog('[Zhuli] action=ble_receipt errorType=${error.runtimeType}\n$stack');
    })));
    try {
      final hello = await _run((session) => _client.bleHandshakeFrame(session, device.id));
      final greeting = await link.exchange(hello, zhuliHandshakeReply);
      final handshake = await _run((session) => _client.bleHandshake(session, device.id, greeting));
      if (handshake.rateCommand case final rate?) await link.exchange(rate, zhuliRateReply);
      if (!handshake.occupied) await _history(link, device, handshake.isn);
      return await work(link, handshake);
    } finally {
      await receipts.cancel();
      await link.disconnect();
    }
  }

  // 补传设备里还没交给服务端的单（同原 App：失败不影响开关水）。
  Future<void> _history(ZhuliBleLink link, ZhuliDevice device, String isn) async {
    try {
      final frame = await _run((session) => _client.bleHistoryFrame(session, device.id, isn));
      final reply = await link.exchange(frame, zhuliHistoryReply);
      await _run((session) => _client.bleEnded(session, device.id, reply));
    } on ZhuliException catch (error) {
      if (error.failure == ZhuliFailure.notSignedIn || error.failure == ZhuliFailure.captchaRequired) rethrow;
      campusLog('[Zhuli] action=ble_history reason=${error.failure.name}');
    }
  }
}
