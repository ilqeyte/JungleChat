import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_controller.dart';
import '../../core/theme.dart';
import '../audit/audit_page.dart';
import '../dashboard/dashboard_page.dart';
import '../reports/reports_page.dart';
import '../support/support_page.dart';
import '../updates/updates_page.dart';
import '../users/users_page.dart';
import '../whitelabel/whitelabel_page.dart';

class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key});

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  int _index = 0;

  static const _labels = [
    'Dashboard',
    'Users',
    'Reports',
    'Support',
    'Updates',
    'Audit',
    'White-label',
  ];

  static const _icons = [
    Icons.dashboard_outlined,
    Icons.people_outline,
    Icons.flag_outlined,
    Icons.support_agent_outlined,
    Icons.system_update_outlined,
    Icons.history_outlined,
    Icons.palette_outlined,
  ];

  static const _pages = [
    DashboardPage(),
    UsersPage(),
    ReportsPage(),
    SupportPage(),
    UpdatesPage(),
    AuditPage(),
    WhiteLabelPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: Colors.black,
            selectedIconTheme: const IconThemeData(color: JCColors.accent),
            selectedLabelTextStyle:
                const TextStyle(color: JCColors.accent, fontWeight: FontWeight.w600),
            unselectedIconTheme: const IconThemeData(color: Colors.white70),
            unselectedLabelTextStyle:
                const TextStyle(color: Colors.white70),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (var i = 0; i < _labels.length; i++)
                NavigationRailDestination(
                  icon: Icon(_icons[i]),
                  label: Text(_labels[i]),
                ),
            ],
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'JungleChat',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextButton.icon(
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).signOut(),
                    icon: const Icon(Icons.logout, color: Colors.white70),
                    label: const Text('Sign out',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.black),
          Expanded(child: _pages[_index]),
        ],
      ),
    );
  }
}
