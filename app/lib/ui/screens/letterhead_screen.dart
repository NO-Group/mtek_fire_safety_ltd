import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme.dart';
import '../../data/auth_store.dart';
import '../../data/local_store.dart';
import '../../documents/pdf_shared.dart';
import '../../documents/share_service.dart';
import '../widgets.dart';

/// CEO-only official letter composer. Drafts remain on-device until exported.
class LetterheadScreen extends StatefulWidget {
  const LetterheadScreen({super.key});

  @override
  State<LetterheadScreen> createState() => _LetterheadScreenState();
}

class _LetterheadScreenState extends State<LetterheadScreen> {
  static const _draftKey = 'ceo_letterhead_draft';
  final _recipient = TextEditingController();
  final _address = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _closing = TextEditingController(text: 'Yours faithfully,');
  Timer? _saveTimer;
  bool _bold = false, _italic = false, _underline = false, _busy = false;
  double _fontSize = 11;
  TextAlign _alignment = TextAlign.left;
  final List<List<TextEditingController>> _table = [];

  @override
  void initState() {
    super.initState();
    for (final c in [_recipient, _address, _subject, _body, _closing]) {
      c.addListener(_scheduleSave);
    }
    unawaited(_restore());
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() => localWrite(_draftKey, jsonEncode({
        'recipient': _recipient.text, 'address': _address.text,
        'subject': _subject.text, 'body': _body.text, 'closing': _closing.text,
        'bold': _bold, 'italic': _italic, 'underline': _underline,
        'fontSize': _fontSize, 'alignment': _alignment.name,
      }));

  Future<void> _restore() async {
    final raw = await localRead(_draftKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final d = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _recipient.text = '${d['recipient'] ?? ''}';
      _address.text = '${d['address'] ?? ''}';
      _subject.text = '${d['subject'] ?? ''}';
      _body.text = '${d['body'] ?? ''}';
      _closing.text = '${d['closing'] ?? 'Yours faithfully,'}';
      _bold = d['bold'] == true; _italic = d['italic'] == true;
      _underline = d['underline'] == true;
      _fontSize = (d['fontSize'] as num?)?.toDouble() ?? 11;
      _alignment = TextAlign.values.firstWhere(
        (a) => a.name == d['alignment'], orElse: () => TextAlign.left);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_save());
    for (final c in [_recipient, _address, _subject, _body, _closing]) {
      c.dispose();
    }
    for (final row in _table) { for (final c in row) { c.dispose(); } }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthStore.instance.isCeo) {
      return const Center(child: Text('Only the CEO can compose official letters.'));
    }
    final style = TextStyle(
      fontSize: _fontSize,
      fontWeight: _bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
      decoration: _underline ? TextDecoration.underline : TextDecoration.none,
    );
    return ListView(padding: const EdgeInsets.all(20), children: [
      PageHeader(
        title: 'Official Letterhead',
        subtitle: 'Compose, preview, download and share company letters',
        icon: Icons.article_outlined,
        actions: [
          OutlinedButton.icon(onPressed: _busy ? null : _preview,
              icon: const Icon(Icons.print_outlined), label: const Text('Print')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _busy ? null : _share,
              icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Share PDF')),
        ],
      ),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        Row(children: [
          Expanded(child: TextField(controller: _recipient,
              decoration: const InputDecoration(labelText: 'Recipient / organisation'))),
          const SizedBox(width: 10),
          SizedBox(width: 180, child: TextField(
              decoration: const InputDecoration(labelText: 'Date'),
              controller: TextEditingController(text: _date(DateTime.now())), readOnly: true)),
        ]),
        TextField(controller: _address, maxLines: 2,
            decoration: const InputDecoration(labelText: 'Recipient address')),
        TextField(controller: _subject,
            decoration: const InputDecoration(labelText: 'Subject / reference')),
      ]))),
      const SizedBox(height: 12),
      Card(child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 4), child: Wrap(
          spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _toggle(Icons.format_bold, _bold, () => _bold = !_bold, 'Bold'),
            _toggle(Icons.format_italic, _italic, () => _italic = !_italic, 'Italic'),
            _toggle(Icons.format_underlined, _underline, () => _underline = !_underline, 'Underline'),
            const SizedBox(width: 8),
            for (final a in [TextAlign.left, TextAlign.center, TextAlign.right, TextAlign.justify])
              _toggle(_alignIcon(a), _alignment == a, () => _alignment = a, a.name),
            const SizedBox(width: 8),
            IconButton(tooltip: 'Insert table', icon: const Icon(Icons.table_chart_outlined),
              onPressed: () => setState(() {
                if (_table.isEmpty) _table.addAll(List.generate(3, (_) => List.generate(3, (_) => TextEditingController())));
              })),
            DropdownButton<double>(value: _fontSize,
              items: [9, 10, 11, 12, 14, 16, 18].map((s) =>
                DropdownMenuItem(value: s.toDouble(), child: Text('${s}pt'))).toList(),
              onChanged: (v) => setState(() { _fontSize = v ?? 11; _scheduleSave(); })),
          ],
        )),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.all(16), child: TextField(
          controller: _body, minLines: 16, maxLines: null,
          textAlign: _alignment, style: style,
          decoration: const InputDecoration(border: InputBorder.none,
            hintText: 'Write the official letter here...'),
        )),
      ])),
      if (_table.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [
          for (final row in _table) Row(children: [for (final cell in row)
            Expanded(child: Padding(padding: const EdgeInsets.all(2), child: TextField(
              controller: cell, decoration: const InputDecoration(isDense: true, hintText: 'Table cell'))))]),
          Row(children: [TextButton.icon(onPressed: () => setState(() => _table.add(
            List.generate(_table.first.length, (_) => TextEditingController()))), icon: const Icon(Icons.add), label: const Text('Add row')),
            TextButton.icon(onPressed: () => setState(() { for (final row in _table) { row.add(TextEditingController()); } }), icon: const Icon(Icons.view_column_outlined), label: const Text('Add column')),
            const Spacer(), IconButton(tooltip: 'Remove table', onPressed: () => setState(() { for (final row in _table) { for (final c in row) { c.dispose(); } } _table.clear(); }), icon: const Icon(Icons.delete_outline))])
        ]))),
      ],
      const SizedBox(height: 12),
      TextField(controller: _closing, maxLines: 3,
          decoration: const InputDecoration(labelText: 'Closing / sign-off')),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(onPressed: _busy ? null : _download,
            icon: const Icon(Icons.download_outlined), label: const Text('Download PDF')),
        const Spacer(),
        TextButton.icon(onPressed: _clear,
            icon: const Icon(Icons.delete_outline), label: const Text('Clear draft')),
      ]),
    ]);
  }

  Widget _toggle(IconData icon, bool selected, VoidCallback change, String tip) =>
      IconButton(tooltip: tip, isSelected: selected, icon: Icon(icon), onPressed: () {
        setState(change); _scheduleSave();
      });

  IconData _alignIcon(TextAlign a) => switch (a) {
    TextAlign.center => Icons.format_align_center,
    TextAlign.right => Icons.format_align_right,
    TextAlign.justify => Icons.format_align_justify,
    _ => Icons.format_align_left,
  };

  Future<Uint8List?> _bytes() async {
    if (_body.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write the letter before creating the PDF.')));
      return null;
    }
    setState(() => _busy = true);
    try {
      await MtekPdfFonts.load();
      final logoData = await rootBundle.load('assets/branding/logo.png');
      final logo = pw.MemoryImage(logoData.buffer.asUint8List());
      final pdf = pw.Document();
      final align = switch (_alignment) {
        TextAlign.center => pw.TextAlign.center,
        TextAlign.right => pw.TextAlign.right,
        TextAlign.justify => pw.TextAlign.justify,
        _ => pw.TextAlign.left,
      };
      pdf.addPage(pw.MultiPage(
        pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(36, 24, 36, 36),
          theme: pw.ThemeData.withFont(base: MtekPdfFonts.base, bold: MtekPdfFonts.bold),
          buildBackground: (_) => documentBackground(logo, PdfPageFormat.a4)),
        header: (_) => pw.Column(children: [corporateHeader(logo), pw.SizedBox(height: 16)]),
        footer: (c) => pw.Align(alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600))),
        build: (_) => [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text(_date(DateTime.now()))),
            if (_recipient.text.trim().isNotEmpty) ...[
              pw.SizedBox(height: 18), pw.Text(_recipient.text, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            ],
            if (_address.text.trim().isNotEmpty) pw.Text(_address.text),
            if (_subject.text.trim().isNotEmpty) ...[
              pw.SizedBox(height: 18),
              pw.Container(width: double.infinity, child: pw.Text(_subject.text.toUpperCase(), textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline))),
            ],
          ]),
          pw.SizedBox(height: 16),
          pw.Text(_body.text, textAlign: align,
            style: pw.TextStyle(fontSize: _fontSize, fontWeight: _bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              fontStyle: _italic ? pw.FontStyle.italic : pw.FontStyle.normal,
              decoration: _underline ? pw.TextDecoration.underline : null, lineSpacing: 3)),
          if (_table.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.TableHelper.fromTextArray(
              data: [for (final row in _table) [for (final cell in row) cell.text]],
              border: pw.TableBorder.all(color: PdfColors.grey700, width: .6),
              cellPadding: const pw.EdgeInsets.all(5),
            ),
          ],
          pw.SizedBox(height: 22),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(_closing.text), pw.SizedBox(height: 8),
            pw.Text(AuthStore.instance.current?.name ?? 'Chief Executive Officer',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('Chief Executive Officer'),
          ]),
        ],
      ));
      return pdf.save();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final bytes = await _bytes(); if (bytes == null) return;
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  Future<void> _share() async {
    final bytes = await _bytes(); if (bytes == null) return;
    final out = await dispatchPdf(bytes: bytes, filename: _filename());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(out.message)));
  }

  Future<void> _download() async {
    final bytes = await _bytes(); if (bytes == null) return;
    final out = await savePdf(bytes: bytes, filename: _filename());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(out.message)));
  }

  Future<void> _clear() async {
    for (final c in [_recipient, _address, _subject, _body]) { c.clear(); }
    _closing.text = 'Yours faithfully,';
    await localWrite(_draftKey, '');
  }

  String _filename() => 'mtek_official_letter_${DateTime.now().millisecondsSinceEpoch}.pdf';
  static String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
