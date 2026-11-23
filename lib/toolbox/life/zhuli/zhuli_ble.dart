import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';

// 设备回帧的命令类型（第 3 个字节，同原 App 的 bleCommon）：握手、历史单、开始、结束、结束回执、设费率、CRC 错。
const zhuliHandshakeReply = {1};
const zhuliHistoryReply = {2, 67};
const zhuliStartReply = {3, 64};
const zhuliEndReply = {4, 5, 65};
const zhuliReceipt = {6, 66};
const zhuliRateReply = {16};
const _crcError = 240;

// 帧的命令类型；不是一整帧为空。
int? zhuliFrameCommand(String frame) => frame.length >= zhuliFrameLength * 2 ? int.tryParse(frame.substring(4, 6), radix: 16) : null;

// 一台水控机的蓝牙连接（只在开水与关水时连上，做完就断开）：按广播名找到并连上，往 ff01 写帧，ff02 通知回帧。
// 帧由服务端生成，这里只搬运（见 zhuli_bath.dart）。
abstract interface class ZhuliBleLink {
  // 找到 bleName 这台并连上、打开通知；蓝牙没开、没给权限、找不到或连不上抛 ZhuliException（message 给人看）。
  // ask 为假是预先连（没有用户操作）：没给过权限就不弹系统授权框、直接失败，等用户点开水时再问。
  Future<void> connect({required String bleName, required String bleMac, bool ask = true});

  // 写一帧，等设备回一帧命令类型在 expect 里的；同原 App：每次最多等 4 秒，没等到再写一次，CRC 错立即失败。没等到抛 ZhuliException。
  Future<String> exchange(String frame, Set<int> expect);

  // 设备自己发来的结束回执（在设备上关了水），收到要交给服务端结算。
  Stream<String> get receipts;

  // 还连着（预先连好的设备可能已经自己断开，用之前看一眼）。
  bool get connected;

  Future<void> disconnect();
}

final _serviceUuid = UUID.fromString('0000ff12-0000-1000-8000-00805f9b34fb');
final _writeUuid = UUID.fromString('0000ff01-0000-1000-8000-00805f9b34fb');
final _notifyUuid = UUID.fromString('0000ff02-0000-1000-8000-00805f9b34fb');
const _scanTimeout = Duration(seconds: 5);
const _connectTimeout = Duration(seconds: 6);
const _connectAttempts = 3;
const _connectPause = Duration(milliseconds: 1500);
// 第一次连接前只等扫描停稳（原 App 第一次也等 1.5 秒，11-23 真机开关水各白等这一下，见 _connect）。
const _firstConnectPause = Duration(milliseconds: 200);
// 取消没连上的连接：插件对没连上的设备收不到断开的回调（模拟器上要等满超时），只等一会儿。
const _cancelTimeout = Duration(seconds: 2);
const _gattTimeout = Duration(seconds: 10);
const _replyTimeout = Duration(seconds: 4);

ZhuliException _ble(String message) => ZhuliException(ZhuliFailure.rejected, message);

String _hex(Uint8List bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join().toUpperCase();

Uint8List _bytes(String hex) => Uint8List.fromList([for (var index = 0; index < hex.length; index += 2) int.parse(hex.substring(index, index + 2), radix: 16)]);

// 插件 bluetooth_low_energy（面对面私信也用它）的实现：只在开水、关水时创建管理器（iOS 第一次会弹蓝牙权限）。
// 权限：安卓 12 起「附近的设备」里的扫描与连接，安卓 11 要位置且定位开关开着（系统规定这时才扫得到），iOS 由系统问。
class PluginZhuliBleLink implements ZhuliBleLink {
  CentralManager? _central;
  Peripheral? _device;
  GATTCharacteristic? _write;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _notified;
  StreamSubscription<PeripheralConnectionStateChangedEventArgs>? _states;
  var _connected = false;
  final _receipts = StreamController<String>.broadcast();
  Completer<String>? _waiting;
  Set<int> _expect = const {};

  @override
  Stream<String> get receipts => _receipts.stream;

  @override
  bool get connected => _connected;

  // 这个进程里连上过一次（iOS 上不弹框查不了授权，连上过才说明给过）。
  static var _granted = false;

  @override
  Future<void> connect({required String bleName, required String bleMac, bool ask = true}) async {
    if (!ask && !await _quietlyGranted()) throw _ble('还没给蓝牙权限');
    await _authorize();
    final central = _central ??= CentralManager();
    await _poweredOn(central);
    final (device, seen) = await _find(central, bleName, bleMac);
    await _connect(central, device, attempts: seen ? _connectAttempts : 1);
    _device = device;
    if (Platform.isAndroid) await _boost();
    try {
      final services = await central.discoverGATT(device).timeout(_gattTimeout);
      final service = services.where((service) => service.uuid == _serviceUuid).firstOrNull;
      final write = service?.characteristics.where((characteristic) => characteristic.uuid == _writeUuid).firstOrNull;
      final notify = service?.characteristics.where((characteristic) => characteristic.uuid == _notifyUuid).firstOrNull;
      if (write == null || notify == null) throw _ble('这台设备不认得，换一台试试');
      _write = write;
      _notified = central.characteristicNotified.listen((event) {
        if (event.peripheral.uuid == device.uuid && event.characteristic.uuid == _notifyUuid) _onFrame(_hex(event.value));
      });
      await central.setCharacteristicNotifyState(device, notify, state: true).timeout(_gattTimeout);
      _states = central.connectionStateChanged.listen((event) {
        if (event.peripheral.uuid == device.uuid && event.state == ConnectionState.disconnected) _connected = false;
      });
      _connected = true;
      _granted = true;
      campusLog('[Zhuli] action=ble_connected');
    } on ZhuliException {
      await disconnect();
      rethrow;
    } catch (error, stack) {
      campusLog('[Zhuli] action=ble_gatt errorType=${error.runtimeType}\n$stack');
      await disconnect();
      throw _ble('设备通讯失败，再试一次');
    }
  }

  // 安卓连上后、发现服务前调高连接优先级（[人工决策] 在 android/app/src/main/kotlin/com/superxd/superxd/ZhuliBleBoost.kt）：发现服务与每次命令帧来回都快些；
  // 插件里拿不到连接（升级改了字段名）时原生回 -1，只记日志、照常开关水。iOS 的连接间隔由系统定，不调。
  Future<void> _boost() async {
    try {
      final boosted = await const MethodChannel('superxd/zhuli_ble').invokeMethod<int>('boost');
      campusLog('[Zhuli] action=ble_boost count=$boosted');
    } catch (error) {
      campusLog('[Zhuli] action=ble_boost reason=${error.runtimeType}');
    }
  }

  // 不弹框地看权限给了没有：安卓查状态，iOS 看这个进程里连上过没有。
  Future<bool> _quietlyGranted() async {
    if (!Platform.isAndroid) return _granted;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    if (sdk >= 31) return await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
    return await Permission.locationWhenInUse.isGranted;
  }

  Future<void> _authorize() async {
    if (!Platform.isAndroid) return;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    if (sdk >= 31) {
      final results = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
      if (!results.values.every((status) => status.isGranted)) throw _ble('要允许「附近的设备」才能用蓝牙开水');
      return;
    }
    if (!(await Permission.locationWhenInUse.request()).isGranted) throw _ble('安卓 11 要允许位置才能扫描蓝牙设备');
    if (await Permission.locationWhenInUse.serviceStatus != ServiceStatus.enabled) throw _ble('安卓 11 要打开定位才能扫描蓝牙设备');
  }

  // 刚创建的管理器先是 unknown，等系统报来（iOS 第一次会等用户点权限弹窗）。
  Future<void> _poweredOn(CentralManager central) async {
    var state = central.state;
    if (state == BluetoothLowEnergyState.unknown) {
      try {
        state = (await central.stateChanged.firstWhere((event) => event.state != BluetoothLowEnergyState.unknown).timeout(const Duration(seconds: 60))).state;
      } on TimeoutException {
        state = central.state;
      }
    }
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        return;
      case BluetoothLowEnergyState.poweredOff:
        throw _ble('先打开手机蓝牙');
      case BluetoothLowEnergyState.unauthorized:
        throw _ble('要允许本应用使用蓝牙');
      case BluetoothLowEnergyState.unsupported:
        throw _ble('这台手机不支持蓝牙低功耗');
      case BluetoothLowEnergyState.unknown:
        throw _ble('蓝牙还没准备好，再试一次');
    }
  }

  // 扫描最多 5 秒（同原 App），按广播名认；安卓上名字没带上时按地址认（插件在安卓上用地址生成标识）。
  // 安卓上原 App 本来就直接按设备地址连、扫描只是顺带（11-22 真机：扫 5 秒认不出那台设备），所以安卓扫不到时照它按地址连一次；iOS 拿不到地址，只能按名字扫到。
  // 扫描结果记进日志（要找的广播名与蓝牙地址、扫到几台、看到的 XN 开头的名字，最多 5 个），真机上认不出时据此分清是名字对不上还是根本没扫到。
  // 广播名与地址是设备公开广播的标识，不是个人信息（11-23 真机诊断包里只有扫到的名字、分不出要找的是哪台，补上）。
  // 返回设备与扫没扫到：扫到的连接照原 App 最多 3 次；扫不到的按地址只试 1 次（11-22 真机：扫不到的老设备按地址一次也没连上过，3 次要白等近半分钟）。
  Future<(Peripheral, bool)> _find(CentralManager central, String bleName, String bleMac) async {
    final byAddress = Platform.isAndroid && bleMac.isNotEmpty ? UUID.fromAddress(bleMac) : null;
    final found = Completer<Peripheral>();
    final peers = <UUID>{}, names = <String>{};
    final subscription = central.discovered.listen((event) {
      peers.add(event.peripheral.uuid);
      final name = event.advertisement.name ?? '';
      if (name.startsWith('XN') && names.length < 5) names.add(name);
      if (found.isCompleted) return;
      if ((bleName.isNotEmpty && name == bleName) || (byAddress != null && event.peripheral.uuid == byAddress)) found.complete(event.peripheral);
    });
    try {
      await central.startDiscovery();
      final device = await found.future.timeout(_scanTimeout);
      campusLog('[Zhuli] action=ble_scan result=found target=$bleName seen=${peers.length}');
      return (device, true);
    } on TimeoutException {
      campusLog('[Zhuli] action=ble_scan result=not_found target=$bleName mac=$bleMac seen=${peers.length} names=${names.join('|')} byAddress=${byAddress != null}');
      if (byAddress != null) return (await central.getPeripheral(bleMac), false);
      throw const ZhuliException(ZhuliFailure.unreachable, '附近没找到这台设备，靠近一点再试');
    } finally {
      await subscription.cancel();
      try {
        await central.stopDiscovery();
      } catch (error) {
        campusLog('[Zhuli] action=ble_stop_scan reason=${error.runtimeType}');
      }
    }
  }

  // 连接：最多 3 次、每次最多等 6 秒，没连上先取消这次挂着的连接再试，免得几次请求叠在系统里（11-22 真机扫到了、一次 6 秒没连上）；
  // 重试之间同原 App 等 1.5 秒，第一次只等 0.2 秒让扫描停稳（原 App 第一次也等 1.5 秒，11-23 诊断包里开水 5.1 秒、关水 6.5 秒，这一下各占 1.5 秒）。
  Future<void> _connect(CentralManager central, Peripheral device, {required int attempts}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      await Future<void>.delayed(attempt == 1 ? _firstConnectPause : _connectPause);
      try {
        await central.connect(device).timeout(_connectTimeout);
        campusLog('[Zhuli] action=ble_connect result=ok attempt=$attempt');
        return;
      } catch (error) {
        campusLog('[Zhuli] action=ble_connect result=failed attempt=$attempt reason=${error.runtimeType} detail=${error is PlatformException ? error.message : ''}');
        try {
          await central.disconnect(device).timeout(_cancelTimeout);
        } catch (cancel) {
          campusLog('[Zhuli] action=ble_cancel reason=${cancel.runtimeType}');
        }
      }
    }
    throw const ZhuliException(ZhuliFailure.unreachable, '连不上这台设备，靠近一点再试');
  }

  void _onFrame(String frame) {
    final command = zhuliFrameCommand(frame);
    if (command == null) return;
    final waiting = _waiting;
    if (command == _crcError) {
      if (waiting != null && !waiting.isCompleted) waiting.completeError(_ble('设备校验没通过，再试一次'));
    } else if (_expect.contains(command)) {
      if (waiting != null && !waiting.isCompleted) waiting.complete(frame.substring(0, zhuliFrameLength * 2));
    } else if (zhuliReceipt.contains(command)) {
      _receipts.add(frame.substring(0, zhuliFrameLength * 2));
    }
  }

  @override
  Future<String> exchange(String frame, Set<int> expect) async {
    final central = _central, device = _device, write = _write;
    if (central == null || device == null || write == null) throw _ble('设备已断开，再试一次');
    final type = write.properties.contains(GATTCharacteristicProperty.write) ? GATTCharacteristicWriteType.withResponse : GATTCharacteristicWriteType.withoutResponse;
    for (var attempt = 0; attempt < 2; attempt++) {
      final waiting = _waiting = Completer<String>();
      _expect = expect;
      try {
        await central.writeCharacteristic(device, write, value: _bytes(frame), type: type).timeout(_gattTimeout);
        return await waiting.future.timeout(_replyTimeout);
      } on TimeoutException {
        campusLog('[Zhuli] action=ble_exchange reason=timeout attempt=$attempt');
      } on ZhuliException {
        rethrow;
      } catch (error) {
        campusLog('[Zhuli] action=ble_exchange reason=${error.runtimeType} attempt=$attempt');
      } finally {
        _waiting = null;
        _expect = const {};
      }
    }
    throw _ble('设备没有回应，靠近一点再试');
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _notified?.cancel();
    _notified = null;
    await _states?.cancel();
    _states = null;
    final central = _central, device = _device;
    _device = null;
    _write = null;
    if (central == null || device == null) return;
    try {
      await central.disconnect(device).timeout(_connectTimeout);
    } catch (error) {
      campusLog('[Zhuli] action=ble_disconnect reason=${error.runtimeType}');
    }
  }
}
