import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' hide ShareResult;

import 'share_service.dart';

/// IO implementation: cache the PDF with a timestamped name, then open the
/// system share sheet with the PDF FILE ONLY — never pre-filled text
/// (owner directive: the document speaks for itself; WhatsApp/Gmail/Drive
/// targets are picked by the user in the OS sheet). On failure, keep the
/// file and report savedOnly so the UI can toast its location.
Future<ShareOutcome> dispatchPdfImpl({
  required Uint8List bytes,
  required String filename,
}) async {
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    try {
      final xfile = XFile(file.path, mimeType: 'application/pdf');
      await Share.shareXFiles([xfile], subject: filename);
      return const ShareOutcome(ShareResult.shared,
          'PDF attached — pick WhatsApp, Gmail or any app in the share sheet.');
    } catch (shareErr) {
      // Fallback: keep the file, tell the user where.
      return ShareOutcome(ShareResult.savedOnly,
          'Share sheet unavailable — PDF saved to app cache: ${file.path}');
    }
  } catch (e) {
    return ShareOutcome(ShareResult.failed, 'Could not write PDF: $e');
  }
}
