import 'dart:async';

import 'package:quiver/collection.dart';

import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/short_video/parse_source.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/domain/campus_log.dart';

class ParseCoordinator {
  ParseCoordinator(
    List<ParseProvider> providers, {
    this.budget = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : providers = Map.unmodifiable({
         for (final provider in providers) provider.source.id: provider,
       }),
       _clock = clock ?? DateTime.now;
  final Map<String, ParseProvider> providers;
  final Duration budget;
  final DateTime Function() _clock;
  final statuses = <String, SourceStatus>{};
  final _nextStart = <String, DateTime>{};
  final _busy = <String>{};
  final _cache = LruMap<String, ({DateTime expires, ParseResult value})>(
    maximumSize: 20,
  );
  static const automatic = 'auto';

  // [人工决策-2026-09-27 21:47:55] 自动仅尝试用户已启用且已同意的来源；线上当前只有BugPK，不并发广播链接或伪造多源。
  List<ParseProvider> candidates(String selected, Set<String> enabled) =>
      selected == automatic
      ? providers.values
            .where((provider) => enabled.contains(provider.source.id))
            .take(3)
            .toList()
      : [?providers[selected]];

  Future<ParseOutcome> parse(
    Uri uri, {
    required String selected,
    required Set<String> enabled,
    required Set<String> consented,
    required ToolboxCancellation cancellation,
    bool refresh = false,
    void Function(String)? onAttempt,
  }) async {
    final candidates = this.candidates(selected, enabled);
    if (candidates.isEmpty) {
      throw const ParseFailure(ParseFailureCode.unavailable, '请先启用一个解析来源');
    }
    if (candidates.any((provider) => !consented.contains(provider.source.id))) {
      throw const ParseFailure(
        ParseFailureCode.consentRequired,
        '请先同意所选来源处理作品链接',
      );
    }
    final watch = Stopwatch()..start();
    final attempts = <ParseAttempt>[];
    ParseFailure? lastFailure;
    for (final provider in candidates) {
      if (cancellation.isCancelled) {
        throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
      }
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw const ParseFailure(ParseFailureCode.timeout, '本次解析已超时');
      }
      final source = provider.source;
      if (!provider.supports(uri)) {
        lastFailure = const ParseFailure(
          ParseFailureCode.unsupported,
          '所选来源暂不支持此链接',
        );
        continue;
      }
      final key = '${source.id}\u0000${source.version}\u0000$uri';
      if (refresh) _cache.remove(key);
      final cached = _cache[key];
      if (cached != null && cached.expires.isAfter(_clock())) {
        return ParseOutcome(cached.value, attempts: attempts, fromCache: true);
      }
      _cache.remove(key);
      if (_busy.contains(source.id) ||
          (_nextStart[source.id]?.isAfter(_clock()) ?? false)) {
        lastFailure = const ParseFailure(
          ParseFailureCode.rateLimited,
          '请求频繁，请稍后再试',
        );
        attempts.add(
          ParseAttempt(
            providerId: source.id,
            elapsed: Duration.zero,
            failure: lastFailure.code,
          ),
        );
        continue;
      }
      _busy.add(source.id);
      _nextStart[source.id] = _clock().add(source.interval);
      onAttempt?.call(source.id);
      final current = ToolboxCancellation();
      final attemptBudget = remaining < const Duration(seconds: 25)
          ? remaining
          : const Duration(seconds: 25);
      final attemptWatch = Stopwatch()..start();
      try {
        final result =
            await Future.any([
              provider.resolve(uri, current),
              cancellation.signal.then<ParseResult>((_) {
                current.cancel();
                throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
              }),
            ]).timeout(
              attemptBudget,
              onTimeout: () {
                current.cancel();
                throw const ParseFailure(ParseFailureCode.timeout, '本次解析已超时');
              },
            );
        if (cancellation.isCancelled) {
          throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
        }
        if (result.resources.isEmpty || result.providerId != source.id) {
          throw const ParseFailure(ParseFailureCode.provider, '解析结果不完整');
        }
        attempts.add(
          ParseAttempt(providerId: source.id, elapsed: attemptWatch.elapsed),
        );
        statuses[source.id] = SourceStatus(
          _clock(),
          true,
          attemptWatch.elapsed,
        );
        _cache[key] = (
          expires: _clock().add(const Duration(minutes: 2)),
          value: result,
        );
        return ParseOutcome(result, attempts: attempts);
      } catch (error, stack) {
        campusLog(
          '[ShortVideo] action=source source=${source.id} errorType=${error.runtimeType}\n$stack',
        );
        if (cancellation.isCancelled) {
          throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
        }
        lastFailure = error is ParseFailure
            ? error
            : const ParseFailure(ParseFailureCode.provider, '来源解析失败');
        if (lastFailure.retryAfter case final retry?) {
          _nextStart[source.id] = _clock().add(retry);
        }
        attempts.add(
          ParseAttempt(
            providerId: source.id,
            elapsed: attemptWatch.elapsed,
            failure: lastFailure.code,
          ),
        );
        statuses[source.id] = SourceStatus(
          _clock(),
          false,
          attemptWatch.elapsed,
        );
        if (selected != automatic ||
            lastFailure.code == ParseFailureCode.invalidInput ||
            lastFailure.code == ParseFailureCode.cancelled) {
          throw lastFailure;
        }
      } finally {
        current.cancel();
        _busy.remove(source.id);
      }
    }
    throw lastFailure ??
        const ParseFailure(ParseFailureCode.unavailable, '暂时没有可用来源');
  }

  void clearCache() => _cache.clear();
  void close() {
    for (final provider in providers.values) {
      provider.close();
    }
    _cache.clear();
  }
}
