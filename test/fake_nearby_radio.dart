import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/domain/nearby_radio.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/nearby_service.dart';
import 'package:superxd/social/social_store.dart';

// 面对面私信的内存假蓝牙：同一个 hub 里开着的几台「手机」互相看得到（出现标记每次现读），发送直接交给对方的 onPayload，对方不收下算 rejected。
class FakeNearbyHub {
  final radios = <FakeNearbyRadio>[];
  FakeNearbyRadio radio(String id) {
    final radio = FakeNearbyRadio._(this, id);
    radios.add(radio);
    return radio;
  }

  void _changed() {
    for (final radio in radios) {
      radio._changes.add(null);
    }
  }
}

class FakeNearbyRadio implements NearbyRadio {
  FakeNearbyRadio._(this.hub, this.id);
  final FakeNearbyHub hub;
  final String id;
  final _changes = StreamController<void>.broadcast(sync: true);
  Uint8List Function()? _presence;
  Future<bool> Function(Uint8List payload)? _onPayload;
  // 开起来时报的状态（测试改成没权限、蓝牙关着等）。
  NearbyRadioState startAs = NearbyRadioState.ready;
  NearbyRadioState _state = NearbyRadioState.off;
  var starts = 0;
  var refreshes = 0;
  final sent = <Uint8List>[];

  @override
  NearbyRadioState get state => _state;

  @override
  List<NearbyPeer> get peers => [
    for (final other in hub.radios)
      if (other != this && other._state == NearbyRadioState.ready && other._presence != null) NearbyPeer(other.id, other._presence!()),
  ];

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> start({required Uint8List Function() presence, required Future<bool> Function(Uint8List payload) onPayload}) async {
    _presence = presence;
    _onPayload = onPayload;
    if (_state == startAs) return;
    starts++;
    _state = startAs;
    hub._changed();
  }

  @override
  Future<void> stop() async {
    if (_state == NearbyRadioState.off) return;
    _state = NearbyRadioState.off;
    _presence = null;
    _onPayload = null;
    hub._changed();
  }

  @override
  void refresh() {
    refreshes++;
    hub._changed();
  }

  @override
  Future<void> send(String peerId, Uint8List payload) async {
    final target = hub.radios.where((radio) => radio.id == peerId && radio._state == NearbyRadioState.ready).firstOrNull;
    if (target == null) throw const NearbyRadioException(rejected: false, message: '走开了');
    sent.add(payload);
    if (!await target._onPayload!(payload)) throw const NearbyRadioException(rejected: true, message: '没收下');
  }

  // 出示方开始或停止出示二维码后出现标记变了：通知附近的手机重读。
  void touch() => hub._changed();

  @override
  Future<void> openSettings() async {}
}

// 一台测试手机的面对面私信：自己的库、身份与假蓝牙。
class NearbyPhone {
  NearbyPhone(this.hub, this.name, this.directory) : radio = hub.radio(name);
  final FakeNearbyHub hub;
  final String name;
  final Directory directory;
  final FakeNearbyRadio radio;
  final vault = MemoryIdentityVault();
  late final NearbyService service = NearbyService(
    radio: radio,
    vault: vault,
    openStore: () => SocialStore.open(path.join(directory.path, '$name.db')),
    watchLifecycle: false,
  );

  // 打开面对面页：读本机、第一次设昵称、开蓝牙。
  Future<NearbyService> ready([String? nickname]) async {
    await service.open();
    if (service.status == NearbyStatus.setup) await service.enable(nickname ?? name);
    service.acquire();
    await pumpEventQueue();
    return service;
  }
}

Future<void> befriend(NearbyPhone presenter, NearbyPhone scanner) async {
  final code = await presenter.service.createInvite();
  presenter.radio.touch();
  await scanner.service.redeem(InviteCode.decode(code.encode(), prefix: nearbyInvitePrefix)!);
  await presenter.service.revokeInvite(code.inviteId);
  await pumpEventQueue();
}
