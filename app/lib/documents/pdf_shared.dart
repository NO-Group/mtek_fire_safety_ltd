import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'branding.dart';

/// Loads DejaVu font pair (bundled) so ₦ (U+20A6) and ✓ render correctly
/// in generated PDFs. Call [load] once (generator startup), then use the
/// getters.
class MtekPdfFonts {
  static pw.Font? _base;
  static pw.Font? _bold;

  static bool get ready => _base != null && _bold != null;
  static pw.Font get base => _base!;
  static pw.Font get bold => _bold!;

  static Future<void> load() async {
    _base ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  }
}

/// Faint background watermark — owner request (2026-08-29). Large rotated
/// brand block at ~5% + micro-text bands, echoing the security pattern of
/// the physical carbon-copy books.
pw.Widget documentWatermark(pw.ImageProvider? logo) {
  pw.Widget microBand() => pw.Wrap(
        spacing: 6,
        runSpacing: 3,
        children: [
          for (var i = 0; i < 14; i++)
            pw.Text('${MtekBranding.watermarkBrandText} · ${MtekBranding.watermarkRcText} · ',
                style: pw.TextStyle(fontSize: 5, color: PdfColors.grey400)),
        ],
      );

  return pw.Stack(alignment: pw.Alignment.center, children: [
    pw.Column(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      microBand(),
      microBand(),
    ]),
    pw.Opacity(
      opacity: 0.055,
      child: pw.Transform.rotate(
        angle: 0.32,
        child: pw.Column(mainAxisSize: pw.MainAxisSize.min, children: [
          if (logo != null) pw.Image(logo, width: 150, height: 150),
          pw.SizedBox(height: 8),
          pw.Text(MtekBranding.watermarkBrandText,
              style: pw.TextStyle(
                  fontSize: 32, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey300)),
          pw.Text(MtekBranding.watermarkRcText,
              style: pw.TextStyle(fontSize: 14, color: PdfColors.blueGrey300)),
        ]),
      ),
    ),
  ]);
}

/// Small verification QR + hash footer (tamper-evidence, SPEC §12.2).
pw.Widget verificationFooter(String docType, int serial, String payload) {
  final hash = _fnv('$docType|$serial|$payload');
  return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
    pw.Container(
      width: 30,
      height: 30,
      child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: hash, width: 30, height: 30),
    ),
    pw.SizedBox(width: 6),
    pw.Text('Scan to verify',
        style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey600)),
  ]);
}


String _fnv(String input) {
  var h = 0x811c9dc5;
  for (final c in utf8.encode(input)) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Corporate header used IDENTICALLY on all three documents
/// (owner decision: consistent dual-office headers).
pw.Widget corporateHeader(pw.ImageProvider? logo) {
  return pw.Column(children: [
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      if (logo != null) pw.Padding(padding: const pw.EdgeInsets.only(right: 8), child: pw.Image(logo, width: 52, height: 52)),
      pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(MtekBranding.companyName,
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.red900)),
          pw.Text(MtekBranding.servicesLine,
              style: const pw.TextStyle(fontSize: 6.5)),
          pw.SizedBox(height: 2),
          _equipLine('FIRE EQUIPMENT:', MtekBranding.fireEquipment),
          _equipLine('SAFETY EQUIPMENT:', MtekBranding.safetyEquipment),
          _equipLine('SECURITY EQUIPMENT:', MtekBranding.securityEquipment),
          _equipLine('SOLAR EQUIPMENT:', MtekBranding.solarEquipment),
        ]),
      ),
      pw.SizedBox(width: 10),
      pw.Container(
        width: 190,
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.blue300, width: 1),
        ),
        child: pw.Text(MtekBranding.dualOfficeBlock,
            style: const pw.TextStyle(fontSize: 6.5)),
      ),
    ]),
    pw.Container(height: 2, color: PdfColors.red900, margin: const pw.EdgeInsets.only(top: 5)),
  ]);
}

pw.Widget _equipLine(String label, String body) => pw.Row(children: [
      pw.Text(label, style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
      pw.Expanded(child: pw.Text(body.replaceAll(RegExp(r'^[A-Z ]+: '), ''), style: const pw.TextStyle(fontSize: 6))),
    ]);

/// Shared small helpers -------------------------------------------------

Uint8List? dataUrlToBytes(String? dataUrl) {
  if (dataUrl == null || !dataUrl.contains(',')) return null;
  try {
    return base64Decode(dataUrl.split(',').last);
  } catch (_) {
    return null;
  }
}

pw.Widget checkboxCell(String label, bool checked) {
  return pw.Row(children: [
    pw.Container(
      width: 9,
      height: 9,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: .8)),
      alignment: pw.Alignment.center,
      child: checked
          ? pw.Text('✓', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))
          : null,
    ),
    pw.SizedBox(width: 4),
    pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
  ]);
}

pw.Widget ruledField(String label, {String value = '', double fontSize = 8.5, bool boldLabel = true}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
      pw.Text(label, style: pw.TextStyle(fontSize: fontSize, fontWeight: boldLabel ? pw.FontWeight.bold : pw.FontWeight.normal)),
      pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(left: 3),
          padding: const pw.EdgeInsets.only(bottom: 1, left: 2),
          decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey600, width: .7))),
          child: pw.Text(value, style: pw.TextStyle(fontSize: fontSize + 1)),
        ),
      ),
    ]),
  );
}
