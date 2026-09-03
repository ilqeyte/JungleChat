import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_update.dart';

/// Byte progress for a download.
///
/// [total] is 0 when the server did not send a Content-Length; the UI then
/// shows transferred megabytes instead of a percentage.
class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  bool get hasTotal => total > 0;

  double get ratio =>
      hasTotal ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

/// A short-lived, server-signed permission to PUT one object into the R2
/// bucket.
///
/// Created by the `r2-upload-url` Edge Function. The URL is PUT-only, scoped
/// to a single server-generated key, and expires — so a leaked ticket cannot
/// be used to overwrite anyone else's file.
class R2UploadTicket {
  const R2UploadTicket({
    required this.key,
    required this.uploadUrl,
    required this.publicUrl,
  });

  factory R2UploadTicket.fromMap(Map<String, dynamic> m) => R2UploadTicket(
    key: m['key'] as String,
    uploadUrl: m['uploadUrl'] as String,
    publicUrl: m['publicUrl'] as String,
  );

  final String key;
  final String uploadUrl;
  final String publicUrl;
}

/// An upload failure whose message is already safe and human-readable.
///
/// Kept separate from database errors: these messages come from OUR upload
/// path, not from a SQL error code, so they must not be flattened into the
/// generic "Something went wrong." by SafeErrors.
class UploadException implements Exception {
  const UploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Throttles progress callbacks so a fast stream cannot flood the UI with
/// rebuilds. A 127 MiB upload emits thousands of chunks.
class _ProgressThrottle {
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  bool shouldEmit() {
    final now = DateTime.now();
    if (now.difference(_lastEmit).inMilliseconds < 100) return false;
    _lastEmit = now;
    return true;
  }
}

class UpdateService {
  final SupabaseClient _db = Supabase.instance.client;

  // ── Reads ───────────────────────────────────────────────────────────────

  /// The currently published release, or null if there is none.
  ///
  /// This is the ONLY user-facing read path. It is served by
  /// `get_latest_update()`, a SECURITY DEFINER function that returns just the
  /// live release and nothing else.
  Future<AppUpdate?> getLatestUpdate() async {
    final result = await _db.rpc('get_latest_update');
    if (result == null) return null;
    final rows = result as List;
    if (rows.isEmpty) return null;
    return AppUpdate.fromMap(Map<String, dynamic>.from(rows.first as Map));
  }

  /// Admin: every release, newest first. Gated server-side.
  Future<List<AppUpdate>> listAllUpdates() async {
    final result = await _db.rpc('admin_list_updates');
    if (result == null) return [];
    final rows = result as List;
    return rows
        .map((r) => AppUpdate.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  // ── Admin writes ────────────────────────────────────────────────────────

  /// Creates the release row and returns its id.
  ///
  /// `p_required_after` is ALWAYS present in the params map, even when null.
  /// postgrest-dart serialises params with jsonEncode, so an explicit null
  /// survives as a JSON null and PostgREST resolves the five-argument
  /// overload. Dropping the key produces PGRST202 ("Could not find the
  /// function"), which the UI renders as a generic failure — that was the
  /// original publish bug.
  Future<String> createUpdate({
    required int versionCode,
    required String versionName,
    required String changelog,
    required bool isRequired,
    DateTime? requiredAfter,
  }) async {
    final result = await _db.rpc(
      'admin_create_update',
      params: {
        'p_version_code': versionCode,
        'p_version_name': versionName,
        'p_changelog': changelog,
        'p_is_required': isRequired,
        'p_required_after': requiredAfter?.toUtc().toIso8601String(),
      },
    );
    return result as String;
  }

  /// Attaches the download link, flips the release live, and notifies every
  /// user — all inside one server-side transaction.
  Future<void> publishUpdate({
    required String updateId,
    required String downloadUrl,
  }) async {
    await _db.rpc(
      'admin_publish_update',
      params: {'p_update_id': updateId, 'p_download_url': downloadUrl},
    );
  }

  /// Admin: toggle the required flag on an existing release.
  Future<void> toggleUpdateRequired(
    String updateId, {
    required bool isRequired,
    DateTime? requiredAfter,
  }) async {
    await _db.rpc(
      'admin_toggle_update_required',
      params: {
        'p_update_id': updateId,
        'p_is_required': isRequired,
        'p_required_after': requiredAfter?.toUtc().toIso8601String(),
      },
    );
  }

  /// Admin: deactivate another release and make this one live.
  Future<void> setActiveUpdate(String updateId) async {
    await _db.rpc('admin_set_active_update', params: {'p_update_id': updateId});
  }

  /// Admin: delete a release.
  Future<void> deleteUpdate(String updateId) async {
    await _db.rpc(
      'admin_delete_update_cascade',
      params: {'p_update_id': updateId},
    );
  }

  // ── R2 uploads ──────────────────────────────────────────────────────────

  /// Asks the server for a pre-signed PUT URL into the Cloudflare R2 bucket.
  ///
  /// Signing happens server-side, always. The R2 secret must never reach the
  /// client: the APK can be decompiled, so anything compiled into the app is
  /// public. This call only hands back a URL that is valid for one object for
  /// a few minutes.
  Future<R2UploadTicket> requestUploadUrl({
    required int versionCode,
    required int size,
    String contentType = 'application/vnd.android.package-archive',
  }) async {
    final response = await _db.functions.invoke(
      'r2-upload-url',
      method: HttpMethod.post,
      body: {
        'versionCode': versionCode,
        'size': size,
        'contentType': contentType,
      },
    );

    final data = response.data;
    if (response.status != 200 || data is! Map) {
      throw UploadException(_uploadErrorMessage(response.status, data));
    }
    return R2UploadTicket.fromMap(Map<String, dynamic>.from(data));
  }

  /// Maps the Edge Function's opaque error code to a calm sentence. The code
  /// itself is never shown.
  String _uploadErrorMessage(int? status, Object? data) {
    final code = (data is Map ? data['error'] : null)?.toString();
    return switch (code) {
      'NOT_ADMIN' => 'Only Adam can publish an update.',
      'INVALID_SIZE' => 'That file is too large or empty.',
      'INVALID_TYPE' => 'That file is not an APK.',
      'INVALID_VERSION' => 'Version code must be a whole number above 0.',
      'NOT_CONFIGURED' => 'Uploads are not set up yet.',
      'UNAUTHORIZED' => 'Your session expired. Please sign in again.',
      _ => 'Could not start the upload (${status ?? '?'}). Please try again.',
    };
  }

  /// Streams [source] straight into the R2 object behind [ticket].
  ///
  /// The bytes go device -> R2 with no Supabase hop, which is what makes a
  /// ~127 MiB APK possible at all: Supabase Storage caps uploads at 50 MB on
  /// the free plan, and an Edge Function cannot proxy a body this large.
  ///
  /// Memory stays flat because the file is streamed, never buffered whole.
  /// [onProgress] fires at most ten times a second and is always followed by
  /// one final call at 100%.
  Future<void> uploadToR2({
    required R2UploadTicket ticket,
    required Stream<List<int>> source,
    required int totalBytes,
    required void Function(DownloadProgress) onProgress,
  }) async {
    final request = http.StreamedRequest('PUT', Uri.parse(ticket.uploadUrl))
      ..headers['Content-Type'] = 'application/vnd.android.package-archive'
      ..contentLength = totalBytes;

    final client = http.Client();
    final throttle = _ProgressThrottle();
    var sent = 0;

    try {
      // Start reading the response before the body is finished; some servers
      // only reply once the request is complete.
      final responseFuture = client.send(request);

      await request.sink.addStream(
        source.map((chunk) {
          sent += chunk.length;
          if (throttle.shouldEmit()) {
            onProgress(DownloadProgress(sent, totalBytes));
          }
          return chunk;
        }),
      );
      await request.sink.close();

      onProgress(DownloadProgress(sent, totalBytes));

      final response = await http.Response.fromStream(await responseFuture);
      if (response.statusCode != 200) {
        throw UploadException('Upload failed (HTTP ${response.statusCode}).');
      }
    } finally {
      client.close();
    }
  }

  // ── Downloads ───────────────────────────────────────────────────────────

  /// Streams the APK from [url] straight into [destFile].
  ///
  /// The link is admin-supplied and validated server-side as http(s), so the
  /// client simply follows it. Progress is reported as it streams, which keeps
  /// memory flat regardless of APK size.
  Future<File> downloadApk(
    String url,
    File destFile,
    void Function(DownloadProgress) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      // Follow up to 5 redirects (common with release-hosting services).
      if (response.isRedirect) {
        response.drain<void>();
        var current = Uri.parse(url);
        for (var i = 0; i < 5; i++) {
          final next = await client.getUrl(current);
          final res = await next.close();
          if (!res.isRedirect) {
            return await _streamToFile(res, destFile, onProgress);
          }
          final location = res.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw Exception('Download failed (bad redirect).');
          }
          current = current.resolve(location);
          res.drain<void>();
        }
        throw Exception('Download failed (too many redirects).');
      }

      if (response.statusCode != 200) {
        throw Exception('Download failed (HTTP ${response.statusCode}).');
      }

      return await _streamToFile(response, destFile, onProgress);
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _streamToFile(
    HttpClientResponse response,
    File destFile,
    void Function(DownloadProgress) onProgress,
  ) async {
    final total = response.contentLength;
    var received = 0;

    final sink = destFile.openWrite();
    // WHY: an APK arrives in thousands of chunks; firing onProgress per
    // chunk re-binds the progress UI thousands of times. uploadToR2 already
    // throttles via _ProgressThrottle — reuse it here so both paths emit at
    // most 10/s.
    final throttle = _ProgressThrottle();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (throttle.shouldEmit()) {
          onProgress(DownloadProgress(received, total));
        }
      }
      // Final tick at 100% so the bar lands on full even when the last
      // mid-stream emission was throttled away. Matches uploadToR2.
      onProgress(DownloadProgress(received, total));
    } finally {
      await sink.flush();
      await sink.close();
    }

    // A truncated or error body must never reach the installer.
    if (total > 0 && received != total) {
      if (await destFile.exists()) {
        await destFile.delete();
      }
      throw Exception('Download was interrupted. Please try again.');
    }

    return destFile;
  }
}
