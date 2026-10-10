import 'package:path/path.dart' as path;

import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_device_channel.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';
import 'package:superxd/toolbox/download/android_file_publisher.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// 学习通签到的服务：自己打开、关闭与清除库、安全存储、设备通道和中转客户端；框架（ToolboxRuntime）只提供
// 目录与公共能力，不认识这里的任何类型。打开函数登记在注册表（toolbox_catalog.dart），页面经 runtime.service 取用。
class ChaoxingService implements ToolboxService {
  ChaoxingService({required this.accounts, required this.hub, this.filePublisher = AndroidFilePublisher.new});
  final ChaoxingAccounts accounts;

  // 代签凭据包的中转，与私信共用同一个自建服务（地址由框架从构建参数给出）；为空时代签码不可用。
  final ChaoxingPackHub? hub;

  // 公共下载目录的文件导出（人脸照片保存到本机用），测试注入内存实现。
  final ToolboxFilePublisher Function() filePublisher;

  // 工具 id：路由、服务与同意记录共用（同意记录里存的就是它，不能改）。
  static const serviceId = 'chaoxing';

  static Future<ChaoxingService> open(ToolboxServiceContext context) async {
    final relayUrl = context.relayUrl;
    return ChaoxingService(
      accounts: ChaoxingAccounts(
        store: await ChaoxingStore.open(path.join(context.base.path, 'chaoxing.db')),
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

  // 清除数据：安全存储里本工具命名空间下的密码与 Cookie 全删（连库里已没有索引的残留一起），再关库删库文件。
  // 学习通云盘里的人脸照片、已导出到下载目录的文件不动。
  @override
  Future<void> clearData() async {
    await accounts.vault.deleteAll();
    hub?.close();
    await accounts.store.destroy();
  }
}
