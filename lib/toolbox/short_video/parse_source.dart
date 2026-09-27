import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

class ParseSource {
  const ParseSource({
    required this.id,
    required this.name,
    required this.host,
    required this.version,
    required this.consentVersion,
    this.interval = const Duration(seconds: 1),
  });
  final String id;
  final String name;
  final String host;
  final String version;
  final String consentVersion;
  final Duration interval;
}

abstract interface class ParseProvider {
  ParseSource get source;
  bool supports(Uri uri);
  Future<ParseResult> resolve(Uri uri, ToolboxCancellation cancellation);
  void close();
}

class SourceStatus {
  const SourceStatus(this.checkedAt, this.success, this.elapsed);
  final DateTime checkedAt;
  final bool success;
  final Duration elapsed;
}
