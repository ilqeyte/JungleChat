import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/animal_glyph.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../home/home_tab.dart';
import '../../services/feedback_service.dart';
import '../../services/social_service.dart';

/// Screen to add members to an existing group.
/// Step 1: Pick animals from discoverable animals.
/// Step 2: Send invitations to selected animals.
class AddGroupMembersScreen extends ConsumerStatefulWidget {
  final String groupId;
  final String? groupName;

  const AddGroupMembersScreen({
    super.key,
    required this.groupId,
    this.groupName,
  });

  @override
  ConsumerState<AddGroupMembersScreen> createState() =>
      _AddGroupMembersScreenState();
}

class _AddGroupMembersScreenState extends ConsumerState<AddGroupMembersScreen> {
  final Set<String> _selectedIds = {};
  List<_DiscoverAnimal> _animals = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAnimals();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final animals = await SocialService().discover(limit: 100);
      if (!mounted) return;
      setState(() {
        _animals = animals
            .map(
              (a) => _DiscoverAnimal(
                id: a.id,
                displayId: a.displayAnimalId,
                animal: a.animal,
              ),
            )
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = SafeErrors.message(e);
      });
    }
  }

  Future<void> _sendInvitations() async {
    if (_selectedIds.isEmpty) {
      setState(() => _error = 'Select at least one animal to invite.');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await ref
          .read(groupServiceProvider)
          .addMembers(widget.groupId, _selectedIds.toList());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invitations sent.')));
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = SafeErrors.message(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JCColors.background,
      appBar: AppBar(
        backgroundColor: JCColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: FeedbackService.click(() => context.pop()),
        ),
        title: Text(
          'Invite to ${widget.groupName ?? 'Group'}',
          style: JCTypography.title,
        ),
        actions: [
          TextButton(
            onPressed: _sending
                ? null
                : FeedbackService.click(_sendInvitations),
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: JCColors.accent,
                    ),
                  )
                : Text(
                    'INVITE',
                    style: JCTypography.secondary.copyWith(
                      color: JCColors.accent,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Selected count
          if (_selectedIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: JCColors.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${_selectedIds.length} selected',
                    style: JCTypography.secondary.copyWith(
                      color: JCColors.accent,
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 8),

          // Error
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: JCTypography.secondary.copyWith(color: JCColors.danger),
              ),
            ),

          // Animal list
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: JCColors.accent,
                    ),
                  )
                : _animals.isEmpty
                ? Center(
                    child: Text(
                      'No animals available to invite.\nThey need to have active accounts.',
                      textAlign: TextAlign.center,
                      style: JCTypography.secondary,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _animals.length,
                    itemBuilder: (context, index) {
                      final a = _animals[index];
                      final selected = _selectedIds.contains(a.id);
                      return ListTile(
                        leading: AnimalGlyph(animal: a.animal, size: 28),
                        title: Text(a.displayId, style: JCTypography.animalId),
                        trailing: Checkbox(
                          value: selected,
                          activeColor: JCColors.accent,
                          onChanged: (v) {
                            FeedbackService.tap();
                            setState(() {
                              if (v == true) {
                                _selectedIds.add(a.id);
                              } else {
                                _selectedIds.remove(a.id);
                              }
                            });
                          },
                        ),
                        onTap: FeedbackService.click(() {
                          setState(() {
                            if (selected) {
                              _selectedIds.remove(a.id);
                            } else {
                              _selectedIds.add(a.id);
                            }
                          });
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DiscoverAnimal {
  final String id;
  final String displayId;
  final String animal;

  const _DiscoverAnimal({
    required this.id,
    required this.displayId,
    required this.animal,
  });
}
