import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/auth_store.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../widgets.dart';

/// STAFF — CEO and Admin see everyone's name, email and phone number. Only
/// the CEO can promote a Sales staffer to Admin or demote an Admin back to
/// Sales (owner directive 2026-09-01); Admins see the same list read-only.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  bool _loading = false;
  String? _busyUid;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await AppStore.instance.refreshStaff();
    if (mounted) setState(() => _loading = false);
  }

  Color _roleColor(String role) => switch (role) {
        'ceo' => Mtek.navy800,
        'admin' => Mtek.brand600,
        _ => Mtek.gray500,
      };

  Widget _roleChip(String role) => switch (role) {
        'ceo' => const StatusChip.pending('CEO'),
        'admin' => const StatusChip.info('ADMIN'),
        _ => const StatusChip.neutral('SALES'),
      };

  Future<void> _toggleRole(StaffMember s) async {
    final newRole = s.role == 'admin' ? 'sales' : 'admin';
    setState(() => _busyUid = s.uid);
    final err = await AppStore.instance.setStaffRole(s.uid, newRole);
    if (mounted) setState(() => _busyUid = null);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final isCeo = AuthStore.instance.isCeo;
    final list = store.staff;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Staff',
            subtitle: list.isEmpty
                ? 'Every account that has signed in or signed up shows here'
                : '${list.length} staff member${list.length == 1 ? '' : 's'}'
                    '${isCeo ? '' : ' · only the CEO can change roles'}',
            icon: Icons.badge,
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: list.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No staff records yet', style: TextStyle(color: Mtek.gray500)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Mtek.gray100),
                      itemBuilder: (context, i) {
                        final s = list[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _roleColor(s.role),
                            child: Text(
                              s.name.isEmpty ? '?' : s.name.trim()[0].toUpperCase(),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                            ),
                          ),
                          title: Text(s.name.isEmpty ? s.email : s.name,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('${s.email}${s.phone.isEmpty ? '' : ' · ${s.phone}'}'),
                          // FittedBox: chip + button can exceed the tile's
                          // trailing space on narrow phones — scale down
                          // instead of painting overflow stripes.
                          trailing: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _roleChip(s.role),
                                if (isCeo && s.role != 'ceo') ...[
                                  const SizedBox(width: 10),
                                  _busyUid == s.uid
                                      ? const SizedBox(
                                          width: 18, height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : OutlinedButton(
                                          onPressed: () => _toggleRole(s),
                                          child: Text(s.role == 'admin' ? 'Demote' : 'Make Admin'),
                                        ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
