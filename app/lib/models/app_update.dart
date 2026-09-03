/// A published app release, as returned by `get_latest_update()`.
class AppUpdate {
  final String id;
  final int versionCode;
  final String versionName;
  final String changelog;

  /// Where the APK lives. Admin-supplied, validated server-side as http(s).
  final String? downloadUrl;

  final bool isRequired;
  final bool isActive;
  final DateTime? requiredAfter;
  final DateTime? publishedAt;
  final DateTime createdAt;

  const AppUpdate({
    required this.id,
    required this.versionCode,
    required this.versionName,
    required this.changelog,
    this.downloadUrl,
    required this.isRequired,
    required this.isActive,
    this.requiredAfter,
    this.publishedAt,
    required this.createdAt,
  });

  bool get hasDownloadUrl => downloadUrl != null && downloadUrl!.isNotEmpty;

  factory AppUpdate.fromMap(Map<String, dynamic> m) {
    int code(dynamic v) => v is int ? v : int.tryParse(v.toString()) ?? 0;
    return AppUpdate(
      id: m['id'] as String,
      versionCode: code(m['version_code']),
      versionName: (m['version_name'] as String?)?.isNotEmpty == true
          ? m['version_name'] as String
          : code(m['version_code']).toString(),
      changelog: (m['changelog'] as String?) ?? '',
      downloadUrl: m['download_url'] as String?,
      isRequired: m['is_required'] as bool? ?? false,
      isActive: m['is_active'] as bool? ?? false,
      requiredAfter: m['required_after'] != null
          ? DateTime.tryParse(m['required_after'].toString())
          : null,
      publishedAt: m['published_at'] != null
          ? DateTime.tryParse(m['published_at'].toString())
          : null,
      createdAt:
          DateTime.tryParse(m['created_at'].toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
