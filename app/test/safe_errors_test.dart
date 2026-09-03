import 'package:flutter_test/flutter_test.dart';
import 'package:junglechat/core/safe_errors.dart';
import 'package:junglechat/services/auth_service.dart';

void main() {
  group('SafeErrors — PRD §50 generic messages', () {
    test('rate limit is surfaced honestly', () {
      final msg = SafeErrors.message(Exception('code=RATE_LIMITED'));
      expect(msg, contains('Too many requests'));
    });

    test('unknown errors stay generic (no internals leak)', () {
      final msg = SafeErrors.message(
          Exception('PGRST116 relation "public.secret" does not exist'));
      expect(msg, 'Something went wrong. Please try again.');
      expect(msg.contains('relation'), isFalse);
    });

    test('block messaging explains both directions uniformly', () {
      expect(SafeErrors.message(Exception('code=MESSAGING_BLOCKED')),
          contains('unavailable'));
    });

    // REGRESSION: the old parser used `code=([A-Z_]{3,40})`, which matched
    // neither PostgREST's `code: PGRST202` format nor any code containing a
    // digit. Every deployment-drift failure therefore degraded to the generic
    // message and hid the real cause.
    group('PostgREST / drift codes are recognised', () {
      test('JSON code with digits (missing RPC signature)', () {
        final msg = SafeErrors.message(
          Exception(
            'PostgrestException(message: Could not find the function '
            'public.send_direct_message, code: PGRST202, details: null)',
          ),
        );
        expect(msg, isNot('Something went wrong. Please try again.'));
      });

      test('bare PGRST202 is not reported as a generic error', () {
        expect(
          SafeErrors.message(Exception('code=PGRST202')),
          isNot('Something went wrong. Please try again.'),
        );
      });

      test('SQLSTATE 42883 (undefined function) is recognised', () {
        expect(
          SafeErrors.message(
            Exception('PostgrestException(message: , code: 42883)'),
          ),
          isNot('Something went wrong. Please try again.'),
        );
      });

      test('admin deletion codes are named, not generic', () {
        expect(
          SafeErrors.message(Exception('code=DELETE_FAILED')),
          contains('server'),
        );
        expect(SafeErrors.message(Exception('code=UNAUTHORIZED')),
            contains('sign in'));
        expect(SafeErrors.message(Exception('code=TARGET_IS_ADMIN')),
            contains('Admin'));
      });

      test('real SQL details still never reach the user', () {
        final msg = SafeErrors.message(
          Exception(
            'PostgrestException(message: operator does not exist: '
            'character varying = uuid, code: 42883, details: '
            'constraint group_messages_deleted_by_fkey)',
          ),
        );
        expect(msg.contains('varying'), isFalse);
        expect(msg.contains('group_messages'), isFalse);
      });
    });
  });

  group('AnimalCard parsing', () {
    test('parses minimal public card', () {
      final card = AnimalCard.fromJson({
        'id': 'uuid-1',
        'animal': 'Wolf',
        'display_animal_id': 'WOLF-427',
        'open_to_talk': true,
      });
      expect(card.displayAnimalId, 'WOLF-427');
      expect(card.openToTalk, isTrue);
    });

    test('tolerates missing optional fields', () {
      final card = AnimalCard.fromJson({'id': 'uuid-2'});
      expect(card.animal, '');
      expect(card.openToTalk, isTrue);
    });
  });

  group('MyProfile parsing', () {
    test('inactivity countdown defaults to 90', () {
      final p = MyProfile.fromJson({
        'id': 'u',
        'display_animal_id': 'FOX-12',
        'days_until_delete': 7,
      });
      expect(p.daysUntilDelete, 7);

      final p2 = MyProfile.fromJson({'id': 'u'});
      expect(p2.daysUntilDelete, 90);
    });
  });
}
