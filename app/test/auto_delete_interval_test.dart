import 'package:flutter_test/flutter_test.dart';

import 'package:junglechat/core/auto_delete_interval.dart';

void main() {
  group('humanizeInterval', () {
    test('parses hours', () {
      expect(humanizeInterval("interval '24 hours'"), 'Disappears after 1 day');
      expect(humanizeInterval("interval '48 hours'"), 'Disappears after 2 days');
      expect(humanizeInterval("interval '12 hours'"), 'Disappears after 12 hours');
    });

    test('parses days', () {
      expect(humanizeInterval("interval '7 days'"), 'Disappears after 7 days');
    });

    test('falls back when unparseable', () {
      expect(humanizeInterval('NULL'), 'Disappears automatically');
      expect(humanizeInterval(''), 'Disappears automatically');
      expect(humanizeInterval('garbage'), 'Disappears automatically');
    });
  });
}
