import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/theme.dart';
import '../../data/auth_store.dart';
import '../../data/store.dart';
import '../../documents/forms_spec.dart';
import '../../documents/serial_service.dart';

/// SETTINGS (Phase B): VAT toggle, watermark/branding info, document
/// serial reseed (continue the paper books), stock TXT import.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _tsv = TextEditingController();
  String _importMsg = '';

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Settings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Mtek.ink)),
        const SizedBox(height: 4),
        const Text('Company profile, tax and document numbering', style: TextStyle(color: Mtek.gray500)),
        const SizedBox(height: 16),

        // ---- financial ----
        Card(
          child: SwitchListTile(
            title: const Text('Apply VAT on invoices & MILS sheets'),
            subtitle: Text('${(store.settings.vatRate * 100).toStringAsFixed(1)}% · configurable per document (SPEC §7)'),
            value: store.settings.vatEnabled,
            activeColor: Mtek.brand600,
            onChanged: (v) async {
              await store.updateSettings(vatEnabled: v);
              if (mounted) setState(() {});
            },
          ),
        ),
        const SizedBox(height: 14),

        // ---- document serials ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('DOCUMENT SERIALS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
                const SizedBox(height: 4),
                const Text('Set each counter to the number of the last used page in the physical book — digital documents continue the sequence.',
                    style: TextStyle(fontSize: 12, color: Mtek.gray500)),
                const SizedBox(height: 10),
                for (final entry in [
                  ('receipt', 'Payment Receipt', MtekForms.seedSerials['receipt']!),
                  ('invoice', 'Sales Invoice', MtekForms.seedSerials['invoice']!),
                  ('mils', 'MILS Sheet', MtekForms.seedSerials['mils']!),
                  ('waybill', 'Waybill (starts 000000001)', MtekForms.seedSerials['waybill']!),
                  ('deliverynote', 'Delivery Note (starts 000000001)', MtekForms.seedSerials['deliverynote']!),
                ])
                  _serialRow(context, entry.$1, entry.$2, entry.$3),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // ---- stock TXT import ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('STOCK IMPORT (TXT)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1, color: Mtek.gray500)),
                const SizedBox(height: 4),
                const Text('Paste the edited products_seed.txt contents (tab-separated) and import. Existing IDs are updated; new IDs are added.',
                    style: TextStyle(fontSize: 12, color: Mtek.gray500)),
                const SizedBox(height: 10),
                TextField(
                  controller: _tsv,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'ID\tNAME\tCATEGORY\tCOST PRICE (NGN)\t…',
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 10, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Import pasted TXT'),
                    onPressed: _importTsv,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.inventory_outlined, size: 18),
                    label: const Text('Load bundled seed file'),
                    onPressed: _loadBundled,
                  ),
                ]),
                if (_importMsg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_importMsg, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mtek.success)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // ---- company profile (read-only in Phase B; editable via Supabase in M3) ----
        const Card(
          child: ListTile(
            leading: Icon(Icons.verified_user_outlined),
            title: Text('M-TEK FIRE & SAFETY LTD.'),
            subtitle: Text('RC: 1082534 · YY12 Kazaure Road, Kaduna (HQ) · Plot 45, Sir P.I. Yakowa Way (Branch)\nmtekfiresafetyltd@gmail.com · 08033489452 / 08170577595'),
            isThreeLine: true,
          ),
        ),
      ],
    );
  }

  Widget _serialRow(BuildContext context, String type, String label, int bookSeed) {
    final controller = TextEditingController(text: '${SerialService.instance.current(type)}');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: 'book started at $bookSeed', isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () async {
            final v = int.tryParse(controller.text);
            if (v == null || v < 1) return;
            await AppStore.instance.updateSettings(serialReseed: {type: v});
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Next $label will be numbered ${v + 1} — continues the book.')));
              setState(() {});
            }
          },
          child: const Text('Set'),
        ),
      ]),
    );
  }

  Future<void> _importTsv() async {
    if (_tsv.text.trim().isEmpty) {
      _setMsg('Paste the TXT contents first (or load the bundled seed).');
      return;
    }
    final added = await AppStore.instance.importSeedCsv(_tsv.text);
    _setMsg('Import complete — $added new products, ${AppStore.instance.products.length} total in stock.');
  }

  Future<void> _loadBundled() async {
    final csv = await rootBundle.loadString('assets/seed/products_seed.txt');
    _tsv.text = csv.length > 20000 ? '${csv.substring(0, 20000)}\n… (truncated preview — full file is imported)' : csv;
    final added = await AppStore.instance.importSeedCsv(csv);
    _setMsg('Bundled seed imported — $added products loaded into Stock.');
  }

  void _setMsg(String m) => setState(() => _importMsg = m);
}
