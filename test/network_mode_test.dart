import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/local/network_mode_memory.dart';

// 联网偏好（人工决策见 lib/domain/network_policy.dart 的 11-16 22:24:59 那条）：本机记录、偏好与策略；私信停下在 social_service_test.dart，
// 节日在 festival_test.dart，应用账号页在 app_account_test.dart，消息页在 social_ui_test.dart。
void main() {
  test('本地化只关应用账号、私信经中转、挑战、解锁、节日抽奖与健康回报，其余照常；联网化全开', () {
    for (final service in NetworkService.values) {
      expect(networkModeAllows(NetworkMode.online, service), isTrue, reason: '$service');
      expect(networkModeAllows(NetworkMode.local, service), !localModeDenied.contains(service), reason: '$service');
    }
    expect(localModeDenied, {NetworkService.appAccount, NetworkService.social, NetworkService.challenge, NetworkService.unlock, NetworkService.festival, NetworkService.appHealth});
    for (final kept in [NetworkService.edu, NetworkService.appUpdate, NetworkService.appFeedback, NetworkService.diagnostics, NetworkService.rollout, NetworkService.developerNotes]) {
      expect(networkModeAllows(NetworkMode.local, kept), isTrue, reason: '$kept 本地化下照常');
    }
  });

  test('本机记录：没有文件、坏文件当联网化；改了重开还在', () async {
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
