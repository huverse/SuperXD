enum MediaKind { video, image, audio }

class MediaResource {
  const MediaResource({
    required this.id,
    required this.kind,
    required this.url,
    required this.label,
    this.pairedImageId,
    this.quality,
    this.bytes,
    this.duration,
    this.width,
    this.height,
  });
  final String id;
  final MediaKind kind;
  final Uri url;
  final String label;
  final String? pairedImageId;
  // 来源给的画质（如「原画」）、大小、时长与分辨率，只有来源说明了的那一项才有；结果页写在这一项下面。
  final String? quality;
  final int? bytes;
  final Duration? duration;
  final int? width;
  final int? height;
}
