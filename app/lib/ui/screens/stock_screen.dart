import 'package:flutter/material.dart';

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/auth_store.dart';
import '../../data/store.dart';
import '../widgets.dart';

/// STOCK — quantities, prices, low-stock alerts, adjustments (audit trail).
/// Stock is NEVER pre-seeded: every product is entered through the app's own
/// fields (Add product / Import TXT) and saved to the one shared server.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {

  /// EVERY product enters the system through these fields — nothing about
  /// stock is hard-coded or pre-seeded. Saved to the shared server.
  Future<void> _addProduct(BuildContext context) async {
    final name = TextEditingController();
    final cost = TextEditingController();
    final price = TextEditingController();
    final qty = TextEditingController();
    final reorder = TextEditingController();
    final unit = TextEditingController(text: 'unit');
    var category = ProductCategory.fire;
    var isService = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Add product'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, autofocus: true,
                    decoration: const InputDecoration(labelText: 'Product name *')),
                const SizedBox(height: 10),
                DropdownButtonFormField<ProductCategory>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: const [
                    DropdownMenuItem(value: ProductCategory.fire, child: Text('Fire')),
                    DropdownMenuItem(value: ProductCategory.safety, child: Text('Safety')),
                    DropdownMenuItem(value: ProductCategory.security, child: Text('Security')),
                    DropdownMenuItem(value: ProductCategory.solar, child: Text('Solar')),
                    DropdownMenuItem(value: ProductCategory.automation, child: Text('Automation & Surveillance')),
                  ],
                  onChanged: (v) => setDialog(() => category = v ?? ProductCategory.fire),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: cost, keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Cost price (₦)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: price, keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Selling price (₦) *'))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: qty, keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Quantity on hand'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: reorder, keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Reorder level'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: unit,
                      decoration: const InputDecoration(labelText: 'Unit'))),
                ]),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Service (not stock-counted)', style: TextStyle(fontSize: 13.5)),
                  value: isService,
                  onChanged: (v) => setDialog(() => isService = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save product')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (name.text.trim().isEmpty || (price.text.trim().isEmpty && !isService)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Mtek.danger,
          content: Text('Product name and selling price are required.')));
      return;
    }
    final n = (String v) => int.tryParse(v.replaceAll(',', '')) ?? 0;
    final products = AppStore.instance.products;
    String nextId() {
      final prefix = switch (category) {
        ProductCategory.fire => 'F', ProductCategory.safety => 'S',
        ProductCategory.security => 'SEC', ProductCategory.solar => 'P',
        ProductCategory.automation => 'A',
      };
      var i = 1;
      while (products.any((p) => p.id == '$prefix${i.toString().padStart(3, '0')}')) {
        i++;
      }
      return '$prefix${i.toString().padStart(3, '0')}';
    }

    try {
      await AppStore.instance.addProduct(Product(
        id: nextId(),
        name: name.text.trim(),
        category: category,
        costPrice: n(cost.text),
        sellingPrice: n(price.text),
        qtyOnHand: isService ? 0 : n(qty.text),
        reorderLevel: n(reorder.text),
        unit: unit.text.trim().isEmpty ? 'unit' : unit.text.trim(),
        isService: isService,
      ));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Mtek.success,
            content: Text('${name.text.trim()} saved to the server.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Mtek.danger,
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  /// Optional bulk path: pick an edited TXT file, rows upsert over the
  /// catalogue (existing IDs update, new IDs append) — no terminal needed.
  Future<void> _importTxt(BuildContext context) async {
    final text = await pickProductsTxt();
    if (text == null || text.trim().isEmpty) return;
    try {
      final count = await AppStore.instance.importProductsTsv(text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Mtek.success,
            content: Text('$count product row(s) imported — catalogue updated.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: Mtek.danger,
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final lowCount = store.products.where((p) => p.isLow).length;

    final list = store.products.where((p) {
      if (_category != null && p.category.name != _category) return false;
      return p.name.toLowerCase().contains(_query.toLowerCase()) ||
          p.id.toLowerCase().contains(_query.toLowerCase());
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Stock',
            subtitle:
                '${store.products.length} items · $lowCount low/out of stock · ${fmt.naira(store.stockValueAtCost())} at cost',
            actions: [
              // stock is created HERE, in the app — never pre-loaded
              if (AuthStore.instance.isManagement)
                FilledButton.icon(
                  onPressed: () => _addProduct(context),
                  icon: const Icon(Icons.add_box),
                  label: const Text('Add product'),
                ),
              // optional bulk path for the owner's edited TXT file (CEO only)
              if (AuthStore.instance.isCeo)
                OutlinedButton.icon(
                  onPressed: () => _importTxt(context),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import TXT'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name or ID…'),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _category,
                hint: const Text('All categories'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All categories')),
                  for (final c in ProductCategory.values)
                    DropdownMenuItem(value: c.name, child: Text(c.name.toUpperCase())),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Mtek.gray100),
                itemBuilder: (context, i) {
                  final p = list[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: p.isOutOfStock
                          ? Mtek.dangerTint
                          : p.isLow
                              ? Mtek.warnTint
                              : Mtek.brandTint,
                      child: Text(
                        '${p.qtyOnHand}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: p.isOutOfStock ? Mtek.danger : p.isLow ? Mtek.warn : Mtek.brand600,
                        ),
                      ),
                    ),
                    title: Text(p.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${p.id} · ${p.category.name.toUpperCase()} · cost ${fmt.naira(p.costPrice)} · reorder @ ${p.reorderLevel}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AmountText(p.sellingPrice),
                        const SizedBox(width: 12),
                        // stock edits: CEO/Admin only (server-enforced too)
                        if (AuthStore.instance.isManagement)
                          IconButton(
                            tooltip: 'Adjust stock',
                            icon: const Icon(Icons.tune, color: Mtek.navy700),
                            onPressed: () => _adjustDialog(context, p),
                          ),
                      ],
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

  void _adjustDialog(BuildContext context, Product p) {
    final qtyCtrl = TextEditingController();
    AdjustmentReason reason = AdjustmentReason.restock;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Adjust — ${p.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Current: ${p.qtyOnHand} ${p.unit}', style: const TextStyle(color: Mtek.gray500)),
              const SizedBox(height: 12),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quantity change (use − for out)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AdjustmentReason>(
                value: reason,
                items: [
                  for (final r in AdjustmentReason.values)
                    DropdownMenuItem(value: r, child: Text(r.name.toUpperCase())),
                ],
                onChanged: (v) => setDialogState(() => reason = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final delta = int.tryParse(qtyCtrl.text) ?? 0;
                if (delta != 0) {
                  AppStore.instance.adjustStock(p, delta, reason, 'Manual adjustment');
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Stock adjusted (${delta >= 0 ? '+' : ''}$delta) — logged in audit trail.')));
                }
                Navigator.pop(context);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}
