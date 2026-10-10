import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/short_video_service.dart';
import 'package:superxd/toolbox/short_video/short_video_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

class ShortVideoController extends ChangeNotifier {
  ShortVideoController(this.service);
  final ShortVideoService service;
  ParseCoordinator get coordinator => service.coordinator;
  ShortVideoStore get store => service.store;
  ParseOutcome? outcome;
  String? error;
  String? attempting;
  bool busy = false;
  String selected = ParseCoordinator.automatic;
  Set<String> enabled = {};
  bool historyEnabled = true;
  ToolboxCancellation? _request;
  bool _disposed = false;

  Future<void> initialize() async {
    selected =
        await store.preference('parse_source') ?? ParseCoordinator.automatic;
    if (selected != ParseCoordinator.automatic &&
        !coordinator.providers.containsKey(selected)) {
      selected = ParseCoordinator.automatic;
    }
    final raw = await store.preference('enabled_sources');
    enabled = raw == null
        ? coordinator.providers.keys.toSet()
        : (jsonDecode(raw) as List)
              .whereType<String>()
              .where(coordinator.providers.containsKey)
              .toSet();
    historyEnabled = await store.preference('history_enabled') != 'false';
    if (!_disposed) notifyListeners();
  }

  Future<void> select(String value) async {
    invalidate();
    selected = value;
    await store.setPreference('parse_source', value);
    if (!_disposed) notifyListeners();
  }

  Future<void> enable(String id, bool value) async {
    invalidate();
    if (value) {
      enabled.add(id);
    } else {
      enabled.remove(id);
    }
    await store.setPreference('enabled_sources', jsonEncode(enabled.toList()));
    if (!_disposed) notifyListeners();
  }

  Future<void> setHistory(bool value) async {
    await store.setPreference('history_enabled', value.toString());
    historyEnabled = value;
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _request?.cancel();
    busy = false;
    outcome = null;
    error = null;
    attempting = null;
    if (!_disposed) notifyListeners();
  }

  // source只作用于本次解析（历史或下载任务按原来源重开），不改写用户保存的来源选择。
  Future<void> parse(
    String input, {
    bool refresh = false,
    String? source,
  }) async {
    invalidate();
    final request = ToolboxCancellation();
    _request = request;
    busy = true;
    notifyListeners();
    final selected = source ?? this.selected;
    try {
      final uri = shortVideoInput(input);
      final consented = <String>{};
      for (final provider in coordinator.candidates(selected, enabled)) {
        if (await service.consents.consent(
          provider.source.id,
          provider.source.consentVersion,
        )) {
          consented.add(provider.source.id);
        }
      }
      final value = await coordinator.parse(
        uri,
        selected: selected,
        enabled: enabled,
        consented: consented,
        cancellation: request,
        refresh: refresh,
        onAttempt: (id) {
          if (!_disposed && request == _request && !request.isCancelled) {
            attempting = id;
            notifyListeners();
          }
        },
      );
      if (_disposed || request.isCancelled || request != _request) return;
      outcome = value;
      if (historyEnabled) {
        try {
          await store.addHistory(
            id: sha256
                .convert(utf8.encode('$uri\u0000${value.result.providerId}'))
                .toString(),
            sourceUrl: uri,
            providerId: value.result.providerId,
            title: value.result.title,
            kind: value.result.kind,
          );
        } catch (failure, stack) {
          campusLog(
            '[ShortVideo] action=history errorType=${failure.runtimeType}\n$stack',
          );
        }
      }
    } catch (failure, stack) {
      campusLog(
        '[ShortVideo] action=parse errorType=${failure.runtimeType}\n$stack',
      );
      if (_disposed || request.isCancelled || request != _request) return;
      error = failure is ParseFailure
          ? failure.message
          : failure is ToolboxException
          ? failure.message
          : '解析未完成，请检查网络后重试';
    } finally {
      if (!_disposed && request == _request && !request.isCancelled) {
        busy = false;
        attempting = null;
        notifyListeners();
      }
    }
  }

  void cancel() {
    _request?.cancel();
    busy = false;
    attempting = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request?.cancel();
    super.dispose();
  }
}
