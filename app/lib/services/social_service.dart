import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

/// Discovery, talk requests, blocking, random talk, reporting.
class SocialService {
  final SupabaseClient _db = Supabase.instance.client;

  Future<List<AnimalCard>> discover({int offset = 0, int limit = 50}) async {
    final rows = await _db.rpc(
      'list_discoverable_animals',
      params: {'p_offset': offset, 'p_limit': limit},
    );
    return (rows as List)
        .map((r) => AnimalCard.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<List<AnimalCard>> discoverSameAnimal(String animal) async {
    final rows = await _db.rpc(
      'list_animal_kind',
      params: {'p_animal': animal, 'p_limit': 50, 'p_offset': 0},
    );
    return (rows as List)
        .map((r) => AnimalCard.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Exact-match search only. Empty result for anything else.
  Future<AnimalCard?> searchExact(String query) async {
    final rows = await _db.rpc(
      'search_animal_by_id',
      params: {'p_query': query},
    );
    if (rows is! List || rows.isEmpty) return null;
    return AnimalCard.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// Full public identity card for ONE animal by user id — the profile
  /// screen (private-chat partner, group member). Unlike the discovery
  /// search this also resolves shadow-mode animals the viewer is already
  /// connected to. Null when the account is gone (deleted / suspended).
  Future<AnimalCard?> animalProfile(String userId) async {
    final rows = await _db.rpc(
      'get_animal_profile',
      params: {'p_user': userId},
    );
    if (rows is! List || rows.isEmpty) return null;
    return AnimalCard.fromJson(Map<String, dynamic>.from(rows.first));
  }

  Future<AnimalCard?> randomCandidate() async {
    final rows = await _db.rpc('random_talk_candidate');
    if (rows is! List || rows.isEmpty) return null;
    return AnimalCard.fromJson(Map<String, dynamic>.from(rows.first));
  }

  Future<void> sendTalkRequest(String targetUserId) =>
      _db.rpc('send_talk_request', params: {'p_target': targetUserId});

  Future<List<TalkRequestView>> listRequests({bool incoming = true}) async {
    final rows = await _db.rpc(
      'list_talk_requests',
      params: {'p_kind': incoming ? 'incoming' : 'outgoing'},
    );
    return (rows as List)
        .map((r) => TalkRequestView.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> respondRequest(String requestId, bool accept) => _db.rpc(
    'respond_talk_request',
    params: {'p_request': requestId, 'p_accept': accept},
  );

  Future<void> cancelRequest(String requestId) =>
      _db.rpc('cancel_talk_request', params: {'p_request': requestId});

  Future<void> block(String userId) =>
      _db.rpc('block_animal', params: {'p_target': userId});

  Future<void> unblock(String userId) =>
      _db.rpc('unblock_animal', params: {'p_target': userId});

  /// list_my_blocks returns user_id/animal/display_animal_id — not the
  /// discoverable-card shape — so map it explicitly (AnimalCard.fromJson
  /// requires an "id" key and would throw here).
  Future<List<AnimalCard>> myBlocks() async {
    final rows = await _db.rpc('list_my_blocks');
    return (rows as List).map((r) {
      final m = Map<String, dynamic>.from(r);
      return AnimalCard(
        id: (m['user_id'] ?? m['id']) as String? ?? '',
        animal: m['animal'] as String? ?? '',
        displayAnimalId: m['display_animal_id'] as String? ?? '',
        openToTalk: false,
      );
    }).toList();
  }

  Future<String> report({
    required String type,
    required String body,
    String? targetUser,
    String? targetMessage,
    String? targetRoom,
  }) async {
    final ref = await _db.rpc(
      'submit_report',
      params: {
        'p_type': type,
        'p_body': body,
        'p_target_user': targetUser,
        'p_target_message': targetMessage,
        'p_target_room': targetRoom,
      },
    );
    return ref as String;
  }
}

class TalkRequestView {
  final String requestId;
  final String otherDisplayId;
  final String otherAnimal;
  final DateTime createdAt;
  final DateTime expiresAt;

  const TalkRequestView({
    required this.requestId,
    required this.otherDisplayId,
    required this.otherAnimal,
    required this.createdAt,
    required this.expiresAt,
  });

  factory TalkRequestView.fromJson(Map<String, dynamic> j) => TalkRequestView(
    requestId: j['request_id'] as String,
    otherDisplayId: j['other_display_id'] as String? ?? '',
    otherAnimal: j['other_animal'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
    expiresAt: DateTime.parse(j['expires_at'] as String),
  );
}
