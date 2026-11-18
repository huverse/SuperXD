import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/network_policy.dart';
import 'package:superxd/relay/relay_client.dart';

// 出口策略（审查 P2-2）：给一项联网服务用的签名传输套一层，发请求前问联网策略，这项服务现在不许联网就在本机拒掉、不发出。
// 联网策略的执行点以前只在上层（组合根的钩子按 NetworkService 拦一层，节日、灰度点名、解锁、诊断包认领里又各自读 online），新功能容易只做一边；
// 上层的判断照旧留着（不起无用的请求、省电省流量），合规由这里兜底：漏判了也出不去。拒掉的当连不上（NETWORK），各客户端照连不上处理，
// 记一行 errorType=policy（照理不该走到这里，出现了说明上层漏了判断）。传输本身不认识具体功能，属于哪项服务由组合根接线时给。
class EgressRelayTransport implements RelayTransport {
  EgressRelayTransport(this.inner, {required this.service, required this.allows});
  final RelayTransport inner;
  final NetworkService service;
  final bool Function(NetworkService service) allows;

  @override
  Future<RelayResponse> send(String method, String pathWithQuery, Map<String, String> headers, List<int>? body, {Duration? timeout, int? limit, bool background = false}) async {
    if (!allows(service)) {
      campusLog('[RelayEgress] action=deny service=${service.name} route=$method ${pathWithQuery.split('?').first} errorType=policy');
      throw const RelayException(RelayCode.network);
    }
    return inner.send(method, pathWithQuery, headers, body, timeout: timeout, limit: limit, background: background);
  }
}
