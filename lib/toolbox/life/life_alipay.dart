import 'package:tobias/tobias.dart';

// 生活下面各子模块共用的支付宝付款端口：把服务方给的支付串交给支付宝，返回支付宝报的结果码（9000 成功、6001 取消…）。
// 结果码只作提示，付没付成只认服务方（服务方收支付宝的回调写库，客户端只查）。
abstract interface class LifeAlipay {
  Future<String> pay(String orderContent);
}

// 插件 tobias（支付宝 SDK 15.8，用户 11-22 为住理生活选的）。安卓没装支付宝时 SDK 自己开网页收银台；
// iOS 付完经 Info.plist 里 CFBundleURLName 为 alipay 的 scheme 回来，自签证书配不了通用链接、应用又是场景模式，SDK 的回调不一定回得来，
// 所以各子模块的结账不只等它：回到前台或点「我已付款」也去服务方查。
class TobiasLifeAlipay implements LifeAlipay {
  final _tobias = Tobias();

  @override
  Future<String> pay(String orderContent) async => '${(await _tobias.pay(orderContent))['resultStatus'] ?? ''}';
}
