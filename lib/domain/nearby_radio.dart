import 'dart:typed_data';

// 面对面私信的传输端口（人工决策见 social/nearby_service.dart）：蓝牙低功耗，双方都开着面对面页时一边广播自己、一边扫描附近的手机。
// 传输只管把字节送到、不认人：附近每台手机的「出现标记」交给私信层认是不是好友，加密与验签也都在私信层。实现在 device/ble_nearby_radio.dart。

// off：没开；starting：正在要权限、起广播与扫描；ready：在广播与扫描；bluetoothOff：蓝牙关着；denied：没给权限（附近设备，安卓 11 是位置）；
// locationOff：安卓 11 的定位开关关着（系统规定这时扫不到蓝牙）；unsupported：这台手机没有蓝牙低功耗或不能广播；failed：起不来（看日志）。
enum NearbyRadioState { off, starting, ready, bluetoothOff, denied, locationOff, unsupported, failed }

// 附近一台开着面对面页的手机：id 是这一次看到它的连接标识（会变，不当身份用），presence 是读到的出现标记（私信层定格式）。
class NearbyPeer {
  const NearbyPeer(this.id, this.presence);
  final String id;
  final Uint8List presence;
}

// 发送失败：rejected 是对方收到了但没收下（不是好友、解不开等），其余是没送到（走开了、连不上、超时）。
class NearbyRadioException implements Exception {
  const NearbyRadioException({required this.rejected, required this.message});
  final bool rejected;
  final String message;
  @override
  String toString() => 'NearbyRadioException(rejected: $rejected, $message)';
}

abstract interface class NearbyRadio {
  NearbyRadioState get state;
  // 附近的手机，按第一次看到的先后；离开一会儿没再看到就拿掉。
  List<NearbyPeer> get peers;
  // 状态或附近的手机变了。
  Stream<void> get changes;
  // 开始：先要权限，再广播与扫描。presence 在被别的手机读时调用；onPayload 收到一整条时调用，返回是否收下（对方据此知道成败）。
  Future<void> start({required Uint8List Function() presence, required Future<bool> Function(Uint8List payload) onPayload});
  Future<void> stop();
  // 重新读一遍附近每台手机的出现标记（扫了好友二维码之后：对方可能是被看到之后才出示的）。
  void refresh();
  // 把一整条交给附近这台手机，对方收下才返回；失败抛 NearbyRadioException。
  Future<void> send(String peerId, Uint8List payload);
  // 权限被拒或蓝牙关着时去系统设置。
  Future<void> openSettings();
}
