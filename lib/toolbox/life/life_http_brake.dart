// [人工决策-2026-11-28 20:03:28] 生活下面各子模块的请求策略统一（用户 11-28 看了住理与胖乖的对比后选「都照住理：不限并发」，
// 没选「同域名同时最多 4 个」与「都照胖乖：一次一个、开始之间隔 200 毫秒」）：
// - 不排队、不限并发、不固定间隔：页面要几个请求就一起发几个（同住理一直以来的做法）；整次超时与响应上限由各子模块的封装给（都是 15 秒、1MB），都不自动重试。
// - 刹车（本类）：回 403、405、429（防火墙拦截、限流）就停这个域名 blockedFor，这期间这个域名的请求在本机直接拒掉、不发出去，拦截页不读。
//   校园网出口是共用 IP，撞了防火墙连同学的官方 App 一起受影响；住理原来没有这一道，胖乖原来自己有一份，现在两边都用这一份。
// [人工决策-2026-11-28 20:14:33] 刹车停多久改成 30 秒（用户看完统一后的策略说「改为30s」，原来是 15 分钟）：撞上一次只歇半分钟，提示写还要等几秒。
// 子模块同层互不依赖，共用的放在生活根目录。
// 连接空闲保持 lifeKeepIdle（11-28 夜胖乖再提速；诊断包 NNK5V9VD 里第一单去掉定位比第二单慢约 0.17 秒，和重新握手相符、但不能据此断定）：打开设备页、挑档位、再点下单，
// 中间常超过 dart:io 默认的 15 秒，点下单时第一个请求就要重新建 TCP 与 TLS。留到 50 秒：常见网关保持 60 到 75 秒，略短于它，免得用上对方正要关的连接。
const lifeKeepIdle = Duration(seconds: 50);

class LifeHttpBrake {
  static const blockedFor = Duration(seconds: 30);
  static const statuses = {403, 405, 429};

  final _blockedUntil = <String, DateTime>{};

  // 这个域名还停着时回解禁的时刻，没停为空。
  DateTime? blockedUntil(String host) {
    final until = _blockedUntil[host];
    return until != null && DateTime.now().isBefore(until) ? until : null;
  }

  // 收到回复后看状态码：是拦截就把这个域名停 blockedFor，回解禁的时刻；不是为空。
  DateTime? observe(String host, int status) => statuses.contains(status) ? _blockedUntil[host] = DateTime.now().add(blockedFor) : null;

  // 离解禁还有几秒（向上取整、至少 1），给提示写「N 秒后再试」。
  static int secondsLeft(DateTime until) => (until.difference(DateTime.now()).inMilliseconds / 1000).ceil().clamp(1, blockedFor.inSeconds);
}
