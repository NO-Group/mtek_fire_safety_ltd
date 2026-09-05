import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
  PaymentMethod? _method;
  DateTimeRange? _range;
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final txns = store.transactions.reversed.where((t) {
      final typeMatches = switch (_filter) {
        'sales' => t.type == TxnType.salePayment,
        'invoices' => t.type == TxnType.invoicePayment,
        'refunds' => t.isRefund,
        _ => true,
      };
      if (!typeMatches || (_method != null && t.method != _method)) return false;
      if (_range != null) {
        final from = DateTime(_range!.start.year, _range!.start.month, _range!.start.day);
        final to = DateTime(_range!.end.year, _range!.end.month, _range!.end.day, 23, 59, 59, 999);
        if (t.date.isBefore(from) || t.date.isAfter(to)) return false;
      }
      return true;
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Transactions',
            subtitle: 'Every naira in and out — one ledger',
            icon: Icons.swap_horiz,
            actions: [
              IconButton(
                tooltip: 'Export filtered ledger',
                onPressed: txns.isEmpty ? null : () => _exportCsv(txns),
                icon: const Icon(Icons.ios_share_outlined),
              ),
              IconButton(
                tooltip: 'Refresh ledger',
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ],
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
          LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 560;
            final method = DropdownButtonFormField<PaymentMethod?>(
              value: _method,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Payment method', isDense: true),
              items: [
                const DropdownMenuItem<PaymentMethod?>(value: null, child: Text('All methods')),
                for (final value in PaymentMethod.values)
                  DropdownMenuItem<PaymentMethod?>(value: value, child: Text(MethodIcon.label(value))),
              ],
              onChanged: (value) => setState(() => _method = value),
            );
            final dates = OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(_range == null
                  ? 'Any date'
                  : '${fmt.fmtDate(_range!.start)} – ${fmt.fmtDate(_range!.end)}'),
            );
            if (compact) {
              return Column(children: [method, const SizedBox(height: 8), SizedBox(width: double.infinity, child: dates)]);
            }
            return Row(children: [Expanded(child: method), const SizedBox(width: 10), dates]);
          }),
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

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _range,
    );
    if (selected != null && mounted) setState(() => _range = selected);
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await AppStore.instance.refreshRemote();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _exportCsv(List<Transaction> transactions) async {
    String cell(Object? value) {
      final escaped = value.toString().replaceAll('"', '""');
      return '"$escaped"';
    }
    final rows = <String>[
      'ID,Date,Type,Method,Reference,Amount (NGN)',
      for (final t in transactions)
        [
          t.id,
          t.date.toIso8601String(),
          t.isRefund ? 'refund' : t.type.name,
          t.method.name,
          t.reference,
          t.isRefund ? -t.amount : t.amount,
        ].map(cell).join(','),
    ];
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/MFSL-transactions-${DateTime.now().millisecondsSinceEpoch}.csv');
    await file.writeAsString(rows.join('\n'), flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'text/csv')],
      subject: 'MFSL transaction ledger',
      text: 'Filtered MFSL transaction ledger (${transactions.length} entries).',
    ));
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
