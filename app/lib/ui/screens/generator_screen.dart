import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
import '../widgets.dart';
import '../../data/auth_store.dart';
import '../../data/env.dart';
import '../../data/store.dart';
import '../signature_pad.dart';
import '../../documents/doc_models.dart';
import '../../documents/forms_spec.dart';
import '../../documents/pdf_painters.dart';
import '../../documents/pdf_shared.dart';
import '../../documents/serial_service.dart';
import '../../documents/share_service.dart';
import '../signature_dialog.dart';

/// DOCUMENT GENERATOR (SPEC §12, Phase A): document-type switcher →
/// per-type form state (context preserved) → validation → Signature
/// Passcode gate → PDF build → share via WhatsApp/email (fallback save).
class GeneratorScreen extends StatefulWidget {
  final DocType initialType;
  const GeneratorScreen({super.key, this.initialType = DocType.receipt});

  @override
  State<GeneratorScreen> createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  DocType _type = DocType.receipt;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  // One live form state per type — switching tabs keeps context.
  final ReceiptDocState _receipt = ReceiptDocState();
  final InvoiceDocState _invoice = InvoiceDocState();
  final MilsDocState _mils = MilsDocState();
  final WaybillDocState _waybill = WaybillDocState();
  final DeliveryNoteDocState _deliveryNote = DeliveryNoteDocState();

  final Map<DocType, String?> _errors = {
    DocType.receipt: null,
    DocType.invoice: null,
    DocType.mils: null,
    DocType.waybill: null,
    DocType.deliveryNote: null,
  };

  static const _labels = {
    DocType.receipt: 'Receipt',
    DocType.invoice: 'Invoice',
    DocType.mils: 'MILS',
    DocType.waybill: 'Waybill',
    DocType.deliveryNote: 'Delivery Note',
  };

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    // The Documents tab already sits inside the app shell's Scaffold. But
    // every "New receipt / New invoice / New MILS / New delivery note /
    // New waybill" button pushes this screen as a standalone route, where
    // there was NO Scaffold/Material ancestor at all — which is exactly what
    // produced the yellow double-underlined text, unstyled giant fonts and
    // crushed layouts. Give the standalone route its own Scaffold + AppBar.
    if (Scaffold.maybeOf(context) != null) return body;
    return Scaffold(
      backgroundColor: Mtek.gray50,
      appBar: AppBar(
        title: Text('New ${_labels[_type] ?? 'document'}'),
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _body(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: PageHeader(
            title: 'Documents',
            subtitle: 'Write up a receipt, invoice, MILS log, waybill or delivery note — signed & shared instantly',
            icon: Icons.draw,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          // Responsive type switcher: the 5-segment SegmentedButton is wider
          // than a phone screen and painted overflow stripes; narrow widths
          // get a wrapping chip row instead.
          child: LayoutBuilder(builder: (context, box) {
            const specs = <(DocType, IconData, String)>[
              (DocType.receipt, Icons.receipt_long_outlined, 'Receipt'),
              (DocType.invoice, Icons.request_quote_outlined, 'Invoice'),
              (DocType.mils, Icons.build_circle_outlined, 'MILS'),
              (DocType.waybill, Icons.local_shipping_outlined, 'Waybill'),
              (DocType.deliveryNote, Icons.inventory_2_outlined, 'Delivery'),
            ];
            if (box.maxWidth < 640) {
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (t, ic, lb) in specs)
                    ChoiceChip(
                      avatar: Icon(ic, size: 15, color: _type == t ? Mtek.brand600 : Mtek.gray500),
                      label: Text(lb),
                      selected: _type == t,
                      selectedColor: Mtek.brandTint,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                ],
              );
            }
            return SegmentedButton<DocType>(
              segments: [
                for (final (t, ic, lb) in specs)
                  ButtonSegment(value: t, icon: Icon(ic), label: Text(lb)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            );
          }),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ...switch (_type) {
                DocType.receipt => _receiptForm(),
                DocType.invoice => _invoiceForm(),
                DocType.mils => _milsForm(),
                DocType.waybill => _waybillForm(),
                DocType.deliveryNote => _deliveryNoteForm(),
              },
              if (_errors[_type] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_errors[_type]!,
                      style: const TextStyle(color: Mtek.danger, fontWeight: FontWeight.w600)),
                ),
              FilledButton.icon(
                icon: const Icon(Icons.draw_outlined),
                label: const Text('Sign & generate PDF'),
                onPressed: _generate,
              ),
              const SizedBox(height: 8),
              const Text(
                'Generation requires your Signature Passcode · PDF carries the corporate header, '
                'watermark, your signature stamp and a verification QR.',
                style: TextStyle(fontSize: 11, color: Mtek.gray500),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- shared field builders ----------

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
    String? hint,
    ValueChanged<String>? onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        enabled: enabled,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: onChanged,
      ),
    );
  }

  Widget _summaryTile(String label, String value, {Color? color, bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        // Flexible (not bare Text + Spacer) so a long label OR a long value
        // (e.g. "Amount in words") wraps instead of overflowing the row.
        Flexible(child: Text(label, style: const TextStyle(color: Mtek.gray500, fontSize: 13))),
        const SizedBox(width: 10),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: strong ? 17 : 14, fontWeight: FontWeight.w800, color: color ?? Mtek.ink)),
        ),
      ]),
    );
  }

  // ------- CUSTOMER / RECEIVER SIGNATURE (data URLs, stored with docs) -------

  String get _customerSigDataUrl => switch (_type) {
        DocType.receipt => _receipt.customerSignature,
        DocType.invoice => _invoice.customerSignature,
        DocType.waybill => _waybill.receiverSignature,
        DocType.deliveryNote => _deliveryNote.receiverSignature,
        DocType.mils => '',
      };

  void _setCustomerSig(String v) {
    switch (_type) {
      case DocType.receipt: _receipt.customerSignature = v;
      case DocType.invoice: _invoice.customerSignature = v;
      case DocType.waybill: _waybill.receiverSignature = v;
      case DocType.deliveryNote: _deliveryNote.receiverSignature = v;
      case DocType.mils: break;
    }
    setState(() {});
  }

  Future<void> _captureSignature(String label) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              SignaturePad(
                onDone: (bytes) {
                  if (bytes != null) {
                    _setCustomerSig('data:image/png;base64,${base64Encode(bytes)}');
                  }
                  Navigator.of(sheetCtx).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sigTile(String label) {
    final current = _customerSigDataUrl;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: current.isEmpty
            ? const Icon(Icons.draw, color: Mtek.navy700)
            : Image.memory(base64Decode(current.split(',').last), width: 64),
        title: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        subtitle: Text(current.isEmpty ? 'They sign here on the device — stored with the document'
                                        : 'Captured — tap to replace', style: const TextStyle(fontSize: 11)),
        trailing: TextButton(
          onPressed: () => _captureSignature(label),
          child: Text(current.isEmpty ? 'Capture' : 'Replace'),
        ),
      ),
    );
  }

  // ---------- RECEIPT ----------

  final _rName = TextEditingController(), _rAddr = TextEditingController(), _rPhone = TextEditingController(), _rEmail = TextEditingController(),
      _rAmount = TextEditingController(), _rFor = TextEditingController(), _rIrn = TextEditingController();

  List<Widget> _receiptForm() {
    return [
      _serialBanner('receipt', _receipt.serial),
      _field(_rIrn, 'IRN (Invoice Reference Number)', onChanged: (v) => _receipt.irn = v),
      _field(_rName, 'Customer name *', onChanged: (v) => _receipt.name = v),
      _field(_rAddr, 'Address', onChanged: (v) => _receipt.address = v),
      _field(_rPhone, 'Phone No. or Email (to send the PDF) *', keyboard: TextInputType.phone, onChanged: (v) => _receipt.phone = v),
      _field(_rEmail, 'Email (optional if phone given)', keyboard: TextInputType.emailAddress, onChanged: (v) => _receipt.customerEmail = v),
      _field(_rFor, 'Being Payment for', hint: 'e.g. Refill of 24 × 6kg extinguishers', onChanged: (v) => _receipt.beingPaymentFor = v),
      _field(_rAmount, 'The Sum of (₦) *', keyboard: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => setState(() => _receipt.amount = double.tryParse(v) ?? 0)),
      _sigTile("Customer's signature"),
      const SizedBox(height: 6),
      const SectionTitle('Payment method'),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        children: [
          for (final m in MtekForms.receiptMethods)
            ChoiceChip(
              label: Text(m),
              selected: _receipt.method == m,
              selectedColor: Mtek.brandTint,
              onSelected: (_) => setState(() => _receipt.method = m),
            ),
        ],
      ),
      const SizedBox(height: 10),
      _summaryTile('The Sum of (words)', _receipt.amountInWords, strong: true),
      _serialBanner('receipt', null, preview: true),
    ];
  }

  // ---------- INVOICE ----------

  final _iName = TextEditingController(), _iAddr = TextEditingController(), _iPhone = TextEditingController(), _iEmail = TextEditingController(),
      _iMils = TextEditingController(), _iRec = TextEditingController(), _iLpo = TextEditingController(),
      _iAdvance = TextEditingController();

  List<Widget> _invoiceForm() {
    return [
      _serialBanner('invoice', _invoice.serial),
      _sigTile("Customer's signature (assent)"),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final variant in MtekForms.invoiceVariants)
            ChoiceChip(
              label: Text(variant),
              selected: _invoice.variant == variant,
              selectedColor: Mtek.brandTint,
              onSelected: (_) => setState(() => _invoice.variant = variant),
            ),
          FilterChip(
            label: const Text('MILS No ref.'),
            selected: _invoice.showMilsNo,
            selectedColor: Mtek.goldTint,
            onSelected: (_) => setState(() => _invoice.showMilsNo = !_invoice.showMilsNo),
          ),
          FilterChip(
            label: const Text('Receipt No ref.'),
            selected: _invoice.showReceiptNo,
            selectedColor: Mtek.goldTint,
            onSelected: (_) => setState(() => _invoice.showReceiptNo = !_invoice.showReceiptNo),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (_invoice.showMilsNo) _field(_iMils, 'MILS No', onChanged: (v) => _invoice.milsNo = v),
      if (_invoice.showReceiptNo) _field(_iRec, 'Receipt No', onChanged: (v) => _invoice.receiptNo = v),
      _field(_iLpo, 'L.P.O. No', onChanged: (v) => _invoice.lpoNo = v),
      _field(_iName, 'Customer name *', onChanged: (v) => _invoice.name = v),
      _field(_iAddr, 'Address', onChanged: (v) => _invoice.address = v),
      _field(_iPhone, 'Phone No. or Email (to send the PDF) *', keyboard: TextInputType.phone, onChanged: (v) => _invoice.phone = v),
      _field(_iEmail, 'Email (optional if phone given)', keyboard: TextInputType.emailAddress, onChanged: (v) => _invoice.customerEmail = v),
      const SizedBox(height: 6),
      const SectionTitle('Itemised ledger'),
      ..._invoiceFormRows(),
      TextButton.icon(
        onPressed: () => setState(() => _invoice.rows.add(LedgerRow())),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add row'),
      ),
      const SizedBox(height: 8),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Apply 7.5% VAT to this document'),
        value: _invoice.vatEnabled,
        onChanged: (value) => setState(() => _invoice.vatEnabled = value),
      ),
      _summaryTile('Subtotal', fmt.naira(_invoice.subtotal)),
      if (_invoice.vatEnabled) _summaryTile('7.5% VAT', fmt.naira(_invoice.vat)),
      _summaryTile('GRAND TOTAL', fmt.naira(_invoice.grandTotal), strong: true, color: Mtek.brand700),
      _field(_iAdvance, 'Advance Payment (₦)', keyboard: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => setState(() => _invoice.advancePayment = double.tryParse(v) ?? 0)),
      _summaryTile('Balance Payment', fmt.naira(_invoice.balance), strong: true, color: Mtek.danger),
      _summaryTile('Amount in words', _invoice.amountInWords),
    ];
  }

  List<Widget> _invoiceFormRows() {
    return [
      for (var i = 0; i < _invoice.rows.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            // Responsive ledger row: the desktop one-line row (description +
            // qty + rate + amount + delete) needs ~520px; below that it
            // overflowed, so phones get a two-line layout instead.
            child: LayoutBuilder(builder: (context, box) {
              final row = _invoice.rows[i];
              final deleteBtn = IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: _invoice.rows.length > 1
                    ? () => setState(() => _invoice.rows.removeAt(i))
                    : null,
              );
              final amountText = () => Text(fmt.naira(row.amount),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13));
              if (box.maxWidth < 520) {
                return Column(
                  children: [
                    TextFormField(
                      initialValue: row.description,
                      decoration: const InputDecoration(labelText: 'Description', isDense: true),
                      onChanged: (v) => row.description = v,
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: row.qty == 1 ? '1' : row.qty.toString(),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                          onChanged: (v) => setState(() => row.qty = double.tryParse(v) ?? 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          initialValue: row.rate == 0 ? '' : row.rate.toString(),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Rate (₦)', isDense: true),
                          onChanged: (v) => setState(() => row.rate = double.tryParse(v) ?? 0),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: amountText()),
                      deleteBtn,
                    ]),
                  ],
                );
              }
              return Row(children: [
                Expanded(
                  flex: 4,
                  child: TextFormField(
                    initialValue: row.description,
                    decoration: const InputDecoration(labelText: 'Description', isDense: true),
                    onChanged: (v) => row.description = v,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: row.qty == 1 ? '1' : row.qty.toString(),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                    onChanged: (v) => setState(() => row.qty = double.tryParse(v) ?? 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    initialValue: row.rate == 0 ? '' : row.rate.toString(),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Rate (₦)', isDense: true),
                    onChanged: (v) => setState(() => row.rate = double.tryParse(v) ?? 0),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(width: 86, child: amountText()),
                deleteBtn,
              ]);
            }),
          ),
        ),
    ];
  }

  // ---------- MILS ----------

  final _mName = TextEditingController(), _mAddr = TextEditingController(), _mPhone = TextEditingController(), _mEmail = TextEditingController(),
      _mInvoiceNo = TextEditingController(), _mReceiptNo = TextEditingController(), _mLpo = TextEditingController(),
      _mAdvance = TextEditingController();

  List<Widget> _milsForm() {
    return [
      _serialBanner('mils', _mils.serial),
      Row(children: [
        Expanded(child: _dateTile('Entry Date', _mils.entryDate, (d) => _mils.entryDate = d)),
        const SizedBox(width: 8),
        Expanded(child: _dateTile('Collection Date', _mils.collectionDate, (d) => _mils.collectionDate = d)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _dateTile('Next Service Date', _mils.nextServiceDate, (d) => _mils.nextServiceDate = d)),
        const SizedBox(width: 8),
        Expanded(child: _field(_mLpo, 'LPO No.', onChanged: (v) => _mils.lpoNo = v)),
      ]),
      _field(_mInvoiceNo, 'Invoice No.', onChanged: (v) => _mils.invoiceNo = v),
      _field(_mReceiptNo, 'Receipt No.', onChanged: (v) => _mils.receiptNo = v),
      const SizedBox(height: 6),
      const SectionTitle('A — Description (extinguishers by weight)'),
      _milsWeightGrid(),
      const SizedBox(height: 10),
      const SectionTitle('B — Replacement (components)'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in MtekForms.components)
            FilterChip(
              label: Text(c),
              selected: (_mils.componentQty[c] ?? 0) > 0,
              selectedColor: Mtek.brandTint,
              onSelected: (on) => setState(() {
                _mils.componentQty[c] = on ? 1 : 0;
                if (!on) _mils.componentRate.remove(c);
              }),
            ),
        ],
      ),
      for (final c in MtekForms.components)
        if ((_mils.componentQty[c] ?? 0) > 0) _milsComponentRow(c),
      const SizedBox(height: 10),
      _field(_mName, "Customer's Name *", onChanged: (v) => _mils.name = v),
      _field(_mAddr, 'Address', onChanged: (v) => _mils.address = v),
      _field(_mPhone, 'Phone Number or Email (to send the PDF) *', keyboard: TextInputType.phone, onChanged: (v) => _mils.phone = v),
      _field(_mEmail, 'Email (optional if phone given)', keyboard: TextInputType.emailAddress, onChanged: (v) => _mils.customerEmail = v),
      const SizedBox(height: 6),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Apply 7.5% VAT to this document'),
        value: _mils.vatEnabled,
        onChanged: (value) => setState(() => _mils.vatEnabled = value),
      ),
      _summaryTile('Subtotal', fmt.naira(_mils.subtotal)),
      if (_mils.vatEnabled) _summaryTile('7.5% VAT', fmt.naira(_mils.vat)),
      _summaryTile('GRAND TOTAL', fmt.naira(_mils.grandTotal), strong: true, color: Mtek.brand700),
      _field(_mAdvance, 'Advance Payment (₦) — min 50% required by policy',
          keyboard: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => _mils.advancePayment = double.tryParse(v) ?? 0),
      _summaryTile('Balance Total', fmt.naira(_mils.balance), strong: true, color: Mtek.danger),
      _summaryTile('Bill in words', _mils.amountInWords),
    ];
  }

  Widget _milsWeightGrid() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        // Responsive: the single-line row (label + slider + qty + rate) needs
        // ~480px; phones get a two-line row so nothing overflows.
        child: LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 480;
          return Column(
            children: [
              for (final wc in MtekForms.weightClasses)
                if (narrow) ...[
                  Row(children: [
                    SizedBox(
                        width: 52,
                        child: Text(wc.label,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                    const Spacer(),
                    Text('${(_mils.weightQty[wc.kg] ?? 0).round()}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  Row(children: [
                    Expanded(
                      child: Slider(
                        value: _mils.weightQty[wc.kg] ?? 0,
                        min: 0,
                        max: 60,
                        divisions: 60,
                        label: '${(_mils.weightQty[wc.kg] ?? 0).round()}',
                        activeColor: Mtek.brand600,
                        onChanged: (v) => setState(() => _mils.weightQty[wc.kg] = v),
                      ),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        initialValue: _mils.weightRate[wc.kg]?.toString() ?? '',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Rate', isDense: true),
                        onChanged: (v) => _mils.weightRate[wc.kg] = double.tryParse(v) ?? 0,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                ] else
                  Row(children: [
                    SizedBox(
                        width: 52,
                        child: Text(wc.label,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                    Expanded(
                      child: Slider(
                        value: _mils.weightQty[wc.kg] ?? 0,
                        min: 0,
                        max: 60,
                        divisions: 60,
                        label: '${(_mils.weightQty[wc.kg] ?? 0).round()}',
                        activeColor: Mtek.brand600,
                        onChanged: (v) => setState(() => _mils.weightQty[wc.kg] = v),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text('${(_mils.weightQty[wc.kg] ?? 0).round()}',
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        initialValue: _mils.weightRate[wc.kg]?.toString() ?? '',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Rate', isDense: true),
                        onChanged: (v) => _mils.weightRate[wc.kg] = double.tryParse(v) ?? 0,
                      ),
                    ),
                  ]),
            ],
          );
        }),
      ),
    );
  }

  Widget _milsComponentRow(String c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LayoutBuilder(builder: (context, box) {
        final qtyField = TextFormField(
          initialValue: (_mils.componentQty[c] ?? 0).toString(),
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Qty', isDense: true),
          onChanged: (v) => setState(() => _mils.componentQty[c] = double.tryParse(v) ?? 0),
        );
        final rateField = Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: _mils.componentRate[c]?.toString() ?? '',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Rate (\u20a6)', isDense: true),
            onChanged: (v) => _mils.componentRate[c] = double.tryParse(v) ?? 0,
          ),
        );
        if (box.maxWidth < 400) {
          // Narrow: stacked label-over-fields so the 90px label never
          // squeezes the fields into an overflow.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 4),
              Row(children: [Expanded(child: qtyField), const SizedBox(width: 8), rateField]),
            ],
          );
        }
        return Row(children: [
          SizedBox(
              width: 90,
              child: Text(c, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
          Expanded(child: qtyField),
          const SizedBox(width: 8),
          rateField,
        ]);
      }),
    );
  }

  Widget _dateTile(String label, DateTime value, ValueChanged<DateTime> onPicked) {
    return Card(
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        title: Text(label, style: const TextStyle(fontSize: 11, color: Mtek.gray500)),
        subtitle: Text(fmt.fmtDate(value), style: const TextStyle(fontWeight: FontWeight.w700)),
        trailing: const Icon(Icons.calendar_month_outlined, size: 18),
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(2020),
            lastDate: DateTime(2035),
          );
          if (d != null) onPicked(d);
        },
      ),
    );
  }

  // ---------- WAYBILL ----------

  final _wbName = TextEditingController(), _wbAddr = TextEditingController(), _wbPhone = TextEditingController(), _wbEmail = TextEditingController(),
      _wbDest = TextEditingController(), _wbFrom = TextEditingController(), _wbMils = TextEditingController(),
      _wbRec = TextEditingController(), _wbInv = TextEditingController(), _wbLpo = TextEditingController(),
      _wbDriver = TextEditingController(), _wbDriverPhone = TextEditingController(), _wbVehicle = TextEditingController(),
      _wbPlate = TextEditingController(), _wbColour = TextEditingController(), _wbReceiver = TextEditingController(),
      _wbReceiverPhone = TextEditingController();

  List<Widget> _waybillForm() {
    return [
      _serialBanner('waybill', _waybill.serial),
      Row(children: [
        Expanded(child: _field(_wbMils, 'MILS NO', onChanged: (v) => _waybill.milsNo = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbRec, 'RECEIPT NO', onChanged: (v) => _waybill.receiptNo = v)),
      ]),
      Row(children: [
        Expanded(child: _field(_wbInv, 'INVOICE NO', onChanged: (v) => _waybill.invoiceNo = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbLpo, 'LPO NO', onChanged: (v) => _waybill.lpoNo = v)),
      ]),
      _field(_wbName, "Buyer's name *", onChanged: (v) => _waybill.name = v),
      _field(_wbAddr, 'Address', onChanged: (v) => _waybill.address = v),
      _field(_wbPhone, 'Phone no. or Email (to send the PDF) *', keyboard: TextInputType.phone, onChanged: (v) => _waybill.phone = v),
      _field(_wbEmail, 'Email (optional if phone given)', keyboard: TextInputType.emailAddress, onChanged: (v) => _waybill.customerEmail = v),
      const SizedBox(height: 6),
      const SectionTitle('Items — products / tech. spec / brand / qty'),
      const SizedBox(height: 6),
      for (var i = 0; i < _waybill.rows.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Product *'),
                controller: TextEditingController(text: _waybill.rows[i].product),
                onChanged: (v) => _waybill.rows[i].product = v,
              ),
              Row(children: [
                Expanded(child: TextField(
                  decoration: const InputDecoration(labelText: 'Tech. spec'),
                  controller: TextEditingController(text: _waybill.rows[i].techSpec),
                  onChanged: (v) => _waybill.rows[i].techSpec = v,
                )),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  decoration: const InputDecoration(labelText: 'Brand'),
                  controller: TextEditingController(text: _waybill.rows[i].brand),
                  onChanged: (v) => _waybill.rows[i].brand = v,
                )),
              ]),
              Row(children: [
                Expanded(child: TextField(
                  decoration: const InputDecoration(labelText: 'Qty'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  controller: TextEditingController(text: _waybill.rows[i].qty == 0 ? '' : '${_waybill.rows[i].qty}'),
                  onChanged: (v) => _waybill.rows[i].qty = double.tryParse(v) ?? 0,
                )),
                if (_waybill.rows.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close, color: Mtek.danger),
                    onPressed: () => setState(() => _waybill.rows.removeAt(i)),
                  ),
              ]),
            ]),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _waybill.rows.add(WaybillRow())),
          icon: const Icon(Icons.add),
          label: const Text('Add row'),
        ),
      ),
      _field(_wbFrom, 'Originating from', onChanged: (v) => _waybill.originatingFrom = v),
      _field(_wbDest, 'Destination *', onChanged: (v) => _waybill.destination = v),
      Row(children: [
        Expanded(child: _field(_wbDriver, "Driver's name", onChanged: (v) => _waybill.driverName = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbDriverPhone, 'Driver phone', keyboard: TextInputType.phone, onChanged: (v) => _waybill.driverPhone = v)),
      ]),
      Row(children: [
        Expanded(child: _field(_wbVehicle, "Vehicle's brand", onChanged: (v) => _waybill.vehicleBrand = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbPlate, 'Plate no.', onChanged: (v) => _waybill.plateNo = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbColour, 'Colour', onChanged: (v) => _waybill.colour = v)),
      ]),
      Row(children: [
        Expanded(child: _field(_wbReceiver, "Receiver's name", onChanged: (v) => _waybill.receiverName = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_wbReceiverPhone, 'Receiver phone', keyboard: TextInputType.phone, onChanged: (v) => _waybill.receiverPhone = v)),
      ]),
      _sigTile("Receiver's signature (signs at hand-over)"),
    ];
  }

  // ---------- DELIVERY NOTE ----------

  final _dnName = TextEditingController(), _dnInst = TextEditingController(), _dnAddr = TextEditingController(),
      _dnPhone = TextEditingController(), _dnEmail = TextEditingController(), _dnLoc = TextEditingController(), _dnReceiver = TextEditingController(),
      _dnReceiverNo = TextEditingController(), _dnProforma = TextEditingController(), _dnCustId = TextEditingController(),
      _dnDispatch = TextEditingController(), _dnMethod = TextEditingController(), _dnAcctNo = TextEditingController(),
      _dnAcctName = TextEditingController(), _dnBanker = TextEditingController(), _dnSummary = TextEditingController();

  List<Widget> _deliveryNoteForm() {
    return [
      _serialBanner('deliverynote', _deliveryNote.serial),
      _field(_dnName, "Customer's name *", onChanged: (v) => _deliveryNote.customerName = v),
      _field(_dnInst, 'Institution', onChanged: (v) => _deliveryNote.institution = v),
      _field(_dnAddr, 'Address', onChanged: (v) => _deliveryNote.address = v),
      _field(_dnPhone, 'Phone no. or Email (to send the PDF) *', keyboard: TextInputType.phone, onChanged: (v) => _deliveryNote.phone = v),
      _field(_dnEmail, 'Email (optional if phone given)', keyboard: TextInputType.emailAddress, onChanged: (v) => _deliveryNote.customerEmail = v),
      const SizedBox(height: 6),
      const SectionTitle('Shipping address'),
      const SizedBox(height: 6),
      _field(_dnLoc, 'Location', onChanged: (v) => _deliveryNote.location = v),
      Row(children: [
        Expanded(child: _field(_dnReceiver, 'Receiver', onChanged: (v) => _deliveryNote.receiver = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_dnReceiverNo, "Receiver's no.", keyboard: TextInputType.phone, onChanged: (v) => _deliveryNote.receiverNo = v)),
      ]),
      const SizedBox(height: 6),
      const SectionTitle('Delivery details'),
      const SizedBox(height: 6),
      _dateTile('Date of Order', _deliveryNote.orderDate, (d) => _deliveryNote.orderDate = d),
      Row(children: [
        Expanded(child: _field(_dnProforma, 'Proforma Invoice ID', onChanged: (v) => _deliveryNote.proformaInvoiceId = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_dnCustId, "Customer's ID", onChanged: (v) => _deliveryNote.customerId = v)),
      ]),
      Row(children: [
        Expanded(child: _field(_dnDispatch, 'Dispatch', onChanged: (v) => _deliveryNote.dispatch = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_dnMethod, 'Delivery Method', onChanged: (v) => _deliveryNote.deliveryMethod = v)),
      ]),
      Row(children: [
        Expanded(child: _field(_dnAcctNo, 'Account No.', onChanged: (v) => _deliveryNote.accountNo = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_dnAcctName, 'Account Name', onChanged: (v) => _deliveryNote.accountName = v)),
      ]),
      _field(_dnBanker, 'Banker', onChanged: (v) => _deliveryNote.banker = v),
      const SizedBox(height: 6),
      const SectionTitle('Items — ordered / delivered / outstanding'),
      const SizedBox(height: 6),
      for (var i = 0; i < _deliveryNote.rows.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Description *'),
                controller: TextEditingController(text: _deliveryNote.rows[i].description),
                onChanged: (v) => _deliveryNote.rows[i].description = v,
              ),
              Row(children: [
                for (final (label, key) in const [('Ordered', 'o'), ('Delivered', 'd'), ('Outstanding', 'x')])
                  Expanded(child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TextField(
                      decoration: InputDecoration(labelText: label),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (v) {
                        final n = double.tryParse(v) ?? 0;
                        if (key == 'o') _deliveryNote.rows[i].ordered = n;
                        if (key == 'd') _deliveryNote.rows[i].delivered = n;
                        if (key == 'x') _deliveryNote.rows[i].outstanding = n;
                      },
                    ),
                  )),
                if (_deliveryNote.rows.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close, color: Mtek.danger),
                    onPressed: () => setState(() => _deliveryNote.rows.removeAt(i)),
                  ),
              ]),
            ]),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _deliveryNote.rows.add(DeliveryNoteRow())),
          icon: const Icon(Icons.add),
          label: const Text('Add row'),
        ),
      ),
      _field(_dnSummary, 'Summary', onChanged: (v) => _deliveryNote.summary = v),
      _sigTile("Client's signature (acknowledges receipt of the goods)"),
    ];
  }

  Widget _serialBanner(String type, int? assigned, {bool preview = false}) {
    final label = switch (type) {
      'receipt' => 'Receipt No',
      'invoice' => 'Invoice No',
      'waybill' => 'Waybill No',
      'deliverynote' => 'Delivery Note No',
      _ => 'MILS No',
    };
    final next = SerialService.instance.current(type) + 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Mtek.goldTint, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        const Icon(Icons.tag, size: 15, color: Mtek.warn),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(
                text: preview
                    ? 'next: ${next.toString().padLeft(9, '0')}'
                    : (assigned ?? next).toString().padLeft(9, '0'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ]),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text('books start at 000000001',
              style: const TextStyle(fontSize: 10.5, color: Mtek.gray600),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }

  // ---------- validation → signature → PDF → share ----------

  /// Copies every field controller's current text into the form models,
  /// immediately before validation. Android autofill and some IMEs can
  /// commit text into a [TextField] WITHOUT firing [TextField.onChanged],
  /// which previously left the models stale (e.g. an autofilled customer
  /// name validated as "required" even though the field visibly held text).
  /// Reading the controllers directly here makes generation see exactly
  /// what is on screen.
  void _syncControllersToModel() {
    // Receipt
    _receipt.irn = _rIrn.text;
    _receipt.name = _rName.text;
    _receipt.address = _rAddr.text;
    _receipt.phone = _rPhone.text;
    _receipt.customerEmail = _rEmail.text;
    _receipt.beingPaymentFor = _rFor.text;
    _receipt.amount = double.tryParse(_rAmount.text) ?? 0;

    // Invoice
    _invoice.name = _iName.text;
    _invoice.address = _iAddr.text;
    _invoice.phone = _iPhone.text;
    _invoice.customerEmail = _iEmail.text;
    _invoice.milsNo = _iMils.text;
    _invoice.receiptNo = _iRec.text;
    _invoice.lpoNo = _iLpo.text;
    _invoice.advancePayment = double.tryParse(_iAdvance.text) ?? 0;

    // MILS
    _mils.name = _mName.text;
    _mils.address = _mAddr.text;
    _mils.phone = _mPhone.text;
    _mils.customerEmail = _mEmail.text;
    _mils.invoiceNo = _mInvoiceNo.text;
    _mils.receiptNo = _mReceiptNo.text;
    _mils.lpoNo = _mLpo.text;
    _mils.advancePayment = double.tryParse(_mAdvance.text) ?? 0;

    // Waybill
    _waybill.name = _wbName.text;
    _waybill.address = _wbAddr.text;
    _waybill.phone = _wbPhone.text;
    _waybill.customerEmail = _wbEmail.text;
    _waybill.destination = _wbDest.text;
    _waybill.originatingFrom = _wbFrom.text;
    _waybill.milsNo = _wbMils.text;
    _waybill.receiptNo = _wbRec.text;
    _waybill.invoiceNo = _wbInv.text;
    _waybill.lpoNo = _wbLpo.text;
    _waybill.driverName = _wbDriver.text;
    _waybill.driverPhone = _wbDriverPhone.text;
    _waybill.vehicleBrand = _wbVehicle.text;
    _waybill.plateNo = _wbPlate.text;
    _waybill.colour = _wbColour.text;
    _waybill.receiverName = _wbReceiver.text;
    _waybill.receiverPhone = _wbReceiverPhone.text;

    // Delivery note
    _deliveryNote.customerName = _dnName.text;
    _deliveryNote.institution = _dnInst.text;
    _deliveryNote.address = _dnAddr.text;
    _deliveryNote.phone = _dnPhone.text;
    _deliveryNote.customerEmail = _dnEmail.text;
    _deliveryNote.location = _dnLoc.text;
    _deliveryNote.receiver = _dnReceiver.text;
    _deliveryNote.receiverNo = _dnReceiverNo.text;
    _deliveryNote.proformaInvoiceId = _dnProforma.text;
    _deliveryNote.customerId = _dnCustId.text;
    _deliveryNote.dispatch = _dnDispatch.text;
    _deliveryNote.deliveryMethod = _dnMethod.text;
    _deliveryNote.accountNo = _dnAcctNo.text;
    _deliveryNote.accountName = _dnAcctName.text;
    _deliveryNote.banker = _dnBanker.text;
    _deliveryNote.summary = _dnSummary.text;
  }

  Future<void> _generate() async {
    // Autofill/IME may have filled fields without firing onChanged — make
    // the models reflect what's on screen before any validation runs.
    _syncControllersToModel();
    String? contactError(String phone, String email) =>
        (phone.trim().isEmpty && email.trim().isEmpty)
            ? 'Add the customer\u2019s phone or email \u2014 the PDF is sent to them.'
            : null;
    final err = switch (_type) {
      DocType.receipt => _receipt.valid
          ? contactError(_receipt.phone, _receipt.customerEmail)
          : 'Customer name and a valid amount are required.',
      DocType.invoice => _invoice.valid
          ? contactError(_invoice.phone, _invoice.customerEmail)
          : 'Customer name and at least one line item (description + amount) are required.',
      DocType.mils => _mils.valid
          ? contactError(_mils.phone, _mils.customerEmail)
          : "Customer's name and at least one weight entry or component are required.",
      DocType.waybill => _waybill.valid
          ? contactError(_waybill.phone, _waybill.customerEmail)
          : "Buyer's name, destination and at least one product are required.",
      DocType.deliveryNote => _deliveryNote.valid
          ? contactError(_deliveryNote.phone, _deliveryNote.customerEmail)
          : "Customer's name and at least one item description are required.",
    };
    setState(() => _errors[_type] = err);
    if (err != null) return;

    final signer = await confirmSignature(context);
    if (signer == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not signed — document NOT issued.')));
      }
      return;
    }

    // serial assignment — SERVER-assigned when the backend is configured
    // (atomic RPC; passcode re-verified against bcrypt server-side). Local
    // counter keeps offline development usable.
    final typeKey = switch (_type) {
      DocType.receipt => 'receipt',
      DocType.invoice => 'invoice',
      DocType.mils => 'mils',
      DocType.waybill => 'waybill',
      DocType.deliveryNote => 'deliverynote',
    };
    final customer = switch (_type) {
      DocType.receipt => _receipt.name,
      DocType.invoice => _invoice.name,
      DocType.mils => _mils.name,
      DocType.waybill => _waybill.name,
      DocType.deliveryNote => _deliveryNote.customerName,
    };
    final docTotal = switch (_type) {
      DocType.receipt => _receipt.amount,
      DocType.invoice => _invoice.grandTotal,
      DocType.mils => _mils.grandTotal,
      DocType.waybill => 0.0,
      DocType.deliveryNote => 0.0,
    };
    final contact = switch (_type) {
      DocType.receipt => _receipt.phone.trim().isNotEmpty ? _receipt.phone.trim() : _receipt.customerEmail.trim(),
      DocType.invoice => _invoice.phone.trim().isNotEmpty ? _invoice.phone.trim() : _invoice.customerEmail.trim(),
      DocType.mils => _mils.phone.trim().isNotEmpty ? _mils.phone.trim() : _mils.customerEmail.trim(),
      DocType.waybill => _waybill.phone.trim().isNotEmpty ? _waybill.phone.trim() : _waybill.customerEmail.trim(),
      DocType.deliveryNote => _deliveryNote.phone.trim().isNotEmpty ? _deliveryNote.phone.trim() : _deliveryNote.customerEmail.trim(),
    };
    final int serial;
    try {
      serial = await AppStore.instance.nextDocSerial(
        type: typeKey,
        customer: customer,
        total: docTotal,
        passcode: AuthStore.instance.lastVerifiedPasscode ?? '',
        contact: contact,
      );
    } catch (e) {
      // Full detail goes to the console only — never onto a production
      // screen. Only our own human-readable [Exception] messages are shown;
      // anything unexpected collapses to a single friendly line.
      debugPrint('Document generation failed: $e');
      if (!mounted) return;
      final msg = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Mtek.danger,
        content: Text(msg.isEmpty
            ? 'Document NOT issued — please try again.'
            : 'Document NOT issued — $msg'),
      ));
      return;
    }
    _receipt.serial = serial; _invoice.serial = serial; _mils.serial = serial;
    _waybill.serial = serial; _deliveryNote.serial = serial;

    final docLabel = switch (_type) {
      DocType.receipt => 'Payment Receipt',
      DocType.invoice => 'Invoice',
      DocType.mils => 'Maintenance Information Log Sheet (MILS)',
      DocType.waybill => 'Waybill',
      DocType.deliveryNote => 'Delivery Note',
    };
    final filename = 'mtek_${typeKey}_$serial'
        '_${DateTime.now().millisecondsSinceEpoch}.pdf';

    // persist into the document history ledger (offline-first; syncs later)
    final hash = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    await AppStore.instance.issueDocument(
      type: typeKey,
      serial: serial,
      customer: customer,
      customerContact: contact,
      total: docTotal,
      signedBy: signer.name,
      verifyHash: hash,
      serverIssued: Env.apiConfigured,
    );

    if (_type == DocType.mils) {
      // A completed MILS sheet IS a maintenance job — feeds the MILS
      // screen's overdue/upcoming tracking and Insights' serviced-by-weight.
      final equipmentParts = <String>[
        for (final e in _mils.servicedByWeight.entries) '${e.key}kg ×${e.value.round()}',
        for (final c in _mils.componentQty.entries.where((e) => e.value > 0))
          '${c.key} ×${c.value.round()}',
      ];
      await AppStore.instance.logMaintenance(
        equipment: equipmentParts.isEmpty ? 'Fire extinguisher service' : equipmentParts.join(', '),
        serial: 'MILS-${serial.toString().padLeft(9, '0')}',
        client: Customer(id: customer, name: customer, isCorporate: false,
            phone: _mils.phone, email: _mils.customerEmail, address: _mils.address),
        location: _mils.address,
        action: MaintenanceAction.refill,
        findings: 'Serviced per MILS-${serial.toString().padLeft(9, '0')}',
        technician: signer.name,
        serviceDate: _mils.entryDate,
        nextDue: _mils.nextServiceDate,
        milsNo: 'MILS-${serial.toString().padLeft(9, '0')}',
      );
    }

    // Build the PDF and hand it to the share sheet — guarded so a PDF
    // build/export failure shows one friendly line instead of crashing.
    try {
      final logoBytes = await rootBundle.load('assets/branding/logo.png');
      final signatureBytes = dataUrlToBytes(signer.signaturePng);
      final bytes = await buildDocument(
        switch (_type) {
          DocType.receipt => GeneratedDoc.receipt,
          DocType.invoice => GeneratedDoc.invoice,
          DocType.mils => GeneratedDoc.mils,
          DocType.waybill => GeneratedDoc.waybill,
          DocType.deliveryNote => GeneratedDoc.deliveryNote,
        },
        logoBytes: logoBytes.buffer.asUint8List(),
        receipt: _receipt,
        invoice: _invoice,
        mils: _mils,
        waybill: _waybill,
        deliveryNote: _deliveryNote,
        signedBy: signer.name,
        signaturePngBytes: signatureBytes,
        customerSignaturePngBytes: dataUrlToBytes(_customerSigDataUrl),
      );

      if (!mounted) return;
      // The PDF is built — offer BOTH an explicit Share button (share sheet:
      // WhatsApp / Gmail / Drive…) and a Download button (saves the file),
      // instead of auto-opening the share sheet.
      _showPdfReady(
        bytes: bytes,
        filename: filename,
        docLabel: docLabel,
        serial: serial,
        signerName: signer.name,
      );
    } catch (e) {
      debugPrint('Document PDF build/export failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: Mtek.danger,
        duration: Duration(seconds: 6),
        content: Text('Document recorded, but the PDF could not be generated — '
            'open it again from Documents history to retry.'),
      ));
    }
  }

  /// Bottom sheet shown once a document PDF is built — the document was
  /// already recorded; this lets the user pick Share (share sheet) or
  /// Download (save the file) with one tap each.
  void _showPdfReady({
    required Uint8List bytes,
    required String filename,
    required String docLabel,
    required int serial,
    required String signerName,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: Mtek.brandGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.picture_as_pdf_outlined, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(docLabel,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('No: $serial · signed by $signerName',
                            style: const TextStyle(color: Mtek.gray500, fontSize: 12.5)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Share PDF'),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  _sharePdf(bytes, filename);
                },
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Download PDF'),
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  _downloadPdf(bytes, filename);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sharePdf(Uint8List bytes, String filename) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await dispatchPdf(bytes: bytes, filename: filename);
      messenger.showSnackBar(SnackBar(
        backgroundColor: outcome.result == ShareResult.failed ? Mtek.danger : Mtek.success,
        content: Text(outcome.message),
      ));
    } catch (e) {
      debugPrint('Share failed: $e');
      messenger.showSnackBar(const SnackBar(
          backgroundColor: Mtek.danger,
          content: Text('Could not share the PDF — please try again.')));
    }
  }

  Future<void> _downloadPdf(Uint8List bytes, String filename) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await savePdf(bytes: bytes, filename: filename);
      messenger.showSnackBar(SnackBar(
        backgroundColor: outcome.result == ShareResult.failed ? Mtek.danger : Mtek.success,
        content: Text(outcome.message),
      ));
    } catch (e) {
      debugPrint('Download failed: $e');
      messenger.showSnackBar(const SnackBar(
          backgroundColor: Mtek.danger,
          content: Text('Could not download the PDF — please try again.')));
    }
  }
}
