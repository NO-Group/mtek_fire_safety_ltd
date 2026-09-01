import 'package:flutter/material.dart';

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../widgets.dart';

/// CUSTOMERS — individuals & corporates, contacts, credit balance,
/// purchase history. M3: Supabase `customers` table.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final list = store.customers
        .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Customers',
            subtitle: '${store.customers.length} on file — ${store.customers.where((c) => c.isCorporate).length} corporate',
            actions: [
              FilledButton.icon(
                onPressed: () => _showNewCustomerDialog(context),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('New customer'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search customers…',
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Mtek.gray100),
                itemBuilder: (context, i) {
                  final c = list[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: c.isCorporate ? Mtek.navy800 : Mtek.brand600,
                      child: Text(
                        c.name.split(' ').take(2).map((w) => w[0]).join(),
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${c.isCorporate ? "Corporate" : "Individual"} · ${c.phone}'),
                    trailing: c.creditBalance > 0
                        ? StatusChip.bad('Credit ${fmt.nairaCompact(c.creditBalance)}')
                        : const StatusChip.neutral('No dues'),
                    onTap: () => _showDetail(context, c),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showNewCustomerDialog(BuildContext context) {
    final name = TextEditingController();
    final phone = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New customer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name / Company')),
            const SizedBox(height: 12),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone (WhatsApp)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                AppStore.instance.customers.add(Customer(
                  id: 'C${AppStore.instance.customers.length + 1}',
                  name: name.text.trim(),
                  isCorporate: name.text.toLowerCase().contains('ltd') || name.text.toLowerCase().contains('depot'),
                  phone: phone.text.trim(),
                  email: '',
                  address: '',
                ));
                AppStore.instance.notifyListeners();
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, Customer c) {
    final store = AppStore.instance;
    final history = store.sales.where((s) => s.customer.id == c.id).toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            Text(c.isCorporate ? 'Corporate customer' : 'Individual customer', style: const TextStyle(color: Mtek.gray500, fontSize: 13)),
            const SizedBox(height: 16),
            _row('Phone', c.phone),
            _row('Email', c.email.isEmpty ? '—' : c.email),
            _row('Address', c.address.isEmpty ? '—' : c.address),
            _row('Credit balance', fmt.naira(c.creditBalance)),
            const SizedBox(height: 8),
            Text('PURCHASE HISTORY (${history.length})', style: const TextStyle(fontSize: 11, letterSpacing: 1, color: Mtek.gray500, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (history.isEmpty) const Text('No purchases yet', style: TextStyle(color: Mtek.gray500)),
            ...history.take(5).map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 70, child: Text(fmt.fmtDateShort(s.date), style: const TextStyle(color: Mtek.gray500, fontSize: 13))),
                      Expanded(child: Text(s.items.map((i) => '${i.product.name} ×${i.qty}').join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                      AmountText(s.total),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Mtek.gray500, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          ],
        ),
      );
}
