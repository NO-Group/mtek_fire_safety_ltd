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

/// Shared full-bleed background for every generated PDF.
///
/// The rightmost 28.57% is the brand's dark blue. All former micro-text and
/// repeated watermark bands have been removed; a single large, centred mark
/// is retained for document identity without cluttering the typesetting.
pw.Widget documentBackground(pw.ImageProvider? logo, PdfPageFormat format) {
  return pw.Stack(children: [
    pw.Positioned(left: 0, top: 0, right: 0, bottom: 0, child: pw.Container(color: PdfColors.white)),
    pw.Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: pw.Container(width: format.width * 0.2857, color: PdfColors.blue900),
    ),
    // A lightly translucent paper surface keeps black body copy legible when
    // it crosses the blue panel, while the full-bleed panel remains visible
    // around the page and subtly through the printable area.
    pw.Positioned(
      left: 14,
      top: 12,
      right: 14,
      bottom: 12,
      child: pw.Opacity(opacity: 0.94, child: pw.Container(color: PdfColors.white)),
    ),
    pw.Positioned(
      left: 0,
      top: 0,
      right: 0,
      bottom: 0,
      child: pw.Center(
        child: pw.Opacity(
          opacity: 0.07,
          child: pw.Column(mainAxisSize: pw.MainAxisSize.min, children: [
            if (logo != null) pw.Image(logo, width: 155, height: 155),
            pw.SizedBox(height: 8),
            pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              child: pw.Text(MtekBranding.watermarkBrandText,
                  maxLines: 1,
                  style: pw.TextStyle(
                      fontSize: 30,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.blueGrey300)),
            ),
          ]),
        ),
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

/// Corporate letterhead used identically on every document. It contains only
/// the head office and is sized so it never wraps on A4 portrait
/// (the narrowest page): company name on ONE line, the equipment catalogue
/// as a two-column table (label column | text), office block on the right.
pw.Widget corporateHeader(pw.ImageProvider? logo) {
  const labelW = 78.0;

  pw.Widget equip(String label, String body) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 1),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(
            width: labelW,
            child: pw.Text(label,
                style: pw.TextStyle(
                    fontSize: 5.5,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.red800)),
          ),
          pw.Expanded(
            child: pw.Text(body.replaceAll(RegExp(r'^[A-Z ]+: '), ''),
                style: const pw.TextStyle(fontSize: 5.5, lineSpacing: 0.5)),
          ),
        ]),
      );

  pw.Widget officeLine(String label, String body) => pw.RichText(
        text: pw.TextSpan(
          style: const pw.TextStyle(fontSize: 5.9, lineSpacing: 1),
          children: [
            pw.TextSpan(
                text: '$label ',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
            pw.TextSpan(text: body),
          ],
        ),
      );

  return pw.Container(
    color: PdfColors.white,
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Column(children: [
      // The wordmark owns the full available header width and is constrained
      // to one line. FittedBox scales long text rather than allowing a break.
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (logo != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(right: 8, top: 1),
            child: pw.Image(logo, width: 52, height: 52),
          ),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(
              height: 24,
              child: pw.FittedBox(
                fit: pw.BoxFit.scaleDown,
                alignment: pw.Alignment.centerLeft,
                child: pw.Text(
                  MtekBranding.companyName,
                  maxLines: 1,
                  softWrap: false,
                  style: pw.TextStyle(
                    fontSize: 19,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.red900,
                    letterSpacing: 0.35,
                  ),
                ),
              ),
            ),
            // Required service strapline: bold and directly beneath name.
            pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                MtekBranding.servicesLine,
                maxLines: 1,
                softWrap: false,
                style: pw.TextStyle(
                  fontSize: 7.1,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue900,
                ),
              ),
            ),
            pw.SizedBox(height: 3),
            equip('FIRE EQUIPMENT:', MtekBranding.fireEquipment),
            equip('SAFETY EQUIPMENT:', MtekBranding.safetyEquipment),
            equip('SECURITY EQUIPMENT:', MtekBranding.securityEquipment),
            equip('SOLAR EQUIPMENT:', MtekBranding.solarEquipment),
          ]),
        ),
        pw.SizedBox(width: 8),
        pw.Container(
          width: 168,
          padding: const pw.EdgeInsets.fromLTRB(6, 5, 6, 5),
          decoration: pw.BoxDecoration(
            color: PdfColors.blue50,
            border: pw.Border.all(color: PdfColors.blue300, width: .8),
          ),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(MtekBranding.rcNumber,
                style: pw.TextStyle(
                    fontSize: 6.3,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.red900)),
            pw.SizedBox(height: 2),
            officeLine('HEAD OFFICE:',
                'YY12, Kazaure Road, By Lagos Street Round About, Kaduna.'),
            officeLine('Tel:', MtekBranding.headOfficeTel.replaceFirst('Tel: ', '')),
            pw.SizedBox(height: 2),
            officeLine('E-mail:', MtekBranding.email),
            officeLine('Website:', MtekBranding.website),
          ]),
        ),
      ]),
      pw.Container(
          height: 2.2,
          color: PdfColors.red900,
          margin: const pw.EdgeInsets.only(top: 5)),
      pw.Container(
          height: 0.8,
          color: PdfColors.blue900,
          margin: const pw.EdgeInsets.only(top: 1.2)),
    ]),
  );
}

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
          child: pw.SizedBox(
            height: fontSize + 3,
            child: pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: pw.Alignment.bottomLeft,
              child: pw.Text(
                value,
                maxLines: 1,
                softWrap: false,
                style: pw.TextStyle(fontSize: fontSize + 1),
              ),
            ),
          ),
        ),
      ),
    ]),
  );
}
