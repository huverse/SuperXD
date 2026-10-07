import 'dart:async';

class ToolboxException implements Exception {
  const ToolboxException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ToolboxCancellation {
  final _cancelled = Completer<void>();
  Future<void> get signal => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const ToolboxException('操作已取消');
  }
}

class ToolboxResource {
  const ToolboxResource({
    required this.version,
    required this.url,
    required this.bytes,
    required this.sha256,
  });
  final String version;
  final Uri url;
  final int bytes;
  final String sha256;
}

enum ToolboxDownloadKind { video, resource, image, audio }

enum ToolboxDownloadState {
  queued,
  downloading,
  pausing,
  paused,
  cancelling,
  verifying,
  awaitingSave,
  saving,
  saved,
  installed,
  cancelled,
  failed,
}

class ToolboxDownload {
  const ToolboxDownload({
    required this.id,
    required this.toolId,
    required this.kind,
    required this.filename,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    this.url,
    this.title = '',
    this.progress = 0,
    this.totalBytes = -1,
    this.mimeType,
    this.savedUri,
    this.error,
    this.resourceVersion,
    this.resourceBytes,
    this.resourceHash,
    this.groupId,
    this.groupTotal = 1,
    this.resourceId,
    this.identity,
    this.sourceUrl,
    this.providerId,
    this.submitted = false,
  });
  final String id;
  final String toolId;
  final ToolboxDownloadKind kind;
  final String filename;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ToolboxDownloadState state;
  final Uri? url;
  final String title;
  final double progress;
  final int totalBytes;
  final String? mimeType;
  final Uri? savedUri;
  final String? error;
  final String? resourceVersion;
  final int? resourceBytes;
  final String? resourceHash;
  final String? groupId;
  final int groupTotal;
  final String? resourceId;
  final String? identity;
  final Uri? sourceUrl;
  final String? providerId;
  final bool submitted;
  String get jobId => groupId ?? id;
  bool get terminal => const {
    ToolboxDownloadState.saved,
    ToolboxDownloadState.installed,
    ToolboxDownloadState.cancelled,
    ToolboxDownloadState.failed,
  }.contains(state);
  bool get transferring =>
      state == ToolboxDownloadState.queued ||
      state == ToolboxDownloadState.downloading;
  // 待保存带错误＝导出失败或旧系统未选保存位置，需用户重试；无错误＝前台排队导出或等回前台自动导出，属正常等待。
  bool get saveFailed =>
      state == ToolboxDownloadState.awaitingSave && error != null;
  // 排队导出的项由逐项锁占着，取消要等导出结束才生效，所以与保存中一样不给取消。
  bool get canCancel =>
      transferring || state == ToolboxDownloadState.paused || saveFailed;

  ToolboxDownload change({
    ToolboxDownloadState? state,
    double? progress,
    int? totalBytes,
    String? mimeType,
    Uri? savedUri,
    String? error,
    bool clearUrl = false,
    bool? submitted,
  }) => ToolboxDownload(
    id: id,
    toolId: toolId,
    kind: kind,
    filename: filename,
    createdAt: createdAt,
    updatedAt: DateTime.now().toUtc(),
    state: state ?? this.state,
    url: clearUrl ? null : url,
    title: title,
    progress: progress ?? this.progress,
    totalBytes: totalBytes ?? this.totalBytes,
    mimeType: mimeType ?? this.mimeType,
    savedUri: savedUri ?? this.savedUri,
    error: error,
    resourceVersion: resourceVersion,
    resourceBytes: resourceBytes,
    resourceHash: resourceHash,
    groupId: groupId,
    groupTotal: groupTotal,
    resourceId: resourceId,
    identity: identity,
    sourceUrl: sourceUrl,
    providerId: providerId,
    submitted: submitted ?? this.submitted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'toolId': toolId,
    'kind': kind.name,
    'filename': filename,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'state': state.name,
    'url': url?.toString(),
    'title': title,
    'progress': progress,
    'totalBytes': totalBytes,
    'mimeType': mimeType,
    'savedUri': savedUri?.toString(),
    'error': error,
    'resourceVersion': resourceVersion,
    'resourceBytes': resourceBytes,
    'resourceHash': resourceHash,
    'groupId': groupId,
    'groupTotal': groupTotal,
    'resourceId': resourceId,
    'identity': identity,
    'sourceUrl': sourceUrl?.toString(),
    'providerId': providerId,
    'submitted': submitted,
  };

  factory ToolboxDownload.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final toolId = json['toolId'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        toolId is! String ||
        !RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(toolId) ||
        json['filename'] != '$id.part') {
      throw const FormatException('下载记录路径无效');
    }
    return ToolboxDownload(
      id: id,
      toolId: toolId,
      kind: ToolboxDownloadKind.values.byName(json['kind'] as String),
      filename: json['filename'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      state: ToolboxDownloadState.values.byName(json['state'] as String),
      url: json['url'] == null ? null : Uri.parse(json['url'] as String),
      title: json['title'] as String,
      progress: (json['progress'] as num).toDouble(),
      totalBytes: json['totalBytes'] as int,
      mimeType: json['mimeType'] as String?,
      savedUri: json['savedUri'] == null
          ? null
          : Uri.parse(json['savedUri'] as String),
      error: json['error'] as String?,
      resourceVersion: json['resourceVersion'] as String?,
      resourceBytes: json['resourceBytes'] as int?,
      resourceHash: json['resourceHash'] as String?,
      groupId: json['groupId'] as String?,
      groupTotal: json['groupTotal'] as int? ?? 1,
      resourceId: json['resourceId'] as String?,
      identity: json['identity'] as String?,
      sourceUrl: json['sourceUrl'] == null
          ? null
          : Uri.parse(json['sourceUrl'] as String),
      providerId: json['providerId'] as String?,
      submitted: json['submitted'] as bool? ?? true,
    );
  }
}

class ToolboxTransferUpdate {
  const ToolboxTransferUpdate(
    this.id,
    this.state, {
    this.progress = 0,
    this.totalBytes = -1,
    this.mimeType,
    this.error,
  });
  final String id;
  final ToolboxDownloadState state;
  final double progress;
  final int totalBytes;
  final String? mimeType;
  final String? error;
}

abstract interface class ToolboxTransfer {
  Stream<ToolboxTransferUpdate> get updates;
  Future<void> initialize();
  Future<void> enqueue(ToolboxDownload download);
  Future<void> cancel(String id);
  Future<bool> pause(String id);
  Future<bool> resume(String id);
  Future<ToolboxTransferUpdate?> lookup(String id);
  Future<void> forget(String id);
  Future<void> requestNotifications();
  Future<void> close();
}

abstract interface class ToolboxFilePublisher {
  Future<Uri?> publish({
    required String id,
    required String source,
    required String filename,
    required String mimeType,
  });
  Future<void> open(Uri uri, String mimeType);
}

// 工具自己的服务（学习通的账号闭环等）：框架不认识具体类型，只按这个接口在退出时统一关闭。
// 打开函数由组合根注入 ToolboxRuntime，工具页面首次使用时经 runtime.service 取用并缓存。
abstract interface class ToolboxService {
  Future<void> close();
}
