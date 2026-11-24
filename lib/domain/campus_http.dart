import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:superxd/domain/campus_log.dart';

// CampusHttp.traced 的请求超时（timeout 或 idleTimeout 到点）；别的内核照旧抛 TimeoutException（各模块日志里的 errorType 不变）。
// stage 写卡在哪一步：body 是响应头到了、正文没读完；没收到响应头时分 reused（这个主机没开新连接，请求发在连接池里的旧连接上）、
// connect（为它开的新连接还没连上，含域名解析与 TLS）与 response（新连接连上了、对方没回）。同一主机同时有几个请求时按主机计数，只是大致的判断。
class CampusHttpTimeout extends TimeoutException {
  CampusHttpTimeout(Duration timeout, this.stage) : super('请求超时', timeout);
  final String stage;
}

// 按主机记开过几条新连接、结束（连上或失败）了几条；主机最多记 64 个，多了丢最早的（电影院的接口主机只有十几个）。
class _ConnectTrace {
  final _counts = <String, ({int started, int finished})>{};

  ({int started, int finished}) of(String host) => _counts[host] ?? (started: 0, finished: 0);

  void start(String host) => _put(host, (started: of(host).started + 1, finished: of(host).finished));

  void finish(String host) => _put(host, (started: of(host).started, finished: of(host).finished + 1));

  void _put(String host, ({int started, int finished}) value) {
    _counts.remove(host);
    _counts[host] = value;
    if (_counts.length > 64) _counts.remove(_counts.keys.first);
  }
}

// 响应体读到上限还没读完（或声明的长度就超了）：已停止读取并中断连接，不把它整个读进内存。
class CampusHttpTooLarge implements Exception {
  const CampusHttpTooLarge(this.limit);
  final int limit;
  @override
  String toString() => 'CampusHttpTooLarge($limit)';
}

// [人工决策-2026-11-10 13:08:45] 对外请求共用这一个有界内核（用户确认 W7 工作包方向）：超时、响应上限、取消与请求记录只在这里实现一遍，
// 各模块的封装（教务、私信中转、视频解析、学习通、代签中转、快递）只管自己的请求头、会话、错误码映射与日志文案。没选「各封装各自补齐」：
// 原来约十套手写封装超时、上限、请求记录各写一遍且不一致（私信与教务页面没有响应上限，有的超时后不中断连接），同一能力全项目只认一个实现。
// 只管机制，不认识任何模块的接口：
// - timeout 管整个请求（连接、发送、读完响应体）：到点中断底层连接，抛 TimeoutException。
// - idleTimeout（可选）管「多久没有进展」：请求体每发出一块、收到响应头、响应体每到一块都重新计时，到点同样中断并抛 TimeoutException；
//   给大文件上传这类整次耗时说不准的请求用，整次仍受 timeout 封顶。
// - cancel 完成即中断底层连接，抛 http.RequestAbortedException（与超时分得开）。
// - 响应体边读边数：声明的长度或读到的字节超过 limit 就停止读取、中断连接，抛 CampusHttpTooLarge。
// - 底层传输不理会中断信号时（测试替身等）也按时返回：结果与中断信号竞速，输了的那一路被丢弃。
// - 断网、TLS、http.ClientException、读响应体时的错误原样抛出（带原堆栈），由调用方映射。
// - 每个请求按 campusRequestLog 记一条（开发者模式才记，只记路径）：读完的记状态与字节数，
//   没读完的记 error=timeout、cancelled、too_large 或异常类型（收到响应头的照样带状态码）。
// 一份 CampusHttp 对应一个模块（请求记录里的 module），底层 http.Client 可注入（测试用 MockClient），close 时关掉。
// publicOnly 只连公网地址：替第三方给的地址发请求时用（电影院的本机代理取清单与密钥），连上之后、发出请求之前核对对方的真实地址，
// 是本机、内网、链路本地这类（campusPublicPeer 为假，代理软件的 fake-ip 段放行）就断开并抛 CampusHttpPrivateAddress；按连上的地址认，域名解析成 127.0.0.1 也挡得住。
// traced 另按主机记新连接（11-24 电影院取证，用户选「先取证」）：超时时写清卡在哪一步（见 CampusHttpTimeout），
// 分得出是复用了连接池里已经断掉的旧连接、新连接没建起来（含域名解析与 TLS），还是连上了对方不回。
class CampusHttp {
  CampusHttp(this.module, {http.Client? client}) : _client = client ?? http.Client(), _trace = null;
  CampusHttp.publicOnly(this.module) : _client = IOClient(HttpClient()..connectionFactory = ((url, proxyHost, proxyPort) => _connect(url, proxyHost, proxyPort, publicOnly: true))), _trace = null;
  CampusHttp._traced(this.module, _ConnectTrace trace) : _client = IOClient(HttpClient()..connectionFactory = ((url, proxyHost, proxyPort) => _connect(url, proxyHost, proxyPort, trace: trace))), _trace = trace;
  factory CampusHttp.traced(String module) => CampusHttp._traced(module, _ConnectTrace());

  static Future<ConnectionTask<Socket>> _connect(Uri url, String? proxyHost, int? proxyPort, {bool publicOnly = false, _ConnectTrace? trace}) async {
    final host = proxyHost ?? url.host, port = proxyPort ?? (url.hasPort ? url.port : (url.isScheme('https') ? 443 : 80));
    trace?.start(url.host);
    final ConnectionTask<Socket> task;
    try {
      task = url.isScheme('https') && proxyHost == null ? await SecureSocket.startConnect(host, port) : await Socket.startConnect(host, port);
    } catch (_) {
      trace?.finish(url.host);
      rethrow;
    }
    return ConnectionTask.fromSocket(
      task.socket.then((socket) {
        trace?.finish(url.host);
        if (!publicOnly || campusPublicPeer(socket.remoteAddress)) return socket;
        socket.destroy();
        throw CampusHttpPrivateAddress(url.host);
      }, onError: (Object error, StackTrace stack) {
        trace?.finish(url.host);
        Error.throwWithStackTrace(error, stack);
      }),
      task.cancel,
    );
  }

  final String module;
  final http.Client _client;
  final _ConnectTrace? _trace;

  // 超时时卡在哪一步（见 CampusHttpTimeout）：before 是请求开始时这个主机的连接计数，status 是收到的响应状态码（没收到为空）。
  String _stage(_ConnectTrace trace, String host, ({int started, int finished}) before, int? status) {
    if (status != null) return 'body';
    final now = trace.of(host);
    if (now.started == before.started) return 'reused';
    return now.finished < now.started ? 'connect' : 'response';
  }

  // headers 先写，再写请求体：body 按 http.Request.body 的规则写（UTF-8，Content-Type 缺 charset 时补上），bodyBytes 原样写、不动请求头；
  // multipart 是表单文件上传；bodyStream 是边读边发的请求体（如文件流），声明 length、不分块，不整个读进内存。
  // logUri 是请求记录里写的地址（比如只写路由模板、不写一次性凭据），为空用 uri。
  // collect 让调用方自己累加响应体（读到 limit 以上要自己停）：教务成绩那条「性能观察项」用它保持原来的读法（见 lib/edu/CLAUDE.md），字体包下载用它边收边报进度。
  Future<http.Response> send(
    String method,
    Uri uri, {
    required Duration timeout,
    required int limit,
    Map<String, String> headers = const {},
    String? body,
    List<int>? bodyBytes,
    ({Map<String, String> fields, List<http.MultipartFile> files})? multipart,
    ({Stream<List<int>> stream, int length})? bodyStream,
    Duration? idleTimeout,
    bool followRedirects = true,
    Future<void>? cancel,
    Uri? logUri,
    Future<List<int>> Function(Stream<List<int>> stream, int limit)? collect,
  }) async {
    final trigger = Completer<void>();
    String? aborted;
    void abort(String reason) {
      if (trigger.isCompleted) return;
      aborted = reason;
      trigger.complete();
    }

    Timer? idle;
    void active() {
      if (idleTimeout == null) return;
      idle?.cancel();
      idle = Timer(idleTimeout, () => abort(_timeout));
    }

    final http.BaseRequest request;
    if (bodyStream != null) {
      request = _AbortableStreamRequest(method, uri, bodyStream.stream.map((chunk) {
        active();
        return chunk;
      }), bodyStream.length, trigger.future)..headers.addAll(headers);
    } else if (multipart != null) {
      request = http.AbortableMultipartRequest(method, uri, abortTrigger: trigger.future)
        ..headers.addAll(headers)
        ..fields.addAll(multipart.fields)
        ..files.addAll(multipart.files);
    } else {
      final plain = http.AbortableRequest(method, uri, abortTrigger: trigger.future)..headers.addAll(headers);
      if (body != null) plain.body = body;
      if (bodyBytes != null) plain.bodyBytes = bodyBytes;
      request = plain;
    }
    request.followRedirects = followRedirects;
    final timer = Timer(timeout, () => abort(_timeout));
    active();
    if (cancel != null) unawaited(cancel.then((_) => abort(_cancelled), onError: (Object _) => abort(_cancelled)));
    final watch = Stopwatch()..start();
    final before = _trace?.of(uri.host);
    int? status;
    try {
      final response = await Future.any([
        _exchange(request, limit, collect, (code) {
          status = code;
          active();
        }, active),
        trigger.future.then<http.Response>((_) => throw http.RequestAbortedException(uri)),
      ]);
      campusRequestLog(module, method, logUri ?? uri, status: response.statusCode, elapsed: watch.elapsed, bytes: response.bodyBytes.length);
      return response;
    } catch (error, stack) {
      final reason = aborted;
      campusRequestLog(module, method, logUri ?? uri, status: status, elapsed: watch.elapsed, error: reason ?? (error is CampusHttpTooLarge ? 'too_large' : '${error.runtimeType}'));
      // 在这里抛（不沿用计时器里的堆栈），堆栈才带得上调用方的那一串 await。
      if (reason == _timeout) {
        final trace = _trace;
        throw trace == null || before == null ? TimeoutException('请求超时', timeout) : CampusHttpTimeout(timeout, _stage(trace, uri.host, before, status));
      }
      if (reason == _cancelled) throw http.RequestAbortedException(uri);
      // 竞速断开了 await 链：原堆栈只到出错的地方，接上这里的调用方那一串，日志里才看得出是哪个模块的哪次请求。
      Error.throwWithStackTrace(error, StackTrace.fromString('$stack<asynchronous suspension>\n${StackTrace.current}'));
    } finally {
      timer.cancel();
      idle?.cancel();
      // 不论成败都发一次中断：没读完的连接立即关掉，读完的什么也不发生。
      if (!trigger.isCompleted) trigger.complete();
    }
  }

  Future<http.Response> _exchange(
    http.BaseRequest request,
    int limit,
    Future<List<int>> Function(Stream<List<int>>, int)? collect,
    void Function(int) onStatus,
    void Function() onChunk,
  ) async {
    final response = await _client.send(request);
    onStatus(response.statusCode);
    if ((response.contentLength ?? 0) > limit) {
      await response.stream.listen(null).cancel();
      throw CampusHttpTooLarge(limit);
    }
    final bytes = await (collect ?? _collect)(response.stream.map((chunk) {
      onChunk();
      return chunk;
    }), limit);
    return http.Response.bytes(
      bytes,
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  static Future<List<int>> _collect(Stream<List<int>> stream, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length > limit) throw CampusHttpTooLarge(limit);
    }
    return builder.takeBytes();
  }

  void close() => _client.close();
}

// 边读边发的请求体：声明长度、不分块，可中断（IOClient 收到 abortTrigger 即断开）。
final class _AbortableStreamRequest extends http.BaseRequest with http.Abortable {
  _AbortableStreamRequest(super.method, super.url, this._body, int length, this.abortTrigger) {
    contentLength = length;
  }
  final Stream<List<int>> _body;
  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

const _timeout = 'timeout';
const _cancelled = 'cancelled';

// 只连公网的 CampusHttp 连到了本机或内网地址（见 CampusHttp.publicOnly），没发出请求。
class CampusHttpPrivateAddress implements Exception {
  const CampusHttpPrivateAddress(this.host);
  final String host;
  @override
  String toString() => 'CampusHttpPrivateAddress($host)';
}

// 公网地址：IPv4 去掉本机、内网、链路本地、运营商级 NAT、基准测试段、组播与保留段；IPv6 认全球单播，映射 IPv4（::ffff:a.b.c.d）与
// NAT64 合成的（64:ff9b::a.b.c.d，只有 IPv6 的移动网络连 IPv4 站点时连上的就是它）按里面的 IPv4 认，其余（链路本地、组播、未指定）都不算。
bool campusPublicAddress(InternetAddress address) => _publicBytes(address.rawAddress);

// 连接时认的对方地址（CampusHttp.publicOnly）：公网，或代理软件的 fake-ip 段。Clash、sing-box、Surge 的 TUN 模式默认把所有域名解析到
// 198.18.0.0/15（IPv6 到 fc00::/8 里的一段），连上的是手机上的代理、再由它连出去；不放行的话开着这类代理的手机什么都取不到
// （11-22 本机实测：开着 fake-ip 时 www.baidu.com 解析成 198.18.0.5）。这时真正连到哪由代理决定、这里核对不到，是已知边界；
// 网址里直接写这两段的地址照旧不认（campusPublicAddress）。fc00::/8 从没分配使用过（真实的本地 IPv6 用 fd00::/8），放行不碰内网。
bool campusPublicPeer(InternetAddress address) {
  final bytes = address.rawAddress;
  final fake = bytes.length == 4 ? bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19) : bytes.length == 16 && bytes[0] == 0xfc;
  return fake || _publicBytes(bytes);
}

bool _publicBytes(List<int> bytes) {
  if (bytes.length == 4) {
    return !(bytes[0] == 0 ||
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        bytes[0] >= 224 ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
        (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)));
  }
  if (bytes.length != 16) return false;
  final head = bytes.sublist(0, 12).join(',');
  if (head == '0,0,0,0,0,0,0,0,0,0,255,255' || head == '0,100,255,155,0,0,0,0,0,0,0,0') return _publicBytes(bytes.sublist(12));
  return bytes[0] & 0xe0 == 0x20;
}
