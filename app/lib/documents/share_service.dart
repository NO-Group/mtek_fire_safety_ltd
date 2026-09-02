import 'dart:typed_data';

/// Export & dispatch pipeline (owner directive 2026-08-30):
///   PDF bytes → timestamped local cache file → native share sheet with the
///   PDF FILE ONLY (no pre-filled text — the OS picker offers WhatsApp, Gmail,
///   Drive, Bluetooth…). Fallback: save to device storage + toast.
///
/// Platform split via conditional imports:
///   io: path_provider + share_plus (Android/Windows/iOS/desktop)
///   web: browser download (fallback) — share_plus is limited on web.
import 'share_impl_io.dart' if (dart.library.html) 'share_impl_web.dart';
export 'share_impl_io.dart' if (dart.library.html) 'share_impl_web.dart';

enum ShareResult { shared, savedOnly, failed }

class ShareOutcome {
  final ShareResult result;
  final String message; // user-facing toast text
  const ShareOutcome(this.result, this.message);
}

/// Calls the platform implementation selected by the conditional export above.
Future<ShareOutcome> dispatchPdf({
  required Uint8List bytes,
  required String filename,
}) =>
    dispatchPdfImpl(bytes: bytes, filename: filename);

/// Saves the PDF to a user-accessible location WITHOUT opening the share
/// sheet — the explicit "Download" action (owner request): Downloads folder
/// on desktop, the app's documents area on Android, a browser download on
/// web. Returns a user-safe outcome (never a raw filesystem path).
Future<ShareOutcome> savePdf({
  required Uint8List bytes,
  required String filename,
}) =>
    savePdfImpl(bytes: bytes, filename: filename);
