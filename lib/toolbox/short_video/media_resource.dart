enum MediaKind { video, image, audio }

class MediaResource {
  const MediaResource({
    required this.id,
    required this.kind,
    required this.url,
    required this.label,
    this.pairedImageId,
  });
  final String id;
  final MediaKind kind;
  final Uri url;
  final String label;
  final String? pairedImageId;
}
