import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';

// 快递（拼多多身份码与快递查询）的服务：只持有登录会话的安全存储与建客户端的工厂，
// 没有自己的业务库——身份码不落盘，待取件与手机号即查即用。框架（ToolboxRuntime）只给目录与公共能力。
class ExpressService implements ToolboxService {
  ExpressService({required this.vault, ExpressClient Function(PddSession session)? clientFactory})
    : clientFactory = clientFactory ?? ((session) => ExpressClient(session: session));
  final ExpressVault vault;

  // 建客户端的工厂：测试注入走假 HTTP 的客户端。
  final ExpressClient Function(PddSession session) clientFactory;

  // 工具 id：路由、服务与同意记录共用（同意记录里存的就是它，不能改）。
  static const serviceId = 'express';

  static Future<ExpressService> open(ToolboxServiceContext context) async => ExpressService(vault: SecureExpressVault());

  @override
  Future<void> close() async {}

  // 清除数据：安全存储里本工具命名空间下的登录会话全删；拼多多账号本身与其服务器上的数据不动。
  @override
  Future<void> clearData() async => vault.deleteAll();
}
