import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/local/network_mode_memory.dart';

// 联网偏好（人工决策见 lib/domain/network_policy.dart 的 11-16 22:24:59 那条）：本机记录、偏好与策略；私信停下在 social_service_test.dart，
// 节日在 festival_test.dart，应用账号页在 app_account_test.dart，消息页在 social_ui_test.dart。
void main() {
  test('仅本机只关应用账号、私信经中转、挑战、解锁、节日抽奖与健康回报，其余照常；联网全开', () {
    for (final service in NetworkService.values) {
      expect(networkModeAllows(NetworkMode.online, service), isTrue, reason: '$service');
      expect(networkModeAllows(NetworkMode.local, service), !localModeDenied.contains(service), reason: '$service');
    }
    expect(localModeDenied, {NetworkService.appAccount, NetworkService.social, NetworkService.challenge, NetworkService.unlock, NetworkService.festival, NetworkService.appHealth});
    for (final kept in [NetworkService.edu, NetworkService.appUpdate, NetworkService.appFeedback, NetworkService.diagnostics, NetworkService.rollout, NetworkService.developerNotes]) {
      expect(networkModeAllows(NetworkMode.local, kept), isTrue, reason: '$kept 仅本机下照常');
    }
  });

  test('本机记录：没有文件、坏文件当联网；改了重开还在', () async {
    final directory = await Directory.systemTemp.createTemp('network_mode');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'network_mode.json'));
    expect((await FileNetworkModeMemory.open(file)).mode, NetworkMode.online);
    await file.writeAsString('{坏');
    expect((await FileNetworkModeMemory.open(file)).mode, NetworkMode.online);
    final memory = await FileNetworkModeMemory.open(file);
    await memory.saveMode(NetworkMode.local);
    expect((await FileNetworkModeMemory.open(file)).mode, NetworkMode.local);
  });

  // 人工决策见 lib/local/network_mode_memory.dart 的 11-17 14:17:05 那条。
  test('老用户迁移：还没有联网偏好时，旧的 leisure.json 写着关过就改为仅本机并写下来、删掉旧文件；开着、坏文件、已有偏好都不改', () async {
    final directory = await Directory.systemTemp.createTemp('network_mode_migrate');
    addTearDown(() => directory.delete(recursive: true));
    File fileOf(String name) => File(path.join(directory.path, name));
    final file = fileOf('network_mode.json'), legacy = fileOf('leisure.json');
    await legacy.writeAsString('{"enabled":false}');
    expect((await FileNetworkModeMemory.open(file, legacy: legacy)).mode, NetworkMode.local);
    expect(await legacy.exists(), isFalse);
    expect((await FileNetworkModeMemory.open(file)).mode, NetworkMode.local, reason: '迁移结果写进了 network_mode.json');

    await file.delete();
    await legacy.writeAsString('{"enabled":true}');
    expect((await FileNetworkModeMemory.open(file, legacy: legacy)).mode, NetworkMode.online);
    expect(await legacy.exists(), isFalse);
    await legacy.writeAsString('{坏');
    expect((await FileNetworkModeMemory.open(file, legacy: legacy)).mode, NetworkMode.online);

    final chosen = await FileNetworkModeMemory.open(file);
    await chosen.saveMode(NetworkMode.online);
    await legacy.writeAsString('{"enabled":false}');
    expect((await FileNetworkModeMemory.open(file, legacy: legacy)).mode, NetworkMode.online, reason: '已经有联网偏好就不再看旧开关');
  });

  test('偏好：变了才写、通知一次；本身就是联网策略', () async {
    final memory = FileNetworkModeMemory.memory();
    final network = NetworkPreference(memory: memory);
    var notified = 0;
    network.addListener(() => notified++);
    await network.setMode(NetworkMode.online);
    expect(notified, 0);
    await network.setMode(NetworkMode.local);
    expect((network.online, memory.mode, notified), (false, NetworkMode.local, 1));
    expect(network.allows(NetworkService.social), isFalse);
    expect(network.allows(NetworkService.appUpdate), isTrue);
    await network.setMode(NetworkMode.online);
    expect((network.online, notified), (true, 2));
  });
}
