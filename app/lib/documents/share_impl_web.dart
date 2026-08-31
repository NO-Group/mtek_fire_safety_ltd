import 'dart:html' as html;
import 'dart:typed_data';

import 'share_service.dart';

/// Web/PWA implementation: share_plus cannot attach files to WhatsApp on
/// the web, so the fallback becomes the primary — trigger a browser
/// download of the PDF (goes to Downloads), user attaches it in the app
/// they choose. NO pre-filled text is ever generated (owner directive).
Future<ShareOutcome> dispatchPdfImpl({
  required Uint8List bytes,
  required String filename,
}) async {
  try {
    final blob = html.Blob([bytes], 'application/pdf');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..download = filename
      ..click();
    html.Url.revokeObjectUrl(url);
    return const ShareOutcome(ShareResult.savedOnly,
        'PDF downloaded — attach it in WhatsApp, Gmail or your chosen app.');
  } catch (e) {
    return ShareOutcome(ShareResult.failed, 'Browser download failed: $e');
  }
}
