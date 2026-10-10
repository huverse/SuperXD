import 'package:superxd/toolbox/short_video/media_resource.dart';

class ParseResult {
  const ParseResult({
    required this.sourceUrl,
    required this.providerId,
    required this.title,
    required this.author,
    required this.resources,
    this.cover,
    this.platform = '',
    this.contentId,
  });
  final Uri sourceUrl;
  final String providerId;
  final String title;
  final String author;
  final List<MediaResource> resources;
  final MediaResource? cover;
  final String platform;
  final String? contentId;
  Iterable<MediaResource> get videos =>
      resources.where((item) => item.kind == MediaKind.video);
  Iterable<MediaResource> get images =>
      resources.where((item) => item.kind == MediaKind.image);
  Iterable<MediaResource> get audio =>
      resources.where((item) => item.kind == MediaKind.audio);
  String get identity => contentId == null
      ? '$providerId\u0000$sourceUrl'
      : '$platform\u0000$contentId';
  String get kind => images.isNotEmpty ? 'gallery' : 'video';
}

enum ParseFailureCode {
  invalidInput,
  unsupported,
  rateLimited,
  timeout,
  network,
  provider,
  unavailable,
  cancelled,
  consentRequired,
}

class ParseFailure implements Exception {
  const ParseFailure(this.code, this.message, {this.retryAfter});
  final ParseFailureCode code;
  final String message;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

class ParseAttempt {
  const ParseAttempt({
    required this.providerId,
    required this.elapsed,
    this.failure,
  });
  final String providerId;
  final Duration elapsed;
  final ParseFailureCode? failure;
}

class ParseOutcome {
  const ParseOutcome(
    this.result, {
    required this.attempts,
    this.fromCache = false,
  });
  final ParseResult result;
  final List<ParseAttempt> attempts;
  final bool fromCache;
}
