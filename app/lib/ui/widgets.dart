import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/env.dart';
import '../data/store.dart';

import '../core/format.dart' as fmt;
import '../core/theme.dart';

/// Small reusable building blocks shared by all screens — the single source
/// of the app's visual language (hero headers, gradient stat cards, status
/// chips, empty states, section titles).

/// Hero page header: gradient accent tile + title + subtitle + actions.
class PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final IconData? icon;
  const PageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.actions = const [],
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: Mtek.brandGradient,
            borderRadius: BorderRadius.circular(13),
            boxShadow: Mtek.softShadow,
          ),
          child: Icon(icon ?? Icons.grid_view_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                      letterSpacing: -0.4,
                    ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 640 && actions.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            identity,
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        );
      }
      return Row(children: [
        Expanded(child: identity),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: actions,
            ),
          ),
        ],
      ]);
    });
  }
}

/// Uppercase tracked section label with a gold accent tick — used between
/// stat bands and detail sections to give the page rhythm.
class SectionTitle extends StatelessWidget {
  final String label;
  final Widget? trailing;
  const SectionTitle(this.label, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            gradient: Mtek.goldGradient,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w800,
            color: Mtek.gray600,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Gradient-accented stat card for the money/stock headline figures.
class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  final IconData icon;
  final Color? accent;
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.hint,
    this.accent,
  });

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
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          color: Mtek.gray500, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(value,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800, color: Mtek.ink)),
            if (hint != null) ...[
              const SizedBox(height: 5),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(hint!,
                        style: const TextStyle(color: Mtek.gray500, fontSize: 11.5)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small inline metric pill — used inside headers or row bands.
class MetricPill extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? accent;
  const MetricPill({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Mtek.brand600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Mtek.gray200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 10.5, color: Mtek.gray500)),
              Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800, color: Mtek.ink)),
            ],
          ),
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const StatusChip(this.label, {super.key, required this.bg, required this.fg});

  const StatusChip.paid(String label, {Key? key})
      : this(label, key: key, bg: Mtek.successTint, fg: Mtek.success);
  const StatusChip.pending(String label, {Key? key})
      : this(label, key: key, bg: Mtek.warnTint, fg: Mtek.warn);
  const StatusChip.bad(String label, {Key? key})
      : this(label, key: key, bg: Mtek.dangerTint, fg: Mtek.danger);
  const StatusChip.neutral(String label, {Key? key})
      : this(label, key: key, bg: Mtek.gray100, fg: Mtek.gray600);
  const StatusChip.info(String label, {Key? key})
      : this(label, key: key, bg: Mtek.infoTint, fg: Mtek.info);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: .18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
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
      'PaymentMethod.pos': (Icons.point_of_sale_outlined, Mtek.gold600),
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
  final double? size;
  const AmountText(this.amount, {super.key, this.bold = true, this.color, this.size});

  @override
  Widget build(BuildContext context) {
    return Text(
      fmt.naira(amount),
      style: TextStyle(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        color: color ?? Mtek.ink,
        fontSize: size,
      ),
    );
  }
}

/// Friendly empty state: soft icon plate + message (never raw exceptions).
class EmptyHint extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyHint(this.message, {super.key, this.icon = Icons.inbox_outlined});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Mtek.gray100,
                shape: BoxShape.circle,
                border: Border.all(color: Mtek.gray200),
              ),
              child: Icon(icon, size: 28, color: Mtek.gray400),
            ),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Mtek.gray500, fontSize: 13.5)),
          ],
        ),
      ),
    );
  }
}

/// Reusable search field with the app's standard styling.
class SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  const SearchField({super.key, required this.hint, required this.onChanged, this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, color: Mtek.gray400),
        hintText: hint,
        suffixIcon: controller != null
            ? IconButton(
                icon: const Icon(Icons.close, size: 18, color: Mtek.gray400),
                onPressed: () {
                  controller!.clear();
                  onChanged('');
                },
              )
            : null,
      ),
      onChanged: onChanged,
    );
  }
}

/// Avatar initials bubble, brand-tinted — used for customers, staff, stock.
class InitialsAvatar extends StatelessWidget {
  final String text;
  final Color? background;
  final Color? foreground;
  final double radius;
  const InitialsAvatar(
    this.text, {
    super.key,
    this.background,
    this.foreground,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final bg = background ?? Mtek.brand600;
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: Text(
        text,
        style: TextStyle(
          color: foreground ?? Colors.white,
          fontSize: radius * 0.62,
          fontWeight: FontWeight.w700,
        ),
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
      decoration: BoxDecoration(
        color: Mtek.gray100,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? const Icon(Icons.broken_image_outlined, size: 18, color: Mtek.gray400)
          : Image.memory(bytes, width: size, height: size, fit: BoxFit.cover),
    );
  }
}


/// "Load older …" footer for history lists: asks the store for records
/// older than the latest 300 the server bootstrap carries.
class LoadOlderTile extends StatefulWidget {
  final String kind; // sales | receipts | invoices | transactions | mils | docs
  const LoadOlderTile(this.kind, {super.key});
  @override
  State<LoadOlderTile> createState() => _LoadOlderTileState();
}

class _LoadOlderTileState extends State<LoadOlderTile> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    if (!Env.apiConfigured || store.exhaustedHistory.contains(widget.kind)) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: TextButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  final n = await store.loadOlder(widget.kind);
                  if (!mounted) return;
                  setState(() => _busy = false);
                  if (n == 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No older records on the server')));
                  }
                },
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.history),
          label: const Text('Load older records'),
        ),
      ),
    );
  }
}
