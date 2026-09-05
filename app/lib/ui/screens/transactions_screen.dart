import 'package:flutter/material.dart';

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../widgets.dart';

/// TRANSACTIONS — unified money ledger (sale payments, invoice payments,
/// refunds).
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final txns = store.transactions.reversed.where((t) {
      return switch (_filter) {
        'sales' => t.type == TxnType.salePayment,
        'invoices' => t.type == TxnType.invoicePayment,
        'refunds' => t.isRefund,
        _ => true,
      };
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: 'Transactions',
            subtitle: 'Every naira in and out — one ledger',
            icon: Icons.swap_horiz,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: [
              for (final f in const [('all', 'All'), ('sales', 'Sale payments'), ('invoices', 'Invoice payments'), ('refunds', 'Refunds')])
                ChoiceChip(
                  label: Text(f.$2),
                  selected: _filter == f.$1,
                  selectedColor: Mtek.brandTint,
                  onSelected: (_) => setState(() => _filter = f.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: txns.isEmpty
                  ? const EmptyHint('No transactions match this filter')
                  : ListView.separated(
                      itemCount: txns.length + 1,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Mtek.gray100),
                      itemBuilder: (context, i) {
                        if (i == txns.length) return const LoadOlderTile('transactions');
                        final t = txns[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.isRefund ? Mtek.dangerTint : Mtek.brandTint,
                            child: Icon(
                              t.isRefund ? Icons.undo : Icons.arrow_downward,
                              size: 18,
                              color: t.isRefund ? Mtek.danger : Mtek.brand600,
                            ),
                          ),
                          title: Text(
                            t.isRefund
                                ? 'Refund'
                                : t.type == TxnType.salePayment
                                    ? 'Sale payment — ${t.reference}'
                                    : 'Invoice payment — ${t.reference}',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          ),
                          subtitle: Text('${fmt.fmtDateTime(t.date)} · ${MethodIcon.label(t.method)} · ${t.id}'),
                          trailing: AmountText(
                            t.isRefund ? -t.amount : t.amount,
                            color: t.isRefund ? Mtek.danger : Mtek.success,
                          ),
                          onTap: () => _showDetail(context, t),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, Transaction t) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.id, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 16),
            _row('Type', t.isRefund ? 'Refund' : (t.type == TxnType.salePayment ? 'Sale payment' : 'Invoice payment')),
            _row('Amount', fmt.naira(t.isRefund ? -t.amount : t.amount)),
            _row('Method', MethodIcon.label(t.method)),
            _row('Date', fmt.fmtDateTime(t.date)),
            _row('Reference', t.reference),
            _row('Recorded in', 'Money ledger'),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Mtek.gray500, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          ],
        ),
      );
}
