import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/format.dart' as fmt;
import '../core/theme.dart';

/// Small reusable building blocks shared by all screens.

class PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  const PageHeader({super.key, required this.title, required this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: Mtek.ink)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(color: Mtek.gray500)),
            ],
          ),
        ),
        ...actions,
      ],
    );
  }
}

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  final IconData icon;
  final Color? accent;
  const StatCard({super.key, required this.label, required this.value, required this.icon, this.hint, this.accent});

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Mtek.brand600;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: color.withOpacity(.1), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: const TextStyle(color: Mtek.gray500, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 14),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Mtek.ink)),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint!, style: const TextStyle(color: Mtek.gray500, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const StatusChip(this.label, {super.key, required this.bg, required this.fg});

  const StatusChip.paid(String label, {super.key})
      : this(label, bg: Mtek.successTint, fg: Mtek.success);
  const StatusChip.pending(String label, {super.key})
      : this(label, bg: Mtek.warnTint, fg: Mtek.warn);
  const StatusChip.bad(String label, {super.key})
      : this(label, bg: Mtek.dangerTint, fg: Mtek.danger);
  const StatusChip.neutral(String label, {super.key})
      : this(label, bg: Mtek.gray100, fg: Mtek.gray600);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class MethodIcon extends StatelessWidget {
  final dynamic method; // PaymentMethod
  const MethodIcon(this.method, {super.key});

  @override
  Widget build(BuildContext context) {
    final map = <String, (IconData, Color)>{
      'PaymentMethod.cash': (Icons.payments_outlined, Mtek.success),
      'PaymentMethod.transfer': (Icons.account_balance_outlined, Mtek.navy700),
      'PaymentMethod.pos': (Icons.point_of_sale_outlined, Mtek.gold500),
      'PaymentMethod.credit': (Icons.credit_score_outlined, Mtek.brand600),
    };
    final entry = map[method.toString()];
    if (entry == null) return const SizedBox.shrink();
    return Icon(entry.$1, size: 18, color: entry.$2);
  }

  static String label(dynamic method) => method
      .toString()
      .split('.')
      .last
      .replaceAllMapped(RegExp(r'^[a-z]'), (m) => m.group(0)!.toUpperCase());
}

class AmountText extends StatelessWidget {
  final num amount;
  final bool bold;
  final Color? color;
  const AmountText(this.amount, {super.key, this.bold = true, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      fmt.naira(amount),
      style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: color ?? Mtek.ink),
    );
  }
}

class EmptyHint extends StatelessWidget {
  final String message;
  const EmptyHint(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Mtek.gray500)),
      ),
    );
  }
}


// =====================================================================
// REAL device attachments (owner directive: no dead buttons, no demos)
// =====================================================================

/// Opens the device picker for real site photos (camera gallery / files).
/// Returns data URLs (base64) ready to store with the MILS job.
Future<List<String>?> pickMilsPhotos() async {
  final res = await FilePicker.platform
      .pickFiles(type: FileType.image, allowMultiple: true, withData: true);
  if (res == null || res.files.isEmpty) return null;
  final out = <String>[];
  for (final f in res.files) {
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) continue;
    final ext = (f.extension ?? 'jpg').toLowerCase();
    final mime = ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    out.add('data:$mime;base64,${base64Encode(bytes)}');
  }
  return out.isEmpty ? null : out;
}

/// Picks the owner's updated products_seed.txt (stock import, CEO only).
/// Returns the file content as text, or null when cancelled.
Future<String?> pickProductsTxt() async {
  final res = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['txt', 'tsv', 'csv'], withData: true);
  final f = res?.files.single;
  if (f == null) return null;
  if (f.bytes != null && f.bytes!.isNotEmpty) return String.fromCharCodes(f.bytes!);
  return null;
}

/// Decoded preview of a stored data-URL photo.
class MilsPhotoImage extends StatelessWidget {
  final String dataUrl;
  final double size;
  const MilsPhotoImage({super.key, required this.dataUrl, this.size = 64});

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(dataUrl.split(',').last);
    } catch (_) {
      bytes = null;
    }
    return Container(
      width: size,
      height: size,
      color: Mtek.gray100,
      child: bytes == null
          ? const Icon(Icons.broken_image_outlined, size: 18, color: Mtek.gray400)
          : Image.memory(bytes, width: size, height: size, fit: BoxFit.cover),
    );
  }
}
