/// Safe, generic user-facing error mapping (PRD §50).
///
/// Backend error codes are translated to calm, uniform sentences.
/// Raw SQL errors, stack traces and internals NEVER reach the UI.
class SafeErrors {
  SafeErrors._();

  /// The single canonical auth failure message — reveals nothing about
  /// whether an Animal ID exists or which factor was wrong (PRD §10).
  static const String invalidCredentials =
      'The Animal ID or recovery credential is incorrect.';

  static String message(Object error) {
    final raw = error.toString();

    // Rate limiting is enforced server-side; surface it honestly but calmly.
    if (raw.contains('RATE_LIMITED')) {
      return 'Too many requests. Please wait a moment and try again.';
    }

    // Deployment drift: the installed APK and the deployed server functions
    // can disagree on RPC signatures. Without this, PostgREST's PGRST202 was
    // swallowed by the generic fallback and looked like a mystery failure.
    // The app now retries the older signature (see core/rpc.dart), so reaching
    // this message means even the legacy call failed — the server really is
    // missing the function.
    if (_isMissingFunction(raw)) {
      return 'This feature is not available on the server yet. Please update and try again.';
    }

    return switch (_code(raw)) {
      'INVALID_ANIMAL' => 'Choose an animal to continue.',
      'TARGET_UNAVAILABLE' => 'That animal cannot be contacted right now.',
      'REQUEST_NOT_FOUND' ||
      'REQUEST_NOT_ACTIVE' => 'This talk request is no longer available.',
      'ROOM_UNAVAILABLE' => 'This room is not available.',
      'ROOM_PRIVATE' => 'This room is private.',
      'ROOM_NOT_JOINED' => 'Join the room before writing.',
      'INVALID_MESSAGE' => 'Message must be between 1 and 1000 characters.',
      'MESSAGE_NOT_EDITABLE' =>
        'This message can no longer be edited (30-minute limit).',
      'MESSAGE_NOT_DELETABLE' => 'This message cannot be deleted.',
      'MUTED_PUBLIC_POSTING' => 'You are currently muted in public rooms.',
      'ACCOUNT_RESTRICTED' => 'Your account is restricted.',
      'MESSAGING_BLOCKED' => 'Messaging is unavailable with this animal.',
      'CONVERSATION_NOT_FOUND' => 'Conversation not found.',
      // App updates. Without these, every publish failure surfaced as the
      // generic "Something went wrong.", which hid the real cause.
      'NOT_ADMIN' => 'Only Adam can do that.',
      'UPDATE_NOT_FOUND' => 'That release no longer exists.',
      'INVALID_DOWNLOAD_URL' => 'Download link must start with https://',
      'INVALID_VERSION' => 'Version code must be a whole number above 0.',
      'INVALID_REPORT_TYPE' ||
      'INVALID_REPORT_BODY' => 'Please complete the report correctly.',
      // Admin permanent deletion (admin-hard-delete-user). These previously
      // all degraded to "Something went wrong.", which made a missing Edge
      // Function indistinguishable from a database failure.
      'NOT_GROUP_MEMBER' => 'You are no longer a member of this group.',
      'INVALID_MESSAGE_LENGTH' => 'Message must be between 1 and 1000 characters.',
      'INVALID_REPLY' => 'That reply target is no longer available.',
      'UNAUTHORIZED' => 'Your admin session expired. Please sign in again.',
      'TARGET_NOT_FOUND' => 'That account no longer exists.',
      'TARGET_IS_ADMIN' => 'Admin accounts cannot be deleted.',
      'INVALID_TARGET' => 'That account cannot be deleted.',
      'LOOKUP_FAILED' => 'Could not verify that account. Please try again.',
      'DELETE_FAILED' => 'The server could not delete that account. Check the server logs.',
      'NOT_CONFIGURED' => 'The delete service is not configured on the server.',
      _ => 'Something went wrong. Please try again.',
    };
  }

  static String? _code(String raw) {
    // WHY: take the LAST `code=…` match. The previous regex greedily
    // grabbed the first (?:code|message) token, so a wrapper string with an
    // earlier SQLSTATE / HINT / CONSTRAINT / JSON-encoded message shadowed
    // the real error code (e.g. code=MESSAGE_NOT_EDITABLE) and degraded
    // every error to "Something went wrong.".
    //
    // PostgREST writes `"code": "PGRST202"` and codes contain digits, so the
    // original `[A-Z_]{3,40}` class matched neither. Codes are now allowed to
    // contain digits, and `code:` is accepted alongside `code=`.
    for (final pattern in <String>[
      r'code["\s:=]+([A-Z][A-Z0-9_]{2,40})',
      r'message["\s:=]+([A-Z][A-Z0-9_]{2,40})',
      r'error["\s:=]+([A-Z][A-Z0-9_]{2,40})',
    ]) {
      final matches = RegExp(pattern).allMatches(raw);
      if (matches.isNotEmpty) return matches.last.group(1);
    }
    return null;
  }

  /// True for PostgREST's "function does not exist / bad signature" errors.
  /// Checked before [_code] because `PGRST202` is a transport-level failure,
  /// not an application error code.
  static bool _isMissingFunction(String raw) {
    final upper = raw.toUpperCase();
    return upper.contains('PGRST202') ||
        upper.contains('PGRST203') ||
        RegExp(r'\b42883\b').hasMatch(raw);
  }
}
