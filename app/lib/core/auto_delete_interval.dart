/// Phase 6 / Phase 8 — pure, testable helpers for the disappearing-message
/// timer label.
///
/// Kept free of Flutter/Dart-UI dependencies so it can be unit-tested without a
/// widget tree. The interval literal arrives from the server (e.g.
/// `interval '24 hours'`); we only render a short label — the client never
/// decides what is expired, RLS does.
String humanizeInterval(String raw) {
  final m = RegExp(r"(\d+)\s*hours?", caseSensitive: false).firstMatch(raw);
  if (m != null) {
    final h = int.parse(m.group(1)!);
    if (h >= 24 && h % 24 == 0) {
      final d = h ~/ 24;
      return d == 1 ? 'Disappears after 1 day' : 'Disappears after $d days';
    }
    return 'Disappears after $h hours';
  }
  final d = RegExp(r"(\d+)\s*days?", caseSensitive: false).firstMatch(raw);
  if (d != null) {
    final days = int.parse(d.group(1)!);
    return days == 1 ? 'Disappears after 1 day' : 'Disappears after $days days';
  }
  return 'Disappears automatically';
}
