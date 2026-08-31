import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/auth_store.dart';
import '../../data/store.dart';
import '../signature_dialog.dart';
import '../signature_pad.dart';
import '../widgets.dart';

/// SALES — the POS screen. Complete a sale → stock decremented, and a
/// Transaction + Receipt are issued (or an Invoice, if credit).
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  final Map<String, SaleItem> _cart = {};
  Customer? _customer;
  PaymentMethod _method = PaymentMethod.cash;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final sellable = store.products.where((p) => !p.isOutOfStock || p.isService);
    final subtotal = _cart.values.fold(0, (s, i) => s + i.total);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final catalogue = _catalogueList(sellable);
      final cartPanel = _cartPanel(store, subtotal);

      return Padding(
        padding: const EdgeInsets.all(20),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: catalogue),
                  const SizedBox(width: 16),
                  SizedBox(width: 380, child: cartPanel),
                ],
              )
            : Column(
                children: [
                  Expanded(child: catalogue),
                  cartPanel,
                ],
              ),
      );
    });
  }

  Widget _catalogueList(Iterable<Product> sellable) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeader(title: 'Sales', subtitle: 'Pick items — stock & receipts update automatically'),
        const SizedBox(height: 14),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              itemCount: sellable.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Mtek.gray100),
              itemBuilder: (context, i) {
                final p = sellable.elementAt(i);
                final inCart = _cart[p.id]?.qty ?? 0;
                return ListTile(
                  enabled: !p.isOutOfStock,
                  leading: CircleAvatar(
                    backgroundColor: Mtek.brandTint,
                    child: Text(p.name.substring(0, 1), style: const TextStyle(color: Mtek.brand600, fontWeight: FontWeight.w700)),
                  ),
                  title: Text(p.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text('${p.id} · ${p.isService ? "service" : "${p.qtyOnHand} ${p.unit} in stock"} · ${fmt.naira(p.sellingPrice)}'),
                  trailing: inCart == 0
                      ? IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Mtek.brand600),
                          tooltip: 'Add to cart',
                          onPressed: p.isOutOfStock ? null : () => _add(p),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => _remove(p)),
                            Text('$inCart', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                            IconButton(icon: const Icon(Icons.add_circle_outline, color: Mtek.brand600), onPressed: () => _add(p)),
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _cartPanel(AppStore store, int subtotal) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_cart_outlined, size: 18),
                const SizedBox(width: 8),
                Text('CURRENT SALE (${_cart.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                const Spacer(),
                if (_cart.isNotEmpty)
                  TextButton(onPressed: () => setState(() => _cart.clear()), child: const Text('Clear')),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<Customer>(
              value: _customer,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: [
                for (final c in store.customers)
                  DropdownMenuItem(value: c, child: Text(c.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (c) => setState(() => _customer = c),
            ),
            const SizedBox(height: 12),
            ..._cart.values.map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${i.product.name} ×${i.qty}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      AmountText(i.total, bold: false),
                    ],
                  ),
                )),
            if (_cart.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: EmptyHint('Tap + on items to start a sale'),
              ),
            const Spacer(),
            const Divider(),
            Row(
              children: [
                const Text('Subtotal', style: TextStyle(color: Mtek.gray500)),
                const Spacer(),
                AmountText(subtotal),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final m in PaymentMethod.values)
                  ChoiceChip(
                    label: Text(MethodIcon.label(m)),
                    selected: _method == m,
                    selectedColor: Mtek.brandTint,
                    onSelected: (_) => setState(() => _method = m),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_cart.isEmpty || _customer == null) ? null : _complete,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(_method == PaymentMethod.credit
                    ? 'Complete — bill on invoice'
                    : 'Complete sale — ${fmt.naira(subtotal)}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _add(Product p) {
    setState(() {
      final existing = _cart[p.id];
      if (existing != null) {
        _cart[p.id] = SaleItem(product: p, qty: existing.qty + 1);
      } else {
        _cart[p.id] = SaleItem(product: p, qty: 1);
      }
    });
  }

  void _remove(Product p) {
    setState(() {
      final existing = _cart[p.id];
      if (existing == null) return;
      if (existing.qty <= 1) {
        _cart.remove(p.id);
      } else {
        _cart[p.id] = SaleItem(product: p, qty: existing.qty - 1);
      }
    });
  }

  Future<void> _complete() async {
    final signer = await confirmSignature(context);
    if (signer == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not signed — sale not issued.')));
      }
      return;
    }
    // CUSTOMER SIGNS TOO (optional when absent): captured on the device and
    // stored with the sale + receipt — proof of purchase on the PDF.
    final customerSig = await _captureCustomerSignature();
    final store = AppStore.instance;
    await store.completeSale(
      customer: _customer!,
      items: _cart.values.toList(),
      method: _method,
      signedBy: signer.name,
      customerSignature: customerSig,
      passcode: AuthStore.instance.lastVerifiedPasscode,
    );
    setState(() => _cart.clear());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: Mtek.success,
      content: Text(_method == PaymentMethod.credit
          ? 'Invoice created & signed by ${signer.name} — payable later, stock deducted.'
          : 'Sale complete — receipt signed by ${signer.name}, stock updated.'),
    ));
  }

  /// Customer signs on the device (skippable when they're not present).
  Future<String?> _captureCustomerSignature() async {
    String? captured;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Customer's signature",
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('Proof of purchase — printed on the receipt. You may skip.',
                  style: TextStyle(fontSize: 11.5, color: Mtek.gray500)),
              const SizedBox(height: 12),
              SignaturePad(
                onDone: (bytes) {
                  if (bytes != null) {
                    captured = 'data:image/png;base64,${base64Encode(bytes)}';
                  }
                  Navigator.of(sheetCtx).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
    return captured;
  }
}
