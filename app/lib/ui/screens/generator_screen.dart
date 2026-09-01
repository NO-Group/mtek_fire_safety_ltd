import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../core/format.dart' as fmt;
import '../../core/theme.dart';
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Documents', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Mtek.ink)),
              SizedBox(height: 4),
              Text('Write up a receipt, invoice, MILS log, waybill or delivery note — PDF mirrors your paper books, signed & shared instantly',
                  style: TextStyle(color: Mtek.gray500)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: SegmentedButton<DocType>(
            segments: const [
              ButtonSegment(value: DocType.receipt, icon: Icon(Icons.receipt_long_outlined), label: Text('Receipt')),
              ButtonSegment(value: DocType.invoice, icon: Icon(Icons.request_quote_outlined), label: Text('Invoice')),
              ButtonSegment(value: DocType.mils, icon: Icon(Icons.build_circle_outlined), label: Text('MILS')),
              ButtonSegment(value: DocType.waybill, icon: Icon(Icons.local_shipping_outlined), label: Text('Waybill')),
              ButtonSegment(value: DocType.deliveryNote, icon: Icon(Icons.inventory_2_outlined), label: Text('Delivery')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
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
        Text(label, style: const TextStyle(color: Mtek.gray500, fontSize: 13)),
        const Spacer(),
        Text(value,
            style: TextStyle(fontSize: strong ? 17 : 14, fontWeight: FontWeight.w800, color: color ?? Mtek.ink)),
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
      const Text('PAYMENT METHOD', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
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
      const Text('ITEMISED LEDGER', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
      ..._invoiceFormRows(),
      TextButton.icon(
        onPressed: () => setState(() => _invoice.rows.add(LedgerRow())),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add row'),
      ),
      const SizedBox(height: 8),
      _summaryTile('Subtotal', fmt.naira(_invoice.subtotal)),
      _summaryTile('7.5% VAT', fmt.naira(_invoice.vat)),
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
            child: Row(children: [
              Expanded(
                flex: 4,
                child: TextFormField(
                  initialValue: _invoice.rows[i].description,
                  decoration: const InputDecoration(labelText: 'Description', isDense: true),
                  onChanged: (v) => _invoice.rows[i].description = v,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: _invoice.rows[i].qty == 1 ? '1' : _invoice.rows[i].qty.toString(),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                  onChanged: (v) => setState(() => _invoice.rows[i].qty = double.tryParse(v) ?? 0),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  initialValue: _invoice.rows[i].rate == 0 ? '' : _invoice.rows[i].rate.toString(),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Rate (₦)', isDense: true),
                  onChanged: (v) => setState(() => _invoice.rows[i].rate = double.tryParse(v) ?? 0),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: Text(fmt.naira(_invoice.rows[i].amount), textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: _invoice.rows.length > 1
                    ? () => setState(() => _invoice.rows.removeAt(i))
                    : null,
              ),
            ]),
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
      const Text('A — DESCRIPTION (EXTINGUISHERS BY WEIGHT)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
      _milsWeightGrid(),
      const SizedBox(height: 10),
      const Text('B — REPLACEMENT (COMPONENTS)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
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
      _summaryTile('Subtotal', fmt.naira(_mils.subtotal)),
      _summaryTile('VAT', fmt.naira(_mils.vat)),
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
        child: Column(
          children: [
            for (final wc in MtekForms.weightClasses)
              Row(children: [
                SizedBox(width: 52, child: Text(wc.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
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
                      textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w800)),
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
        ),
      ),
    );
  }

  Widget _milsComponentRow(String c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 90, child: Text(c, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        Expanded(
          child: TextFormField(
            initialValue: (_mils.componentQty[c] ?? 0).toString(),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Qty', isDense: true),
            onChanged: (v) => setState(() => _mils.componentQty[c] = double.tryParse(v) ?? 0),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: _mils.componentRate[c]?.toString() ?? '',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Rate (₦)', isDense: true),
            onChanged: (v) => setState(() => _mils.componentRate[c] = double.tryParse(v) ?? 0),
          ),
        ),
      ]),
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
      const Text('ITEMS — PRODUCTS / TECH. SPEC / BRAND / QTY',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
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
      const Text('SHIPPING ADDRESS',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
      const SizedBox(height: 6),
      _field(_dnLoc, 'Location', onChanged: (v) => _deliveryNote.location = v),
      Row(children: [
        Expanded(child: _field(_dnReceiver, 'Receiver', onChanged: (v) => _deliveryNote.receiver = v)),
        const SizedBox(width: 8),
        Expanded(child: _field(_dnReceiverNo, "Receiver's no.", keyboard: TextInputType.phone, onChanged: (v) => _deliveryNote.receiverNo = v)),
      ]),
      const SizedBox(height: 6),
      const Text('DELIVERY DETAILS',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
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
      const Text('ITEMS — DESCRIPTION / ORDERED / DELIVERED / OUTSTANDING',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Mtek.gray500)),
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
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(preview
            ? 'next: ${next.toString().padLeft(9, '0')}'
            : (assigned ?? next).toString().padLeft(9, '0'),
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const Spacer(),
        Text('books start at 000000001', style: TextStyle(fontSize: 10.5, color: Mtek.gray600)),
      ]),
    );
  }

  // ---------- validation → signature → PDF → share ----------

  Future<void> _generate() async {
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Mtek.danger,
        content: Text('Document NOT issued — '
            '${e.toString().replaceFirst('Exception: ', '')}'),
      ));
      return;
    }
    _receipt.serial = serial; _invoice.serial = serial; _mils.serial = serial;
    _waybill.serial = serial; _deliveryNote.serial = serial;

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
      total: docTotal,
      signedBy: signer.name,
      verifyHash: hash,
      serverIssued: Env.backendConfigured,
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

    final outcome = await dispatchPdf(bytes: bytes, filename: filename);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: outcome.result == ShareResult.failed ? Mtek.danger : Mtek.success,
      content: Text('✓ $docLabel No: $serial signed by ${signer.name} — ${outcome.message}'),
    ));
  }
}
