import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';

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
// - cancel 完成即中断底层连接，抛 http.RequestAbortedException（与超时分得开）。
// - 响应体边读边数：声明的长度或读到的字节超过 limit 就停止读取、中断连接，抛 CampusHttpTooLarge。
// - 底层传输不理会中断信号时（测试替身等）也按时返回：结果与中断信号竞速，输了的那一路被丢弃。
// - 断网、TLS、http.ClientException、读响应体时的错误原样抛出（带原堆栈），由调用方映射。
// - 每个请求按 campusRequestLog 记一条（开发者模式才记，只记路径）：读完的记状态与字节数，
//   没读完的记 error=timeout、cancelled、too_large 或异常类型（收到响应头的照样带状态码）。
// 一份 CampusHttp 对应一个模块（请求记录里的 module），底层 http.Client 可注入（测试用 MockClient），close 时关掉。
class CampusHttp {
  CampusHttp(this.module, {http.Client? client}) : _client = client ?? http.Client();

  final String module;
  final http.Client _client;

  // headers 先写，再写请求体：body 按 http.Request.body 的规则写（UTF-8，Content-Type 缺 charset 时补上），bodyBytes 原样写、不动请求头；
  // multipart 是表单文件上传。logUri 是请求记录里写的地址（比如只写路由模板、不写一次性凭据），为空用 uri。
  // collect 让调用方自己累加响应体（读到 limit 以上要自己停）：只给教务成绩那条「性能观察项」用，保持它原来的读法（见 lib/edu/CLAUDE.md）。
  Future<http.Response> send(
    String method,
    Uri uri, {
    required Duration timeout,
    required int limit,
    Map<String, String> headers = const {},
    String? body,
    List<int>? bodyBytes,
    ({Map<String, String> fields, List<http.MultipartFile> files})? multipart,
    bool followRedirects = true,
    Future<void>? cancel,
    Uri? logUri,
    Future<List<int>> Function(Stream<List<int>> stream, int limit)? collect,
  }) async {
    final trigger = Completer<void>();
    final http.BaseRequest request;
    if (multipart != null) {
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
    String? aborted;
    void abort(String reason) {
      if (trigger.isCompleted) return;
      aborted = reason;
      trigger.complete();
    }

    final timer = Timer(timeout, () => abort(_timeout));
    if (cancel != null) unawaited(cancel.then((_) => abort(_cancelled), onError: (Object _) => abort(_cancelled)));
    final watch = Stopwatch()..start();
    int? status;
    try {
      final response = await Future.any([
        _exchange(request, limit, collect, (code) => status = code),
        trigger.future.then<http.Response>((_) => throw http.RequestAbortedException(uri)),
      ]);
      campusRequestLog(module, method, logUri ?? uri, status: response.statusCode, elapsed: watch.elapsed, bytes: response.bodyBytes.length);
      return response;
    } catch (error, stack) {
      final reason = aborted;
      campusRequestLog(module, method, logUri ?? uri, status: status, elapsed: watch.elapsed, error: reason ?? (error is CampusHttpTooLarge ? 'too_large' : '${error.runtimeType}'));
      // 在这里抛（不沿用计时器里的堆栈），堆栈才带得上调用方的那一串 await。
      if (reason == _timeout) throw TimeoutException('请求超时', timeout);
      if (reason == _cancelled) throw http.RequestAbortedException(uri);
      // 竞速断开了 await 链：原堆栈只到出错的地方，接上这里的调用方那一串，日志里才看得出是哪个模块的哪次请求。
      Error.throwWithStackTrace(error, StackTrace.fromString('$stack<asynchronous suspension>\n${StackTrace.current}'));
    } finally {
      timer.cancel();
      // 不论成败都发一次中断：没读完的连接立即关掉，读完的什么也不发生。
      if (!trigger.isCompleted) trigger.complete();
    }
  }

  Future<http.Response> _exchange(http.BaseRequest request, int limit, Future<List<int>> Function(Stream<List<int>>, int)? collect, void Function(int) onStatus) async {
    final response = await _client.send(request);
    onStatus(response.statusCode);
    if ((response.contentLength ?? 0) > limit) {
      await response.stream.listen(null).cancel();
      throw CampusHttpTooLarge(limit);
    }
    final bytes = await (collect ?? _collect)(response.stream, limit);
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

const _timeout = 'timeout';
const _cancelled = 'cancelled';
