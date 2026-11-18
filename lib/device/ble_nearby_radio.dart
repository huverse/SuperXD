import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/nearby_radio.dart';

// 面对面私信的蓝牙低功耗传输（人工决策见 social/nearby_service.dart）：插件 bluetooth_low_energy（中心与外围两种角色，安卓与 iOS）。
// 每台开着面对面页的手机同时：外围——广播本应用的服务号，开一个只读的「出现标记」特征和一个可写的「收件」特征；
// 中心——按服务号扫描，看到新手机就连上读一次出现标记再断开，发送时连上把一整条按帧写进对方的收件特征再断开。
// 广播只带服务号（iOS 外围只能广播名字和服务号，名字也不放）；出现标记的内容由私信层定，不带设备号（见 social/nearby_protocol.dart）。
// 只在用户打开面对面页时创建插件的两个管理器（创建即初始化，iOS 会弹蓝牙权限），启动时不碰蓝牙。
// 权限：安卓 12 起要「附近的设备」（扫描、广播、连接，扫描声明不用于定位），安卓 11 要位置且定位开关开着（系统规定这时才扫得到蓝牙），iOS 由系统在第一次用时问。

final nearbyServiceUuid = UUID.fromString('5d1e2c3a-7b4f-4e0a-9c61-3f8a1b2d4c70');
final _presenceUuid = UUID.fromString('5d1e2c3a-7b4f-4e0a-9c61-3f8a1b2d4c71');
final _inboxUuid = UUID.fromString('5d1e2c3a-7b4f-4e0a-9c61-3f8a1b2d4c72');

// 一整条的上限：同线上私信单条密文 256KB，留一点信封余量。
const nearbyPayloadLimit = 256 * 1024 + 1024;
// 一帧最多 512 字节（ATT 属性值上限）；实际按这次连接能写的长度取，不让系统拆成长写。
const _frameMax = 512;
// 多久没再看到就算走开了。
const _peerExpiry = Duration(seconds: 15);
// 读出现标记失败后隔多久再试。
const _readRetry = Duration(seconds: 10);
const _connectTimeout = Duration(seconds: 10);
const _gattTimeout = Duration(seconds: 10);
const _frameTimeout = Duration(seconds: 10);
// 收件方：一条拼到一半超过这么久没下一帧就丢掉。
const _assemblyTimeout = Duration(seconds: 30);

// 日志里只写连接标识的末 4 位（安卓上是会轮换的蓝牙地址，前面一截都是 0）。
String _tail(String id) => id.length <= 4 ? id : id.substring(id.length - 4);

// 帧：第一帧 0x01 | 总长(4，大端) | 数据，之后每帧 0x02 | 数据。写入都要回应，顺序与流控由 GATT 保证；最后一帧的回应即对方收没收下。
List<Uint8List> nearbyFrames(Uint8List payload, int frameSize) {
  if (frameSize < 8) throw ArgumentError.value(frameSize, 'frameSize');
  final frames = <Uint8List>[];
  final header = ByteData(5)..setUint8(0, 1)..setUint32(1, payload.length);
  var offset = min(payload.length, frameSize - 5);
  frames.add(Uint8List.fromList([...header.buffer.asUint8List(), ...payload.sublist(0, offset)]));
  while (offset < payload.length) {
    final end = min(payload.length, offset + frameSize - 1);
    frames.add(Uint8List.fromList([2, ...payload.sublist(offset, end)]));
    offset = end;
  }
  return frames;
}

// 收件方按发件手机拼帧（外部输入：长度、顺序不对就丢掉这一条）。
class NearbyAssembler {
  NearbyAssembler({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  BytesBuilder? _buffer;
  int _expected = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  // 返回拼好的一整条；还没拼完为空；帧不合格抛 FormatException（这一条作废）。
  Uint8List? add(Uint8List frame) {
    final now = _clock();
    if (_buffer != null && now.difference(_last) > _assemblyTimeout) _buffer = null;
    _last = now;
    if (frame.isEmpty) throw const FormatException('空帧');
    switch (frame[0]) {
      case 1:
        if (frame.length < 5) throw const FormatException('首帧太短');
        _expected = ByteData.sublistView(frame, 1, 5).getUint32(0);
        if (_expected == 0 || _expected > nearbyPayloadLimit) {
          _buffer = null;
          throw const FormatException('长度不对');
        }
        _buffer = BytesBuilder(copy: false)..add(frame.sublist(5));
      case 2:
        final buffer = _buffer;
        if (buffer == null) throw const FormatException('没有首帧');
        buffer.add(frame.sublist(1));
      default:
        _buffer = null;
        throw const FormatException('帧类型不对');
    }
    final buffer = _buffer!;
    if (buffer.length > _expected) {
      _buffer = null;
      throw const FormatException('超出声明的长度');
    }
    if (buffer.length < _expected) return null;
    _buffer = null;
    return buffer.takeBytes();
  }
}

class BleNearbyRadio implements NearbyRadio {
  BleNearbyRadio();

  CentralManager? _central;
  PeripheralManager? _peripheral;
  GATTService? _service;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _changes = StreamController<void>.broadcast();
  // 中心角色的连接一次只做一件事（读出现标记或发送），插件与系统都不擅长并发连接。
  final _centralLock = Lock();
  final _devices = <String, Peripheral>{};
  final _seen = <String, DateTime>{};
  final _presence = <String, Uint8List>{};
  final _reading = <String>{};
  final _failedAt = <String, DateTime>{};
  final _assemblers = <String, NearbyAssembler>{};
  Timer? _sweep;
  Uint8List Function()? _presenceOf;
  Future<bool> Function(Uint8List payload)? _onPayload;
  NearbyRadioState _state = NearbyRadioState.off;
  int _generation = 0;

  @override
  NearbyRadioState get state => _state;

  @override
  List<NearbyPeer> get peers => [for (final entry in _presence.entries) NearbyPeer(entry.key, entry.value)];

  @override
  Stream<void> get changes => _changes.stream;

  void _set(NearbyRadioState state) {
    if (_state == state) return;
    _state = state;
    campusLog('[Nearby] action=radio state=${state.name}');
    _changes.add(null);
  }

  @override
  Future<void> start({required Uint8List Function() presence, required Future<bool> Function(Uint8List payload) onPayload}) async {
    _presenceOf = presence;
    _onPayload = onPayload;
    if (_state == NearbyRadioState.ready || _state == NearbyRadioState.starting) return;
    final generation = ++_generation;
    _set(NearbyRadioState.starting);
    try {
      final allowed = await _authorize();
      if (generation != _generation) return;
      if (allowed != null) return _set(allowed);
      final central = _central ??= CentralManager();
      final peripheral = _peripheral ??= PeripheralManager();
      final blocked = _blocked(await _settled(central)) ?? _blocked(await _settled(peripheral));
      if (generation != _generation) return;
      if (blocked != null) {
        _watchState(central, peripheral);
        return _set(blocked);
      }
      await _begin(central, peripheral);
      if (generation != _generation) return await _end();
      _set(NearbyRadioState.ready);
    } catch (error, stack) {
      campusLog('[Nearby] action=start errorType=${error.runtimeType}\n$stack');
      if (generation == _generation) {
        await _end();
        _set(NearbyRadioState.failed);
      }
    }
  }

  // 权限：返回挡住的状态，都给了为空。
  Future<NearbyRadioState?> _authorize() async {
    if (!Platform.isAndroid) return null;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    if (sdk >= 31) {
      final results = await [Permission.bluetoothScan, Permission.bluetoothAdvertise, Permission.bluetoothConnect].request();
      return results.values.every((status) => status.isGranted) ? null : NearbyRadioState.denied;
    }
    if (!(await Permission.locationWhenInUse.request()).isGranted) return NearbyRadioState.denied;
    if (await Permission.locationWhenInUse.serviceStatus != ServiceStatus.enabled) return NearbyRadioState.locationOff;
    return null;
  }

  // 刚创建的管理器先是 unknown，等系统报来（iOS 第一次会等用户点权限弹窗）。
  Future<BluetoothLowEnergyState> _settled(BluetoothLowEnergyManager manager) async {
    if (manager.state != BluetoothLowEnergyState.unknown) return manager.state;
    try {
      return (await manager.stateChanged.firstWhere((event) => event.state != BluetoothLowEnergyState.unknown).timeout(const Duration(seconds: 60))).state;
    } on TimeoutException {
      return manager.state;
    }
  }

  NearbyRadioState? _blocked(BluetoothLowEnergyState state) => switch (state) {
    BluetoothLowEnergyState.poweredOn => null,
    BluetoothLowEnergyState.poweredOff => NearbyRadioState.bluetoothOff,
    BluetoothLowEnergyState.unauthorized => NearbyRadioState.denied,
    BluetoothLowEnergyState.unsupported => NearbyRadioState.unsupported,
    BluetoothLowEnergyState.unknown => NearbyRadioState.failed,
  };

  // 蓝牙被关掉或打开时跟着停或接着开（页面开着时）。
  void _watchState(CentralManager central, PeripheralManager peripheral) {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.add(central.stateChanged.listen((event) {
      final blocked = _blocked(event.state);
      if (blocked != null && _state == NearbyRadioState.ready) {
        unawaited(_end().then((_) => _set(blocked)));
      } else if (blocked == null && _state != NearbyRadioState.ready && _state != NearbyRadioState.starting && _state != NearbyRadioState.off) {
        _state = NearbyRadioState.off;
        final presence = _presenceOf, onPayload = _onPayload;
        if (presence != null && onPayload != null) unawaited(start(presence: presence, onPayload: onPayload));
      }
    }));
  }

  Future<void> _begin(CentralManager central, PeripheralManager peripheral) async {
    _watchState(central, peripheral);
    _subscriptions
      ..add(central.discovered.listen(_onDiscovered))
      ..add(peripheral.characteristicReadRequested.listen(_onRead))
      ..add(peripheral.characteristicWriteRequested.listen(_onWrite));
    final service = GATTService(uuid: nearbyServiceUuid, isPrimary: true, includedServices: const [], characteristics: [
      GATTCharacteristic.mutable(uuid: _presenceUuid, properties: const [GATTCharacteristicProperty.read], permissions: const [GATTCharacteristicPermission.read], descriptors: const []),
      GATTCharacteristic.mutable(uuid: _inboxUuid, properties: const [GATTCharacteristicProperty.write], permissions: const [GATTCharacteristicPermission.write], descriptors: const []),
    ]);
    await peripheral.removeAllServices();
    await peripheral.addService(service);
    _service = service;
    await peripheral.startAdvertising(Advertisement(serviceUUIDs: [nearbyServiceUuid]));
    await central.startDiscovery(serviceUUIDs: [nearbyServiceUuid]);
    _sweep = Timer.periodic(const Duration(seconds: 3), (_) => _expire());
    campusLog('[Nearby] action=begin');
  }

  @override
  Future<void> stop() async {
    _generation++;
    _presenceOf = null;
    _onPayload = null;
    await _end();
    _set(NearbyRadioState.off);
  }

  Future<void> _end() async {
    _sweep?.cancel();
    _sweep = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final central = _central, peripheral = _peripheral;
    try {
      if (central != null && central.state == BluetoothLowEnergyState.poweredOn) await central.stopDiscovery();
      if (peripheral != null && peripheral.state == BluetoothLowEnergyState.poweredOn) {
        await peripheral.stopAdvertising();
        if (_service != null) await peripheral.removeAllServices();
      }
    } catch (error, stack) {
      campusLog('[Nearby] action=end errorType=${error.runtimeType}\n$stack');
    }
    _service = null;
    final hadPeers = _presence.isNotEmpty;
    _devices.clear();
    _seen.clear();
    _presence.clear();
    _reading.clear();
    _failedAt.clear();
    _assemblers.clear();
    if (hadPeers) _changes.add(null);
  }

  // ---------- 中心：发现与读出现标记 ----------

  void _onDiscovered(DiscoveredEventArgs event) {
    final id = event.peripheral.uuid.toString();
    _devices[id] = event.peripheral;
    _seen[id] = DateTime.now();
    final failed = _failedAt[id];
    if (_presence.containsKey(id) || _reading.contains(id) || (failed != null && DateTime.now().difference(failed) < _readRetry)) return;
    _reading.add(id);
    final generation = _generation;
    unawaited(_readPresence(id, event.peripheral, generation));
  }

  Future<void> _readPresence(String id, Peripheral device, int generation) => _centralLock.synchronized(() async {
    try {
      if (generation != _generation) return;
      final value = await _connected(device, (inbox, presence) async => await _central!.readCharacteristic(device, presence).timeout(_gattTimeout));
      if (generation != _generation || !_seen.containsKey(id)) return;
      _presence[id] = value;
      _failedAt.remove(id);
      _changes.add(null);
      campusLog('[Nearby] action=presence peer=${_tail(id)} bytes=${value.length}');
    } catch (error) {
      // 走开了、对方正忙或不是这一版：隔一会儿再试，不算错误。
      _failedAt[id] = DateTime.now();
      campusLog('[Nearby] action=presence_retry peer=${_tail(id)} reason=${error.runtimeType}');
    } finally {
      _reading.remove(id);
    }
  });

  // 连上、找到两个特征、做完就断开。
  Future<T> _connected<T>(Peripheral device, Future<T> Function(GATTCharacteristic inbox, GATTCharacteristic presence) work) async {
    final central = _central!;
    await central.connect(device).timeout(_connectTimeout);
    try {
      final services = await central.discoverGATT(device).timeout(_gattTimeout);
      final service = services.where((service) => service.uuid == nearbyServiceUuid).firstOrNull;
      final inbox = service?.characteristics.where((characteristic) => characteristic.uuid == _inboxUuid).firstOrNull;
      final presence = service?.characteristics.where((characteristic) => characteristic.uuid == _presenceUuid).firstOrNull;
      if (inbox == null || presence == null) throw const NearbyRadioException(rejected: false, message: '对方不是这一版');
      return await work(inbox, presence);
    } finally {
      try {
        await central.disconnect(device).timeout(_connectTimeout);
      } catch (error) {
        campusLog('[Nearby] action=disconnect reason=${error.runtimeType}');
      }
    }
  }

  void _expire() {
    final now = DateTime.now();
    final gone = [for (final entry in _seen.entries) if (now.difference(entry.value) > _peerExpiry) entry.key];
    if (gone.isEmpty) return;
    var changed = false;
    for (final id in gone) {
      _seen.remove(id);
      _devices.remove(id);
      _failedAt.remove(id);
      changed = _presence.remove(id) != null || changed;
    }
    if (changed) _changes.add(null);
  }

  @override
  void refresh() {
    _presence.clear();
    _failedAt.clear();
    _changes.add(null);
    for (final entry in _devices.entries.toList()) {
      if (_reading.contains(entry.key)) continue;
      _reading.add(entry.key);
      unawaited(_readPresence(entry.key, entry.value, _generation));
    }
  }

  // ---------- 中心：发送 ----------

  @override
  Future<void> send(String peerId, Uint8List payload) {
    if (payload.length > nearbyPayloadLimit) throw ArgumentError.value(payload.length, 'payload');
    final device = _devices[peerId];
    if (device == null || _state != NearbyRadioState.ready) throw const NearbyRadioException(rejected: false, message: '对方不在附近');
    return _centralLock.synchronized(() async {
      final central = _central!;
      try {
        await _connected(device, (inbox, _) async {
          // 不写超过一个包的长度：长写（分段准备再执行）在 iOS 外围与插件上都不可靠。安卓按这次协商到的 MTU（插件记的可能是上一次连接的），iOS 由系统协商。
          int? negotiated;
          if (Platform.isAndroid) {
            try {
              negotiated = await central.requestMTU(device, mtu: 517).timeout(_gattTimeout) - 3;
            } catch (error) {
              campusLog('[Nearby] action=mtu reason=${error.runtimeType}');
              negotiated = 20;
            }
          }
          final writable = negotiated ?? await central.getMaximumWriteLength(device, type: GATTCharacteristicWriteType.withoutResponse);
          final frames = nearbyFrames(payload, min(_frameMax, writable));
          for (var index = 0; index < frames.length; index++) {
            try {
              await central.writeCharacteristic(device, inbox, value: frames[index], type: GATTCharacteristicWriteType.withResponse).timeout(_frameTimeout);
            } catch (error) {
              if (index == frames.length - 1 && error is! TimeoutException) throw NearbyRadioException(rejected: true, message: '对方没有收下：${error.runtimeType}');
              rethrow;
            }
          }
          campusLog('[Nearby] action=send peer=${_tail(peerId)} bytes=${payload.length} frames=${frames.length}');
        });
      } on NearbyRadioException {
        rethrow;
      } catch (error, stack) {
        campusLog('[Nearby] action=send peer=${_tail(peerId)} errorType=${error.runtimeType}\n$stack');
        throw NearbyRadioException(rejected: false, message: '没送到：${error.runtimeType}');
      }
    });
  }

  // ---------- 外围：出现标记与收件 ----------

  Future<void> _onRead(GATTCharacteristicReadRequestedEventArgs event) async {
    final peripheral = _peripheral!;
    try {
      final presence = _presenceOf;
      if (event.characteristic.uuid != _presenceUuid || presence == null) {
        await peripheral.respondReadRequestWithError(event.request, error: GATTError.readNotPermitted);
        return;
      }
      final value = presence();
      final offset = event.request.offset;
      if (offset > value.length) {
        await peripheral.respondReadRequestWithError(event.request, error: GATTError.invalidOffset);
        return;
      }
      await peripheral.respondReadRequestWithValue(event.request, value: value.sublist(offset));
    } catch (error, stack) {
      campusLog('[Nearby] action=serve_presence errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<void> _onWrite(GATTCharacteristicWriteRequestedEventArgs event) async {
    final peripheral = _peripheral!;
    final central = event.central.uuid.toString();
    try {
      final onPayload = _onPayload;
      if (event.characteristic.uuid != _inboxUuid || onPayload == null) {
        await peripheral.respondWriteRequestWithError(event.request, error: GATTError.writeNotPermitted);
        return;
      }
      if (event.request.offset != 0) {
        _assemblers.remove(central);
        await peripheral.respondWriteRequestWithError(event.request, error: GATTError.invalidOffset);
        return;
      }
      final Uint8List? payload;
      try {
        payload = (_assemblers[central] ??= NearbyAssembler()).add(event.request.value);
      } on FormatException catch (error) {
        campusLog('[Nearby] action=receive reason=${error.message}');
        await peripheral.respondWriteRequestWithError(event.request, error: GATTError.invalidAttributeValueLength);
        return;
      }
      if (payload == null) {
        await peripheral.respondWriteRequest(event.request);
        return;
      }
      _assemblers.remove(central);
      final accepted = await onPayload(payload);
      if (accepted) {
        await peripheral.respondWriteRequest(event.request);
      } else {
        await peripheral.respondWriteRequestWithError(event.request, error: GATTError.unlikelyError);
      }
    } catch (error, stack) {
      campusLog('[Nearby] action=receive errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  Future<void> openSettings() => openAppSettings();
}
