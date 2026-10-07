import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_device_channel.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

// 学习通签到的服务：自己打开与关闭库、安全存储、设备通道和中转客户端；框架（ToolboxRuntime）只提供
// 目录与公共能力，不认识这里的任何类型。打开函数由组合根注入，页面经 runtime.service 取用。
class ChaoxingService implements ToolboxService {
  ChaoxingService({required this.accounts, required this.hub});
  final ChaoxingAccounts accounts;

  // 代签凭据包的中转，与私信共用同一个自建服务（地址由组合根从构建参数取）；为空时代签码不可用。
  final ChaoxingPackHub? hub;

  static const serviceId = 'chaoxing';

  static Future<ChaoxingService> open(Directory base, {Uri? relayUrl}) async {
    return ChaoxingService(
      accounts: ChaoxingAccounts(
        store: await ChaoxingStore.open(path.join(base.path, 'chaoxing.db')),
        vault: SecureChaoxingVault(),
        device: ChannelChaoxingDeviceProbe(),
      ),
      hub: relayUrl == null ? null : ChaoxingPackHub(baseUrl: relayUrl),
    );
  }

  @override
  Future<void> close() async {
    await accounts.store.close();
    hub?.close();
  }
}
